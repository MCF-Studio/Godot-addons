@tool
extends RefCounted
## Adds a Control to the editor as a movable dock.
## Godot 4.6+ : EditorDock + EditorPlugin.add_dock() (the user can drag it to any slot, float it, close it,
## and the editor remembers where it went). Older versions: add_control_to_dock / add_control_to_bottom_panel.
## Everything version-specific goes through ClassDB/call so this file parses on every 4.x.

## EditorDock.DockSlot values (same numbers as EditorPlugin.DockSlot for the sides).
const SLOT_LEFT_BL := 1
const SLOT_RIGHT_BL := 5
const SLOT_BOTTOM := 8
## EditorDock.DockLayout: vertical | horizontal | floating
const LAYOUT_ALL := 7

var content: Control
var title := ""
var slot := SLOT_BOTTOM

var _plugin: EditorPlugin
var _dock: Control  # the EditorDock (4.6+), else null


func _init(p_plugin: EditorPlugin, p_content: Control, p_title: String, p_layout_key: String, p_slot: int, p_icon: String = "") -> void:
	_plugin = p_plugin
	content = p_content
	title = p_title
	slot = p_slot
	if ClassDB.class_exists("EditorDock"):
		_dock = ClassDB.instantiate("EditorDock")
		_dock.set("title", p_title)
		_dock.set("layout_key", p_layout_key)
		_dock.set("default_slot", p_slot)
		_dock.set("available_layouts", LAYOUT_ALL)
		_dock.set("global", true)  # listed in Editor > Editor Docks, can be closed and reopened
		var icon := _editor_icon(p_icon)
		if icon:
			_dock.set("dock_icon", icon)
		_dock.add_child(p_content)
		p_plugin.call("add_dock", _dock)
	elif p_slot == SLOT_BOTTOM:
		p_content.name = p_title
		p_plugin.add_control_to_bottom_panel(p_content, p_title)
	else:
		p_content.name = p_title
		p_plugin.add_control_to_dock(p_slot, p_content)


## Removes the dock (call from _exit_tree).
func free_dock() -> void:
	if _dock:
		_plugin.call("remove_dock", _dock)
		_dock.remove_child(content)
		_dock.queue_free()
		_dock = null
	elif content and content.get_parent():
		if slot == SLOT_BOTTOM:
			_plugin.remove_control_from_bottom_panel(content)
		else:
			_plugin.remove_control_from_docks(content)
	if content:
		content.queue_free()
		content = null


## Brings the dock to the front (selects its tab / opens the bottom panel).
func make_visible() -> void:
	if _dock:
		_dock.call("make_visible")
	elif slot == SLOT_BOTTOM:
		_plugin.make_bottom_panel_item_visible(content)
	elif content.get_parent() is TabContainer:
		var tabs: TabContainer = content.get_parent()
		tabs.current_tab = tabs.get_tab_idx_from_control(content)


static func _editor_icon(icon_name: String) -> Texture2D:
	if icon_name.is_empty():
		return null
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon(icon_name, "EditorIcons"):
		return theme.get_icon(icon_name, "EditorIcons")
	return null
