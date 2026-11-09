@tool
extends TextEdit
## Multi-line input that grows with its content (up to `max_lines`, then scrolls).
## Enter submits, Shift+Enter inserts a new line, Escape emits `cancelled`.

signal submitted(text: String)
signal cancelled

@export var min_lines := 1
@export var max_lines := 6
## When false, Enter inserts a new line like a plain TextEdit.
@export var submit_on_enter := true

var _fit_pending := false


func _init() -> void:
	wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	scroll_fit_content_height = false
	scroll_smooth = true
	caret_blink = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_changed.connect(_fit_soon)
	resized.connect(_fit_soon)


func _ready() -> void:
	_fit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_fit()


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			if event.shift_pressed or not submit_on_enter:
				return  # TextEdit inserts the new line itself
			if has_ime_text():
				return
			accept_event()
			submitted.emit(text)
		KEY_ESCAPE:
			accept_event()
			cancelled.emit()


## Replaces the content and puts the caret at the end.
func set_content(value: String) -> void:
	text = value
	set_caret_line(get_line_count() - 1)
	set_caret_column(get_line(get_line_count() - 1).length())
	_fit()


func clear_content() -> void:
	text = ""
	_fit()


## TextEdit re-wraps its text after `resized` / `text_changed` have been emitted, so the number of
## wrapped lines is only right one frame later.
func _fit_soon() -> void:
	if _fit_pending or not is_inside_tree():
		return
	_fit_pending = true
	get_tree().process_frame.connect(func():
		_fit_pending = false
		_fit(), CONNECT_ONE_SHOT)


func _fit() -> void:
	if not is_inside_tree():
		return
	var line_height := get_line_height()  # already includes the line_spacing theme constant
	var visible_lines := clampi(get_total_visible_line_count(), min_lines, max_lines)
	var padding := 0.0
	var box := get_theme_stylebox("normal")
	if box:
		padding = box.get_minimum_size().y
	var wanted := visible_lines * line_height + padding + 2.0
	if not is_equal_approx(custom_minimum_size.y, wanted):
		custom_minimum_size.y = wanted
