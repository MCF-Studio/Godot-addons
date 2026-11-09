@tool
extends VBoxContainer
## Content of the "Claude" dock: transcript, input, status bar. Talks to a ClaudeSession.

const AutoTextEdit = preload("../ui/auto_text_edit.gd")
const TextLinks = preload("../ui/text_links.gd")
const Markdown = preload("markdown.gd")
const ClaudeSession = preload("claude_session.gd")

const MENU_COPY_RESUME := 0
const MENU_PICK_SERVER := 1
const MENU_PICK_CLAUDE := 2
const MAX_RESULT_CHARS := 4000
const GREEN := Color(0.45, 0.8, 0.45)
const ORANGE := Color(1.0, 0.7, 0.25)
const RED := Color(1.0, 0.45, 0.4)
const GREY := Color(0.55, 0.55, 0.55)

var session: ClaudeSession

var _dot: Label
var _title: Label
var _status: Label
var _stop_button: Button
var _menu: MenuButton
var _banner: PanelContainer
var _banner_label: Label
var _banner_pick: Button
var _scroll: ScrollContainer
var _messages: VBoxContainer
var _empty: Label
var _input: AutoTextEdit
var _send_button: Button
var _dialog: FileDialog
var _dialog_setting := ""

## Streaming text widgets: "<message id>:<block index>" -> {label, md, final}
var _texts := {}
var _text_order := {}  # message id -> [keys in creation order]
var _tools := {}  # tool_use id -> {panel, mark, title, details, input, result}
var _dirty: Array = []
var _follow := true
var _activity := ""


func _init(p_session: ClaudeSession = null) -> void:
	session = p_session
	name = "Claude"
	custom_minimum_size = Vector2(240, 160)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	_build()
	visibility_changed.connect(_on_visibility_changed)
	if session:
		session.init_received.connect(_on_init)
		session.block_started.connect(_on_block_started)
		session.text_delta.connect(_on_text_delta)
		session.assistant_block.connect(_on_assistant_block)
		session.tool_result.connect(_on_tool_result)
		session.turn_finished.connect(_on_turn_finished)
		session.notice.connect(_on_notice)
		session.state_changed.connect(_refresh_header)
	_refresh_header()


func _process(_delta: float) -> void:
	if _dirty.is_empty():
		return
	for key in _dirty:
		var entry: Dictionary = _texts.get(key, {})
		if not entry.is_empty():
			entry["label"].text = Markdown.to_bbcode(entry["md"])
	_dirty.clear()


# --- Construction ------------------------------------------------------------

func _build() -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	add_child(bar)
	_dot = Label.new()
	_dot.text = "●"
	bar.add_child(_dot)
	_title = Label.new()
	_title.text = "Claude"
	_title.add_theme_font_size_override("font_size", 15)
	bar.add_child(_title)
	_status = Label.new()
	_status.modulate.a = 0.7
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.clip_text = true
	bar.add_child(_status)
	_stop_button = Button.new()
	_stop_button.text = "Stop"
	_stop_button.flat = true
	_stop_button.visible = false
	_stop_button.tooltip_text = "Interrompre Claude (la conversation continue)"
	_stop_button.pressed.connect(func(): session.interrupt())
	bar.add_child(_stop_button)
	var new_button := Button.new()
	new_button.text = "Nouveau"
	new_button.flat = true
	new_button.tooltip_text = "Nouvelle conversation (l'ancienne reste reprenable dans un terminal)"
	new_button.pressed.connect(_on_new_conversation)
	bar.add_child(new_button)
	_menu = MenuButton.new()
	_menu.text = "⋯"
	_menu.flat = true
	var popup := _menu.get_popup()
	popup.add_item("Copier la commande de reprise (terminal)", MENU_COPY_RESUME)
	popup.add_separator()
	popup.add_item("Choisir le serveur MCP Godot (index.js)…", MENU_PICK_SERVER)
	popup.add_item("Choisir l'exécutable claude…", MENU_PICK_CLAUDE)
	popup.id_pressed.connect(_on_menu)
	bar.add_child(_menu)

	_banner = PanelContainer.new()
	_banner.visible = false
	var banner_line := HBoxContainer.new()
	_banner.add_child(banner_line)
	_banner_label = Label.new()
	_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_banner_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_banner_label.add_theme_color_override("font_color", ORANGE)
	banner_line.add_child(_banner_label)
	_banner_pick = Button.new()
	_banner_pick.text = "Choisir…"
	_banner_pick.pressed.connect(func(): _pick_file(ClaudeSession.SETTING_SERVER_PATH, "*.js", "Serveur MCP Godot"))
	banner_line.add_child(_banner_pick)
	add_child(_banner)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	_scroll.add_child(column)
	_messages = VBoxContainer.new()
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_theme_constant_override("separation", 8)
	column.add_child(_messages)
	_empty = Label.new()
	_empty.text = "Parle à Claude : il voit ton projet et pilote l'éditeur (scènes, nœuds, scripts, lancement du jeu).\n\nEntrée = envoyer · Maj+Entrée = nouvelle ligne"
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.modulate.a = 0.55
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_empty)
	var vbar := _scroll.get_v_scroll_bar()
	vbar.changed.connect(func():
		if _follow:
			_scroll.scroll_vertical = int(vbar.max_value))
	vbar.value_changed.connect(func(_v): _follow = vbar.value + vbar.page >= vbar.max_value - 24.0)

	var input_row := HBoxContainer.new()
	add_child(input_row)
	var input := AutoTextEdit.new()
	input.max_lines = 8
	input.placeholder_text = "Message à Claude…  (Entrée = envoyer)"
	input.submitted.connect(func(text: String): _submit(text, true))
	_input = input
	input_row.add_child(input)
	_send_button = Button.new()
	_send_button.text = "Envoyer"
	_send_button.size_flags_vertical = Control.SIZE_SHRINK_END
	_send_button.pressed.connect(func(): _submit(_input.text, true))
	input_row.add_child(_send_button)


# --- Public ------------------------------------------------------------------

## Typing should be possible as soon as the user opens the dock (not at editor start-up).
func _on_visibility_changed() -> void:
	if is_visible_in_tree() and Time.get_ticks_msec() > 8000:
		_input.grab_focus.call_deferred()


## Sends a message as if the user had typed it (used by "Ask Claude" in the todo list).
func ask(text: String) -> void:
	_submit(text, false)


func focus_input() -> void:
	_input.grab_focus()


# --- Sending -----------------------------------------------------------------

func _submit(text: String, from_input: bool) -> void:
	text = text.strip_edges()
	if text.is_empty() or session == null:
		return
	if not session.send(text):
		return  # the reason was shown as a notice; the typed text stays in the input
	_add_user_message(text)
	if from_input:
		_input.clear_content()
	_follow = true
	_activity = "Claude démarre…" if not session.running else ""
	_refresh_header()


func _on_new_conversation() -> void:
	session.new_conversation()
	for child in _messages.get_children():
		child.queue_free()
	_texts.clear()
	_text_order.clear()
	_tools.clear()
	_dirty.clear()
	_banner.hide()
	_activity = ""
	_empty.show()
	_refresh_header()


# --- Events from the session -------------------------------------------------

func _on_init(info: Dictionary) -> void:
	_refresh_header()
	# claude must run in the project folder (it loads the project's CLAUDE.md, MCP config, history).
	var cwd := str(info.get("cwd", "")).replace("\\", "/").trim_suffix("/")
	var wanted := session.project_dir().replace("\\", "/")
	if not cwd.is_empty() and cwd.to_lower() != wanted.to_lower() and not _banner.visible:
		_show_banner("Claude tourne dans %s au lieu du dossier du projet (%s)." % [cwd, wanted], false)
		return
	var godot_ok := false
	var seen := []
	for server in info.get("mcp_servers", []):
		if server is Dictionary and str(server.get("name", "")).to_lower().contains("godot"):
			seen.append("%s : %s" % [server.get("name"), server.get("status")])
			godot_ok = godot_ok or str(server.get("status", "")) == "connected"
	if godot_ok:
		_banner.hide()
	else:
		var detail := "" if seen.is_empty() else " (%s)" % ", ".join(seen)
		_show_banner("Le MCP Godot n'est pas connecté à ce Claude%s : il ne pourra pas piloter l'éditeur. Indique l'emplacement de server/dist/index.js." % detail, true)


func _on_block_started(kind: String) -> void:
	_activity = {"text": "Claude écrit…", "thinking": "Claude réfléchit…", "tool_use": "Claude prépare un outil…"}.get(kind, "")
	_refresh_header()


func _on_text_delta(message_id: String, index: int, delta: String) -> void:
	var entry := _text_entry("%s:%d" % [message_id, index], message_id)
	entry["md"] += delta
	_mark_dirty("%s:%d" % [message_id, index])


func _on_assistant_block(message_id: String, block: Dictionary) -> void:
	match str(block.get("type", "")):
		"text":
			var text := str(block.get("text", ""))
			if text.strip_edges().is_empty():
				return
			var key := _first_open_text(message_id)
			if key.is_empty():
				key = "%s:final%d" % [message_id, _text_order.get(message_id, []).size()]
			var entry := _text_entry(key, message_id)
			entry["md"] = text
			entry["final"] = true
			_mark_dirty(key)
		"tool_use":
			_add_tool(block)
			_activity = "Outil : %s" % _short_tool_name(str(block.get("name", "")))
			_refresh_header()


func _on_tool_result(tool_use_id: String, content: String, is_error: bool) -> void:
	var tool: Dictionary = _tools.get(tool_use_id, {})
	if tool.is_empty():
		return
	var mark: Label = tool["mark"]
	mark.text = "✗" if is_error else "✓"
	mark.add_theme_color_override("font_color", RED if is_error else GREEN)
	var shown := content
	if shown.length() > MAX_RESULT_CHARS:
		shown = shown.left(MAX_RESULT_CHARS) + "\n… (%d caractères de plus)" % (content.length() - MAX_RESULT_CHARS)
	tool["result"] = shown
	_render_tool_details(tool)
	_activity = "Claude réfléchit…"
	_refresh_header()


func _on_turn_finished(result: Dictionary) -> void:
	_activity = ""
	for key in _texts:
		_texts[key]["final"] = true
	if bool(result.get("interrupted", false)):
		_add_notice("Interrompu.", false)
	elif bool(result.get("is_error", false)) and str(result.get("subtype", "")) != "process_exited":
		var detail := str(result["result"]) if result.get("result") != null else str(result.get("subtype", "erreur"))
		_add_notice("Erreur : " + detail, true)
	elif result.has("duration_ms"):
		var seconds := float(result["duration_ms"]) / 1000.0
		var footer := Label.new()
		footer.text = "%.1f s" % seconds
		footer.modulate.a = 0.4
		footer.add_theme_font_size_override("font_size", 11)
		footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_add(footer)
	_refresh_header()


func _on_notice(message: String, is_error: bool) -> void:
	_add_notice(message, is_error)


# --- Transcript widgets ------------------------------------------------------

func _add(node: Control) -> void:
	_empty.hide()
	_messages.add_child(node)


func _accent() -> Color:
	if has_theme_color("accent_color", "Editor"):
		return get_theme_color("accent_color", "Editor")
	return Color(0.34, 0.6, 1.0)


func _make_label(bbcode: bool) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = bbcode
	label.fit_content = true
	label.scroll_active = false
	label.selection_enabled = true
	label.mouse_filter = Control.MOUSE_FILTER_PASS  # a STOP label would swallow the mouse wheel
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	label.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	label.meta_clicked.connect(func(meta): TextLinks.open(meta))
	return label


func _add_user_message(text: String) -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(_accent(), 0.13)
	style.border_color = _accent()
	style.border_width_left = 3
	style.set_corner_radius_all(3)
	style.content_margin_left = 9
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var label := _make_label(false)
	TextLinks.append(label, text)
	panel.add_child(label)
	_add(panel)


func _text_entry(key: String, message_id: String) -> Dictionary:
	if _texts.has(key):
		return _texts[key]
	var label := _make_label(true)
	_add(label)
	var entry := {"label": label, "md": "", "final": false}
	_texts[key] = entry
	if not _text_order.has(message_id):
		_text_order[message_id] = []
	_text_order[message_id].append(key)
	return entry


func _first_open_text(message_id: String) -> String:
	for key in _text_order.get(message_id, []):
		if not _texts[key]["final"]:
			return key
	return ""


func _mark_dirty(key: String) -> void:
	if not _dirty.has(key):
		_dirty.append(key)


func _add_notice(message: String, is_error: bool) -> void:
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", RED if is_error else GREY)
	_add(label)


static func _short_tool_name(name: String) -> String:
	if name.begins_with("mcp__"):
		var parts := name.split("__")
		if parts.size() >= 3:
			return "%s › %s" % [parts[1], "__".join(parts.slice(2))]
	return name


## One short line describing what a tool call is about.
static func _summarize(input: Dictionary) -> String:
	for key in ["command", "file_path", "path", "node_path", "pattern", "query", "url", "scene_path", "text", "description", "type", "name"]:
		if input.has(key):
			return str(input[key]).replace("\n", " ").left(90)
	if input.is_empty():
		return ""
	return JSON.stringify(input).left(90)


func _add_tool(block: Dictionary) -> void:
	var id := str(block.get("id", ""))
	if _tools.has(id):
		return
	var input: Dictionary = block.get("input", {}) if block.get("input") is Dictionary else {}
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.045)
	style.set_corner_radius_all(3)
	style.content_margin_left = 8
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	panel.add_child(column)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	column.add_child(head)
	var mark := Label.new()
	mark.text = "…"
	mark.add_theme_color_override("font_color", ORANGE)
	head.add_child(mark)
	var title := Label.new()
	var summary := _summarize(input)
	title.text = _short_tool_name(str(block.get("name", "?"))) + ("  " + summary if not summary.is_empty() else "")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.clip_text = true
	title.tooltip_text = title.text
	head.add_child(title)
	var toggle := Button.new()
	toggle.text = "▸"
	toggle.flat = true
	toggle.focus_mode = Control.FOCUS_NONE
	head.add_child(toggle)
	var details := _make_label(true)
	details.visible = false
	column.add_child(details)
	var tool := {"panel": panel, "mark": mark, "title": title, "details": details, "input": input, "result": ""}
	_tools[id] = tool
	toggle.pressed.connect(func():
		details.visible = not details.visible
		toggle.text = "▾" if details.visible else "▸")
	_render_tool_details(tool)
	_add(panel)


func _render_tool_details(tool: Dictionary) -> void:
	var text := ""
	if not tool["input"].is_empty():
		text += "[b]Entrée[/b]\n" + Markdown.code_block(PackedStringArray([JSON.stringify(tool["input"], "  ")]))
	if not str(tool["result"]).is_empty():
		text += "\n[b]Résultat[/b]\n" + Markdown.code_block(PackedStringArray([str(tool["result"])]))
	tool["details"].text = text


# --- Header, banner, menu ----------------------------------------------------

func _refresh_header() -> void:
	if session == null:
		return
	var color := GREY
	var text := "Arrêté"
	if not ClaudeSession.is_supported():
		text = "Nécessite Godot 4.5+"
	elif session.busy:
		color = ORANGE
		text = _activity if not _activity.is_empty() else "Claude travaille…"
	elif session.running:
		color = GREEN
		text = "Prêt"
	elif not session.session_id.is_empty():
		text = "Conversation en pause (reprise au prochain message)"
	else:
		text = "Aucune conversation"
	_dot.add_theme_color_override("font_color", color)
	_status.text = text + ("  ·  " + session.model if session.running and not session.model.is_empty() else "")
	_stop_button.visible = session.busy
	_send_button.text = "Envoyer"


func _show_banner(message: String, offer_pick: bool) -> void:
	_banner_label.text = message
	_banner_pick.visible = offer_pick
	_banner.show()


func _on_menu(id: int) -> void:
	match id:
		MENU_COPY_RESUME:
			DisplayServer.clipboard_set(session.resume_command())
			_add_notice("Copié : %s\n(à lancer depuis %s)" % [session.resume_command(), session.project_dir()], false)
		MENU_PICK_SERVER:
			_pick_file(ClaudeSession.SETTING_SERVER_PATH, "*.js", "Serveur MCP Godot")
		MENU_PICK_CLAUDE:
			_pick_file(ClaudeSession.SETTING_CLAUDE_PATH, "*.exe, *", "Exécutable claude")


func _pick_file(setting: String, filter: String, description: String) -> void:
	if _dialog == null:
		_dialog = FileDialog.new()
		_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_dialog.file_selected.connect(_on_file_picked)
		_dialog.size = Vector2i(760, 480)
		add_child(_dialog)
	_dialog_setting = setting
	_dialog.clear_filters()
	_dialog.add_filter(filter, description)
	_dialog.title = "Choisir un fichier"
	_dialog.popup_centered()


func _on_file_picked(path: String) -> void:
	EditorInterface.get_editor_settings().set_setting(_dialog_setting, path)
	_banner.hide()
	_add_notice("Enregistré dans les paramètres de l'éditeur. Pris en compte au prochain redémarrage de Claude.", false)
	session.stop()  # restarts (with --resume) on the next message so the new setting is used
