@tool
extends EditorPlugin
## Déclare l'autoload ST_API (le même réglage est écrit dans project.godot).

const AUTOLOAD_NAME := "ST_API"
const AUTOLOAD_PATH := "res://addons/StreamingTribeAPI/main.gd"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
