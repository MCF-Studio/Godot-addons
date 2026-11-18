@tool
extends RefCounted
## Claude Code plugin that gives Claude the GDScript language server of Godot (errors after each edit of a
## .gd file, go to definition, references, hover, symbols).
##
## Godot's language server speaks TCP; Claude Code wants a command on stdio. The plugin runs the addon's MCP
## server in bridge mode (`godot-mcp-server.mjs --lsp`), which finds the editor that has the project open
## (session files, see ws_server.gd) or starts a headless one, then relays.
##
## Written to the user config folder, not to the project: one plugin for every project, and a terminal
## `claude` can install it once (local marketplace, see install_commands()). The server file is copied in so
## the plugin does not depend on where this project lives.

const WsServer = preload("../ws_server.gd")

const PLUGIN_NAME := "godot-gdscript-lsp"
const MARKETPLACE_NAME := "godot-mcp-local"
const SERVER_FILE := "server/godot-mcp-server.mjs"


## Folder holding the local marketplace (and the plugin, in a subfolder).
static func marketplace_dir() -> String:
	return WsServer.session_dir().path_join("claude-plugins")


static func plugin_dir() -> String:
	return marketplace_dir().path_join(PLUGIN_NAME)


## .lsp.json content. `node` is looked up in PATH: Claude Code refuses a command containing spaces
## ("C:/Program Files/nodejs/node.exe"), so the chat puts Node's folder in PATH instead.
static func lsp_config() -> Dictionary:
	return {
		"gdscript": {
			"command": "node",
			"args": ["${CLAUDE_PLUGIN_ROOT}/" + SERVER_FILE, "--lsp"],
			"extensionToLanguage": {".gd": "gdscript"},
			# A headless editor may have to start (and import the project) first.
			"startupTimeout": 120000,
			"maxRestarts": 3,
		},
	}


static func plugin_manifest() -> Dictionary:
	return {
		"name": PLUGIN_NAME,
		"displayName": "GDScript (Godot language server)",
		"version": "1.0.0",
		"description": "GDScript errors, definitions, references and docs from Godot's own language server (via the Godot MCP addon).",
		"author": {"name": "MCF Studio"},
		"license": "MIT",
	}


static func marketplace_manifest() -> Dictionary:
	return {
		"name": MARKETPLACE_NAME,
		"description": "Plugins written on this machine by the Godot MCP addon for Godot.",
		"owner": {"name": "Godot MCP addon (local copy)"},
		"plugins": [{
			"name": PLUGIN_NAME,
			"source": "./" + PLUGIN_NAME,
			"description": plugin_manifest()["description"],
		}],
	}


## Writes (or refreshes) the plugin from `server_file` (absolute path of the bundled MCP server).
## Returns the plugin folder, or "" with the reason in `error` when it could not be written.
static func install(server_file: String) -> Dictionary:
	if server_file.is_empty() or not FileAccess.file_exists(server_file):
		return {"dir": "", "error": "serveur MCP introuvable (%s)" % server_file}
	var dir := plugin_dir()
	for sub in [dir.path_join(".claude-plugin"), dir.path_join("server"), marketplace_dir().path_join(".claude-plugin")]:
		if DirAccess.make_dir_recursive_absolute(sub) != OK:
			return {"dir": "", "error": "impossible de créer " + sub}
	var target := dir.path_join(SERVER_FILE)
	if not FileAccess.file_exists(target) or FileAccess.get_md5(target) != FileAccess.get_md5(server_file):
		var copy_err := DirAccess.copy_absolute(server_file, target)
		if copy_err != OK:
			return {"dir": "", "error": "copie du serveur impossible (%s)" % error_string(copy_err)}
	var writes := [
		[dir.path_join(".claude-plugin/plugin.json"), plugin_manifest()],
		[dir.path_join(".lsp.json"), lsp_config()],
		[marketplace_dir().path_join(".claude-plugin/marketplace.json"), marketplace_manifest()],
	]
	for entry in writes:
		var text := JSON.stringify(entry[1], "  ") + "\n"
		if FileAccess.file_exists(entry[0]) and FileAccess.get_file_as_string(entry[0]) == text:
			continue
		var file := FileAccess.open(entry[0], FileAccess.WRITE)
		if file == null:
			return {"dir": "", "error": "écriture impossible : " + str(entry[0])}
		file.store_string(text)
		file.close()
	return {"dir": dir, "error": ""}


## Commands that install the plugin for good in a terminal Claude Code (every project, every session).
static func install_commands() -> String:
	return 'claude plugin marketplace add "%s"\nclaude plugin install %s@%s' % [marketplace_dir(), PLUGIN_NAME, MARKETPLACE_NAME]


## Puts `node_path`'s folder first in this process's PATH (inherited by claude, then by the plugin) when
## it is not there yet. Pure on `current_path` for the unit tests; returns the new PATH ("" = unchanged).
static func path_with_node(node_path: String, current_path: String, windows: bool) -> String:
	if node_path.is_empty():
		return ""
	var node_dir := node_path.get_base_dir()
	var separator := ";" if windows else ":"
	for entry in current_path.split(separator, false):
		var clean := entry.strip_edges().trim_prefix('"').trim_suffix('"').replace("\\", "/").trim_suffix("/")
		if (clean.to_lower() == node_dir.to_lower()) if windows else (clean == node_dir):
			return ""
	var native := node_dir.replace("/", "\\") if windows else node_dir
	return native + separator + current_path if not current_path.is_empty() else native
