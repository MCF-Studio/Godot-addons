class_name McfClient
extends RefCounted
## Client réseau générique : se connecte à un hôte en ENet, fait la poignée de main (HELLO → WELCOME), vérifie que son contenu
## local correspond à l'empreinte annoncée (`content_checker`), puis envoie ses intentions / demandes et reçoit états et
## événements. Tout ce qui arrive passe par McfCodec (types autorisés : ceux d'un hôte). Aucune règle de jeu.
## À appeler : `poll(delta)` à chaque image physique.

signal joined(info: Dictionary)
signal disconnected(reason: String)
signal kicked(reason: String)
## Instantané reçu (seulement s'il est plus récent que le précédent).
signal state_received(tick: int, payload: PackedByteArray)
signal event_received(tick: int, kind: int, payload: PackedByteArray)
signal roster_received(players: Array)
signal rtt_updated(ms: int)

enum State { IDLE, CONNECTING, HANDSHAKE, JOINED, CLOSED }

const CONNECT_TIMEOUT := 6.0
const HANDSHAKE_TIMEOUT := 5.0
const MAX_EVENTS_PER_POLL := 512
const PING_INTERVAL := 1.0

var state: State = State.IDLE
var player_id: int = 0
## Message WELCOME décodé : player_id, level_id, content_hash, mode, seed, max_players.
var welcome: Dictionary = {}
## `func(level_id: String, content_hash: PackedByteArray) -> String` : message d'erreur, "" si le contenu local correspond.
## Appelé avant d'accepter la partie ; non défini = pas de contrôle.
var content_checker: Callable
var rtt_ms: int = 0

var _conn: ENetConnection
var _peer: ENetPacketPeer
var _name: String = ""
var _tags: Array[String] = []
var _game_id: String = ""
var _game_version: String = ""
var _age: float = 0.0
var _last_state_tick: int = -1
var _ping_timer: float = 0.0
var _ping_sent: Dictionary = {} ## jeton -> ms


## Lance la connexion. Renvoie OK, ou une erreur si l'adresse / le port sont invalides.
func connect_to(address: String, port: int, player_name: String, tags: Array[String], game_id: String, game_version: String) -> Error:
	if state != State.IDLE and state != State.CLOSED:
		return ERR_ALREADY_IN_USE
	if address.strip_edges().is_empty() or address.length() > 253 or port < 1 or port > 65535:
		return ERR_INVALID_PARAMETER
	_conn = ENetConnection.new()
	var err: Error = _conn.create_host(1, McfHost.CHANNELS)
	if err != OK:
		_conn = null
		return err
	_peer = _conn.connect_to_host(address.strip_edges(), port, McfHost.CHANNELS)
	if _peer == null:
		_conn.destroy()
		_conn = null
		return ERR_CANT_CONNECT
	_name = player_name
	_tags = tags
	_game_id = game_id
	_game_version = game_version
	_age = 0.0
	_last_state_tick = -1
	state = State.CONNECTING
	return OK


func is_joined() -> bool:
	return state == State.JOINED


func poll(delta: float) -> void:
	if _conn == null:
		return
	_age += delta
	for _i: int in MAX_EVENTS_PER_POLL:
		var ev: Array = _conn.service(0)
		var kind: int = ev[0]
		if kind == ENetConnection.EVENT_NONE or kind == ENetConnection.EVENT_ERROR:
			break
		match kind:
			ENetConnection.EVENT_CONNECT:
				state = State.HANDSHAKE
				_age = 0.0
				_send_raw(McfHost.CHANNEL_RELIABLE, McfCodec.encode_hello(_game_id, _game_version, _name, _tags), ENetPacketPeer.FLAG_RELIABLE)
			ENetConnection.EVENT_DISCONNECT:
				_close("connexion perdue" if state == State.JOINED else "connexion refusée ou hôte introuvable")
				return
			ENetConnection.EVENT_RECEIVE:
				_on_packet(_peer.get_packet())
				if _conn == null:
					return
	if state == State.CONNECTING and _age > CONNECT_TIMEOUT:
		_close("hôte introuvable (délai dépassé)")
	elif state == State.HANDSHAKE and _age > HANDSHAKE_TIMEOUT:
		_close("l'hôte n'a pas répondu à la poignée de main")
	elif state == State.JOINED:
		_ping_timer += delta
		if _ping_timer >= PING_INTERVAL:
			_ping_timer = 0.0
			var token: int = Time.get_ticks_msec() & 0x7FFFFFFF
			_ping_sent[token] = Time.get_ticks_msec()
			_send_raw(McfHost.CHANNEL_STATE, McfCodec.encode_ping(token), 0)
			if _ping_sent.size() > 8:
				_ping_sent.erase(_ping_sent.keys()[0])


## Intention pour l'image physique `tick`. Non fiable par défaut (la suivante arrive bientôt) ; `reliable = true` pour un appui
## unique qui ne doit jamais se perdre (saut, tir…).
func send_input(tick: int, payload: PackedByteArray, reliable: bool = false) -> void:
	if state != State.JOINED:
		return
	var bytes: PackedByteArray = McfCodec.encode_input(tick, payload)
	if bytes.is_empty():
		return
	_send_raw(McfHost.CHANNEL_RELIABLE if reliable else McfHost.CHANNEL_STATE, bytes, ENetPacketPeer.FLAG_RELIABLE if reliable else 0)


## Demande ponctuelle (achat, choix, « prêt »…) : toujours fiable. L'hôte la limite et la revalide.
func send_request(kind: int, payload: PackedByteArray = PackedByteArray()) -> void:
	if state != State.JOINED:
		return
	var bytes: PackedByteArray = McfCodec.encode_request(kind, payload)
	if not bytes.is_empty():
		_send_raw(McfHost.CHANNEL_RELIABLE, bytes, ENetPacketPeer.FLAG_RELIABLE)


func leave() -> void:
	if _conn == null:
		return
	_peer.peer_disconnect_now()
	_conn.flush()
	_close("tu as quitté la partie")


## Envoi garde-fou : jamais vers un pair qui n'est plus connecté.
func _send_raw(channel: int, bytes: PackedByteArray, flags: int) -> void:
	if _peer != null and _peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
		_peer.send(channel, bytes, flags)


func _on_packet(bytes: PackedByteArray) -> void:
	var result: Dictionary = McfCodec.decode(bytes, McfCodec.HOST_TYPES)
	if not result["ok"]:
		push_warning("McfClient : paquet de l'hôte refusé (%s)" % result["error"])
		return
	var msg: Dictionary = result["msg"]
	match int(msg["type"]):
		McfCodec.MsgType.WELCOME:
			if state != State.HANDSHAKE:
				return
			var problem: String = str(content_checker.call(msg["level_id"], msg["content_hash"])) if content_checker.is_valid() else ""
			if not problem.is_empty():
				_peer.peer_disconnect_now()
				_conn.flush()
				_close(problem)
				return
			state = State.JOINED
			player_id = int(msg["player_id"])
			welcome = msg
			joined.emit(msg)
		McfCodec.MsgType.KICK:
			kicked.emit(str(msg["reason"]))
			_close(str(msg["reason"]))
		McfCodec.MsgType.STATE:
			if state == State.JOINED and int(msg["tick"]) > _last_state_tick:
				_last_state_tick = int(msg["tick"])
				state_received.emit(int(msg["tick"]), msg["payload"])
		McfCodec.MsgType.EVENT:
			if state == State.JOINED:
				event_received.emit(int(msg["tick"]), int(msg["kind"]), msg["payload"])
		McfCodec.MsgType.ROSTER:
			if state == State.JOINED:
				roster_received.emit(msg["players"])
		McfCodec.MsgType.PONG:
			var sent: Variant = _ping_sent.get(int(msg["token"]))
			if sent != null:
				_ping_sent.erase(int(msg["token"]))
				rtt_ms = Time.get_ticks_msec() - int(sent)
				rtt_updated.emit(rtt_ms)


func _close(reason: String) -> void:
	if state == State.CLOSED:
		return
	state = State.CLOSED
	if _conn != null:
		_conn.destroy()
	_conn = null
	_peer = null
	disconnected.emit(reason)
