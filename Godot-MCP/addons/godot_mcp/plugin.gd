@tool
extends EditorPlugin
## Godot MCP : pont WebSocket pour les clients MCP + dock « Claude » (chat IA) dans l'éditeur.
##
## L'addon MCF Todo est optionnel : s'il est actif, ses tâches sont accessibles par les outils todo_*
## (commands/todo_commands.gd) et chaque tâche gagne l'entrée « Demander à Claude ». Aucune dépendance directe :
## tout passe par les métadonnées d'Engine (contrat décrit dans MCF-Todo/README.md).

const WsServer = preload("ws_server.gd")
const DockHost = preload("dock_host.gd")
const ClaudeSession = preload("chat/claude_session.gd")
const ChatPanel = preload("chat/chat_panel.gd")

const TODO_ACTIONS_META := "mcf_todo_actions"

var _server: WsServer
var _session: ClaudeSession
var _chat_panel: ChatPanel
var _chat_dock: DockHost
var _todo_action := {}


func _enter_tree() -> void:
	_register_editor_settings()
	_server = WsServer.new(self)
	_server.start()

	# Chat : panneau du bas par défaut ; le dock se déplace n'importe où ou passe en fenêtre flottante.
	_session = ClaudeSession.new()
	_session.godot_port = _server.listening_port
	_chat_panel = ChatPanel.new(_session)
	_chat_dock = DockHost.new(self, _chat_panel, "Claude", "GodotMCP_Claude", DockHost.SLOT_BOTTOM, "RichTextLabel")
	_register_todo_action()


func _exit_tree() -> void:
	_unregister_todo_action()
	# Le processus claude ne s'arrête pas tout seul avec l'éditeur : on le termine d'abord.
	if _session:
		_session.shutdown()
		_session = null
	if _chat_dock:
		_chat_dock.free_dock()
		_chat_dock = null
		_chat_panel = null
	if _server:
		_server.stop()
		_server = null


func _process(_delta: float) -> void:
	if _server:
		_server.poll()
	if _session:
		_session.poll()


# --- Intégration facultative avec MCF Todo ------------------------------------

func _register_todo_action() -> void:
	_todo_action = {"label": "Demander à Claude", "callable": _on_ask_claude}
	var actions: Array = Engine.get_meta(TODO_ACTIONS_META, [])
	actions.append(_todo_action)
	Engine.set_meta(TODO_ACTIONS_META, actions)


func _unregister_todo_action() -> void:
	var actions = Engine.get_meta(TODO_ACTIONS_META, null)
	if not (actions is Array):
		return
	for i in range(actions.size() - 1, -1, -1):
		if is_same(actions[i], _todo_action):
			actions.remove_at(i)
	if actions.is_empty():
		Engine.remove_meta(TODO_ACTIONS_META)
	_todo_action = {}


func _on_ask_claude(item: Dictionary) -> void:
	if _chat_dock == null:
		return
	_chat_dock.make_visible()
	_chat_panel.ask("Voici une tâche de ma todo (id %s) : « %s ».\nFais-la : passe-la en « doing » avec todo_update au début, puis en « done » quand c'est terminé." % [item["id"], item["text"]])


## Réglages valables pour toute la machine (Éditeur > Paramètres de l'éditeur > Godot Mcp), pas par projet.
func _register_editor_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	var definitions := [
		[ClaudeSession.SETTING_CLAUDE_PATH, PROPERTY_HINT_GLOBAL_FILE, "*.exe,*"],
		[ClaudeSession.SETTING_SERVER_PATH, PROPERTY_HINT_GLOBAL_FILE, "*.js"],
		[ClaudeSession.SETTING_EXTRA_ARGS, PROPERTY_HINT_NONE, ""],
	]
	for definition in definitions:
		var key: String = definition[0]
		if not settings.has_setting(key):
			settings.set_setting(key, "")
		settings.set_initial_value(key, "", false)
		settings.add_property_info({"name": key, "type": TYPE_STRING, "hint": definition[1], "hint_string": definition[2]})
