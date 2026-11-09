@tool
extends RefCounted
## One conversation with Claude Code, run as a child process:
##   claude -p --input-format stream-json --output-format stream-json ...
## Messages go to its stdin as JSON lines; its stdout (JSON lines) is turned into signals.
## The process is persistent (MCP servers are not restarted for every message) and started on the first
## message. The conversation id is kept in the project, so `claude --resume <id>` continues it in a terminal.
##
## Pipes are read without blocking (OS.execute_with_pipe, Godot 4.5+); the plugin calls poll() every frame.

signal init_received(info: Dictionary)
## Kind of block Claude just started writing: "text", "thinking" or "tool_use".
signal block_started(kind: String)
signal text_delta(message_id: String, index: int, delta: String)
## A finished content block of an assistant message (text, tool_use, thinking).
signal assistant_block(message_id: String, block: Dictionary)
signal tool_result(tool_use_id: String, content: String, is_error: bool)
signal turn_finished(result: Dictionary)
signal notice(message: String, is_error: bool)
signal state_changed

const SETTING_CLAUDE_PATH := "godot_mcp/claude_path"
const SETTING_SERVER_PATH := "godot_mcp/server_path"
const SETTING_EXTRA_ARGS := "godot_mcp/claude_extra_args"
const STATE_FILE := "res://.godot/godot_mcp_chat.json"
const MCP_CONFIG_FILE := "res://.godot/godot_mcp_mcp.json"
const MIN_GODOT_HEX := 0x040500
const MAX_MESSAGE_BYTES := 120000
const READ_CHUNK := 65536
const LINES_PER_POLL := 400
const GRACEFUL_STOP_MSEC := 1500
const INTERRUPT_GRACE_MSEC := 6000

const SYSTEM_PROMPT := "You are running inside the chat dock of the Godot editor (project: %s). " \
	+ "The godot MCP tools drive this very editor (scenes, nodes, scripts, run). " \
	+ "The editor's Todo dock is shared with the user through todo_list / todo_add / todo_update / todo_remove. " \
	+ "The user reads your replies in a narrow dock: be concise and avoid wide tables."

## Id of the conversation (empty until the first message).
var session_id := ""
var running := false
## A turn is in progress (a message was sent and no result has come back yet).
var busy := false
var model := ""
var mcp_servers: Array = []
var last_error := ""
## Port of this editor's WebSocket server (0 = not listening). The MCP server given to claude must use
## it, otherwise a second editor open on another project would drive the first one.
var godot_port := 0

var _pid := -1
var _stdio: FileAccess
var _stderr: FileAccess
var _out := PackedByteArray()
var _stderr_tail := ""
var _resume := false
var _got_init := false
var _spawned_at := 0
var _last_sent := ""
var _retrying := false
var _closing_since := 0
var _interrupt_deadline := 0
var _interrupted := false
var _message_id := ""
var _request_count := 0
var _project_name := ""


func _init() -> void:
	_project_name = str(ProjectSettings.get_setting("application/config/name", ""))
	_load_state()


# --- Public API ----------------------------------------------------------------

## True when this Godot can run the chat (non-blocking pipes need 4.5).
static func is_supported() -> bool:
	return int(Engine.get_version_info()["hex"]) >= MIN_GODOT_HEX


## Command a user can paste in a terminal (from the project folder) to continue this conversation.
func resume_command() -> String:
	return "claude --resume %s" % session_id if not session_id.is_empty() else "claude"


func project_dir() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/")


## Sends a user message (starting the process if needed). Returns false when it could not be sent.
func send(text: String) -> bool:
	if text.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		notice.emit("Message trop long (%d Ko max)." % (MAX_MESSAGE_BYTES / 1000), true)
		return false
	if not _ensure_running():
		return false
	_last_sent = text
	_interrupted = false
	busy = true
	_write({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}})
	state_changed.emit()
	return true


## Asks Claude to stop what it is doing; the process stays usable. Forces a stop if it does not react.
func interrupt() -> void:
	if not running or not busy:
		return
	_interrupted = true
	_request_count += 1
	_write({"type": "control_request", "request_id": "req_%d" % _request_count, "request": {"subtype": "interrupt"}})
	_interrupt_deadline = Time.get_ticks_msec() + INTERRUPT_GRACE_MSEC


## Ends the process (the conversation can be resumed by the next message).
func stop() -> void:
	if not running or _closing_since != 0:
		return
	_closing_since = Time.get_ticks_msec()
	if _stdio:
		_stdio.close()  # EOF on stdin: claude finishes cleanly and stops its MCP servers
		_stdio = null


## Stops now and waits a moment for a clean exit (editor shutdown). Never leaves a process behind.
func shutdown() -> void:
	stop()
	var waited := 0
	while running and OS.is_process_running(_pid) and waited < GRACEFUL_STOP_MSEC:
		OS.delay_msec(50)
		waited += 50
	if running and OS.is_process_running(_pid):
		OS.kill(_pid)
	_reset_process()


func new_conversation() -> void:
	stop()  # its output is ignored from now on (stdout is closed); a new process starts with the next message
	session_id = ""
	_resume = false
	model = ""
	mcp_servers = []
	busy = false
	_save_state()
	state_changed.emit()


## Called every frame by the plugin.
func poll() -> void:
	if _pid <= 0:
		return
	_read_pipes()
	var now := Time.get_ticks_msec()
	if not OS.is_process_running(_pid):
		_read_pipes()  # whatever was written just before exiting
		_on_exited()
		return
	if _closing_since != 0 and now - _closing_since > GRACEFUL_STOP_MSEC:
		OS.kill(_pid)
	elif _interrupt_deadline != 0 and busy and now > _interrupt_deadline:
		_interrupt_deadline = 0
		stop()  # it ignored the interrupt: restart it with the next message


# --- Process -------------------------------------------------------------------

func resolve_claude_path() -> String:
	var settings := EditorInterface.get_editor_settings()
	if settings.has_setting(SETTING_CLAUDE_PATH):
		var custom := str(settings.get_setting(SETTING_CLAUDE_PATH)).strip_edges()
		if not custom.is_empty():
			return custom
	var home := OS.get_environment("USERPROFILE" if OS.get_name() == "Windows" else "HOME").replace("\\", "/")
	var candidates := []
	if OS.get_name() == "Windows":
		candidates = [home + "/.local/bin/claude.exe"]
	else:
		candidates = [home + "/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return "claude"  # let the OS look it up in PATH


func _ensure_running() -> bool:
	if running and _closing_since == 0:
		return true
	if running:
		shutdown()  # was being closed: finish before starting again
	if not is_supported():
		notice.emit("Le chat nécessite Godot 4.5 ou plus récent (version actuelle : %s)." % Engine.get_version_info()["string"], true)
		return false
	if session_id.is_empty():
		session_id = _new_uuid()
		_resume = false
	var path := resolve_claude_path()
	var info = OS.callv("execute_with_pipe", [path, _build_args(), false])
	if not (info is Dictionary) or info.is_empty() or int(info.get("pid", -1)) <= 0:
		last_error = "Impossible de lancer « %s ». Installe Claude Code (claude.ai/install) ou indique son chemin dans Éditeur > Paramètres de l'éditeur > Godot Mcp." % path
		notice.emit(last_error, true)
		return false
	_pid = int(info["pid"])
	_stdio = info["stdio"]
	_stderr = info["stderr"]
	running = true
	_got_init = false
	_closing_since = 0
	_interrupt_deadline = 0
	_spawned_at = Time.get_ticks_msec()
	_out.clear()
	_stderr_tail = ""
	_save_state()
	state_changed.emit()
	return true


func _build_args() -> PackedStringArray:
	var args := PackedStringArray([
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--include-partial-messages",
		"--permission-mode", "bypassPermissions",
		"--resume" if _resume else "--session-id", session_id,
		"--append-system-prompt", SYSTEM_PROMPT % _project_name,
	])
	var mcp_config := _write_mcp_config()
	if not mcp_config.is_empty():
		args.append_array(["--mcp-config", mcp_config])
	var settings := EditorInterface.get_editor_settings()
	if settings.has_setting(SETTING_EXTRA_ARGS):
		args.append_array(split_args(str(settings.get_setting(SETTING_EXTRA_ARGS))))
	return args


## --mcp-config with the godot MCP server, when its location is known (Editor Settings > Godot Mcp).
## Otherwise claude uses whatever MCP servers the user declared with `claude mcp add`.
func _write_mcp_config() -> String:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_SERVER_PATH):
		return ""
	var server := str(settings.get_setting(SETTING_SERVER_PATH)).strip_edges()
	if server.is_empty() or not FileAccess.file_exists(server):
		return ""
	if godot_port <= 0:
		notice.emit("Le serveur WebSocket du plugin n'écoute pas (voir la sortie de l'éditeur) : Claude ne pourra pas piloter cet éditeur.", true)
		return ""
	var env := {"GODOT_MCP_PORT": str(godot_port)}
	var token := OS.get_environment("GODOT_MCP_TOKEN")
	if token.is_empty() and ProjectSettings.has_setting("godot_mcp/token"):
		token = str(ProjectSettings.get_setting("godot_mcp/token"))
	if not token.is_empty():
		env["GODOT_MCP_TOKEN"] = token
	env["GODOT_PROJECT_PATH"] = project_dir()
	var config := {"mcpServers": {"godot": {"command": "node", "args": [server], "env": env}}}
	var file := FileAccess.open(MCP_CONFIG_FILE, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(config))
	file.close()
	return ProjectSettings.globalize_path(MCP_CONFIG_FILE)


func _write(message: Dictionary) -> void:
	if _stdio == null:
		return
	_stdio.store_string(JSON.stringify(message) + "\n")
	_stdio.flush()


func _read_pipes() -> void:
	if _stdio:
		var chunk := _stdio.get_buffer(READ_CHUNK)
		while not chunk.is_empty():
			_out.append_array(chunk)
			if _out.size() > 8 * 1024 * 1024:
				break  # parse what we have before reading more
			chunk = _stdio.get_buffer(READ_CHUNK)
	if _stderr:
		var err_chunk := _stderr.get_buffer(READ_CHUNK)
		if not err_chunk.is_empty():
			_stderr_tail = (_stderr_tail + err_chunk.get_string_from_utf8()).right(4000)
	var handled := 0
	var start := 0
	while handled < LINES_PER_POLL:
		var newline := _out.find(10, start)
		if newline < 0:
			break
		var line := _out.slice(start, newline).get_string_from_utf8().strip_edges()
		start = newline + 1
		handled += 1
		if not line.is_empty():
			_handle_line(line)
	if start > 0:
		_out = _out.slice(start)


func _on_exited() -> void:
	var was_busy := busy
	var tail := _stderr_tail.strip_edges()
	var early := Time.get_ticks_msec() - _spawned_at < 20000
	var requested := _closing_since != 0
	var resume_failed := _resume and not _got_init and early and not requested
	_reset_process()
	if resume_failed and not _retrying and not _last_sent.is_empty():
		# The saved conversation does not exist any more: start a fresh one with the same message.
		notice.emit("Conversation précédente introuvable : nouvelle conversation.", false)
		session_id = ""
		_resume = false
		_retrying = true
		var message := _last_sent
		send(message)
		_retrying = false
		return
	if was_busy and not requested:
		var message := "Claude s'est arrêté pendant la réponse."
		if not tail.is_empty():
			message += "\n" + tail.right(600)
		notice.emit(message, true)
		turn_finished.emit({"subtype": "process_exited", "is_error": true})
	elif not requested and not _got_init and not tail.is_empty():
		notice.emit("Claude n'a pas démarré :\n" + tail.right(600), true)
	state_changed.emit()


func _reset_process() -> void:
	running = false
	busy = false
	_pid = -1
	_stdio = null
	_stderr = null
	_out.clear()
	_closing_since = 0
	_interrupt_deadline = 0
	if _got_init and not session_id.is_empty():
		_resume = true  # a conversation that started can be resumed by the next message
		_save_state()


# --- Events from Claude Code ---------------------------------------------------

func _handle_line(line: String) -> void:
	var json := JSON.new()
	if json.parse(line) != OK or not (json.data is Dictionary):
		return  # not a protocol line (stray output)
	var event: Dictionary = json.data
	match str(event.get("type", "")):
		"system":
			_handle_system(event)
		"stream_event":
			if event.get("parent_tool_use_id") == null:
				_handle_stream(event.get("event", {}))
		"assistant":
			var message: Dictionary = event.get("message", {})
			for block in message.get("content", []):
				if block is Dictionary:
					assistant_block.emit(str(message.get("id", "")), block)
		"user":
			var content = event.get("message", {}).get("content")
			if content is Array:
				for block in content:
					if block is Dictionary and block.get("type") == "tool_result":
						tool_result.emit(str(block.get("tool_use_id", "")), _flatten(block.get("content")), bool(block.get("is_error", false)))
		"result":
			if not _got_init and bool(event.get("is_error", false)):
				return  # failed before the conversation started (e.g. resuming a missing one): handled when the process exits
			busy = false
			_interrupt_deadline = 0
			if _interrupted and str(event.get("subtype", "")) == "error_during_execution":
				event["interrupted"] = true
			_interrupted = false
			turn_finished.emit(event)
			state_changed.emit()
		"rate_limit_event":
			var info: Dictionary = event.get("rate_limit_info", {})
			if str(info.get("status", "allowed")) != "allowed":
				notice.emit("Limite d'utilisation de Claude atteinte (%s)." % str(info.get("rateLimitType", "")), true)


func _handle_system(event: Dictionary) -> void:
	match str(event.get("subtype", "")):
		"init":
			_got_init = true
			if not busy and _closing_since == 0:
				busy = true  # a queued message started its turn after the previous result
			session_id = str(event.get("session_id", session_id))
			model = str(event.get("model", model))
			mcp_servers = event.get("mcp_servers", [])
			_resume = true
			_save_state()
			init_received.emit(event)
			state_changed.emit()
		"api_retry":
			notice.emit("L'API a refusé la requête, nouvelle tentative…", false)


func _handle_stream(event: Dictionary) -> void:
	match str(event.get("type", "")):
		"message_start":
			_message_id = str(event.get("message", {}).get("id", ""))
		"content_block_start":
			block_started.emit(str(event.get("content_block", {}).get("type", "")))
		"content_block_delta":
			var delta: Dictionary = event.get("delta", {})
			if str(delta.get("type", "")) == "text_delta":
				text_delta.emit(_message_id, int(event.get("index", 0)), str(delta.get("text", "")))


## tool_result content is a string or a list of {type: text, text: ...} / images.
static func _flatten(content: Variant) -> String:
	if content is String:
		return content
	if content is Array:
		var parts := PackedStringArray()
		for part in content:
			if part is Dictionary and part.get("type") == "text":
				parts.append(str(part.get("text", "")))
			elif part is Dictionary:
				parts.append("[%s]" % str(part.get("type", "?")))
		return "\n".join(parts)
	return "" if content == null else str(content)


# --- Persistence and helpers ---------------------------------------------------

func _load_state() -> void:
	if not FileAccess.file_exists(STATE_FILE):
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(STATE_FILE)) == OK and json.data is Dictionary:
		session_id = str(json.data.get("session_id", ""))
		_resume = bool(json.data.get("started", false)) and not session_id.is_empty()
		if not _resume:
			session_id = ""


func _save_state() -> void:
	var file := FileAccess.open(STATE_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"session_id": session_id, "started": _resume}))
		file.close()


static func _new_uuid() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40  # version 4
	b[8] = (b[8] & 0x3f) | 0x80  # variant
	var hex := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]


## Splits "--model opus --foo 'a b'" into arguments (single and double quotes group words).
static func split_args(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	var quote := ""
	var has_token := false
	for ch in text:
		if quote.is_empty() and (ch == "\"" or ch == "'"):
			quote = ch
			has_token = true
		elif ch == quote:
			quote = ""
		elif quote.is_empty() and ch in [" ", "\t", "\n"]:
			if has_token:
				out.append(current)
				current = ""
				has_token = false
		else:
			current += ch
			has_token = true
	if has_token:
		out.append(current)
	return out
