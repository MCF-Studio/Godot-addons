@tool
extends RefCounted
## Clickable links in plain text: http(s) URLs and res:// paths (optionally followed by :line).

static var _pattern: RegEx


static func _regex() -> RegEx:
	if _pattern == null:
		_pattern = RegEx.create_from_string("(https?://[^\\s<>\"'`]+|res://[^\\s<>\"'`()\\[\\]{}|*?]+)")
	return _pattern


## Removes the punctuation a sentence puts after a link ("see res://a.gd.").
static func _trim(link: String) -> String:
	while not link.is_empty() and link[link.length() - 1] in [".", ",", ";", ":", "!", "?", ")", "]"]:
		link = link.left(link.length() - 1)
	return link


## Returns [[start, end, link], ...] for every link found in `text`.
static func find(text: String) -> Array:
	var out := []
	for m in _regex().search_all(text):
		var link := _trim(m.get_string())
		if link == "res://" or link == "http://" or link == "https://":
			continue
		out.append([m.get_start(), m.get_start() + link.length(), link])
	return out


## Appends `text` to a RichTextLabel as plain text, turning links into meta links.
static func append(label: RichTextLabel, text: String) -> void:
	var cursor := 0
	for hit in find(text):
		if hit[0] > cursor:
			label.add_text(text.substr(cursor, hit[0] - cursor))
		label.push_meta(hit[2])
		label.add_text(text.substr(hit[0], hit[1] - hit[0]))
		label.pop()
		cursor = hit[1]
	if cursor < text.length():
		label.add_text(text.substr(cursor))


## Handles a meta_clicked payload: opens a URL in the browser or a res:// file in the editor.
static func open(meta: Variant) -> void:
	var link := str(meta)
	if link.begins_with("http://") or link.begins_with("https://"):
		OS.shell_open(link)
	elif link.begins_with("res://"):
		open_resource(link)


static func open_resource(link: String) -> void:
	var line := -1
	var path := link
	# res://a.gd:42 -> path + line (the "res://" colon is not a line separator).
	var colon := link.rfind(":")
	if colon > 5 and link.substr(colon + 1).is_valid_int():
		path = link.left(colon)
		line = int(link.substr(colon + 1))
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		push_warning("[Godot MCP] File not found: " + path)
		return
	var ext := path.get_extension().to_lower()
	if ext == "tscn" or ext == "scn":
		EditorInterface.open_scene_from_path(path)
	elif ext == "gd" or ext == "cs" or ext == "gdshader":
		var script = load(path)
		if script is Script:
			EditorInterface.edit_script(script, maxi(line, 1), 0)
	else:
		var res = load(path) if ResourceLoader.exists(path) else null
		if res is Resource:
			EditorInterface.edit_resource(res)
	EditorInterface.select_file(path)
