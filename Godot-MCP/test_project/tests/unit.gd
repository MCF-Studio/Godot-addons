extends SceneTree
## Tests unitaires de l'addon Godot MCP (conversion Markdown, liens, helpers de session), sans éditeur.
## Lancer :  godot --headless --path test_project -s tests/unit.gd
## Nécessite la jonction test_project/addons/godot_mcp (voir README).

const Markdown = preload("res://addons/godot_mcp/chat/markdown.gd")
const TextLinks = preload("res://addons/godot_mcp/ui/text_links.gd")
const ClaudeSession = preload("res://addons/godot_mcp/chat/claude_session.gd")
const LspPlugin = preload("res://addons/godot_mcp/chat/lsp_plugin.gd")
const Commands = preload("res://addons/godot_mcp/commands/base.gd")

var failures := 0


func check(cond: bool, label: String) -> void:
	if not cond:
		failures += 1
	print("%s %s" % ["PASS" if cond else "FAIL", label])


func _initialize() -> void:
	_test_markdown()
	_test_links()
	_test_session_helpers()
	_test_server_selection()
	_test_connect_helpers()
	_test_lsp_plugin()
	_test_res_paths()
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


## Quel fichier serveur MCP le chat donne à claude : l'override des réglages, sinon celui de l'addon.
func _test_server_selection() -> void:
	var dir := "user://unit_server"
	DirAccess.make_dir_recursive_absolute(dir)
	var custom := dir.path_join("custom.mjs")
	var bundled := dir.path_join("bundled.mjs")
	for path in [custom, bundled]:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string("// test")
		f.close()
	var custom_abs := ProjectSettings.globalize_path(custom)
	var bundled_abs := ProjectSettings.globalize_path(bundled)

	var both := ClaudeSession.choose_server(custom_abs, bundled)
	check(both["source"] == "setting" and both["path"] == custom_abs, "serveur: l'override des réglages passe avant le serveur de l'addon")
	var only_bundled := ClaudeSession.choose_server("", bundled)
	check(only_bundled["source"] == "bundled" and only_bundled["path"] == bundled_abs, "serveur: sans override, on prend le serveur livré dans l'addon (chemin absolu)")
	var stale := ClaudeSession.choose_server("C:/n/existe/pas.mjs", bundled)
	check(stale["source"] == "bundled", "serveur: un override qui pointe vers un fichier disparu est ignoré")
	check(ClaudeSession.choose_server("  ", dir.path_join("absent.mjs"))["source"] == "", "serveur: aucun fichier trouvé = source vide")
	for path in [custom, bundled]:
		DirAccess.remove_absolute(path)


func _test_connect_helpers() -> void:
	var server := "C:/Mon dossier/addons/godot_mcp/server/godot-mcp-server.mjs"
	check(ClaudeSession.terminal_command(server, 6505) == 'claude mcp add godot -- node "%s"' % server, "connexion terminal: commande avec guillemets (chemin avec espaces), port par défaut sans -e")
	check(ClaudeSession.terminal_command(server, 6507) == 'claude mcp add godot -e GODOT_MCP_PORT=6507 -- node "%s"' % server, "connexion terminal: un autre port est transmis avec -e")
	var desktop = JSON.parse_string(ClaudeSession.desktop_config(server, 6505))
	check(desktop is Dictionary and desktop["mcpServers"]["godot"]["command"] == "node" and desktop["mcpServers"]["godot"]["args"] == [server] and not desktop["mcpServers"]["godot"].has("env"), "connexion Claude Desktop: JSON valide, sans env au port par défaut")
	var custom_port = JSON.parse_string(ClaudeSession.desktop_config(server, 6508))
	check(custom_port["mcpServers"]["godot"]["env"]["GODOT_MCP_PORT"] == "6508", "connexion Claude Desktop: un autre port est transmis dans env")
	var node := ClaudeSession.find_node()
	check(node.is_empty() or FileAccess.file_exists(node), "find_node(): renvoie un fichier existant, ou rien, sans lancer de processus")


func _test_lsp_plugin() -> void:
	var lsp: Dictionary = LspPlugin.lsp_config()["gdscript"]
	check(lsp["command"] == "node" and not " " in lsp["command"], "plugin LSP: commande sans espace (Claude Code refuse « C:/Program Files/... »)")
	check(lsp["args"] == ["${CLAUDE_PLUGIN_ROOT}/server/godot-mcp-server.mjs", "--lsp"], "plugin LSP: lance le serveur copié dans le plugin en mode --lsp")
	check(lsp["extensionToLanguage"] == {".gd": "gdscript"}, "plugin LSP: associé aux fichiers .gd")
	var allowed := ["command", "extensionToLanguage", "args", "transport", "env", "initializationOptions", "settings", "workspaceFolder", "startupTimeout", "shutdownTimeout", "requestTimeout", "restartOnCrash", "maxRestarts", "diagnostics"]
	var unknown := lsp.keys().filter(func(k): return not k in allowed)
	check(unknown.is_empty(), "plugin LSP: aucune clé inconnue (Claude Code refuserait le plugin) %s" % [unknown])
	var market: Dictionary = LspPlugin.marketplace_manifest()
	check(market["plugins"][0]["name"] == LspPlugin.PLUGIN_NAME and market["plugins"][0]["source"] == "./" + LspPlugin.PLUGIN_NAME, "plugin LSP: le marketplace local pointe vers le dossier du plugin")
	check(not "claude" in LspPlugin.PLUGIN_NAME, "plugin LSP: nom non réservé par Claude Code")
	check(LspPlugin.install_commands().contains('marketplace add "%s"' % LspPlugin.marketplace_dir()) and LspPlugin.install_commands().contains("install godot-gdscript-lsp@godot-mcp-local"), "plugin LSP: commandes d'installation pour le terminal")

	var win_path := "C:\\Windows;c:\\program files\\NODEJS\\;D:\\x"
	check(LspPlugin.path_with_node("C:/Program Files/nodejs/node.exe", win_path, true) == "", "PATH: Node déjà présent (casse et \\ final ignorés) = inchangé")
	check(LspPlugin.path_with_node("C:/Users/a b/node/node.exe", "C:\\Windows", true) == "C:\\Users\\a b\\node;C:\\Windows", "PATH: dossier de Node ajouté en tête, au format Windows")
	check(LspPlugin.path_with_node("/opt/node/bin/node", "/usr/bin", false) == "/opt/node/bin:/usr/bin", "PATH: séparateur « : » hors Windows")
	check(LspPlugin.path_with_node("", "/usr/bin", false) == "", "PATH: sans Node trouvé, rien ne change")


func _test_res_paths() -> void:
	check(Commands.check_res_path("res://scripts/player.gd") == "", "chemins: res:// dans le projet accepté")
	check(Commands.check_res_path("res://a/../b.gd") != "", "chemins: « .. » refusé")
	check(Commands.check_res_path("res://..\\x.gd") != "", "chemins: « ..\\ » refusé (séparateur Windows)")
	check(Commands.check_res_path("C:/Windows/win.ini") != "", "chemins: chemin absolu refusé")
	check(Commands.check_res_path("user://x.cfg") != "", "chemins: user:// refusé")
	check(Commands.check_res_path("res://a..b/c.gd") == "", "chemins: « .. » au milieu d'un nom n'est pas un dossier parent")
