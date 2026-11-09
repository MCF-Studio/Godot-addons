class_name McfServerConsole
extends RefCounted
## Console d'administration du serveur dédié (option --console) : des commandes tapées dans la fenêtre du serveur (entrée standard).
## `execute(line)` est une fonction pure qui renvoie la réponse : testable sans entrée standard ; la lecture de l'entrée se fait dans un
## fil séparé (jamais dans la boucle de jeu) et les lignes sont traitées dans la boucle principale. Les commandes sont journalisées.
##   help · status · players · kick <id> [raison] · ban <id> [raison] · unban <adresse> · bans · stop
## Le jeu peut ajouter ses commandes avec `extra_commands` (voir plus bas).

const MAX_LINE := 200

var server: McfDedicatedServer
## `func(command: String, args: PackedStringArray) -> Variant` : renvoie le texte de réponse, ou `null` si la commande n'est pas
## la sienne. `extra_help` est ajouté à la réponse de « help ».
var extra_commands: Callable
var extra_help: String = ""

var _thread: Thread
var _lines: Array[String] = []
var _mutex := Mutex.new()


func _init(p_server: McfDedicatedServer) -> void:
	server = p_server


## Lance la lecture de l'entrée standard (un fil bloqué sur la lecture ne gêne pas le jeu ; il s'arrête avec le processus).
func start_reading() -> void:
	_thread = Thread.new()
	_thread.start(_read_loop)


func _read_loop() -> void:
	while true:
		var line: String = OS.read_string_from_stdin(MAX_LINE + 2)
		if line.is_empty():
			break # entrée fermée (pas de terminal) : on s'arrête, le serveur continue sans console
		_mutex.lock()
		if _lines.size() < 32:
			_lines.append(line)
		_mutex.unlock()


## À appeler à chaque image : exécute les lignes reçues.
func process() -> void:
	_mutex.lock()
	var pending: Array[String] = _lines.duplicate()
	_lines.clear()
	_mutex.unlock()
	for line: String in pending:
		var answer: String = execute(line)
		if not answer.is_empty():
			print(answer)


func execute(raw: String) -> String:
	var line: String = McfServerLog.clean(raw).strip_edges().left(MAX_LINE)
	if line.is_empty():
		return ""
	var parts: PackedStringArray = line.split(" ", false)
	var command: String = parts[0].to_lower()
	var host: McfHost = server.host
	match command:
		"help":
			return "commandes : status · players · kick <id> [raison] · ban <id> [raison] · unban <adresse> · bans · stop" + extra_help
		"status":
			return "%d joueur(s) sur %d, port %d, niveau %s" % [host.player_count(), host.max_players, host.port(), host.level_id]
		"players":
			var rows: PackedStringArray = []
			for p: Dictionary in host.players_info():
				rows.append("  %d  %s  %s  %d ms" % [p["id"], p["name"], p["address"], p["rtt"]])
			return "aucun joueur" if rows.is_empty() else "joueurs :\n" + "\n".join(rows)
		"kick", "ban":
			if parts.size() < 2 or not parts[1].is_valid_int():
				return "usage : %s <id> [raison]" % command
			var id: int = int(parts[1])
			if not host.player_ids().has(id):
				return "joueur %d inconnu" % id
			var reason: String = " ".join(parts.slice(2)) if parts.size() > 2 else ("expulsé par l'administrateur" if command == "kick" else "banni")
			var name: String = host.player_name(id)
			var done: bool = host.kick(id, reason) if command == "kick" else host.ban(id, reason)
			server.log.info("administration : %s du joueur %d (%s) — %s" % [command, id, name, reason])
			return ("%s : joueur %d (%s)" % [command, id, name]) if done else "impossible"
		"unban":
			if parts.size() < 2:
				return "usage : unban <adresse>"
			server.log.info("administration : unban %s" % parts[1])
			return "adresse débannie" if host.unban(parts[1]) else "adresse non bannie"
		"bans":
			return "adresses bannies : %s" % (", ".join(PackedStringArray(host.banned.keys())) if not host.banned.is_empty() else "aucune")
		"stop":
			server.log.info("administration : arrêt demandé")
			server.request_stop()
			return "arrêt…"
	if extra_commands.is_valid():
		var answer: Variant = extra_commands.call(command, parts.slice(1))
		if answer != null:
			server.log.info("administration : %s" % command)
			return str(answer)
	return "commande inconnue : %s (help)" % command.left(20)
