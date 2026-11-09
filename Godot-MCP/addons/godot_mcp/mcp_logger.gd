extends Logger
## Captures editor log output into a ring buffer (Godot 4.5+ only; loaded conditionally).
## Logger callbacks can come from any thread, hence the mutex.

const MAX_LINES := 2000

var _lines: Array = []
var _mutex := Mutex.new()
var _ansi := RegEx.create_from_string("\u001b\\[[0-9;]*[A-Za-z]")
## Editor progress bars ("[ 42% ] save | ...", "[ DONE ] save") are noise.
var _progress := RegEx.create_from_string("^\\[\\s*(\\d+%|DONE)\\s*\\]")


func _log_message(message: String, error: bool) -> void:
	var text := _ansi.sub(message, "", true).strip_edges()
	if text.is_empty() or _progress.search(text):
		return
	_push({"type": "error" if error else "message", "text": text})


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
	var kind := "warning" if error_type == ERROR_TYPE_WARNING else "error"
	var text := rationale if not rationale.is_empty() else code
	_push({"type": kind, "text": text, "source": "%s:%d @ %s()" % [file, line, function]})


func get_lines(max_lines: int, errors_only: bool, clear: bool) -> Array:
	_mutex.lock()
	var out: Array = []
	for entry in _lines:
		if not errors_only or entry["type"] != "message":
			out.append(entry)
	if clear:
		_lines.clear()
	_mutex.unlock()
	return out.slice(maxi(0, out.size() - max_lines))


func _push(entry: Dictionary) -> void:
	entry["time"] = Time.get_time_string_from_system()
	_mutex.lock()
	_lines.append(entry)
	if _lines.size() > MAX_LINES:
		_lines = _lines.slice(_lines.size() - MAX_LINES)
	_mutex.unlock()
