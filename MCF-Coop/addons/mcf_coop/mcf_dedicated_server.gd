class_name McfDedicatedServer
extends Node
## Serveur dédié générique : héberge une partie SANS joueur local, sans fenêtre : lit et valide la ligne de commande
## (McfServerConfig), écoute en ENet (McfHost), tient un journal (McfServerLog) et une console d'administration facultative.
## Aucune règle de jeu ici : le jeu écoute `started` (puis `host.input_received`…) et fait tourner sa simulation.
##
## Lancement (voir McfServerConfig pour les arguments) :
##   Godot --headless --path . res://ma_scene_serveur.tscn -- --port=2302 --max-players=4
## ou, avec un export « serveur dédié » (feature `dedicated_server`), l'exécutable avec --server (voir `requested()`).
##
## Mise en place dans la scène serveur du jeu : poser `game_id`, `level_id`, `content_hash`, `mode`, `schema` / `extra_commands`
## AVANT `_ready` (ou mettre `auto_start = false` et appeler `start(config)` à la main, comme les tests), puis connecter `started`.

## Le serveur est prêt : `host` écoute, `log` est ouvert. Le jeu branche ses signaux ici.
signal started
## Le serveur va s'arrêter (bilans, sauvegardes éventuelles du jeu).
signal stopping

## Faux = ne rien lire sur la ligne de commande (tests : `start()` est appelé à la main).
var auto_start: bool = true
var game_id: String = ""
var game_version: String = McfNetUtil.project_version()
var level_id: String = ""
var content_hash: PackedByteArray = PackedByteArray()
var mode: int = 0
## Arguments de ligne de commande propres au jeu (voir McfServerConfig.parse).
var schema: Dictionary = {}
## Commandes de console du jeu (voir McfServerConsole.extra_commands) et leur aide.
var extra_commands: Callable
var extra_help: String = ""
var hello_validator: Callable

var config: McfServerConfig
var host: McfHost
var console: McfServerConsole
var log: McfServerLog
var running: bool = false

const STATUS_EVERY := 60.0
var _status_timer: float = 0.0


## Vrai si le programme a été lancé pour servir une partie (argument --server ou export « serveur dédié »).
static func requested() -> bool:
	return OS.has_feature("dedicated_server") or OS.get_cmdline_user_args().has("--server")


func _ready() -> void:
	if auto_start:
		# Différé : les scripts parents ont fini leur `_ready` (et branché `started`) avant le démarrage.
		_auto_start.call_deferred()


func _auto_start() -> void:
	var parsed: Dictionary = McfServerConfig.parse(OS.get_cmdline_user_args(), schema)
	if not parsed["ok"]:
		printerr("Serveur : %s" % parsed["error"])
		get_tree().quit(2)
		return
	if start(parsed["config"]) != OK:
		get_tree().quit(3)


## Démarre le serveur. Renvoie OK, ou une erreur (déjà écrite dans le journal).
func start(p_config: McfServerConfig) -> Error:
	config = p_config
	log = McfServerLog.new(config.log_file)
	if not McfCodec.valid_id(game_id):
		log.error("identifiant de jeu manquant ou invalide (réglage du jeu)")
		return ERR_UNCONFIGURED
	host = McfHost.new()
	host.game_id = game_id
	host.game_version = game_version
	host.level_id = level_id
	host.content_hash = content_hash
	host.mode = mode
	host.seed_value = randi()
	host.max_players = config.max_players
	host.reserve_local = false # personne ne joue sur le serveur : toutes les places sont pour les clients
	host.hello_validator = hello_validator
	var err: Error = host.start(config.port, config.bind_address)
	if err != OK:
		log.error("impossible d'écouter sur le port %d (%s)" % [config.port, error_string(err)])
		host = null
		return err
	host.player_joined.connect(func(id: int, info: Dictionary) -> void: log.info("joueur %d rejoint : %s" % [id, info["name"]]))
	host.player_left.connect(func(id: int, reason: String) -> void: log.info("joueur %d parti : %s" % [id, reason]))
	host.peer_refused.connect(func(address: String, reason: String) -> void: log.warn("connexion refusée (%s) : %s" % [address, reason]))
	if config.console:
		console = McfServerConsole.new(self)
		console.extra_commands = extra_commands
		console.extra_help = extra_help
		console.start_reading()
		log.info("console d'administration active (help)")
	running = true
	log.info("serveur « %s » démarré : port %d, niveau %s, %d joueurs max, version %s" % [
		config.server_name, host.port(), level_id, config.max_players, game_version])
	started.emit()
	return OK


func _physics_process(delta: float) -> void:
	if running:
		host.poll(delta)


func _process(delta: float) -> void:
	if not running:
		return
	if console != null:
		console.process()
	_status_timer += delta
	if _status_timer >= STATUS_EVERY:
		_status_timer = 0.0
		log.info("état : %d joueur(s)" % host.player_count())


## Arrêt demandé (commande « stop ») : le jeu est prévenu, le port fermé, le processus se termine.
func request_stop() -> void:
	shutdown()
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		shutdown()
		get_tree().quit()


func shutdown() -> void:
	if not running:
		return
	running = false
	log.info("arrêt du serveur")
	stopping.emit()
	host.stop()
	log.close()


func _exit_tree() -> void:
	shutdown()
