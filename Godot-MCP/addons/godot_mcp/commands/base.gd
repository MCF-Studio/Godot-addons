@tool
extends RefCounted
## Shared helpers for command groups. Subclasses override register().

var plugin: EditorPlugin
var server: RefCounted


func _init(p_plugin: EditorPlugin, p_server: RefCounted) -> void:
	plugin = p_plugin
	server = p_server


## Adds "method name" -> Callable entries to the handler table.
func register(_handlers: Dictionary) -> void:
	pass


static func err(message: String) -> Dictionary:
	return {"__error": message}


static func is_err(value) -> bool:
	return value is Dictionary and value.has("__error")


func undo_redo() -> EditorUndoRedoManager:
	return plugin.get_undo_redo()


func scene_root() -> Node:
	return EditorInterface.get_edited_scene_root()


## Resolves a path relative to the edited scene root. Returns the node or an error dictionary.
func find_node(path: String):
	var root := scene_root()
	if root == null:
		return err("No scene is open in the editor. Use open_scene or create_scene first.")
	if path.is_empty() or path == "." or path == str(root.name):
		return root
	if path.begins_with(str(root.name) + "/"):
		path = path.substr(str(root.name).length() + 1)
	var node := root.get_node_or_null(NodePath(path))
	if node == null:
		return err("Node not found: '%s'. Use get_scene_tree to see valid paths." % path)
	return node


func path_of(node: Node) -> String:
	var root := scene_root()
	if root == null or node == null:
		return ""
	return str(root.get_path_to(node))


## Makes the editor FileSystem dock notice a file written outside of ResourceSaver.
func refresh_file(path: String) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs.get_filesystem_path(path.get_base_dir()) == null:
		fs.scan()
	else:
		fs.update_file(path)


static func ensure_dir(res_path: String) -> int:
	var dir := res_path.get_base_dir()
	if DirAccess.dir_exists_absolute(dir):
		return OK
	return DirAccess.make_dir_recursive_absolute(dir)


## [node, owner] pairs for a subtree, so owners can be restored after remove/re-add.
static func snapshot_owners(node: Node) -> Array:
	var out := []
	for child in node.get_children(true):
		out.append([child, child.owner])
		out.append_array(snapshot_owners(child))
	return out


static func restore_owners(pairs: Array) -> void:
	for pair in pairs:
		if is_instance_valid(pair[0]):
			pair[0].owner = pair[1]


# --- Variant <-> JSON --------------------------------------------------------

static func to_json(v):
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
		TYPE_FLOAT:
			return v if is_finite(v) else str(v)
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(v)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"x": v.x, "y": v.y}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			return {"x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_COLOR:
			return {"r": v.r, "g": v.g, "b": v.b, "a": v.a, "html": "#" + v.to_html()}
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Node:
				return {"_type": "Node", "class": v.get_class(), "name": str(v.name)}
			if v is Resource:
				return {"_type": "Resource", "class": v.get_class(), "path": v.resource_path}
			return {"_type": "Object", "class": v.get_class()}
		TYPE_ARRAY:
			var arr := []
			for item in v:
				arr.append(to_json(item))
			return arr
		TYPE_DICTIONARY:
			var d := {}
			for key in v:
				d[str(key)] = to_json(v[key])
			return d
		TYPE_PACKED_BYTE_ARRAY:
			return {"_type": "PackedByteArray", "size": v.size()}
		_:
			if typeof(v) >= TYPE_PACKED_INT32_ARRAY:
				var items := []
				for item in v:
					items.append(to_json(item))
				return items
			return {"_type": type_string(typeof(v)), "value": var_to_str(v)}


## Converts a JSON value to a Variant suited for a property of type `target`
## (a Variant.Type, or TYPE_NIL when unknown).
static func from_json(value, target: int):
	# Godot literals like "Rect2(0, 0, 1, 1)" work for every type.
	if value is String and target != TYPE_STRING and target != TYPE_STRING_NAME and target != TYPE_NODE_PATH:
		if value.begins_with("res://") or value.begins_with("uid://"):
			return load(value) if ResourceLoader.exists(value) else null
		if target == TYPE_COLOR:
			return Color.from_string(value, Color.BLACK) if not value.contains("(") else str_to_var(value)
		if value.contains("("):
			var parsed = str_to_var(value)
			if parsed != null:
				return parsed
	match target:
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_STRING:
			return str(value)
		TYPE_STRING_NAME:
			return StringName(str(value))
		TYPE_NODE_PATH:
			return NodePath(str(value))
		TYPE_VECTOR2:
			var c := _components(value, ["x", "y"])
			return Vector2(c[0], c[1])
		TYPE_VECTOR2I:
			var c := _components(value, ["x", "y"])
			return Vector2i(int(c[0]), int(c[1]))
		TYPE_VECTOR3:
			var c := _components(value, ["x", "y", "z"])
			return Vector3(c[0], c[1], c[2])
		TYPE_VECTOR3I:
			var c := _components(value, ["x", "y", "z"])
			return Vector3i(int(c[0]), int(c[1]), int(c[2]))
		TYPE_VECTOR4:
			var c := _components(value, ["x", "y", "z", "w"])
			return Vector4(c[0], c[1], c[2], c[3])
		TYPE_QUATERNION:
			var c := _components(value, ["x", "y", "z", "w"])
			return Quaternion(c[0], c[1], c[2], c[3])
		TYPE_COLOR:
			if value is Dictionary and value.has("html"):
				return Color.from_string(str(value["html"]), Color.BLACK)
			var c := _components(value, ["r", "g", "b", "a"], 1.0)
			return Color(c[0], c[1], c[2], c[3])
		TYPE_RECT2:
			var c := _components(value, ["x", "y", "w", "h"])
			return Rect2(c[0], c[1], c[2], c[3])
	return value


static func _components(value, keys: Array, fill: float = 0.0) -> Array:
	var out := []
	for i in keys.size():
		var item = fill
		if value is Array and i < value.size():
			item = value[i]
		elif value is Dictionary and value.has(keys[i]):
			item = value[keys[i]]
		elif (value is int or value is float) and i < keys.size():
			item = value
		out.append(float(item))
	return out


## Type of a property on an object, or -1 if it does not exist.
static func property_type(obj: Object, prop: String) -> int:
	for p in obj.get_property_list():
		if p["name"] == prop:
			return p["type"]
	return -1


## Applies a {name: json_value} map to a freshly created (not yet in tree) object.
static func apply_properties(obj: Object, props: Dictionary) -> Variant:
	for key in props:
		var t := property_type(obj, str(key))
		if t == -1:
			return err("Unknown property '%s' on %s" % [key, obj.get_class()])
		obj.set(str(key), from_json(props[key], t))
	return null
