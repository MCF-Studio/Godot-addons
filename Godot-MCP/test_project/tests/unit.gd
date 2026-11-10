extends SceneTree
## Tests unitaires de l'addon Godot MCP (conversion Markdown, liens, helpers de session), sans éditeur.
## Lancer :  godot --headless --path test_project -s tests/unit.gd
## Nécessite la jonction test_project/addons/godot_mcp (voir README).

const Markdown = preload("res://addons/godot_mcp/chat/markdown.gd")
const TextLinks = preload("res://addons/godot_mcp/ui/text_links.gd")
const ClaudeSession = preload("res://addons/godot_mcp/chat/claude_session.gd")

var failures := 0


func check(cond: bool, label: String) -> void:
	if not cond:
		failures += 1
	print("%s %s" % ["PASS" if cond else "FAIL", label])


func _initialize() -> void:
	_test_markdown()
	_test_links()
	_test_session_helpers()
	print("
" + ("%d FAILURE(S)" % failures if failures else "ALL PASSED"))
	quit(1 if failures else 0)


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
