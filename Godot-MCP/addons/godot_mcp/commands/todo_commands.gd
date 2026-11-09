@tool
extends "base.gd"
## MCP access to the todo dock. The store lives in the editor (server.todo_store), so the dock
## updates immediately when a client adds or ticks a task.

const TodoStore = preload("../todo/todo_store.gd")
const STATUSES := ["open", "doing", "done"]


func register(h: Dictionary) -> void:
	h["todo_list"] = todo_list
	h["todo_add"] = todo_add
	h["todo_update"] = todo_update
	h["todo_remove"] = todo_remove


func _store():
	var store = server.todo_store
	if store == null:
		return err("The todo list is not available (plugin not fully started).")
	return store


static func _view(item: Dictionary, index: int) -> Dictionary:
	return {
		"id": item["id"],
		"index": index,
		"text": item["text"],
		"status": item["status"],
		"created": item["created"],
		"updated": item["updated"],
	}


func todo_list(p: Dictionary):
	var store = _store()
	if is_err(store):
		return store
	var wanted := str(p.get("status", "all"))
	if wanted != "all" and wanted != "active" and not wanted in STATUSES:
		return err("status must be one of: all, active, open, doing, done.")
	var out := []
	for i in store.items.size():
		var item: Dictionary = store.items[i]
		if wanted == "all" or item["status"] == wanted or (wanted == "active" and item["status"] != "done"):
			out.append(_view(item, i))
	return {"items": out, "counts": store.counts()}


func todo_add(p: Dictionary):
	var store = _store()
	if is_err(store):
		return store
	var status := str(p.get("status", "open"))
	if not status in STATUSES:
		return err("status must be one of: open, doing, done.")
	var at_top := str(p.get("position", "bottom")) == "top"

	var entries := []
	if p.has("items"):
		if typeof(p["items"]) != TYPE_ARRAY:
			return err("items must be an array of strings.")
		for entry in p["items"]:
			entries.append(str(entry))
	if p.has("text"):
		entries.append(str(p["text"]))
	if entries.is_empty():
		return err("Provide `text` or `items`.")

	var added := []
	var index := 0  # only used when adding at the top, keeps the given order
	for text in entries:
		var item: Dictionary = store.add(text, status, index if at_top else -1, "mcp")
		if item.is_empty():
			continue  # blank entry
		added.append(_view(item, store.find_index(item["id"])))
		index += 1
	if added.is_empty():
		return err("Nothing to add: the text is empty.")
	store.flush()
	return {"added": added, "counts": store.counts()}


func todo_update(p: Dictionary):
	var store = _store()
	if is_err(store):
		return store
	var id := str(p.get("id", ""))
	if store.find_index(id) < 0:
		return err("No todo with id '%s'. Use todo_list to see the ids." % id)
	var fields := {}
	if p.has("text"):
		if TodoStore.clean_text(str(p["text"])).is_empty():
			return err("text cannot be empty. Use todo_remove to delete a task.")
		fields["text"] = str(p["text"])
	if p.has("status"):
		if not str(p["status"]) in STATUSES:
			return err("status must be one of: open, doing, done.")
		fields["status"] = str(p["status"])
	if fields.is_empty() and not p.has("position"):
		return err("Nothing to change: pass text, status and/or position.")
	if not fields.is_empty():
		store.update(id, fields, "mcp")
	if p.has("position"):
		var position = p["position"]
		var target := -1
		if str(position) == "top":
			target = 0
		elif str(position) == "bottom":
			target = store.items.size() - 1
		elif position is int or position is float:
			target = int(position)
		else:
			return err("position must be 'top', 'bottom' or a 0-based index.")
		store.move(id, target, "mcp")
	store.flush()
	var index: int = store.find_index(id)
	return {"updated": _view(store.items[index], index), "counts": store.counts()}


func todo_remove(p: Dictionary):
	var store = _store()
	if is_err(store):
		return store
	var removed := 0
	if bool(p.get("done_only", false)):
		removed = store.clear_done("mcp")
	else:
		var ids := []
		if p.has("ids") and typeof(p["ids"]) == TYPE_ARRAY:
			for id in p["ids"]:
				ids.append(str(id))
		if p.has("id"):
			ids.append(str(p["id"]))
		if ids.is_empty():
			return err("Provide `id`, `ids` or `done_only: true`.")
		removed = store.remove(ids, "mcp")
		if removed == 0:
			return err("No todo matches these ids. Use todo_list to see the ids.")
	store.flush()
	return {"removed": removed, "counts": store.counts()}
