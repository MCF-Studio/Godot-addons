class_name McfCodec
extends RefCounted
## Codec réseau générique de `mcf_coop` : encode / décode les messages entre client et hôte en octets, SANS réseau.
## C'est le SEUL endroit qui transforme des octets reçus en données : tout est borné et vérifié ; un paquet invalide est
## refusé avec un message (jamais d'erreur ni de plantage), jamais de `Variant` arbitraire ni d'objet décodé.
##
## Format : [magie 'M','C'][version du protocole u8][type u8][corps]. Petit-boutiste. Les chaînes sont en UTF-8 valide, sans
## caractères de contrôle, avec une longueur maximale ; les listes ont un nombre maximal d'éléments.
##
## Le jeu ne décrit PAS ses messages ici : il met ses propres octets dans une « charge utile » (`payload`) de INPUT / REQUEST /
## STATE / EVENT, qu'il encode et décode lui-même avec `Writer` et `Reader` (mêmes bornes strictes). Voir README.md.
##
## Un client n'envoie que : HELLO, PING, INPUT, REQUEST. L'hôte envoie : WELCOME, KICK, PONG, ROSTER, STATE, EVENT.

const PROTOCOL_VERSION := 1
const MAGIC_0 := 0x4D # M
const MAGIC_1 := 0x43 # C
const HEADER_SIZE := 4
## Taille maximale d'un paquet accepté (octets), en-tête compris.
const MAX_PACKET := 8192
## Charge utile maximale d'un client (INPUT / REQUEST) : une intention est petite, un client n'a pas à envoyer plus.
const MAX_CLIENT_PAYLOAD := 512
## Charge utile maximale de l'hôte (STATE / EVENT).
const MAX_HOST_PAYLOAD := MAX_PACKET - 16

const MAX_PLAYERS_LIMIT := 16
const MAX_NAME := 20
const MAX_GAME_ID := 32
const MAX_GAME_VERSION := 16
const MAX_ID := 48
const MAX_TAGS := 6
const MAX_REASON := 64

enum MsgType { HELLO = 1, WELCOME = 2, KICK = 3, PING = 4, PONG = 5, ROSTER = 6, INPUT = 7, REQUEST = 8, STATE = 9, EVENT = 10 }
## Types de message qu'un CLIENT a le droit d'envoyer à l'hôte.
const CLIENT_TYPES: Array[int] = [MsgType.HELLO, MsgType.PING, MsgType.INPUT, MsgType.REQUEST]
## Types qu'un HÔTE envoie aux clients.
const HOST_TYPES: Array[int] = [MsgType.WELCOME, MsgType.KICK, MsgType.PONG, MsgType.ROSTER, MsgType.STATE, MsgType.EVENT]

static var _id_regex: RegEx = RegEx.create_from_string("^[A-Za-z0-9_.:-]+$")


# ------------------------------------------------------------------ écriture

class Writer:
	extends RefCounted
	var buf := PackedByteArray()

	func u8(v: int) -> void:
		buf.append(clampi(v, 0, 255))

	func i8(v: int) -> void:
		buf.append(clampi(v, -128, 127) & 0xFF)

	func u16(v: int) -> void:
		var at: int = buf.size()
		buf.resize(at + 2)
		buf.encode_u16(at, clampi(v, 0, 65535))

	func i16(v: int) -> void:
		var at: int = buf.size()
		buf.resize(at + 2)
		buf.encode_s16(at, clampi(v, -32768, 32767))

	func u32(v: int) -> void:
		var at: int = buf.size()
		buf.resize(at + 4)
		buf.encode_u32(at, clampi(v, 0, 4294967295))

	func f32(v: float) -> void:
		var at: int = buf.size()
		buf.resize(at + 4)
		buf.encode_float(at, v if is_finite(v) else 0.0)

	## Texte UTF-8 précédé de sa longueur en octets (255 octets au plus).
	func text(s: String, max_len: int) -> void:
		var bytes: PackedByteArray = s.left(max_len).to_utf8_buffer()
		if bytes.size() > 255:
			bytes = bytes.slice(0, 255)
		u8(bytes.size())
		buf.append_array(bytes)

	func raw(bytes: PackedByteArray) -> void:
		buf.append_array(bytes)


# ------------------------------------------------------------------ lecture

class Reader:
	extends RefCounted
	var buf: PackedByteArray
	var pos: int = 0
	var error: String = ""

	func _init(p_buf: PackedByteArray, start: int = 0) -> void:
		buf = p_buf
		pos = start

	func ok() -> bool:
		return error.is_empty()

	func fail(message: String) -> void:
		if error.is_empty():
			error = message

	func remaining() -> int:
		return buf.size() - pos

	func _need(n: int) -> bool:
		if not error.is_empty():
			return false
		if pos + n > buf.size():
			fail("paquet tronqué")
			return false
		return true

	func u8() -> int:
		if not _need(1):
			return 0
		pos += 1
		return buf[pos - 1]

	func i8() -> int:
		var v: int = u8()
		return v - 256 if v > 127 else v

	func u16() -> int:
		if not _need(2):
			return 0
		pos += 2
		return buf.decode_u16(pos - 2)

	func i16() -> int:
		if not _need(2):
			return 0
		pos += 2
		return buf.decode_s16(pos - 2)

	func u32() -> int:
		if not _need(4):
			return 0
		pos += 4
		return buf.decode_u32(pos - 4)

	## Nombre fini dans [lo, hi] (sinon la lecture échoue).
	func f32(lo: float, hi: float, what: String) -> float:
		if not _need(4):
			return 0.0
		pos += 4
		var v: float = buf.decode_float(pos - 4)
		if not is_finite(v) or v < lo or v > hi:
			fail("%s hors bornes" % what)
			return 0.0
		return v

	func text(max_len: int, what: String) -> String:
		var n: int = u8()
		if not _need(n):
			return ""
		var bytes: PackedByteArray = buf.slice(pos, pos + n)
		pos += n
		var s: String = bytes.get_string_from_utf8()
		# Octets invalides : la conversion les remplace ; on exige un aller-retour identique.
		if s.to_utf8_buffer() != bytes:
			fail("%s : texte invalide" % what)
			return ""
		if s.length() > max_len:
			fail("%s trop long" % what)
			return ""
		for i: int in s.length():
			var code: int = s.unicode_at(i)
			if code < 32 or code == 127:
				fail("%s : caractère interdit" % what)
				return ""
		return s

	func raw(n: int) -> PackedByteArray:
		if not _need(n):
			return PackedByteArray()
		pos += n
		return buf.slice(pos - n, pos)


# ------------------------------------------------------------------ encodage

static func _begin(type: int) -> Writer:
	var w := Writer.new()
	w.u8(MAGIC_0)
	w.u8(MAGIC_1)
	w.u8(PROTOCOL_VERSION)
	w.u8(type)
	return w


static func encode_hello(game_id: String, game_version: String, player_name: String, tags: Array[String]) -> PackedByteArray:
	var w: Writer = _begin(MsgType.HELLO)
	w.text(game_id, MAX_GAME_ID)
	w.text(game_version, MAX_GAME_VERSION)
	w.text(player_name, MAX_NAME)
	w.u8(mini(tags.size(), MAX_TAGS))
	for i: int in mini(tags.size(), MAX_TAGS):
		w.text(tags[i], MAX_ID)
	return w.buf


## `level_id` : identifiant de la carte / du niveau (facultatif, vide autorisé) ; `content_hash` : 32 octets (empreinte du contenu
## que les clients doivent posséder à l'identique, vide = aucune) ; `mode` : numéro de mode de jeu choisi par le jeu ;
## `seed_value` : graine aléatoire commune.
static func encode_welcome(player_id: int, level_id: String, content_hash: PackedByteArray, mode: int, seed_value: int, max_players: int) -> PackedByteArray:
	var w: Writer = _begin(MsgType.WELCOME)
	w.u8(player_id)
	w.text(level_id, MAX_ID)
	var hash32: PackedByteArray = content_hash.slice(0, 32)
	hash32.resize(32)
	w.raw(hash32)
	w.u8(mode)
	w.u32(seed_value)
	w.u8(max_players)
	return w.buf


## Liste des joueurs : [{id, name, score}].
static func encode_roster(players: Array) -> PackedByteArray:
	var w: Writer = _begin(MsgType.ROSTER)
	var n: int = mini(players.size(), MAX_PLAYERS_LIMIT)
	w.u8(n)
	for i: int in n:
		w.u8(int(players[i]["id"]))
		w.text(str(players[i]["name"]), MAX_NAME)
		w.u32(int(players[i].get("score", 0)))
	return w.buf


static func encode_kick(reason: String) -> PackedByteArray:
	var w: Writer = _begin(MsgType.KICK)
	w.text(reason, MAX_REASON)
	return w.buf


static func encode_ping(token: int, pong: bool = false) -> PackedByteArray:
	var w: Writer = _begin(MsgType.PONG if pong else MsgType.PING)
	w.u32(token)
	return w.buf


## Intention d'un joueur pour l'image physique `tick` (client → hôte). Vide si la charge utile dépasse MAX_CLIENT_PAYLOAD.
static func encode_input(tick: int, payload: PackedByteArray) -> PackedByteArray:
	if payload.size() > MAX_CLIENT_PAYLOAD:
		return PackedByteArray()
	var w: Writer = _begin(MsgType.INPUT)
	w.u32(tick)
	w.raw(payload)
	return w.buf


## Demande ponctuelle d'un client (achat, choix, « prêt »…), de type `kind` défini par le jeu.
static func encode_request(kind: int, payload: PackedByteArray) -> PackedByteArray:
	if payload.size() > MAX_CLIENT_PAYLOAD:
		return PackedByteArray()
	var w: Writer = _begin(MsgType.REQUEST)
	w.u8(kind)
	w.raw(payload)
	return w.buf


## Instantané de l'état (hôte → clients). Vide si la charge utile dépasse MAX_HOST_PAYLOAD.
static func encode_state(tick: int, payload: PackedByteArray) -> PackedByteArray:
	if payload.size() > MAX_HOST_PAYLOAD:
		return PackedByteArray()
	var w: Writer = _begin(MsgType.STATE)
	w.u32(tick)
	w.raw(payload)
	return w.buf


## Événement fiable (hôte → clients), de type `kind` défini par le jeu.
static func encode_event(tick: int, kind: int, payload: PackedByteArray) -> PackedByteArray:
	if payload.size() > MAX_HOST_PAYLOAD:
		return PackedByteArray()
	var w: Writer = _begin(MsgType.EVENT)
	w.u32(tick)
	w.u8(kind)
	w.raw(payload)
	return w.buf


# ------------------------------------------------------------------ décodage

## Décode un paquet. Renvoie {"ok": true, "error": "", "msg": {"type": MsgType, …}} ou {"ok": false, "error": "…", "msg": {}}.
## `allowed` : types acceptés (CLIENT_TYPES côté hôte, HOST_TYPES côté client) ; vide = tous.
static func decode(bytes: PackedByteArray, allowed: Array[int] = []) -> Dictionary:
	if bytes.size() > MAX_PACKET:
		return _fail("paquet trop gros (%d octets)" % bytes.size())
	if bytes.size() < HEADER_SIZE:
		return _fail("paquet trop court")
	if bytes[0] != MAGIC_0 or bytes[1] != MAGIC_1:
		return _fail("ce n'est pas un paquet de ce jeu")
	if bytes[2] != PROTOCOL_VERSION:
		return _fail("version de protocole %d non prise en charge (attendu %d)" % [bytes[2], PROTOCOL_VERSION])
	var type: int = bytes[3]
	if not allowed.is_empty() and not allowed.has(type):
		return _fail("type de message %d non autorisé de ce côté" % type)
	var r := Reader.new(bytes, HEADER_SIZE)
	var msg: Dictionary = {"type": type}
	match type:
		MsgType.HELLO:
			msg["game_id"] = r.text(MAX_GAME_ID, "identifiant du jeu")
			msg["game"] = r.text(MAX_GAME_VERSION, "version du jeu")
			msg["name"] = r.text(MAX_NAME, "nom")
			var count: int = r.u8()
			if count > MAX_TAGS:
				r.fail("trop d'étiquettes")
			var tags: Array[String] = []
			for i: int in mini(count, MAX_TAGS):
				var id: String = r.text(MAX_ID, "étiquette")
				if r.ok() and not valid_id(id):
					r.fail("identifiant d'étiquette invalide")
				tags.append(id)
			msg["tags"] = tags
		MsgType.WELCOME:
			msg["player_id"] = r.u8()
			if r.ok() and (msg["player_id"] < 1 or msg["player_id"] > MAX_PLAYERS_LIMIT):
				r.fail("numéro de joueur invalide")
			msg["level_id"] = r.text(MAX_ID, "niveau")
			if r.ok() and not msg["level_id"].is_empty() and not valid_id(msg["level_id"]):
				r.fail("identifiant de niveau invalide")
			msg["content_hash"] = r.raw(32)
			msg["mode"] = r.u8()
			msg["seed"] = r.u32()
			msg["max_players"] = r.u8()
			if r.ok() and (msg["max_players"] < 1 or msg["max_players"] > MAX_PLAYERS_LIMIT):
				r.fail("nombre de joueurs invalide")
		MsgType.ROSTER:
			var roster: Array = []
			var n_roster: int = r.u8()
			if n_roster > MAX_PLAYERS_LIMIT:
				r.fail("trop de joueurs dans la liste")
			for i: int in mini(n_roster, MAX_PLAYERS_LIMIT):
				if not r.ok():
					break
				var rid: int = r.u8()
				if r.ok() and (rid < 1 or rid > MAX_PLAYERS_LIMIT):
					r.fail("numéro de joueur invalide")
				roster.append({"id": rid, "name": r.text(MAX_NAME, "nom"), "score": r.u32()})
			msg["players"] = roster
		MsgType.INPUT:
			msg["tick"] = r.u32()
			msg["payload"] = _payload(r, MAX_CLIENT_PAYLOAD)
		MsgType.REQUEST:
			msg["kind"] = r.u8()
			msg["payload"] = _payload(r, MAX_CLIENT_PAYLOAD)
		MsgType.STATE:
			msg["tick"] = r.u32()
			msg["payload"] = _payload(r, MAX_HOST_PAYLOAD)
		MsgType.EVENT:
			msg["tick"] = r.u32()
			msg["kind"] = r.u8()
			msg["payload"] = _payload(r, MAX_HOST_PAYLOAD)
		MsgType.KICK:
			msg["reason"] = r.text(MAX_REASON, "raison")
		MsgType.PING, MsgType.PONG:
			msg["token"] = r.u32()
		_:
			return _fail("type de message inconnu (%d)" % type)
	if not r.ok():
		return _fail(r.error)
	# Les types à charge utile consomment tout le reste du paquet ; les autres ne doivent rien laisser.
	if r.pos != bytes.size():
		return _fail("octets en trop après le message (%d)" % (bytes.size() - r.pos))
	return {"ok": true, "error": "", "msg": msg}


## Lit tout le reste du paquet comme charge utile, bornée.
static func _payload(r: Reader, max_size: int) -> PackedByteArray:
	if not r.ok():
		return PackedByteArray()
	if r.remaining() > max_size:
		r.fail("charge utile trop grande (%d octets)" % r.remaining())
		return PackedByteArray()
	return r.raw(r.remaining())


static func valid_id(id: String) -> bool:
	return not id.is_empty() and id.length() <= MAX_ID and _id_regex.search(id) != null


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message, "msg": {}}
