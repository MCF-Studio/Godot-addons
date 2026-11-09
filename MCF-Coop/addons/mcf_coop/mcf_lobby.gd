class_name McfLobby
extends Node
## Préparation d'une partie en réseau depuis un menu : héberger (port, nombre de joueurs) ou rejoindre (adresse, port). Valide
## tout ce que demande l'interface (jamais fiable), traduit les échecs en messages lisibles et signale quand la partie peut
## commencer. N'ouvre aucune scène : le jeu réagit à `ready_to_play` puis récupère l'hôte ou le client avec `take_host()` /
## `take_client()` (il en devient propriétaire : c'est lui qui appelle `poll(delta)` et `stop()` / `leave()`).
##
## Hébergement : le port est ouvert tout de suite, la partie démarre, les amis arrivent en cours de route.
## Client : la poignée de main (jeu, version, places, contenu) est faite ICI ; `ready_to_play` n'est émis que si le contenu local
## correspond à ce qu'annonce l'hôte (`content_checker`), sinon un message clair est publié.
##
## Réglages à poser avant d'appeler host_game / join_game : `game_id`, `game_version` (défaut : version du projet),
## `content_checker` (côté client). Voir README.md.

signal status_changed(info: Dictionary)
signal ready_to_play(role: StringName)

const DEFAULT_PORT := 2302
const MIN_PORT := 1024
const DEFAULT_PLAYERS := 4

## Identifiant du jeu (≤ 32 caractères : lettres, chiffres, _ . : -). OBLIGATOIRE.
var game_id: String = ""
var game_version: String = McfNetUtil.project_version()
## Nombre maximal de joueurs qu'un hôte peut demander (≤ McfCodec.MAX_PLAYERS_LIMIT).
var max_players_limit: int = 8
## `func(level_id: String, content_hash: PackedByteArray) -> String` (voir McfClient.content_checker).
var content_checker: Callable

var host: McfHost
var client: McfClient

var _joining: bool = false


## Valeurs par défaut pour afficher l'écran : port, joueurs, adresses locales, version.
func menu_data(player_name: String = "") -> Dictionary:
	return {"port": DEFAULT_PORT, "max_players": DEFAULT_PLAYERS, "name": player_name, "addresses": McfNetUtil.lan_addresses(),
		"version": game_version, "status": {"state": "idle", "message": ""}}


# ------------------------------------------------------------------ héberger

## Démarre une partie hébergée. `options` (tous facultatifs) : `level_id` (String), `content_hash` (PackedByteArray, 32 octets),
## `mode` (int), `bind` (adresse d'écoute, "*" par défaut), `hello_validator` (Callable, voir McfHost). Renvoie vrai si le port est
## ouvert ; sinon l'erreur est publiée par `status_changed`.
func host_game(port: int, max_players: int, player_name: String, options: Dictionary = {}) -> bool:
	cancel()
	if not McfCodec.valid_id(game_id) or game_id.length() > McfCodec.MAX_GAME_ID:
		return _fail("Réglage du jeu invalide : identifiant de jeu manquant.")
	if port < MIN_PORT or port > 65535:
		return _fail("Le port doit être entre %d et 65535." % MIN_PORT)
	if max_players < 2 or max_players > mini(max_players_limit, McfCodec.MAX_PLAYERS_LIMIT):
		return _fail("Le nombre de joueurs doit être entre 2 et %d." % mini(max_players_limit, McfCodec.MAX_PLAYERS_LIMIT))
	var h := McfHost.new()
	h.game_id = game_id
	h.game_version = game_version
	h.level_id = str(options.get("level_id", ""))
	h.content_hash = options.get("content_hash", PackedByteArray())
	h.mode = int(options.get("mode", 0))
	h.seed_value = randi()
	h.max_players = max_players
	h.reserve_local = true
	if options.get("hello_validator") is Callable:
		h.hello_validator = options["hello_validator"]
	var err: Error = h.start(port, str(options.get("bind", "*")))
	if err != OK:
		return _fail("Impossible d'ouvrir le port %d. Un autre programme l'utilise peut-être, ou une partie est déjà hébergée." % port)
	host = h
	status_changed.emit({"state": "hosting", "message": "Partie ouverte sur le port %d (UDP)." % port})
	ready_to_play.emit(&"host")
	return true


# ------------------------------------------------------------------ rejoindre

func join_game(address: String, port: int, player_name: String, tags: Array[String] = []) -> bool:
	cancel()
	address = address.strip_edges()
	if not McfNetUtil.is_valid_address(address):
		return _fail("Adresse invalide : une adresse IP (192.168.1.20) ou un nom (monserveur.exemple.fr).")
	if port < 1 or port > 65535:
		return _fail("Le port doit être entre 1 et 65535.")
	var c := McfClient.new()
	c.content_checker = content_checker
	var err: Error = c.connect_to(address, port, McfNetUtil.clean_name(player_name), tags, game_id, game_version)
	if err != OK:
		return _fail("Connexion impossible : vérifie l'adresse et le port.")
	client = c
	_joining = true
	c.joined.connect(_on_joined)
	c.disconnected.connect(_on_disconnected)
	status_changed.emit({"state": "connecting", "message": "Connexion à %s:%d…" % [address, port]})
	return true


## Annule ce qui est en cours (connexion ou partie ouverte non encore reprise par le jeu).
func cancel() -> void:
	_joining = false
	if client != null:
		client.leave()
		client = null
	if host != null:
		host.stop()
		host = null


## Le jeu prend possession de l'hôte (le lobby ne le fermera plus).
func take_host() -> McfHost:
	var h: McfHost = host
	host = null
	return h


## Le jeu prend possession du client connecté.
func take_client() -> McfClient:
	var c: McfClient = client
	client = null
	return c


func _process(delta: float) -> void:
	if client != null and _joining:
		client.poll(delta)


func _on_joined(welcome: Dictionary) -> void:
	_joining = false
	status_changed.emit({"state": "joined", "message": "Connecté : partie de %d joueurs maximum." % int(welcome["max_players"])})
	ready_to_play.emit(&"client")


func _on_disconnected(reason: String) -> void:
	if not _joining:
		return
	_joining = false
	client = null
	_fail(reason if reason.length() > 0 else "Connexion perdue.")


func _fail(message: String) -> bool:
	status_changed.emit({"state": "error", "message": message})
	return false
