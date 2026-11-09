class_name McfHost
extends RefCounted
## Hôte réseau générique : écoute en ENet, fait la poignée de main (jeu, version, places, nom), puis reçoit les intentions et
## demandes des joueurs. Sert le jeu hébergé depuis un client comme le serveur dédié. AUCUNE règle de jeu ici : le jeu lit
## `input_received` / `request_received` (charges utiles à décoder avec McfCodec.Reader) et envoie `broadcast_state` / `send_event`.
##
## Défenses : un pair qui n'a pas fini la poignée de main est coupé au bout de `handshake_timeout` s (et leur nombre est limité) ;
## tout paquet est limité en débit, borné en taille et décodé par McfCodec (types autorisés : ceux d'un client) ; un pair qui
## envoie trop de paquets invalides, trop gros ou qui inonde est expulsé ; une même adresse ne peut pas ouvrir plus de
## `max_connects_per_address` connexions par fenêtre de CONNECT_WINDOW s ; adresses bannissables ; ENet reçoit un plafond de
## bande passante entrante ; un pair muet est détecté en quelques secondes ; l'identifiant d'un joueur vient du pair ENet,
## jamais d'un champ du paquet ; jamais d'envoi vers un pair déconnecté.
## À appeler : `poll(delta)` à chaque image physique.

signal player_joined(id: int, info: Dictionary)
signal player_left(id: int, reason: String)
## Intention d'un joueur (déjà attribuée à son pair). `payload` : octets du jeu, ≤ McfCodec.MAX_CLIENT_PAYLOAD.
signal input_received(id: int, tick: int, payload: PackedByteArray)
## Demande ponctuelle d'un joueur (limitée à `request_per_second`). Le jeu revalide tout (prix, droits…).
signal request_received(id: int, kind: int, payload: PackedByteArray)
## Un pair a été refusé ou coupé avant d'être joueur (journal de l'hôte).
signal peer_refused(address: String, reason: String)

const CHANNEL_RELIABLE := 0
const CHANNEL_STATE := 1
const CHANNELS := 2
const HANDSHAKE_TIMEOUT := 5.0
const MAX_PENDING := 8
const MAX_BAD_PACKETS := 8
const MAX_FLOOD_REFUSALS := 30
const MAX_EVENTS_PER_POLL := 512
const MAX_OVERSIZE := 3
const CONNECT_WINDOW := 10.0
const MAX_CONNECTS_PER_ADDRESS := 12
const INCOMING_BYTES_PER_PLAYER := 64 * 1024
const REQUEST_PER_SECOND := 5.0
const PEER_TIMEOUT_MS := [32, 4000, 12000]

## Identifiant du jeu : un client d'un autre jeu est refusé (évite de mélanger deux jeux qui utilisent l'addon).
var game_id: String = ""
var game_version: String = ""
## Niveau / carte (identifiant), empreinte du contenu que les clients doivent avoir (32 octets, vide = aucune), mode de jeu
## (numéro choisi par le jeu) et graine commune : envoyés dans WELCOME.
var level_id: String = ""
var content_hash: PackedByteArray = PackedByteArray()
var mode: int = 0
var seed_value: int = 0
var max_players: int = 4
## Vrai quand l'hôte joue aussi (jeu hébergé depuis le client) : le joueur 1 est réservé au joueur local.
var reserve_local: bool = true
var handshake_timeout: float = HANDSHAKE_TIMEOUT
## Connexions permises par adresse et par fenêtre (réglable : une famille derrière une même box peut en avoir besoin).
var max_connects_per_address: int = MAX_CONNECTS_PER_ADDRESS
## Débit permis par joueur (paquets / s et octets / s, rafale d'une seconde).
var packets_per_second: float = 90.0
var bytes_per_second: float = 24000.0
var request_per_second: float = REQUEST_PER_SECOND
## Contrôle supplémentaire du jeu à la poignée de main : `func(info: Dictionary) -> String` (info = {name, tags}), renvoie ""
## pour accepter ou la raison du refus.
var hello_validator: Callable

## Adresses IP bannies pour la durée de cette partie (ban manuel de l'hôte ou du serveur).
var banned: Dictionary = {}

var _conn: ENetConnection
var _pending: Dictionary = {} ## ENetPacketPeer -> {age, rate, bad, refused, oversize}
var _players: Dictionary = {} ## id -> {peer, name, tags, rate, req_rate, bad, refused, oversize}
var _peer_ids: Dictionary = {} ## ENetPacketPeer -> id
var _connects: Dictionary = {} ## adresse IP -> instants (ms) des connexions récentes


## Ouvre le port (0 = au choix du système, voir `port()`). Renvoie OK ou le code d'erreur d'ENet.
func start(port: int, bind_address: String = "*") -> Error:
	if port < 0 or port > 65535 or max_players < 1 or max_players > McfCodec.MAX_PLAYERS_LIMIT:
		return ERR_INVALID_PARAMETER
	_conn = ENetConnection.new()
	var err: Error = _conn.create_host_bound(bind_address, port, max_players + MAX_PENDING, CHANNELS)
	if err != OK:
		_conn = null
		return err
	_conn.bandwidth_limit(INCOMING_BYTES_PER_PLAYER * max_players, 0)
	return OK


func port() -> int:
	return _conn.get_local_port() if _conn != null else 0


func is_running() -> bool:
	return _conn != null


func player_ids() -> Array[int]:
	var out: Array[int] = []
	for id: int in _players:
		out.append(id)
	return out


func player_count() -> int:
	return _players.size()


func player_name(id: int) -> String:
	return str((_players.get(id, {}) as Dictionary).get("name", ""))


func player_tags(id: int) -> Array[String]:
	var out: Array[String] = []
	out.assign((_players.get(id, {}) as Dictionary).get("tags", []))
	return out


## Dernier temps aller-retour mesuré par ENet (ms) avec un joueur, -1 s'il n'existe pas.
func rtt_ms(id: int) -> int:
	var d: Dictionary = _players.get(id, {})
	return int((d["peer"] as ENetPacketPeer).get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)) if not d.is_empty() else -1


func poll(delta: float) -> void:
	if _conn == null:
		return
	for d: Dictionary in _pending.values():
		d["age"] = float(d["age"]) + delta
		(d["rate"] as McfRateLimiter).refill(delta)
	for d: Dictionary in _players.values():
		(d["rate"] as McfRateLimiter).refill(delta)
		(d["req_rate"] as McfRateLimiter).refill(delta)
	for _i: int in MAX_EVENTS_PER_POLL:
		if _conn == null:
			return
		var ev: Array = _conn.service(0)
		var kind: int = ev[0]
		if kind == ENetConnection.EVENT_NONE or kind == ENetConnection.EVENT_ERROR:
			break
		var peer := ev[1] as ENetPacketPeer
		match kind:
			ENetConnection.EVENT_CONNECT:
				_on_connect(peer)
			ENetConnection.EVENT_DISCONNECT:
				_on_disconnect(peer)
			ENetConnection.EVENT_RECEIVE:
				_on_packet(peer, peer.get_packet())
	for peer: ENetPacketPeer in _pending.keys():
		if float((_pending[peer] as Dictionary)["age"]) > handshake_timeout:
			_drop_pending(peer, "poignée de main trop lente")


# ------------------------------------------------------------------ envoi

## Envoie à un joueur (fiable = événements, sinon instantanés).
func send_to(id: int, bytes: PackedByteArray, reliable: bool = false) -> void:
	var d: Dictionary = _players.get(id, {})
	if d.is_empty() or bytes.is_empty():
		return
	_send(d["peer"], bytes, reliable)


func broadcast(bytes: PackedByteArray, reliable: bool = false) -> void:
	if bytes.is_empty():
		return
	for d: Dictionary in _players.values():
		_send(d["peer"], bytes, reliable)


## Instantané de l'état (non fiable : le suivant arrive bientôt ; le client ignore les plus anciens que celui déjà reçu).
func broadcast_state(tick: int, payload: PackedByteArray) -> void:
	broadcast(McfCodec.encode_state(tick, payload), false)


func send_state_to(id: int, tick: int, payload: PackedByteArray) -> void:
	send_to(id, McfCodec.encode_state(tick, payload), false)


## Événement fiable et ordonné, à tous.
func broadcast_event(tick: int, kind: int, payload: PackedByteArray = PackedByteArray()) -> void:
	broadcast(McfCodec.encode_event(tick, kind, payload), true)


func send_event_to(id: int, tick: int, kind: int, payload: PackedByteArray = PackedByteArray()) -> void:
	send_to(id, McfCodec.encode_event(tick, kind, payload), true)


## Liste des joueurs [{id, name, score}] envoyée à tous (à chaque arrivée / départ, et quand les scores changent).
func broadcast_roster(players: Array) -> void:
	broadcast(McfCodec.encode_roster(players), true)


## Adresse IP (sans port) d'un joueur ; "" s'il est inconnu.
func address_of(id: int) -> String:
	var d: Dictionary = _players.get(id, {})
	return str((d["peer"] as ENetPacketPeer).get_remote_address()) if not d.is_empty() else ""


## Les joueurs pour une console d'administration : [{id, name, address, rtt}].
func players_info() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: int in _players:
		out.append({"id": id, "name": _players[id]["name"], "address": address_of(id), "rtt": rtt_ms(id)})
	return out


# ------------------------------------------------------------------ administration

## Expulse ET interdit l'adresse jusqu'à la fin de la partie (ou `unban`).
func ban(id: int, reason: String = "banni") -> bool:
	var address: String = address_of(id)
	if address.is_empty():
		return false
	banned[address] = true
	return kick(id, reason)


func unban(address: String) -> bool:
	return banned.erase(address)


## Un joueur a fait quelque chose d'invalide côté jeu (offre inconnue, valeur absurde…) : même compteur que les paquets invalides.
func strike(id: int, why: String) -> void:
	var d: Dictionary = _players.get(id, {})
	if not d.is_empty():
		_bad(d["peer"], id, d, why)


## Expulse un joueur (avec la raison). Faux s'il n'existe pas.
func kick(id: int, reason: String) -> bool:
	var d: Dictionary = _players.get(id, {})
	if d.is_empty():
		return false
	var peer: ENetPacketPeer = d["peer"]
	_send(peer, McfCodec.encode_kick(reason), true)
	_forget_player(id, "expulsé : %s" % reason)
	peer.peer_disconnect_later()
	return true


## Envoie tout de suite ce qui est en attente (avant de fermer).
func flush() -> void:
	if _conn != null:
		_conn.flush()


func stop() -> void:
	if _conn == null:
		return
	for peer: ENetPacketPeer in _peer_ids.keys():
		_send(peer, McfCodec.encode_kick("La partie est fermée"), true)
	_conn.flush()
	for peer: ENetPacketPeer in _peer_ids.keys():
		peer.peer_disconnect_now()
	for peer: ENetPacketPeer in _pending.keys():
		peer.peer_disconnect_now()
	var ids: Array = _players.keys()
	_players.clear()
	_peer_ids.clear()
	_pending.clear()
	_conn.flush()
	_conn.destroy()
	_conn = null
	for id: int in ids:
		player_left.emit(id, "partie fermée")


# ------------------------------------------------------------------ pairs

func _on_connect(peer: ENetPacketPeer) -> void:
	var ip: String = str(peer.get_remote_address())
	if banned.has(ip):
		peer_refused.emit(_address(peer), "adresse bannie")
		peer.peer_disconnect_now()
		return
	if not _connect_allowed(ip):
		peer_refused.emit(_address(peer), "trop de connexions récentes depuis cette adresse")
		peer.peer_disconnect_now()
		return
	peer.set_timeout(PEER_TIMEOUT_MS[0], PEER_TIMEOUT_MS[1], PEER_TIMEOUT_MS[2])
	if _pending.size() >= MAX_PENDING:
		peer_refused.emit(_address(peer), "trop de connexions en attente")
		peer.peer_disconnect_now()
		return
	_pending[peer] = {"age": 0.0, "rate": _new_rate(), "bad": 0, "refused": 0, "oversize": 0}


func _new_rate() -> McfRateLimiter:
	return McfRateLimiter.new(packets_per_second, bytes_per_second, 1.0)


## Limite le nombre de connexions d'une même adresse (fenêtre glissante) : un pair qui se reconnecte en boucle est refusé.
func _connect_allowed(ip: String) -> bool:
	var now: int = Time.get_ticks_msec()
	var recent: Array = _connects.get(ip, [])
	recent = recent.filter(func(t: int) -> bool: return now - t < int(CONNECT_WINDOW * 1000.0))
	recent.append(now)
	_connects[ip] = recent
	if _connects.size() > 512: # la table elle-même est bornée
		for key: String in _connects.keys():
			if (_connects[key] as Array).is_empty() or now - int((_connects[key] as Array).back()) > int(CONNECT_WINDOW * 1000.0):
				_connects.erase(key)
	return recent.size() <= max_connects_per_address


func _on_disconnect(peer: ENetPacketPeer) -> void:
	_pending.erase(peer)
	if _peer_ids.has(peer):
		_forget_player(_peer_ids[peer], "déconnecté")


func _on_packet(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id: int = _peer_ids.get(peer, 0)
	var state: Dictionary = _players[id] if id != 0 else _pending.get(peer, {})
	if state.is_empty():
		return
	if bytes.size() > McfCodec.MAX_PACKET:
		state["oversize"] = int(state.get("oversize", 0)) + 1
		if int(state["oversize"]) > MAX_OVERSIZE:
			_expel(peer, id, "paquets trop gros")
		return
	if not (state["rate"] as McfRateLimiter).allow(bytes.size()):
		state["refused"] = int(state["refused"]) + 1
		if int(state["refused"]) > MAX_FLOOD_REFUSALS:
			_expel(peer, id, "trop de paquets")
		return
	var result: Dictionary = McfCodec.decode(bytes, McfCodec.CLIENT_TYPES)
	if not result["ok"]:
		_bad(peer, id, state, str(result["error"]))
		return
	var msg: Dictionary = result["msg"]
	match int(msg["type"]):
		McfCodec.MsgType.HELLO:
			if id != 0:
				_bad(peer, id, state, "HELLO en double")
			else:
				_on_hello(peer, msg)
		McfCodec.MsgType.INPUT:
			if id == 0:
				_bad(peer, id, state, "intention avant la poignée de main")
			else:
				input_received.emit(id, int(msg["tick"]), msg["payload"])
		McfCodec.MsgType.PING:
			if id != 0:
				_send(peer, McfCodec.encode_ping(int(msg["token"]), true), false)
		McfCodec.MsgType.REQUEST:
			if id == 0:
				_bad(peer, id, state, "demande avant la poignée de main")
			elif (state["req_rate"] as McfRateLimiter).allow(0):
				request_received.emit(id, int(msg["kind"]), msg["payload"])
			else:
				_bad(peer, id, state, "trop de demandes")


func _on_hello(peer: ENetPacketPeer, msg: Dictionary) -> void:
	if str(msg["game_id"]) != game_id:
		_refuse(peer, "ce serveur héberge un autre jeu")
		return
	if not same_version(str(msg["game"]), game_version):
		_refuse(peer, "version du jeu différente (hôte %s, toi %s)" % [game_version, msg["game"]])
		return
	var id: int = _free_id()
	if id == 0:
		_refuse(peer, "Partie pleine")
		return
	var name: String = _unique_name(McfNetUtil.clean_name(str(msg["name"])))
	if hello_validator.is_valid():
		var problem: String = str(hello_validator.call({"name": name, "tags": msg["tags"]}))
		if not problem.is_empty():
			_refuse(peer, problem)
			return
	_pending.erase(peer)
	_players[id] = {"peer": peer, "name": name, "tags": msg["tags"], "rate": _new_rate(), "bad": 0, "refused": 0,
		"oversize": 0, "req_rate": McfRateLimiter.new(request_per_second, 100000.0, 1.0)}
	_peer_ids[peer] = id
	_send(peer, McfCodec.encode_welcome(id, level_id, content_hash, mode, seed_value, max_players), true)
	player_joined.emit(id, {"name": name, "tags": msg["tags"]})


func _refuse(peer: ENetPacketPeer, reason: String) -> void:
	peer_refused.emit(_address(peer), reason)
	_send(peer, McfCodec.encode_kick(reason), true)
	_pending.erase(peer)
	peer.peer_disconnect_later()


func _bad(peer: ENetPacketPeer, id: int, state: Dictionary, why: String) -> void:
	state["bad"] = int(state["bad"]) + 1
	if int(state["bad"]) > MAX_BAD_PACKETS:
		_expel(peer, id, "paquets invalides (%s)" % why)


func _expel(peer: ENetPacketPeer, id: int, reason: String) -> void:
	if id != 0:
		kick(id, reason)
	else:
		_drop_pending(peer, reason)


func _drop_pending(peer: ENetPacketPeer, reason: String) -> void:
	peer_refused.emit(_address(peer), reason)
	_pending.erase(peer)
	_send(peer, McfCodec.encode_kick(reason), true)
	peer.peer_disconnect_later()


func _forget_player(id: int, reason: String) -> void:
	var d: Dictionary = _players.get(id, {})
	if d.is_empty():
		return
	_peer_ids.erase(d["peer"])
	_players.erase(id)
	player_left.emit(id, reason)


func _send(peer: ENetPacketPeer, bytes: PackedByteArray, reliable: bool) -> void:
	# Jamais vers un pair qui n'est plus connecté (départs en rafale : l'événement de déconnexion n'est pas encore traité).
	if peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
		return
	peer.send(CHANNEL_RELIABLE if reliable else CHANNEL_STATE, bytes, ENetPacketPeer.FLAG_RELIABLE if reliable else 0)


func _address(peer: ENetPacketPeer) -> String:
	return "%s:%d" % [peer.get_remote_address(), peer.get_remote_port()]


## Plus petit numéro libre (le 1 est réservé au joueur local d'un hôte qui joue). 0 = plein.
func _free_id() -> int:
	var first: int = 2 if reserve_local else 1
	var used: int = _players.size() + (1 if reserve_local else 0)
	if used >= max_players:
		return 0
	for id: int in range(first, McfCodec.MAX_PLAYERS_LIMIT + 1):
		if not _players.has(id):
			return id
	return 0


## Les versions « majeure.mineure » doivent être identiques (le correctif ne change pas le protocole).
static func same_version(a: String, b: String) -> bool:
	var pa: PackedStringArray = a.split(".")
	var pb: PackedStringArray = b.split(".")
	return pa.size() >= 2 and pb.size() >= 2 and pa[0] == pb[0] and pa[1] == pb[1]


func _unique_name(name: String) -> String:
	var taken: Dictionary = {}
	for d: Dictionary in _players.values():
		taken[d["name"]] = true
	if not taken.has(name):
		return name
	var n: int = 2
	while taken.has("%s %d" % [name.left(McfCodec.MAX_NAME - 3), n]):
		n += 1
	return "%s %d" % [name.left(McfCodec.MAX_NAME - 3), n]
