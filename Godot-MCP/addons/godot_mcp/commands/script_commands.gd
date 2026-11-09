@tool
extends "base.gd"


func register(h: Dictionary) -> void:
	h["create_script"] = create_script
	h["read_script"] = read_script
	h["attach_script"] = attach_script


func create_script(p: Dictionary):
	var path := str(p.get("path", ""))
	if not path.begins_with("res://"):
		return err("path must start with res://")
	var content := str(p.get("content", ""))
	if not p.has("content"):
		content = "extends %s\n\n\nfunc _ready() -> void:\n\tpass\n" % str(p.get("base_type", "Node"))
	if ensure_dir(path) != OK:
		return err("Could not create folder " + path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return err("Cannot write %s: %s" % [path, error_string(FileAccess.get_open_error())])
	file.store_string(content)
	file.close()

	# Reload the cached script (if any) so nodes and the script editor see the new code.
	var script: Script = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	refresh_file(path)
	# can_instantiate() is always false in the editor for non-@tool scripts, so check the reload instead.
	var valid := script != null and script.reload(true) == OK
	var result := {"path": path, "valid": valid}
	if not result["valid"]:
		result["hint"] = "The script has errors; run check_script or get_editor_log for details."

	if p.has("attach_to") and script:
		var attached = attach_script({"node_path": p["attach_to"], "script_path": path})
		if is_err(attached):
			return attached
		result["attached_to"] = attached["path"]
	return result


func read_script(p: Dictionary):
	var path := str(p.get("path", ""))
	if not FileAccess.file_exists(path):
		return err("File not found: " + path)
	return {"path": path, "content": FileAccess.get_file_as_string(path)}


func attach_script(p: Dictionary):
	var node = find_node(str(p.get("node_path", "")))
	if is_err(node):
		return node
	var path := str(p.get("script_path", ""))
	var script: Script = null
	if not path.is_empty():
		if not ResourceLoader.exists(path):
			return err("Script not found: " + path)
		script = load(path)
		if script == null:
			return err("Could not load script: " + path)
	var ur := undo_redo()
	ur.create_action("MCP: Attach script to %s" % node.name, UndoRedo.MERGE_DISABLE, scene_root())
	ur.add_do_method(node, "set_script", script)
	ur.add_undo_method(node, "set_script", node.get_script())
	ur.commit_action()
	return {"path": path_of(node), "script": path}
