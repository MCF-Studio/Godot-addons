@tool
extends EditorPlugin
## MCF Todo : liste de tâches dans un dock de l'éditeur (par défaut en bas à gauche, déplaçable / flottant).
##
## Contrat public pour les autres addons (ex. Godot MCP), sans dépendance directe :
##   - Engine.get_meta("mcf_todo_store") : le TodoStore (todo_store.gd) tant que l'addon est actif
##   - Engine.get_meta("mcf_todo_actions") : tableau de {"label", "callable"} ajoutant des entrées au
##     menu contextuel d'une tâche (voir todo_panel.gd)

const DockHost = preload("dock_host.gd")
const TodoStore = preload("todo_store.gd")
const TodoPanel = preload("todo_panel.gd")

const META_STORE := "mcf_todo_store"

var _store: TodoStore
var _panel: TodoPanel
var _dock: DockHost


func _enter_tree() -> void:
	_store = TodoStore.new()
	Engine.set_meta(META_STORE, _store)
	_panel = TodoPanel.new(_store)
	_dock = DockHost.new(self, _panel, "Todo", "MCF_Todo", DockHost.SLOT_LEFT_BL, "ItemList")


func _exit_tree() -> void:
	if Engine.get_meta(META_STORE, null) == _store:
		Engine.remove_meta(META_STORE)
	if _dock:
		_dock.free_dock()
		_dock = null
		_panel = null
	if _store:
		_store.flush()
		_store = null


func _process(_delta: float) -> void:
	if _store:
		_store.poll()
