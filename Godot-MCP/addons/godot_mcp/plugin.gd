@tool
extends EditorPlugin

const WsServer = preload("ws_server.gd")
const DockHost = preload("dock_host.gd")
const TodoStore = preload("todo/todo_store.gd")
const TodoPanel = preload("todo/todo_panel.gd")
const ClaudeSession = preload("chat/claude_session.gd")
const ChatPanel = preload("chat/chat_panel.gd")

var _server: WsServer
var _store: TodoStore
var _session: ClaudeSession
var _todo_dock: DockHost
var _todo_panel: TodoPanel
var _chat_dock: DockHost
var _chat_panel: ChatPanel


func _enter_tree() -> void:
	_register_editor_settings()
	_store = TodoStore.new()
	_server = WsServer.new(self)
	_server.todo_store = _store
	_server.start()

	# Todo: bottom-left slot by default. Chat: bottom panel. Both can be dragged anywhere or floated.
	_todo_panel = TodoPanel.new(_store)
	_todo_dock = DockHost.new(self, _todo_panel, "Todo", "GodotMCP_Todo", DockHost.SLOT_LEFT_BL, "ItemList")
	_session = ClaudeSession.new()
	_session.godot_port = _server.listening_port
	_chat_panel = ChatPanel.new(_session)
	_chat_dock = DockHost.new(self, _chat_panel, "Claude", "GodotMCP_Claude", DockHost.SLOT_BOTTOM, "RichTextLabel")
	_todo_panel.ask_claude.connect(_on_ask_claude)


func _exit_tree() -> void:
	# The claude process does not stop with the editor on its own: end it first.
	if _session:
		_session.shutdown()
		_session = null
	if _chat_dock:
		_chat_dock.free_dock()
		_chat_dock = null
		_chat_panel = null
	if _todo_dock:
		_todo_dock.free_dock()
		_todo_dock = null
		_todo_panel = null
	if _store:
		_store.flush()
		_store = null
	if _server:
		_server.stop()
		_server = null


func _process(_delta: float) -> void:
	if _server:
		_server.poll()
	if _store:
		_store.poll()
	if _session:
		_session.poll()


func _on_ask_claude(item: Dictionary) -> void:
	if _chat_dock == null:
		return
	_chat_dock.make_visible()
	_chat_panel.ask("Voici une tâche de ma todo (id %s) : « %s ».\nFais-la : passe-la en « doing » avec todo_update au début, puis en « done » quand c'est terminé." % [item["id"], item["text"]])


## Machine-wide settings (Editor > Editor Settings > Godot Mcp), not stored in the project.
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
