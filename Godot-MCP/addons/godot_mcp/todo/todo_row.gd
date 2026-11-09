@tool
extends PanelContainer
## One task of the todo list: grip (drag to reorder), check box, wrapped text, delete button.
## Double-click / F2 / Enter edits in place, Delete removes, Space ticks, Up/Down moves between rows.

const AutoTextEdit = preload("../ui/auto_text_edit.gd")
const TextLinks = preload("../ui/text_links.gd")
const TodoStore = preload("todo_store.gd")

signal status_toggled(id: String)
signal edit_committed(id: String, text: String)
signal edit_finished
signal delete_requested(id: String)
signal context_requested(id: String, screen_position: Vector2)

const DRAG_KEY := "godot_mcp_todo"
## Longer texts are folded to this many lines until the user asks for the rest.
const COLLAPSED_LINES := 6
const MARKER_NONE := 0
const MARKER_ABOVE := -1
const MARKER_BELOW := 1

var item_id := ""
var text := ""
var status := "open"

var _grip: Label
var _check: CheckBox
var _doing_mark: Label
var _body: VBoxContainer
var _label: RichTextLabel
var _more: Button
var _editor: TextEdit
var _delete: Button
var _expanded := false
var _editing := false
var _hover := false
var _marker := MARKER_NONE
var _height_pending := false


func _init(item: Dictionary = {}) -> void:
	item_id = str(item.get("id", ""))
	text = str(item.get("text", ""))
	status = str(item.get("status", "open"))
	focus_mode = Control.FOCUS_ALL
	# PASS (not STOP): wheel scrolling and drops must reach the ScrollContainer / the list behind the row.
	mouse_filter = Control.MOUSE_FILTER_PASS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var margins := StyleBoxEmpty.new()
	margins.content_margin_left = 4
	margins.content_margin_right = 4
	margins.content_margin_top = 3
	margins.content_margin_bottom = 3
	add_theme_stylebox_override("panel", margins)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(line)

	_grip = Label.new()
	_grip.text = "⋮⋮"
	_grip.modulate.a = 0.45
	_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	_grip.mouse_default_cursor_shape = Control.CURSOR_DRAG
	_grip.tooltip_text = "Glisser pour réordonner"
	_grip.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_grip.set_drag_forwarding(_grip_drag_data, Callable(), Callable())
	line.add_child(_grip)

	_check = CheckBox.new()
	_check.focus_mode = Control.FOCUS_NONE
	_check.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_check.toggled.connect(func(_on): status_toggled.emit(item_id))
	line.add_child(_check)

	_doing_mark = Label.new()
	_doing_mark.text = "▶"
	_doing_mark.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_doing_mark.mouse_filter = Control.MOUSE_FILTER_PASS
	_doing_mark.tooltip_text = "En cours"
	line.add_child(_doing_mark)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 0)
	_body.mouse_filter = Control.MOUSE_FILTER_PASS
	line.add_child(_body)

	_label = RichTextLabel.new()
	_label.fit_content = false
	_label.scroll_active = false
	_label.selection_enabled = false
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.custom_minimum_size = Vector2(0, 20)
	# The default RichTextLabel style is a padded dark box; rows draw their own background and the
	# height computed below would be off by the style margins.
	_label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_label.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_label.meta_clicked.connect(func(meta): TextLinks.open(meta))
	_label.resized.connect(_on_label_resized)
	_body.add_child(_label)

	_more = Button.new()
	_more.flat = true
	_more.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_more.focus_mode = Control.FOCUS_NONE
	_more.add_theme_font_size_override("font_size", 11)
	_more.modulate.a = 0.75
	_more.visible = false
	_more.pressed.connect(func():
		_expanded = not _expanded
		_update_height())
	_body.add_child(_more)

	_delete = Button.new()
	_delete.flat = true
	_delete.focus_mode = Control.FOCUS_NONE
	_delete.tooltip_text = "Supprimer (Suppr)"
	_delete.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_delete.modulate.a = 0.3
	_delete.pressed.connect(func(): delete_requested.emit(item_id))
	line.add_child(_delete)

	mouse_entered.connect(func(): _set_hover(true))
	mouse_exited.connect(func(): _set_hover(false))
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	_render()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_ENTER_TREE:
		_apply_theme()
	elif what == NOTIFICATION_DRAG_END:
		set_marker(MARKER_NONE)


func is_editing() -> bool:
	return _editing


func set_marker(marker: int) -> void:
	if marker != _marker:
		_marker = marker
		queue_redraw()


## Shows the task with its current data (after the store changed it).
func refresh(item: Dictionary) -> void:
	text = str(item.get("text", ""))
	status = str(item.get("status", "open"))
	_render()


# --- Rendering ---------------------------------------------------------------

func _accent() -> Color:
	if has_theme_color("accent_color", "Editor"):
		return get_theme_color("accent_color", "Editor")
	return Color(0.34, 0.6, 1.0)


func _apply_theme() -> void:
	if _delete == null:
		return
	if has_theme_icon("Close", "EditorIcons"):
		_delete.icon = get_theme_icon("Close", "EditorIcons")
	else:
		_delete.text = "✕"
	_doing_mark.add_theme_color_override("font_color", _accent())
	_render()


func _render() -> void:
	var done := status == "done"
	_check.set_pressed_no_signal(done)
	_doing_mark.visible = status == "doing"
	_label.clear()
	if done:
		var color := _label.get_theme_color("default_color")
		color.a = 0.55
		_label.push_color(color)
		_label.push_strikethrough()
	TextLinks.append(_label, text)
	if done:
		_label.pop()
		_label.pop()
	queue_redraw()
	_update_height()


## `resized` is emitted before RichTextLabel invalidates its line cache for the new width, so the
## height has to be measured one frame later or it would be computed for the previous width.
func _on_label_resized() -> void:
	if _height_pending or not is_inside_tree():
		return
	_height_pending = true
	get_tree().process_frame.connect(func():
		_height_pending = false
		_update_height(), CONNECT_ONE_SHOT)


## RichTextLabel does not size itself when we want to fold long texts, so the height is set by hand.
## Line counts and offsets come from the label itself (they also validate its line cache).
func _update_height() -> void:
	if _label == null or _editing or _label.size.x < 24.0:
		return
	var lines := _label.get_line_count()
	var content := float(_label.get_content_height())
	var foldable := lines > COLLAPSED_LINES + 1  # folding a single hidden line would be silly
	var wanted := content
	if foldable and not _expanded:
		wanted = float(_label.get_line_offset(COLLAPSED_LINES))
	wanted = maxf(wanted, 20.0)
	if not is_equal_approx(_label.custom_minimum_size.y, wanted):
		_label.custom_minimum_size.y = wanted
	_more.visible = foldable
	if foldable:
		_more.text = "▴ Réduire" if _expanded else "▾ Afficher tout (+%d lignes)" % (lines - COLLAPSED_LINES)


func _draw() -> void:
	var accent := _accent()
	if _hover or has_focus():
		draw_rect(Rect2(Vector2.ZERO, size), Color(accent, 0.09))
	if status == "doing":
		draw_rect(Rect2(0, 0, 3, size.y), accent)
	if has_focus():
		draw_rect(Rect2(Vector2.ZERO, size), Color(accent, 0.6), false, 1.0)
	if _marker != MARKER_NONE:
		var y := 0.0 if _marker == MARKER_ABOVE else size.y - 2.0
		draw_rect(Rect2(0, y, size.x, 2.0), accent)


func _set_hover(value: bool) -> void:
	_hover = value
	_delete.modulate.a = 1.0 if value else 0.3
	_grip.modulate.a = 0.9 if value else 0.45
	queue_redraw()


# --- Editing -----------------------------------------------------------------

func begin_edit() -> void:
	if _editing:
		return
	_editing = true
	_label.hide()
	_more.hide()
	var editor := AutoTextEdit.new()
	editor.max_lines = 12
	_editor = editor
	_body.add_child(editor)
	_body.move_child(editor, 0)
	editor.set_content(text)
	editor.submitted.connect(func(value: String): _finish_edit(true, value))
	editor.cancelled.connect(func(): _finish_edit(false, ""))
	editor.focus_exited.connect(func():
		if is_instance_valid(editor):
			_finish_edit(true, editor.text))
	editor.grab_focus()


func _finish_edit(commit: bool, value: String) -> void:
	if not _editing:
		return
	_editing = false
	var editor := _editor
	_editor = null
	editor.queue_free()
	_label.show()
	value = TodoStore.clean_text(value)
	if commit and not value.is_empty() and value != text:
		text = value
		edit_committed.emit(item_id, value)
	_render()
	edit_finished.emit()
	if is_inside_tree():
		grab_focus()


# --- Input -------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if _editing:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			grab_focus()
			if event.double_click:
				begin_edit()
				accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			grab_focus()
			context_requested.emit(item_id, get_screen_position() + get_local_mouse_position())
			accept_event()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_DELETE:
				delete_requested.emit(item_id)
				accept_event()
			KEY_F2, KEY_ENTER, KEY_KP_ENTER:
				begin_edit()
				accept_event()
			KEY_SPACE:
				status_toggled.emit(item_id)
				accept_event()
			KEY_UP, KEY_DOWN:
				_focus_neighbour(-1 if event.keycode == KEY_UP else 1)
				accept_event()


func _focus_neighbour(step: int) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var index := get_index() + step
	if index >= 0 and index < parent.get_child_count():
		parent.get_child(index).grab_focus()


# --- Drag and drop (the grip is the only drag source) ------------------------

func _grip_drag_data(_at: Vector2) -> Variant:
	var preview := PanelContainer.new()
	var label := Label.new()
	label.text = text.get_slice("\n", 0).left(60)
	preview.add_child(label)
	preview.modulate.a = 0.85
	set_drag_preview(preview)
	return {DRAG_KEY: item_id}
