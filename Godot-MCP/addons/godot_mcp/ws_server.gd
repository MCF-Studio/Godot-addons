@tool
extends RefCounted
## Local WebSocket server receiving JSON commands from the MCP server.
## Request:  {"id": 1, "method": "add_node", "params": {...}, "token": "..."}
## Response: {"id": 1, "result": ...} or {"id": 1, "error": {"message": "..."}}

const DEFAULT_PORT := 6505
const BUFFER_SIZE := 16 * 1024 * 1024
const LOGGER_SCRIPT := "res://addons/godot_mcp/mcp_logger.gd"

const COMMAND_SCRIPTS := [
	preload("commands/project_commands.gd"),
	preload("commands/scene_commands.gd"),
	preload("commands/node_commands.gd"),
	preload("commands/script_commands.gd"),
	preload("commands/todo_commands.gd"),
]

var plugin: EditorPlugin
## Ring buffer of editor log lines (Godot 4.5+), or null.
var logger: Object
## Todo list shown in the dock (set by the plugin), or null.
var todo_store: RefCounted
## Port the server actually listens on (0 when it could not start).
var listening_port := 0

var _tcp := TCPServer.new()
var _peers: Array[WebSocketPeer] = []
var _handlers := {}
var _commands := []
var _token := ""


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
	print("[Godot MCP] listening on 127.0.0.1:%d" % port)


func stop() -> void:
	listening_port = 0
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
	if not _token.is_empty() and str(msg.get("token", "")) != _token:
		_send(peer, {"id": id, "error": {"message": "Invalid or missing token"}})
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


func _send(peer: WebSocketPeer, data: Dictionary) -> void:
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		peer.send_text(JSON.stringify(data))
