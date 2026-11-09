@tool
extends EditorPlugin

const WsServer = preload("ws_server.gd")

var _server: WsServer


func _enter_tree() -> void:
	_server = WsServer.new(self)
	_server.start()


func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server = null


func _process(_delta: float) -> void:
	if _server:
		_server.poll()
