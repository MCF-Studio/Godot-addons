@tool
extends RefCounted
## Todo list model and persistence (res://.godot_mcp/todo.json).
##
## Changes come from the dock UI, from MCP commands, or from someone editing the file by hand.
## `changed(source)` says which one ("ui", "mcp" or "external") so the UI can avoid
## re-rendering what it just did itself and never steals an edit in progress.

signal changed(source: String)
## Something the user should know about (corrupt file, write failure...).
signal warning(message: String)

const DIR := "res://.godot_mcp"
const PATH := "res://.godot_mcp/todo.json"
const VERSION := 1
const STATUSES := ["open", "doing", "done"]
const MAX_TEXT := 20000
const SAVE_DELAY_MSEC := 300
const CHECK_INTERVAL_MSEC := 1000
const TRASH_LIMIT := 20

## [{id, text, status, created, updated}]
var items: Array = []
var path := PATH
## Last warning raised (also emitted as a signal; kept for UIs created after the fact).
var last_warning := ""

var _trash: Array = []  # groups: [{item, index}, ...], most recent last
var _dirty := false
var _save_due := 0
var _next_check := 0
var _known_stat := []  # [exists, mtime, length] of the file as we last read/wrote it
var _known_hash := ""
var _backed_up_hash := ""


func _init(p_path: String = PATH) -> void:
	path = p_path
	load_from_disk("external", false)


# --- Queries -----------------------------------------------------------------

func find_index(id: String) -> int:
	for i in items.size():
		if items[i]["id"] == id:
			return i
	return -1


func get_item(id: String) -> Dictionary:
	var i := find_index(id)
	return items[i] if i >= 0 else {}


func counts() -> Dictionary:
	var c := {"open": 0, "doing": 0, "done": 0, "total": items.size()}
	for item in items:
		c[item["status"]] += 1
	return c


func can_undo_remove() -> bool:
	return not _trash.is_empty()


## Normalised text: unix newlines, trimmed, capped. Empty string when there is nothing to keep.
static func clean_text(text: String) -> String:
	text = text.replace("\r\n", "\n").replace("\r", "\n").strip_edges()
	if text.length() > MAX_TEXT:
		text = text.left(MAX_TEXT)
	return text


# --- Mutations ---------------------------------------------------------------

## Adds a task and returns it, or {} when the text is empty. index -1 = at the end, 0 = at the top.
func add(text: String, status: String = "open", index: int = -1, source: String = "ui") -> Dictionary:
	text = clean_text(text)
	if text.is_empty():
		return {}
	var now := int(Time.get_unix_time_from_system())
	var item := {
		"id": _new_id(),
		"text": text,
		"status": status if status in STATUSES else "open",
		"created": now,
		"updated": now,
	}
	if index < 0 or index >= items.size():
		items.append(item)
	else:
		items.insert(index, item)
	_touch(source)
	return item


## Changes `text` and/or `status` of a task. Returns false when the id is unknown or nothing is valid.
func update(id: String, fields: Dictionary, source: String = "ui") -> bool:
	var i := find_index(id)
	if i < 0:
		return false
	var item: Dictionary = items[i]
	var modified := false
	if fields.has("text"):
		var text := clean_text(str(fields["text"]))
		if text.is_empty():
			return false
		if text != item["text"]:
			item["text"] = text
			modified = true
	if fields.has("status"):
		var status := str(fields["status"])
		if not status in STATUSES:
			return false
		if status != item["status"]:
			item["status"] = status
			modified = true
	if modified:
		item["updated"] = int(Time.get_unix_time_from_system())
		_touch(source)
	return true


## Moves a task so that it ends up at `to_index` in the final list.
func move(id: String, to_index: int, source: String = "ui") -> bool:
	var from := find_index(id)
	if from < 0:
		return false
	to_index = clampi(to_index, 0, items.size() - 1)
	if to_index == from:
		return true
	var item: Dictionary = items[from]
	items.remove_at(from)
	items.insert(to_index, item)
	_touch(source)
	return true


## Removes tasks (they can be brought back with undo_remove). Returns how many were removed.
func remove(ids: Array, source: String = "ui") -> int:
	var group := []
	for i in range(items.size() - 1, -1, -1):
		if items[i]["id"] in ids:
			group.push_front({"item": items[i], "index": i})
			items.remove_at(i)
	if group.is_empty():
		return 0
	_trash.append(group)
	if _trash.size() > TRASH_LIMIT:
		_trash.pop_front()
	_touch(source)
	return group.size()


func clear_done(source: String = "ui") -> int:
	var ids := []
	for item in items:
		if item["status"] == "done":
			ids.append(item["id"])
	return remove(ids, source)


## Restores the most recent removal (all the tasks removed by that one call). Returns them.
func undo_remove(source: String = "ui") -> Array:
	if _trash.is_empty():
		return []
	var group: Array = _trash.pop_back()
	var restored := []
	for entry in group:  # ascending indexes, so each insert lands where it was
		var index := mini(int(entry["index"]), items.size())
		items.insert(index, entry["item"])
		restored.append(entry["item"])
	_touch(source)
	return restored


# --- Persistence -------------------------------------------------------------

## Call every frame: flushes pending saves and notices edits made to the file elsewhere.
func poll() -> void:
	var now := Time.get_ticks_msec()
	if _dirty and now >= _save_due:
		flush()
	if not _dirty and now >= _next_check:
		_next_check = now + CHECK_INTERVAL_MSEC
		if _stat() != _known_stat:
			load_from_disk("external")


## Writes pending changes now.
func flush() -> void:
	if not _dirty:
		return
	_dirty = false
	_write()


func _touch(source: String) -> void:
	_dirty = true
	_save_due = Time.get_ticks_msec() + SAVE_DELAY_MSEC
	changed.emit(source)


func _write() -> bool:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			_warn("Impossible de créer %s (%s)" % [dir, error_string(made)])
			return false
	var text := JSON.stringify({"version": VERSION, "items": items}, "\t")
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		_warn("Impossible d'écrire %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(text)
	file.close()
	var moved := DirAccess.rename_absolute(tmp, path)
	if moved != OK:
		_warn("Impossible de remplacer %s (%s)" % [path, error_string(moved)])
		return false
	_known_hash = text.sha256_text()
	_known_stat = _stat()
	return true


## Reads the file. A file we cannot parse is copied aside (never silently overwritten).
func load_from_disk(source: String = "external", notify: bool = true) -> void:
	_known_stat = _stat()
	var read_path := path
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".tmp"):
		read_path = path + ".tmp"  # crash between writing the temp file and renaming it
	if not FileAccess.file_exists(read_path):
		_known_hash = ""
		if not items.is_empty() and notify:
			items = []
			changed.emit(source)
		return

	var text := FileAccess.get_file_as_string(read_path).trim_prefix(String.chr(0xFEFF))  # Notepad adds a BOM
	var digest := text.sha256_text()
	if digest == _known_hash:
		return
	# JSON.new().parse() reports errors by return code; parse_string() would print an engine error.
	var json := JSON.new()
	var data = json.data if json.parse(text) == OK else null
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("items")) != TYPE_ARRAY:
		_known_hash = digest
		_back_up_corrupt(read_path, digest)
		return
	_known_hash = digest
	var parsed := _sanitize(data["items"])
	if parsed == items:
		return
	items = parsed
	if notify:
		changed.emit(source)


func _back_up_corrupt(from_path: String, digest: String) -> void:
	if digest == _backed_up_hash:
		return
	_backed_up_hash = digest
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var backup := "%s.bak-%s" % [path, stamp]
	var err := DirAccess.copy_absolute(from_path, backup)
	if err == OK:
		_warn("todo.json est illisible : copie conservée dans %s. La liste affichée peut être incomplète." % backup.get_file())
	else:
		_warn("todo.json est illisible et la sauvegarde a échoué (%s)." % error_string(err))


func _warn(message: String) -> void:
	last_warning = message
	warning.emit(message)


func _sanitize(raw: Array) -> Array:
	var out := []
	var seen := {}
	var now := int(Time.get_unix_time_from_system())
	for entry in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var text := clean_text(str(entry.get("text", "")))
		if text.is_empty():
			continue
		var id := str(entry.get("id", ""))
		if id.is_empty() or seen.has(id):
			id = _new_id(seen)
		seen[id] = true
		var status := str(entry.get("status", "open"))
		out.append({
			"id": id,
			"text": text,
			"status": status if status in STATUSES else "open",
			"created": int(entry.get("created", now)),
			"updated": int(entry.get("updated", now)),
		})
	return out


func _stat() -> Array:
	if not FileAccess.file_exists(path):
		return [false, 0, 0]
	var length := 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		length = file.get_length()
	return [true, FileAccess.get_modified_time(path), length]


func _new_id(taken: Dictionary = {}) -> String:
	while true:
		var id := "t" + String.num_int64(randi() & 0xFFFFFF, 36)
		if not taken.has(id) and find_index(id) < 0:
			return id
	return ""
