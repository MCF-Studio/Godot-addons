@tool
extends VBoxContainer
## Content of the "Todo" dock: filter bar, scrolling list of rows, undo bar, input.

const AutoTextEdit = preload("ui/auto_text_edit.gd")
const TodoRow = preload("todo_row.gd")
const TodoStore = preload("todo_store.gd")

## Other addons can add entries to the task context menu: append {"label": String, "callable": Callable}
## to the Array stored in Engine metadata under this name; the Callable receives the task (Dictionary:
## id, text, status, created, updated). Read when the menu opens, so enabling order does not matter.
const META_ACTIONS := "mcf_todo_actions"

const MENU_EDIT := 0
const MENU_DOING := 1
const MENU_DONE := 2
const MENU_DELETE := 4
## Ids of entries added by other addons start here.
const MENU_ACTION_BASE := 100
const UNDO_BAR_SECONDS := 6.0

## "Copier" menu: give the list to an AI (Markdown on the clipboard) or save it to a file.
const COPY_ACTIVE := 0
const COPY_ALL := 1
const EXPORT_FILE := 2
const COPY_LABEL := "Copier ▾"
const COPY_FEEDBACK_SECONDS := 1.8

var store: RefCounted

var _filter := "all"
var _filter_buttons: Array[Button] = []
var _warning_bar: PanelContainer
var _warning_label: Label
var _counter: Label
var _clear_done: Button
var _copy_button: MenuButton
var _copy_timer: Timer
var _export_dialog: FileDialog
var _scroll: ScrollContainer
var _rows: VBoxContainer
var _empty: Label
var _undo_bar: PanelContainer
var _undo_label: Label
var _undo_timer: Timer
var _input: AutoTextEdit
var _menu: PopupMenu
var _menu_id := ""
var _menu_actions: Array = []
var _rebuild_pending := false


func _init(p_store: RefCounted = null) -> void:
	store = p_store
	name = "Todo"
	custom_minimum_size = Vector2(190, 140)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	_build()
	if store:
		store.changed.connect(_on_store_changed)
		store.warning.connect(_show_warning)
		if not store.last_warning.is_empty():
			_show_warning(store.last_warning)
	rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _clear_done:
		_apply_icons()


# --- Construction ------------------------------------------------------------

func _build() -> void:
	_warning_bar = PanelContainer.new()
	_warning_bar.visible = false
	var warning_line := HBoxContainer.new()
	_warning_bar.add_child(warning_line)
	_warning_label = Label.new()
	_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_warning_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))
	warning_line.add_child(_warning_label)
	var dismiss := Button.new()
	dismiss.text = "✕"
	dismiss.flat = true
	dismiss.pressed.connect(func(): _warning_bar.hide())
	warning_line.add_child(dismiss)
	add_child(_warning_bar)

	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 2)
	bar.add_theme_constant_override("v_separation", 2)
	add_child(bar)
	var group := ButtonGroup.new()
	for entry in [["Toutes", "all"], ["À faire", "active"], ["Faites", "done"]]:
		var button := Button.new()
		button.text = entry[0]
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = entry[1] == _filter
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_set_filter.bind(entry[1]))
		_filter_buttons.append(button)
		bar.add_child(button)
	_counter = Label.new()
	_counter.modulate.a = 0.7
	_counter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(_counter)
	_copy_button = MenuButton.new()
	_copy_button.text = COPY_LABEL
	_copy_button.flat = true
	_copy_button.focus_mode = Control.FOCUS_NONE
	_copy_button.tooltip_text = "Copier la liste en Markdown pour la donner à une IA, ou l'exporter dans un fichier"
	var copy_popup := _copy_button.get_popup()
	copy_popup.add_item("Copier les tâches à faire", COPY_ACTIVE)
	copy_popup.add_item("Copier toute la liste", COPY_ALL)
	copy_popup.add_separator()
	copy_popup.add_item("Exporter en fichier Markdown…", EXPORT_FILE)
	copy_popup.about_to_popup.connect(_update_copy_menu)
	copy_popup.id_pressed.connect(_on_copy_menu)
	bar.add_child(_copy_button)
	_copy_timer = Timer.new()
	_copy_timer.one_shot = true
	_copy_timer.timeout.connect(func(): _copy_button.text = COPY_LABEL)
	add_child(_copy_timer)
	_clear_done = Button.new()
	_clear_done.flat = true
	_clear_done.focus_mode = Control.FOCUS_NONE
	_clear_done.tooltip_text = "Supprimer les tâches faites"
	_clear_done.pressed.connect(_on_clear_done)
	bar.add_child(_clear_done)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(column)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 1)
	column.add_child(_rows)
	# Drops are handled on the column (rows + the empty space under them, same origin as _rows):
	# the engine walks up from the control under the mouse and gives up at the first STOP control.
	column.set_drag_forwarding(Callable(), _can_drop, _drop)
	_empty = Label.new()
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.modulate.a = 0.55
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_empty)

	_undo_bar = PanelContainer.new()
	_undo_bar.visible = false
	var undo_line := HBoxContainer.new()
	_undo_bar.add_child(undo_line)
	_undo_label = Label.new()
	_undo_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_undo_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	undo_line.add_child(_undo_label)
	var undo := Button.new()
	undo.text = "Annuler"
	undo.focus_mode = Control.FOCUS_NONE
	undo.pressed.connect(_on_undo)
	undo_line.add_child(undo)
	add_child(_undo_bar)
	_undo_timer = Timer.new()
	_undo_timer.one_shot = true
	_undo_timer.timeout.connect(func(): _undo_bar.hide())
	add_child(_undo_timer)

	var input := AutoTextEdit.new()
	input.max_lines = 5
	input.placeholder_text = "Nouvelle tâche…  (Entrée)"
	input.submitted.connect(_on_input_submitted)
	_input = input
	add_child(input)

	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	_apply_icons()


func _apply_icons() -> void:
	if has_theme_icon("Clear", "EditorIcons"):
		_clear_done.icon = get_theme_icon("Clear", "EditorIcons")
		_clear_done.text = ""
	else:
		_clear_done.text = "Vider"


# --- Rendering ---------------------------------------------------------------

func _matches(item: Dictionary) -> bool:
	match _filter:
		"active":
			return item["status"] != "done"
		"done":
			return item["status"] == "done"
	return true


## Brings the rows in line with the store. Rows are reused (keyed by task id) so hover, focus,
## scroll position and a text being edited survive changes coming from elsewhere.
func rebuild() -> void:
	if store == null:
		return
	_rebuild_pending = false
	var existing := {}
	for row in _rows.get_children():
		existing[row.item_id] = row
	var index := 0
	for item in store.items:
		if not _matches(item):
			continue
		var row = existing.get(item["id"])
		if row == null:
			row = _make_row(item)
			_rows.add_child(row)
		else:
			existing.erase(item["id"])
			row.refresh(item)
		_rows.move_child(row, index)
		index += 1
	for row in existing.values():
		if row.is_editing():
			_rebuild_pending = true  # never destroy a text being typed; retry when it ends
			continue
		_rows.remove_child(row)
		row.queue_free()
	_update_footer()


func _make_row(item: Dictionary) -> Control:
	var row := TodoRow.new(item)
	row.status_toggled.connect(_on_toggle)
	row.edit_committed.connect(func(id: String, text: String): store.update(id, {"text": text}))
	row.edit_finished.connect(_on_edit_finished)
	row.delete_requested.connect(_on_delete)
	row.context_requested.connect(_on_context)
	return row


func _update_footer() -> void:
	var counts: Dictionary = store.counts()
	_counter.text = "%d/%d" % [counts["done"], counts["total"]]
	_counter.tooltip_text = "%d faites sur %d (%d en cours)" % [counts["done"], counts["total"], counts["doing"]]
	_clear_done.visible = counts["done"] > 0
	_empty.visible = _rows.get_child_count() == 0
	if _empty.visible:
		if counts["total"] == 0:
			_empty.text = "Rien à faire pour l'instant.\nÉcris une tâche ci-dessous."
		elif _filter == "done":
			_empty.text = "Aucune tâche terminée."
		else:
			_empty.text = "Tout est fait. 🎉"


func _show_warning(message: String) -> void:
	_warning_label.text = message
	_warning_bar.show()


func _set_filter(value: String) -> void:
	_filter = value
	rebuild()


# --- Store events and user actions -------------------------------------------

func _on_store_changed(_source: String) -> void:
	rebuild()


func _on_edit_finished() -> void:
	if _rebuild_pending:
		rebuild.call_deferred()


func _on_toggle(id: String) -> void:
	var item: Dictionary = store.get_item(id)
	if not item.is_empty():
		store.update(id, {"status": "open" if item["status"] == "done" else "done"})


func _on_delete(id: String) -> void:
	var item: Dictionary = store.get_item(id)
	if item.is_empty() or store.remove([id]) == 0:
		return
	_show_undo("Tâche supprimée")


func _on_clear_done() -> void:
	var removed: int = store.clear_done()
	if removed > 0:
		_show_undo("%d tâche%s supprimée%s" % [removed, "s" if removed > 1 else "", "s" if removed > 1 else ""])


func _show_undo(message: String) -> void:
	_undo_label.text = message
	_undo_bar.show()
	_undo_timer.start(UNDO_BAR_SECONDS)


func _on_undo() -> void:
	store.undo_remove()
	_undo_bar.hide()


func _on_input_submitted(value: String) -> void:
	var item: Dictionary = store.add(value)
	if item.is_empty():
		return
	_input.clear_content()
	if _filter == "done":
		_set_filter("all")  # a new task would be invisible under the "done" filter
		_select_filter_button("all")
	_scroll_to_bottom.call_deferred()


func _select_filter_button(value: String) -> void:
	var index := ["all", "active", "done"].find(value)
	if index >= 0:
		_filter_buttons[index].set_pressed_no_signal(true)


func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


## Focuses the input so a task can be typed right away.
func focus_input() -> void:
	_input.grab_focus()


# --- Copy / export -----------------------------------------------------------

func _project_title() -> String:
	return str(ProjectSettings.get_setting("application/config/name", ""))


## The list as Markdown (see TodoStore.to_markdown). "" when there is nothing to give.
func markdown(include_done: bool) -> String:
	return TodoStore.to_markdown(store.items, include_done, _project_title())


func _count_exportable(include_done: bool) -> int:
	var count := 0
	for item in store.items:
		if include_done or item["status"] != "done":
			count += 1
	return count


## Grey out what would produce an empty text.
func _update_copy_menu() -> void:
	var popup := _copy_button.get_popup()
	popup.set_item_disabled(popup.get_item_index(COPY_ACTIVE), _count_exportable(false) == 0)
	popup.set_item_disabled(popup.get_item_index(COPY_ALL), _count_exportable(true) == 0)
	popup.set_item_disabled(popup.get_item_index(EXPORT_FILE), _count_exportable(true) == 0)


func _flash_copy(message: String) -> void:
	_copy_button.text = message
	_copy_timer.start(COPY_FEEDBACK_SECONDS)


func _on_copy_menu(id: int) -> void:
	match id:
		COPY_ACTIVE, COPY_ALL:
			var include_done := id == COPY_ALL
			var text := markdown(include_done)
			if text.is_empty():
				_flash_copy("Rien à copier")
				return
			if not DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
				_flash_copy("Presse-papiers indisponible")  # ex. éditeur lancé en headless : il reste l'export en fichier
				return
			DisplayServer.clipboard_set(text)
			var count := _count_exportable(include_done)
			_flash_copy("Copié ✓ (%d)" % count)
		EXPORT_FILE:
			_open_export_dialog()


func _open_export_dialog() -> void:
	if _export_dialog == null:
		_export_dialog = FileDialog.new()
		_export_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_export_dialog.add_filter("*.md", "Markdown")
		_export_dialog.title = "Exporter la todo"
		_export_dialog.size = Vector2i(760, 480)
		_export_dialog.file_selected.connect(_on_export_path)
		add_child(_export_dialog)
	_export_dialog.current_dir = ProjectSettings.globalize_path("res://").trim_suffix("/")
	_export_dialog.current_file = "todo.md"
	_export_dialog.popup_centered()


func _on_export_path(path: String) -> void:
	var err := export_to_file(path)
	if err == OK:
		_flash_copy("Exporté ✓")
	else:
		_show_warning("Export impossible vers %s (%s)." % [path, error_string(err)])


## Writes the whole list (done tasks included) as Markdown. Adds ".md" when the name has no extension.
func export_to_file(path: String) -> int:
	if path.get_extension().is_empty():
		path += ".md"
	var text := markdown(true)
	if text.is_empty():
		return ERR_UNCONFIGURED
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	file.close()
	return OK


# --- Context menu ------------------------------------------------------------

func _on_context(id: String, screen_position: Vector2) -> void:
	var item: Dictionary = store.get_item(id)
	if item.is_empty():
		return
	_menu_id = id
	_menu.clear()
	_menu.add_item("Modifier", MENU_EDIT)
	_menu.add_separator()
	if item["status"] == "doing":
		_menu.add_item("Plus en cours", MENU_DOING)
	else:
		_menu.add_item("Marquer « en cours »", MENU_DOING)
	_menu.add_item("Rouvrir" if item["status"] == "done" else "Marquer comme faite", MENU_DONE)
	_menu_actions = _external_actions()
	if not _menu_actions.is_empty():
		_menu.add_separator()
		for i in _menu_actions.size():
			_menu.add_item(str(_menu_actions[i]["label"]), MENU_ACTION_BASE + i)
	_menu.add_separator()
	_menu.add_item("Supprimer", MENU_DELETE)
	_menu.reset_size()
	_menu.popup(Rect2i(Vector2i(screen_position), Vector2i.ZERO))


## Valid entries registered by other addons (see META_ACTIONS).
func _external_actions() -> Array:
	var out := []
	for action in Engine.get_meta(META_ACTIONS, []):
		if action is Dictionary and action.get("callable") is Callable and not str(action.get("label", "")).is_empty():
			out.append(action)
	return out


func _on_menu(menu_id: int) -> void:
	var item: Dictionary = store.get_item(_menu_id)
	if item.is_empty():
		return
	match menu_id:
		MENU_EDIT:
			for row in _rows.get_children():
				if row.item_id == _menu_id:
					row.begin_edit()
		MENU_DOING:
			store.update(_menu_id, {"status": "open" if item["status"] == "doing" else "doing"})
		MENU_DONE:
			store.update(_menu_id, {"status": "open" if item["status"] == "done" else "done"})
		MENU_DELETE:
			_on_delete(_menu_id)
		_:
			var index := menu_id - MENU_ACTION_BASE
			if index >= 0 and index < _menu_actions.size():
				var action: Callable = _menu_actions[index]["callable"]
				if action.is_valid():
					action.call(item)


# --- Drag and drop reordering ------------------------------------------------

## Where a drop at `at` (in column/_rows coordinates) would land: {row, above} or {} when the list is empty.
func _drop_target(at: Vector2) -> Dictionary:
	var last: Control = null
	for row in _rows.get_children():
		last = row
		if at.y < row.position.y + row.size.y * 0.5:
			return {"row": row, "above": true}
	if last:
		return {"row": last, "above": false}
	return {}


func _clear_markers() -> void:
	for row in _rows.get_children():
		row.set_marker(TodoRow.MARKER_NONE)


func _can_drop(at: Vector2, data: Variant) -> bool:
	if not (data is Dictionary and data.has(TodoRow.DRAG_KEY)):
		return false
	var target := _drop_target(at)
	_clear_markers()
	if target.is_empty():
		return false
	target["row"].set_marker(TodoRow.MARKER_ABOVE if target["above"] else TodoRow.MARKER_BELOW)
	return true


func _drop(at: Vector2, data: Variant) -> void:
	_clear_markers()
	var target := _drop_target(at)
	if target.is_empty():
		return
	var id := str(data[TodoRow.DRAG_KEY])
	var from: int = store.find_index(id)
	var before: int = store.find_index(target["row"].item_id)  # store index of the row we land next to
	if from < 0 or before < 0:
		return
	var insert_at := before if target["above"] else before + 1
	store.move(id, insert_at - 1 if from < insert_at else insert_at)
