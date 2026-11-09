@tool
extends "base.gd"


func register(h: Dictionary) -> void:
	h["ping"] = func(_p): return {"pong": true}
	h["get_editor_state"] = get_editor_state
	h["list_files"] = list_files
	h["search_classes"] = search_classes
	h["get_class_info"] = get_class_info
	h["run_project"] = run_project
	h["run_current_scene"] = run_current_scene
	h["stop_project"] = stop_project
	h["get_editor_log"] = get_editor_log


func get_editor_state(_p: Dictionary) -> Dictionary:
	var root := scene_root()
	var selected := []
	for node in EditorInterface.get_selection().get_selected_nodes():
		selected.append(path_of(node))
	return {
		"godot_version": Engine.get_version_info()["string"],
		"project_name": ProjectSettings.get_setting("application/config/name", ""),
		"project_path": ProjectSettings.globalize_path("res://").trim_suffix("/"),
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
		"open_scenes": Array(EditorInterface.get_open_scenes()),
		"edited_scene": root.scene_file_path if root else null,
		"edited_scene_root": {"name": str(root.name), "type": root.get_class()} if root else null,
		"selected_nodes": selected,
		"is_playing": EditorInterface.is_playing_scene(),
		"playing_scene": EditorInterface.get_playing_scene(),
	}


func list_files(p: Dictionary):
	var path := str(p.get("path", "res://"))
	if not DirAccess.dir_exists_absolute(path):
		return err("Folder not found: " + path)
	var exts := []
	for e in p.get("extensions", []):
		exts.append(str(e).trim_prefix(".").to_lower())
	var out := []
	_walk(path, bool(p.get("recursive", true)), exts, out)
	if out.size() > 5000:
		return {"files": out.slice(0, 5000), "truncated": true, "total": out.size()}
	return {"files": out}


func _walk(dir_path: String, recursive: bool, exts: Array, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.include_hidden = false
	for file in dir.get_files():
		if file.ends_with(".import") or file.ends_with(".uid"):
			continue
		if exts.is_empty() or file.get_extension().to_lower() in exts:
			out.append(dir_path.path_join(file))
	if recursive:
		for sub in dir.get_directories():
			if not sub.begins_with("."):
				_walk(dir_path.path_join(sub), recursive, exts, out)


func search_classes(p: Dictionary) -> Dictionary:
	var query := str(p.get("query", "")).to_lower()
	var base := str(p.get("base_class", ""))
	var limit := int(p.get("limit", 100))
	var names: Array = Array(ClassDB.get_class_list())
	var script_classes := {}
	for info in ProjectSettings.get_global_class_list():
		script_classes[str(info["class"])] = str(info["base"])
		names.append(str(info["class"]))
	names.sort()
	var out := []
	for name in names:
		if not query.is_empty() and not str(name).to_lower().contains(query):
			continue
		if not base.is_empty() and not _inherits(str(name), base, script_classes):
			continue
		out.append(str(name))
		if out.size() >= limit:
			break
	return {"classes": out, "count": out.size()}


func _inherits(cls: String, base: String, script_classes: Dictionary) -> bool:
	while script_classes.has(cls):
		if cls == base:
			return true
		cls = script_classes[cls]
	return cls == base or (ClassDB.class_exists(cls) and ClassDB.is_parent_class(cls, base))


func get_class_info(p: Dictionary):
	var cls := str(p.get("class_name", ""))
	if not ClassDB.class_exists(cls):
		return err("Unknown built-in class: '%s'. Use search_classes to find valid names." % cls)
	var no_inherit := not bool(p.get("include_inherited", false))
	var chain := []
	var parent := ClassDB.get_parent_class(cls)
	while not parent.is_empty():
		chain.append(parent)
		parent = ClassDB.get_parent_class(parent)
	var props := []
	for prop in ClassDB.class_get_property_list(cls, no_inherit):
		if prop["usage"] & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			continue
		var entry := {"name": prop["name"], "type": type_string(prop["type"])}
		if not str(prop["class_name"]).is_empty():
			entry["class"] = prop["class_name"]
		props.append(entry)
	var methods := []
	for m in ClassDB.class_get_method_list(cls, no_inherit):
		if str(m["name"]).begins_with("_"):
			continue
		var args := []
		for a in m["args"]:
			args.append("%s: %s" % [a["name"], type_string(a["type"])])
		methods.append("%s(%s)" % [m["name"], ", ".join(args)])
	var signals := []
	for s in ClassDB.class_get_signal_list(cls, no_inherit):
		signals.append(s["name"])
	return {
		"class": cls,
		"inherits": chain,
		"can_instantiate": ClassDB.can_instantiate(cls),
		"properties": props,
		"methods": methods,
		"signals": signals,
	}


func run_project(_p: Dictionary):
	if str(ProjectSettings.get_setting("application/run/main_scene", "")).is_empty():
		return err("No main scene set (application/run/main_scene). Use run_current_scene instead.")
	EditorInterface.play_main_scene()
	return {"running": true}


func run_current_scene(p: Dictionary):
	var path := str(p.get("path", ""))
	if not path.is_empty():
		if not ResourceLoader.exists(path):
			return err("Scene not found: " + path)
		EditorInterface.play_custom_scene(path)
		return {"running": path}
	if scene_root() == null:
		return err("No scene is open in the editor.")
	EditorInterface.play_current_scene()
	return {"running": scene_root().scene_file_path}


func stop_project(_p: Dictionary) -> Dictionary:
	var was_playing := EditorInterface.is_playing_scene()
	EditorInterface.stop_playing_scene()
	return {"stopped": was_playing}


func get_editor_log(p: Dictionary):
	if server.logger == null:
		return err("Editor log capture requires Godot 4.5 or newer.")
	return {"lines": server.logger.get_lines(int(p.get("max_lines", 200)), bool(p.get("errors_only", false)), bool(p.get("clear", false)))}
