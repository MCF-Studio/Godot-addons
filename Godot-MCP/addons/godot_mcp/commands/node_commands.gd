@tool
extends "base.gd"
## Node edits. Every change goes through EditorUndoRedoManager so Ctrl+Z works in the editor.


func register(h: Dictionary) -> void:
	h["add_node"] = add_node
	h["delete_node"] = delete_node
	h["rename_node"] = rename_node
	h["reparent_node"] = reparent_node
	h["get_node_properties"] = get_node_properties
	h["set_node_properties"] = set_node_properties


func add_node(p: Dictionary):
	var parent = find_node(str(p.get("parent_path", ".")))
	if is_err(parent):
		return parent
	var type := str(p.get("type", ""))
	var node: Node = _instantiate(type)
	if node == null:
		return err("'%s' is not an instantiable Node class. Use search_classes to find one." % type)
	node.name = str(p.get("name", type))
	var props_err = apply_properties(node, p.get("properties", {}))
	if props_err != null:
		node.free()
		return props_err

	var root := scene_root()
	var ur := undo_redo()
	ur.create_action("MCP: Add %s" % node.name, UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "add_child", node, true)
	ur.add_do_method(node, "set_owner", root)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()
	return {"path": path_of(node), "type": node.get_class()}


## Built-in classes, plus global script classes (class_name).
func _instantiate(type: String) -> Node:
	if ClassDB.class_exists(type):
		if ClassDB.can_instantiate(type) and ClassDB.is_parent_class(type, "Node"):
			return ClassDB.instantiate(type)
		return null
	for info in ProjectSettings.get_global_class_list():
		if str(info["class"]) == type:
			var script = load(info["path"])
			var obj = script.new() if script else null
			if obj is Node:
				return obj
			return null
	return null


func delete_node(p: Dictionary):
	var node = find_node(str(p.get("node_path", "")))
	if is_err(node):
		return node
	var root := scene_root()
	if node == root:
		return err("Cannot delete the scene root.")
	var parent: Node = node.get_parent()
	var owners := snapshot_owners(node)
	var ur := undo_redo()
	ur.create_action("MCP: Delete %s" % node.name, UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node, true)
	ur.add_undo_method(parent, "move_child", node, node.get_index())
	ur.add_undo_method(node, "set_owner", node.owner)
	ur.add_undo_method(self, "restore_owners", owners)
	ur.add_undo_reference(node)
	var deleted := path_of(node)
	ur.commit_action()
	return {"deleted": deleted}


func rename_node(p: Dictionary):
	var node = find_node(str(p.get("node_path", "")))
	if is_err(node):
		return node
	var new_name := str(p.get("new_name", ""))
	if new_name.is_empty() or new_name.validate_node_name() != new_name:
		return err("Invalid node name: '%s' (no . : @ / \" %% allowed)." % new_name)
	var ur := undo_redo()
	ur.create_action("MCP: Rename %s" % node.name, UndoRedo.MERGE_DISABLE, scene_root())
	ur.add_do_property(node, "name", new_name)
	ur.add_undo_property(node, "name", node.name)
	ur.commit_action()
	return {"path": path_of(node), "name": str(node.name)}


func reparent_node(p: Dictionary):
	var node = find_node(str(p.get("node_path", "")))
	if is_err(node):
		return node
	var new_parent = find_node(str(p.get("new_parent_path", ".")))
	if is_err(new_parent):
		return new_parent
	var root := scene_root()
	if node == root:
		return err("Cannot reparent the scene root.")
	if new_parent == node or node.is_ancestor_of(new_parent):
		return err("Cannot move a node under itself or one of its descendants.")
	var old_parent: Node = node.get_parent()
	var owners := snapshot_owners(node)
	owners.append([node, node.owner])
	var ur := undo_redo()
	ur.create_action("MCP: Reparent %s" % node.name, UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(node, "reparent", new_parent, true)
	ur.add_do_method(self, "restore_owners", owners)
	ur.add_undo_method(node, "reparent", old_parent, true)
	ur.add_undo_method(old_parent, "move_child", node, node.get_index())
	ur.add_undo_method(self, "restore_owners", owners)
	ur.commit_action()
	return {"path": path_of(node)}


func get_node_properties(p: Dictionary):
	var node = find_node(str(p.get("node_path", "")))
	if is_err(node):
		return node
	var filter := str(p.get("filter", "")).to_lower()
	var non_default := bool(p.get("non_default_only", false))
	var cls: String = node.get_class()
	var class_props := {}
	if non_default:
		for prop in ClassDB.class_get_property_list(cls):
			class_props[prop["name"]] = true
	var props := []
	for prop in node.get_property_list():
		var usage: int = prop["usage"]
		if not usage & PROPERTY_USAGE_EDITOR:
			continue
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			continue
		var name: String = prop["name"]
		if not filter.is_empty() and not name.to_lower().contains(filter):
			continue
		var value = node.get(name)
		if non_default and class_props.has(name):
			var default_value = ClassDB.class_get_property_default_value(cls, name)
			if typeof(default_value) == typeof(value) and default_value == value:
				continue
		var entry := {"name": name, "type": type_string(prop["type"]), "value": to_json(value)}
		if not str(prop["hint_string"]).is_empty() and prop["hint"] == PROPERTY_HINT_ENUM:
			entry["options"] = prop["hint_string"]
		props.append(entry)
	return {"path": path_of(node), "type": cls, "properties": props}


func set_node_properties(p: Dictionary):
	var node = find_node(str(p.get("node_path", "")))
	if is_err(node):
		return node
	var props = p.get("properties", {})
	if typeof(props) != TYPE_DICTIONARY or props.is_empty():
		return err("properties must be a non-empty object")
	var changes := {}
	for key in props:
		var name := str(key)
		var t := property_type(node, name)
		if t == -1:
			return err("Unknown property '%s' on %s. Use get_node_properties to list them." % [name, node.get_class()])
		changes[name] = from_json(props[key], t)

	var ur := undo_redo()
	ur.create_action("MCP: Set properties on %s" % node.name, UndoRedo.MERGE_DISABLE, scene_root())
	for name in changes:
		ur.add_do_property(node, name, changes[name])
		ur.add_undo_property(node, name, node.get(name))
	ur.commit_action()

	var result := {}
	for name in changes:
		result[name] = to_json(node.get(name))
	return {"path": path_of(node), "values": result}
