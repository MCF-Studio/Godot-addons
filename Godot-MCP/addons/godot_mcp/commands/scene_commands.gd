@tool
extends "base.gd"


func register(h: Dictionary) -> void:
	h["get_scene_tree"] = get_scene_tree
	h["open_scene"] = open_scene
	h["create_scene"] = create_scene
	h["save_scene"] = save_scene
	h["instantiate_scene"] = instantiate_scene
	h["undo"] = func(_p): return _history_step(true)
	h["redo"] = func(_p): return _history_step(false)


func get_scene_tree(p: Dictionary):
	var root := scene_root()
	if root == null:
		return err("No scene is open in the editor.")
	return {"scene": root.scene_file_path, "root": _describe(root, root, int(p.get("max_depth", -1)), 0)}


func _describe(node: Node, root: Node, max_depth: int, depth: int) -> Dictionary:
	var d := {"name": str(node.name), "type": node.get_class(), "path": str(root.get_path_to(node))}
	var script = node.get_script()
	if script:
		d["script"] = script.resource_path
	if node != root and not node.scene_file_path.is_empty():
		d["instance_of"] = node.scene_file_path
	var children := []
	for child in node.get_children():
		# Only nodes saved with this scene (skips internals of instanced scenes and editor helpers).
		if child.owner != root:
			continue
		if max_depth >= 0 and depth >= max_depth:
			d["children_count"] = node.get_child_count()
			break
		children.append(_describe(child, root, max_depth, depth + 1))
	if not children.is_empty():
		d["children"] = children
	return d


func open_scene(p: Dictionary):
	var path := str(p.get("path", ""))
	if not ResourceLoader.exists(path):
		return err("Scene not found: " + path)
	EditorInterface.open_scene_from_path(path)
	await plugin.get_tree().process_frame
	var root := scene_root()
	return {"opened": root.scene_file_path if root else path}


func create_scene(p: Dictionary):
	var path := str(p.get("path", ""))
	if not path.begins_with("res://") or not (path.ends_with(".tscn") or path.ends_with(".scn")):
		return err("path must be a res:// path ending in .tscn")
	var type := str(p.get("root_type", "Node2D"))
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node") or not ClassDB.can_instantiate(type):
		return err("'%s' is not an instantiable Node class." % type)
	var root: Node = ClassDB.instantiate(type)
	root.name = str(p.get("root_name", path.get_file().get_basename().to_pascal_case()))
	var packed := PackedScene.new()
	var pack_err := packed.pack(root)
	root.free()
	if pack_err != OK:
		return err("Could not pack scene: " + error_string(pack_err))
	if ensure_dir(path) != OK:
		return err("Could not create folder " + path.get_base_dir())
	var save_err := ResourceSaver.save(packed, path)
	if save_err != OK:
		return err("Could not save scene: " + error_string(save_err))
	refresh_file(path)
	if bool(p.get("open", true)):
		EditorInterface.open_scene_from_path(path)
		await plugin.get_tree().process_frame
	return {"created": path, "root_type": type}


func save_scene(p: Dictionary):
	var root := scene_root()
	if root == null:
		return err("No scene is open in the editor.")
	var path := str(p.get("path", ""))
	if not path.is_empty():
		if ensure_dir(path) != OK:
			return err("Could not create folder " + path.get_base_dir())
		EditorInterface.save_scene_as(path)
		return {"saved": path}
	if root.scene_file_path.is_empty():
		return err("This scene has never been saved; pass a path.")
	var save_err := EditorInterface.save_scene()
	if save_err != OK:
		return err("Save failed: " + error_string(save_err))
	return {"saved": root.scene_file_path}


## Undo/redo in the edited scene's history (same as Ctrl+Z / Ctrl+Shift+Z).
func _history_step(undo: bool):
	var root := scene_root()
	if root == null:
		return err("No scene is open in the editor.")
	var ur := undo_redo()
	var history := ur.get_history_undo_redo(ur.get_object_history_id(root))
	var action := history.get_current_action_name()
	if undo:
		if not history.undo():
			return err("Nothing to undo.")
		return {"undone": action}
	if not history.redo():
		return err("Nothing to redo.")
	return {"redone": history.get_current_action_name()}


func instantiate_scene(p: Dictionary):
	var parent = find_node(str(p.get("parent_path", ".")))
	if is_err(parent):
		return parent
	var scene_path := str(p.get("scene_path", ""))
	if not ResourceLoader.exists(scene_path):
		return err("Scene not found: " + scene_path)
	var packed = load(scene_path)
	if not packed is PackedScene:
		return err(scene_path + " is not a scene")
	if scene_path == scene_root().scene_file_path:
		return err("A scene cannot instance itself.")
	var inst: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if p.has("name"):
		inst.name = str(p["name"])
	var root := scene_root()
	var ur := undo_redo()
	ur.create_action("MCP: Instance " + scene_path.get_file(), UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "add_child", inst, true)
	ur.add_do_method(inst, "set_owner", root)
	ur.add_do_reference(inst)
	ur.add_undo_method(parent, "remove_child", inst)
	ur.commit_action()
	return {"path": path_of(inst), "instance_of": scene_path}
