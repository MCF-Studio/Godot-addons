extends SceneTree
## Headless unit tests for the pure parts of the addon (todo store, markdown conversion).
## Run:  godot --headless --path test_project -s tests/unit.gd
## Needs the addons/godot_mcp junction in test_project (see README).

const TodoStore = preload("res://addons/godot_mcp/todo/todo_store.gd")
const Markdown = preload("res://addons/godot_mcp/chat/markdown.gd")
const TextLinks = preload("res://addons/godot_mcp/ui/text_links.gd")
const ClaudeSession = preload("res://addons/godot_mcp/chat/claude_session.gd")
const TodoPanel = preload("res://addons/godot_mcp/todo/todo_panel.gd")
const TodoRow = preload("res://addons/godot_mcp/todo/todo_row.gd")

var failures := 0
var tmp_dir := "user://unit_tests"


func check(cond: bool, label: String) -> void:
	if not cond:
		failures += 1
	print("%s %s" % ["PASS" if cond else "FAIL", label])


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	_test_todo_store()
	_test_todo_persistence()
	_test_todo_corrupt_file()
	_test_todo_bom()
	_test_todo_external_edit()
	_test_markdown()
	_test_links()
	_test_session_helpers()
	await _test_todo_panel()
	print("\n" +("%d FAILURE(S)" % failures if failures else "ALL PASSED"))
	quit(1 if failures else 0)


func _fresh(name: String) -> String:
	for file in DirAccess.get_files_at(tmp_dir):
		if file.begins_with(name):
			DirAccess.remove_absolute(tmp_dir.path_join(file))
	return tmp_dir.path_join(name)


func _test_todo_store() -> void:
	var s := TodoStore.new(_fresh("a.json"))
	var a := s.add("  first \r\n line two  ")
	check(a["text"] == "first \n line two", "add trims and normalises newlines")
	check(s.add("   ").is_empty(), "blank text is rejected")
	var b := s.add("second")
	var c := s.add("third", "doing", 0)
	check(s.items.map(func(i): return i["text"]) == ["third", "first \n line two", "second"], "index 0 inserts at the top")
	check(s.update(b["id"], {"status": "done"}), "update status")
	check(not s.update(b["id"], {"status": "bogus"}), "invalid status is rejected")
	check(not s.update("nope", {"text": "x"}), "unknown id is rejected")
	check(s.counts() == {"open": 1, "doing": 1, "done": 1, "total": 3}, "counts")
	check(s.move(c["id"], 2), "move")
	check(s.items[2]["id"] == c["id"], "move puts the task at the requested final index")
	check(s.remove([a["id"], b["id"]]) == 2, "remove two")
	check(s.items.size() == 1, "one left after removal")
	s.undo_remove()
	check(s.items.size() == 3, "undo_remove restores the whole group")
	check(s.items[0]["id"] == a["id"] and s.items[1]["id"] == b["id"], "undo_remove restores original positions")
	check(s.clear_done() == 1 and s.items.size() == 2, "clear_done")
	var ids := {}
	for i in 200:
		ids[s.add("x%d" % i)["id"]] = true
	check(ids.size() == 200, "ids are unique")


func _test_todo_persistence() -> void:
	var path := _fresh("b.json")
	var s := TodoStore.new(path)
	s.add("alpha")
	s.add("beta", "done")
	s.flush()
	check(FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".tmp"), "flush writes the file and leaves no temp file")
	var s2 := TodoStore.new(path)
	check(s2.items == s.items, "round trip through the file")
	# A crash between writing the temp file and renaming it must not lose the list.
	DirAccess.rename_absolute(path, path + ".tmp")
	var s3 := TodoStore.new(path)
	check(s3.items.size() == 2, "recovers from an orphan temp file")


func _test_todo_corrupt_file() -> void:
	var path := _fresh("c.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	var s := TodoStore.new(path)
	check(s.items.is_empty(), "corrupt file gives an empty list")
	check(not s.last_warning.is_empty(), "corrupt file raises a warning")
	var backups := 0
	for file in DirAccess.get_files_at(tmp_dir):
		if file.begins_with("c.json.bak-"):
			backups += 1
	check(backups == 1, "corrupt file is copied aside before anything can overwrite it")
	# Hand-written entries are cleaned up.
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string('{"items":[{"text":"ok"},{"text":""},"junk",{"id":"dup","text":"a","status":"weird"},{"id":"dup","text":"b"}]}')
	f.close()
	s.load_from_disk()
	check(s.items.size() == 3, "invalid entries are dropped")
	check(s.items[1]["status"] == "open" and s.items[1]["id"] != s.items[2]["id"], "bad status and duplicate ids are repaired")


func _test_todo_bom() -> void:
	var path := _fresh("e.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))
	f.store_string('{"items":[{"id":"a","text":"with bom"}]}')
	f.close()
	var s := TodoStore.new(path)
	check(s.items.size() == 1 and s.last_warning.is_empty(), "a UTF-8 BOM (Notepad) is accepted")


func _test_todo_external_edit() -> void:
	var path := _fresh("d.json")
	var s := TodoStore.new(path)
	var sources := []
	s.changed.connect(func(src): sources.append(src))
	s.add("mine")
	s.flush()
	s.poll()
	check(sources == ["ui"], "own write is not reported as external")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string('{"version":1,"items":[{"id":"zz","text":"from outside","status":"open"}]}')
	f.close()
	s.load_from_disk()
	check(sources.back() == "external" and s.items.size() == 1 and s.items[0]["id"] == "zz", "external edit is picked up")


## What a RichTextLabel would actually display for a BBCode string.
func _shown(bbcode: String) -> String:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = bbcode
	var shown := label.get_parsed_text()
	label.free()
	return shown


func _test_markdown() -> void:
	var hostile := "hi [b]x[/b] [img]res://icon.svg[/img] [url=https://evil.example]click[/url] [font_size=99]big[/font_size]"
	check(_shown(Markdown.to_bbcode(hostile)) == hostile, "markdown: tags written by the model are shown literally")
	check(_shown(Markdown.to_bbcode("`a[0]` and `[/code]`")) == "a[0] and [/code]", "markdown: brackets inside inline code")
	check(_shown(Markdown.to_bbcode("```gd\nvar a = [1, 2]\nprint(a)\n```")).strip_edges() == "var a = [1, 2]\nprint(a)", "markdown: fenced code block")
	check(_shown(Markdown.to_bbcode("```\nstill streaming [b]")).strip_edges() == "still streaming [b]", "markdown: unclosed fence while streaming")
	check(Markdown.to_bbcode("**bold** text").contains("[b]bold[/b]"), "markdown: bold")
	check(_shown(Markdown.to_bbcode("**bol")) == "**bol", "markdown: unfinished bold stays literal")
	check(Markdown.to_bbcode("an *italic* word").contains("[i]italic[/i]"), "markdown: italic")
	check(_shown(Markdown.to_bbcode("my_var_name and 2 * 3 * 4")) == "my_var_name and 2 * 3 * 4", "markdown: snake_case and maths are not italics")
	check(Markdown.to_bbcode("[Godot](https://godotengine.org)").contains("[url=https://godotengine.org]Godot[/url]"), "markdown: link")
	check(_shown(Markdown.to_bbcode("[x](javascript:alert(1))")) == "[x](javascript:alert(1))", "markdown: unsafe link scheme is not linked")
	check(Markdown.to_bbcode("see res://scenes/a.tscn:12.").contains("[url=res://scenes/a.tscn:12]"), "markdown: res:// path becomes a link (trailing dot excluded)")
	check(_shown(Markdown.to_bbcode("- one\n  - two")) == "• one\n\t• two", "markdown: bullet list (nested items are indented)")
	check(_shown(Markdown.to_bbcode("# Title")) == "Title", "markdown: heading")
	var table := Markdown.to_bbcode("| a | b |\n|---|---|\n| 1 | [x] |")
	check(table.contains("[table=2]") and _shown(table).contains("[x]"), "markdown: table")


func _test_links() -> void:
	var hits := TextLinks.find("go to https://a.b/c?d=1, then res://x/y.gd:7. (res://z.tscn)")
	check(hits.map(func(h): return h[2]) == ["https://a.b/c?d=1", "res://x/y.gd:7", "res://z.tscn"], "links: urls and res:// paths, punctuation trimmed")
	check(TextLinks.find("nothing here, not even res:// alone").is_empty(), "links: bare res:// is not a link")


func _test_session_helpers() -> void:
	check(ClaudeSession.split_args("--model opus --x 'a b' \"c d\" e") == PackedStringArray(["--model", "opus", "--x", "a b", "c d", "e"]), "session: extra args are split like a shell would")
	var uuid := ClaudeSession._new_uuid()
	var rx := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	check(rx.search(uuid) != null, "session: generated ids are valid v4 UUIDs")
	check(ClaudeSession._flatten([{"type": "text", "text": "a"}, {"type": "image"}]) == "a\n[image]", "session: tool results are flattened to text")


## Drives the todo dock UI the way the user would (needs a few frames for the layout).
func _test_todo_panel() -> void:
	var store := TodoStore.new(_fresh("ui.json"))
	var panel := TodoPanel.new(store)
	panel.size = Vector2(320, 500)
	root.add_child(panel)
	await process_frame
	await process_frame
	var rows := func() -> Array: return panel._rows.get_children().map(func(r): return r.text)

	panel._on_input_submitted("alpha")
	panel._on_input_submitted("beta\nsecond line")
	panel._on_input_submitted("gamma")
	await process_frame
	check(rows.call() == ["alpha", "beta\nsecond line", "gamma"], "todo ui: submitting the input adds rows in order")

	var a_row = panel._rows.get_child(0)
	var a_id: String = a_row.item_id
	panel._on_toggle(a_id)
	await process_frame
	check(store.get_item(a_id)["status"] == "done" and panel._rows.get_child(0) == a_row, "todo ui: ticking keeps the same row (no rebuild flicker)")
	check(a_row.status == "done", "todo ui: the row shows the new status")

	panel._set_filter("active")
	await process_frame
	check(rows.call() == ["beta\nsecond line", "gamma"], "todo ui: the 'à faire' filter hides done tasks")
	panel._set_filter("all")
	await process_frame

	# Drag "gamma" above "alpha".
	var gamma_id: String = panel._rows.get_child(2).item_id
	panel._can_drop(Vector2(10, 1), {TodoRow.DRAG_KEY: gamma_id})
	check(panel._rows.get_child(0)._marker == TodoRow.MARKER_ABOVE, "todo ui: the drop marker shows where the task will land")
	panel._drop(Vector2(10, 1), {TodoRow.DRAG_KEY: gamma_id})
	await process_frame
	check(rows.call() == ["gamma", "alpha", "beta\nsecond line"], "todo ui: drag and drop moves a task to the top")
	# Drag "gamma" below the last row.
	var last: Control = panel._rows.get_child(2)
	panel._drop(Vector2(10, last.position.y + last.size.y - 1), {TodoRow.DRAG_KEY: gamma_id})
	await process_frame
	check(rows.call() == ["alpha", "beta\nsecond line", "gamma"], "todo ui: drag and drop moves a task to the end")

	# Delete then undo.
	panel._on_delete(store.items[1]["id"])
	await process_frame
	check(rows.call() == ["alpha", "gamma"] and panel._undo_bar.visible, "todo ui: deleting shows the undo bar")
	panel._on_undo()
	await process_frame
	check(rows.call() == ["alpha", "beta\nsecond line", "gamma"] and not panel._undo_bar.visible, "todo ui: undo brings the task back where it was")

	# Edit in place: Enter commits, Escape cancels.
	var row: Control = panel._rows.get_child(1)
	row.begin_edit()
	check(row.is_editing(), "todo ui: begin_edit opens the editor")
	row._editor.text = "beta edited"
	row._editor.submitted.emit("beta edited")
	await process_frame
	check(store.items[1]["text"] == "beta edited" and not row.is_editing(), "todo ui: Enter commits the edit")
	row = panel._rows.get_child(1)
	row.begin_edit()
	row._editor.text = "should not stick"
	row._editor.cancelled.emit()
	await process_frame
	check(store.items[1]["text"] == "beta edited", "todo ui: Escape cancels the edit")

	# A change made elsewhere while a row is being edited must not destroy the editor.
	row.begin_edit()
	row._editor.text = "typing…"
	store.remove([store.items[2]["id"]], "mcp")
	await process_frame
	check(row.is_editing() and row._editor.text == "typing…", "todo ui: external changes never wipe a text being typed")
	row._editor.cancelled.emit()

	# Long text is folded, the rest is one click away.
	store.add("line\n".repeat(12))
	await process_frame
	await process_frame
	await process_frame
	var long_row = panel._rows.get_child(panel._rows.get_child_count() - 1)
	check(long_row._more.visible and long_row._label.custom_minimum_size.y > 20.0, "todo ui: a 12-line task is folded with a 'show all' button")
	long_row._more.pressed.emit()
	await process_frame
	check(long_row._label.custom_minimum_size.y > long_row._label.get_line_offset(7), "todo ui: 'show all' expands it")

	panel.queue_free()
