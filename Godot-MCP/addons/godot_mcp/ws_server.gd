@tool
extends RefCounted
## Local WebSocket server receiving JSON commands from the MCP server.
## Request:  {"id": 1, "method": "add_node", "params": {...}, "token": "..."}
## Response: {"id": 1, "result": ...} or {"id": 1, "error": {"message": "..."}}
##
## Every request must carry the token. Without one configured (GODOT_MCP_TOKEN or the project setting
## godot_mcp/token), a random token is made at each start. Listening on 127.0.0.1 is not enough on its own:
## any web page open in a browser can open a WebSocket to 127.0.0.1, and Godot does not let us check the
## Origin header. The token is written to a session file only this user can read (see session_dir()),
## where the MCP server finds it; a web page cannot read local files.

const DEFAULT_PORT := 6505
const BUFFER_SIZE := 16 * 1024 * 1024
const LOGGER_SCRIPT := "res://addons/godot_mcp/mcp_logger.gd"

const COMMAND_SCRIPTS := [
	preload("commands/project_commands.gd"),
	preload("commands/scene_commands.gd"),
	preload("commands/node_commands.gd"),
	preload("commands/script_commands.gd"),
	preload("commands/todo_commands.gd"),  # outils todo_* : utiles seulement si l'addon MCF Todo est actif
]

var plugin: EditorPlugin
## Ring buffer of editor log lines (Godot 4.5+), or null.
var logger: Object
## Port the server actually listens on (0 when it could not start).
var listening_port := 0

var _tcp := TCPServer.new()
var _peers: Array[WebSocketPeer] = []
var _handlers := {}
var _commands := []
var _token := ""
var _session_file := ""


func _init(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	for script in COMMAND_SCRIPTS:
		var cmd = script.new(plugin, self)
		cmd.register(_handlers)
		_commands.append(cmd)


func start() -> void:
	var port := DEFAULT_PORT
	var explicit_port := true
	if OS.has_environment("GODOT_MCP_PORT"):
		port = int(OS.get_environment("GODOT_MCP_PORT"))
	elif ProjectSettings.has_setting("godot_mcp/port"):
		port = int(ProjectSettings.get_setting("godot_mcp/port"))
	else:
		explicit_port = false
	_token = OS.get_environment("GODOT_MCP_TOKEN")
	if _token.is_empty() and ProjectSettings.has_setting("godot_mcp/token"):
		_token = str(ProjectSettings.get_setting("godot_mcp/token"))
	if _token.is_empty():
		_token = Crypto.new().generate_random_bytes(32).hex_encode()

	if ClassDB.class_exists("Logger") and ResourceLoader.exists(LOGGER_SCRIPT):
		logger = load(LOGGER_SCRIPT).new()
		OS.call("add_logger", logger)

	var err := _tcp.listen(port, "127.0.0.1")
	if err != OK and not explicit_port:
		# Another editor (another project) already has the default port: take the next free one.
		# The chat dock hands this port to its own MCP server; other clients keep using the port they configured.
		for candidate in range(port + 1, port + 11):
			if _tcp.listen(candidate, "127.0.0.1") == OK:
				print("[Godot MCP] port %d is in use (another editor?), using %d instead" % [port, candidate])
				port = candidate
				err = OK
				break
	if err != OK:
		push_error("[Godot MCP] Cannot listen on 127.0.0.1:%d (%s). Is another editor already running the plugin?" % [port, error_string(err)])
		return
	listening_port = port
	_write_session_file()
	print("[Godot MCP] listening on 127.0.0.1:%d" % port)


## Token clients must send (the chat hands it to its own MCP server).
func token() -> String:
	return _token


func stop() -> void:
	listening_port = 0
	if not _session_file.is_empty():
		DirAccess.remove_absolute(_session_file)
		_session_file = ""
	for peer in _peers:
		peer.close()
	_peers.clear()
	_tcp.stop()
	# Commands hold a reference back to this server; break the cycle.
	_handlers.clear()
	_commands.clear()
	if logger:
		OS.call("remove_logger", logger)
		logger = null


func poll() -> void:
	if not _tcp.is_listening():
		return
	while _tcp.is_connection_available():
		var peer := WebSocketPeer.new()
		peer.inbound_buffer_size = BUFFER_SIZE
		peer.outbound_buffer_size = BUFFER_SIZE
		peer.accept_stream(_tcp.take_connection())
		_peers.append(peer)

	for peer in _peers.duplicate():
		peer.poll()
		match peer.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				while peer.get_available_packet_count() > 0:
					_handle(peer, peer.get_packet().get_string_from_utf8())
			WebSocketPeer.STATE_CLOSED:
				_peers.erase(peer)


func _handle(peer: WebSocketPeer, text: String) -> void:
	var msg = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY:
		_send(peer, {"id": null, "error": {"message": "Invalid JSON request"}})
		return
	var id = msg.get("id")
	if not _token_matches(str(msg.get("token", ""))):
		_send(peer, {"id": id, "error": {"message": "Invalid or missing token. The Godot MCP server reads it from %s (update the server if it is older than the addon), or set the same GODOT_MCP_TOKEN on both sides." % session_dir()}})
		peer.close(1008, "invalid token")
		return
	var method := str(msg.get("method", ""))
	if not _handlers.has(method):
		_send(peer, {"id": id, "error": {"message": "Unknown method: %s" % method}})
		return
	var params = msg.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}

	# Handlers may be coroutines (they await a frame after opening scenes, etc.).
	var result = await _handlers[method].call(params)
	if result is Dictionary and result.has("__error"):
		_send(peer, {"id": id, "error": {"message": str(result["__error"])}})
	else:
		_send(peer, {"id": id, "result": result})


## Compares in constant time, so the answer delay does not reveal how much of a guess was right.
func _token_matches(candidate: String) -> bool:
	var a := candidate.to_utf8_buffer()
	var b := _token.to_utf8_buffer()
	if a.size() != b.size():
		return false
	var diff := 0
	for i in a.size():
		diff |= a[i] ^ b[i]
	return diff == 0


# --- Session file ----------------------------------------------------------------
# One JSON file per running editor, read by the MCP server (token, and which editor has which project)
# and by its GDScript language-server bridge (the editor's LSP port). Removed when the plugin stops.

## <user config dir>/Godot/godot_mcp: %APPDATA% on Windows, ~/Library/Application Support on macOS,
## $XDG_CONFIG_HOME or ~/.config on Linux (the MCP server computes the same path).
static func session_dir() -> String:
	return OS.get_config_dir().replace("\\", "/").path_join("Godot/godot_mcp")


## Port of this editor's GDScript language server (editor setting). An editor started with --lsp-port
## cannot be detected (Godot hides its own options from scripts): clients then need GODOT_LSP_PORT.
## A wrong port is harmless: clients check which project the server they reach has open.
static func lsp_port() -> int:
	var settings := EditorInterface.get_editor_settings()
	if settings.has_setting("network/language_server/remote_port"):
		return int(settings.get_setting("network/language_server/remote_port"))
	return 6005


static func lsp_host() -> String:
	var settings := EditorInterface.get_editor_settings()
	if settings.has_setting("network/language_server/remote_host"):
		var host := str(settings.get_setting("network/language_server/remote_host")).strip_edges()
		if not host.is_empty():
			return host
	return "127.0.0.1"


func _write_session_file() -> void:
	var dir := session_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		push_warning("[Godot MCP] cannot create %s: MCP servers will need GODOT_MCP_TOKEN to connect." % dir)
		return
	var unix := OS.get_name() != "Windows"
	if unix:
		FileAccess.set_unix_permissions(dir, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER)
	var path := dir.path_join("editor-%d.json" % listening_port)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[Godot MCP] cannot write %s: MCP servers will need GODOT_MCP_TOKEN to connect." % path)
		return
	if unix:
		FileAccess.set_unix_permissions(path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	file.store_string(JSON.stringify({
		"version": 1,
		"port": listening_port,
		"token": _token,
		"pid": OS.get_process_id(),
		"project_path": ProjectSettings.globalize_path("res://").trim_suffix("/"),
		"godot_executable": OS.get_executable_path(),
		"godot_version": Engine.get_version_info()["string"],
		"lsp_host": lsp_host(),
		"lsp_port": lsp_port(),
		"started_at": int(Time.get_unix_time_from_system()),
	}, "  "))
	file.close()
	_session_file = path


func _send(peer: WebSocketPeer, data: Dictionary) -> void:
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		peer.send_text(JSON.stringify(data))
