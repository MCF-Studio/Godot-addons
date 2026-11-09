extends Node
## Test de l'addon mcf_coop : codec (aller-retour et paquets hostiles), hôte + clients en boucle locale (poignée de main, refus,
## entrées / états / événements / demandes, expulsion, bannissement, inondation, paquets bruités), configuration du serveur,
## console, lobby, écran de lobby et serveur dédié.
##   Godot_console.exe --headless --audio-driver Dummy --path . res://tests/TestCoop.tscn

const GAME := "test_game"
const VERSION := "1.2.3"

var _failures: int = 0


func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures += 1
		print("ÉCHEC : ", what)
	else:
		print("  [ok] ", what)


func _ready() -> void:
	_test_codec()
	_test_server_config()
	await _test_host_client()
	await _test_hostile()
	await _test_lobby()
	await _test_lobby_screen()
	await _test_readme_example()
	await _test_dedicated()
	print("== %s (%d échec(s))" % ["OK" if _failures == 0 else "ÉCHEC", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


# ------------------------------------------------------------------ outils

func _pump(host: McfHost, clients: Array, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		var dt := 1.0 / 60.0
		if host != null:
			host.poll(dt)
		for c: McfClient in clients:
			c.poll(dt)
		t += dt


func _new_host(max_players := 4, reserve_local := false) -> McfHost:
	var h := McfHost.new()
	h.game_id = GAME
	h.game_version = VERSION
	h.level_id = "niveau_1"
	var hash := PackedByteArray()
	hash.resize(32)
	hash.fill(9)
	h.content_hash = hash
	h.mode = 2
	h.seed_value = 777
	h.max_players = max_players
	h.reserve_local = reserve_local
	h.max_connects_per_address = 100
	_check(h.start(0, "127.0.0.1") == OK, "l'hôte ouvre un port")
	return h


func _new_client(host: McfHost, player_name: String, game_id := GAME, version := VERSION, tags: Array[String] = []) -> McfClient:
	var c := McfClient.new()
	var err := c.connect_to("127.0.0.1", host.port(), player_name, tags, game_id, version)
	_check(err == OK, "le client se lance (%s)" % player_name)
	return c


# ------------------------------------------------------------------ codec

func _test_codec() -> void:
	var tags: Array[String] = ["couleur_rouge", "chapeau"]
	var hello := McfCodec.decode(McfCodec.encode_hello(GAME, VERSION, "Aroun", tags), McfCodec.CLIENT_TYPES)
	_check(hello["ok"] and hello["msg"]["name"] == "Aroun" and hello["msg"]["tags"] == tags, "HELLO aller-retour")
	var hash := PackedByteArray()
	hash.resize(32)
	hash.fill(5)
	var w := McfCodec.decode(McfCodec.encode_welcome(3, "lvl", hash, 1, 99, 4), McfCodec.HOST_TYPES)
	_check(w["ok"] and w["msg"]["player_id"] == 3 and w["msg"]["seed"] == 99 and w["msg"]["content_hash"] == hash, "WELCOME aller-retour")
	var payload := PackedByteArray([1, 2, 3, 250])
	var inp := McfCodec.decode(McfCodec.encode_input(42, payload), McfCodec.CLIENT_TYPES)
	_check(inp["ok"] and inp["msg"]["tick"] == 42 and inp["msg"]["payload"] == payload, "INPUT aller-retour")
	var ev := McfCodec.decode(McfCodec.encode_event(7, 5, payload), McfCodec.HOST_TYPES)
	_check(ev["ok"] and ev["msg"]["kind"] == 5 and ev["msg"]["payload"] == payload, "EVENT aller-retour")
	var roster := McfCodec.decode(McfCodec.encode_roster([{"id": 1, "name": "A", "score": 5}, {"id": 2, "name": "É", "score": 9}]), McfCodec.HOST_TYPES)
	_check(roster["ok"] and roster["msg"]["players"].size() == 2 and roster["msg"]["players"][1]["name"] == "É", "ROSTER aller-retour")
	_check(McfCodec.encode_input(1, PackedByteArray([0]).duplicate()).size() > 0, "petite charge acceptée")
	var big := PackedByteArray()
	big.resize(McfCodec.MAX_CLIENT_PAYLOAD + 1)
	_check(McfCodec.encode_input(1, big).is_empty(), "charge client trop grande : encodage refusé")

	# Paquets hostiles : jamais d'erreur, toujours un refus propre.
	var good := McfCodec.encode_hello(GAME, VERSION, "x", [] as Array[String])
	var bad_cases: Array[PackedByteArray] = []
	bad_cases.append(PackedByteArray())
	bad_cases.append(PackedByteArray([1, 2, 3]))
	var wrong_magic := good.duplicate()
	wrong_magic[0] = 0
	bad_cases.append(wrong_magic)
	var wrong_version := good.duplicate()
	wrong_version[2] = 99
	bad_cases.append(wrong_version)
	bad_cases.append(good.slice(0, good.size() - 1))
	var extra := good.duplicate()
	extra.append(0)
	bad_cases.append(extra)
	var oversize := PackedByteArray()
	oversize.resize(McfCodec.MAX_PACKET + 1)
	bad_cases.append(oversize)
	var control := McfCodec.Writer.new()
	control.u8(McfCodec.MAGIC_0)
	control.u8(McfCodec.MAGIC_1)
	control.u8(McfCodec.PROTOCOL_VERSION)
	control.u8(McfCodec.MsgType.HELLO)
	control.text("jeu", 32)
	control.text("1.0", 16)
	control.text("a\u0001b", 20)
	control.u8(0)
	bad_cases.append(control.buf)
	var refused := 0
	for p in bad_cases:
		if not McfCodec.decode(p, McfCodec.CLIENT_TYPES)["ok"]:
			refused += 1
	_check(refused == bad_cases.size(), "les %d paquets hostiles sont tous refusés (%d)" % [bad_cases.size(), refused])
	# Un client ne peut pas se faire passer pour l'hôte.
	_check(not McfCodec.decode(McfCodec.encode_state(1, payload), McfCodec.CLIENT_TYPES)["ok"], "un client ne peut pas envoyer STATE")
	_check(not McfCodec.decode(McfCodec.encode_kick("x"), McfCodec.CLIENT_TYPES)["ok"], "un client ne peut pas envoyer KICK")
	# Fuzzing : octets aléatoires.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var survived := true
	for i in 2000:
		var junk := PackedByteArray()
		junk.resize(rng.randi_range(0, 64))
		for j in junk.size():
			junk[j] = rng.randi() & 0xFF
		if rng.randi() % 2 == 0 and junk.size() >= 4:
			junk[0] = McfCodec.MAGIC_0
			junk[1] = McfCodec.MAGIC_1
			junk[2] = McfCodec.PROTOCOL_VERSION
			junk[3] = rng.randi_range(1, 11)
		var r := McfCodec.decode(junk)
		if not r.has("ok"):
			survived = false
	_check(survived, "2000 paquets aléatoires décodés sans erreur")


func _test_server_config() -> void:
	var schema := {"map": {"type": "regex", "pattern": "^[a-z0-9_]{1,16}$", "default": "demo"},
		"rounds": {"type": "int", "min": 1, "max": 9, "default": 3},
		"mode": {"type": "enum", "values": ["coop", "versus"], "default": "coop"},
		"verbose": {"type": "flag"}}
	var d := McfServerConfig.parse(PackedStringArray([]), schema)
	_check(d["ok"] and d["config"].port == 2302 and d["config"].extra["map"] == "demo" and d["config"].extra["verbose"] == false, "valeurs par défaut")
	var p := McfServerConfig.parse(PackedStringArray(["--server", "--port=3000", "--max-players=6", "--name=Mon serveur", "--bind=127.0.0.1",
			"--console", "--map=niveau_2", "--rounds=5", "--mode=versus", "--verbose"]), schema)
	var c: McfServerConfig = p["config"]
	_check(p["ok"] and c.port == 3000 and c.max_players == 6 and c.server_name == "Mon serveur" and c.console, "arguments génériques")
	_check(c.extra["map"] == "niveau_2" and c.extra["rounds"] == 5 and c.extra["mode"] == "versus" and c.extra["verbose"] == true, "arguments du jeu")
	for bad in [["--port=80"], ["--port=abc"], ["--max-players=99"], ["--bind=1.2.3.999"], ["--inconnu=1"], ["bonjour"], ["--map=../x"],
			["--rounds=10"], ["--mode=autre"], ["--verbose=1"], ["--name="]]:
		_check(not McfServerConfig.parse(PackedStringArray(bad), schema)["ok"], "refusé : %s" % bad[0])


# ------------------------------------------------------------------ hôte + clients

func _test_host_client() -> void:
	var host := _new_host(3)
	var joined: Array = []
	var left: Array = []
	var inputs: Array = []
	var requests: Array = []
	host.player_joined.connect(func(id: int, info: Dictionary) -> void: joined.append([id, info["name"], info["tags"]]))
	host.player_left.connect(func(id: int, reason: String) -> void: left.append([id, reason]))
	host.input_received.connect(func(id: int, tick: int, payload: PackedByteArray) -> void: inputs.append([id, tick, payload]))
	host.request_received.connect(func(id: int, kind: int, payload: PackedByteArray) -> void: requests.append([id, kind, payload]))

	var a := _new_client(host, "Alice", GAME, VERSION, ["rouge"] as Array[String])
	var b := _new_client(host, "Alice")
	var states: Array = []
	var events: Array = []
	var rosters: Array = []
	a.state_received.connect(func(tick: int, payload: PackedByteArray) -> void: states.append([tick, payload]))
	a.event_received.connect(func(tick: int, kind: int, payload: PackedByteArray) -> void: events.append([tick, kind, payload]))
	a.roster_received.connect(func(players: Array) -> void: rosters.append(players))
	var checked: Array = []
	a.content_checker = func(level: String, hash: PackedByteArray) -> String:
		checked.append([level, hash[0]])
		return ""
	await _pump(host, [a, b], 0.5)
	_check(a.is_joined() and b.is_joined(), "les deux clients ont rejoint")
	_check(joined.size() == 2 and joined[0][1] == "Alice" and joined[1][1] == "Alice 2", "noms rendus uniques : %s" % str(joined.map(func(j): return j[1])))
	_check(joined[0][2] == ["rouge"], "étiquettes transmises à l'hôte")
	_check(a.player_id == 1 and b.player_id == 2, "identifiants 1 et 2 (hôte sans joueur local)")
	_check(a.welcome["level_id"] == "niveau_1" and a.welcome["mode"] == 2 and a.welcome["seed"] == 777, "WELCOME : niveau, mode, graine")
	_check(checked == [["niveau_1", 9]], "content_checker appelé avec le niveau et l'empreinte")

	# Intentions, demandes.
	a.send_input(10, PackedByteArray([1, 2]))
	a.send_input(11, PackedByteArray([3]), true)
	a.send_request(4, PackedByteArray([7, 7]))
	await _pump(host, [a, b], 0.3)
	_check(inputs.size() == 2 and inputs[0][0] == 1 and inputs[0][1] == 10 and inputs[1][2] == PackedByteArray([3]), "intentions reçues, attribuées au bon joueur")
	_check(requests == [[1, 4, PackedByteArray([7, 7])]], "demande reçue")

	# États (les anciens sont ignorés), événements, liste.
	host.send_state_to(1, 5, PackedByteArray([5]))
	host.send_state_to(1, 9, PackedByteArray([9]))
	await _pump(host, [a, b], 0.2)
	host.send_state_to(1, 7, PackedByteArray([7])) # plus ancien que 9 : ignoré
	host.broadcast_event(12, 3, PackedByteArray([42]))
	host.broadcast_roster([{"id": 1, "name": "Alice", "score": 10}])
	await _pump(host, [a, b], 0.3)
	_check(states.size() == 2 and states[1][0] == 9, "états ordonnés, le plus ancien ignoré (%d reçus)" % states.size())
	_check(events == [[12, 3, PackedByteArray([42])]], "événement fiable reçu")
	_check(rosters.size() == 1 and rosters[0][0]["score"] == 10, "liste des joueurs reçue")
	await _pump(host, [a, b], 1.3)
	_check(a.rtt_ms >= 0 and host.rtt_ms(1) >= 0, "temps aller-retour mesuré")

	# Partie pleine (3 places) puis refus de version et de jeu.
	var c := _new_client(host, "Carl")
	await _pump(host, [a, b, c], 0.4)
	_check(c.is_joined() and host.player_count() == 3, "troisième joueur accepté")
	var full := _new_client(host, "Dan")
	var full_reason: Array = []
	full.kicked.connect(func(r: String) -> void: full_reason.append(r))
	await _pump(host, [a, b, c, full], 0.4)
	_check(not full.is_joined() and full_reason == ["Partie pleine"], "partie pleine refusée : %s" % str(full_reason))

	# Expulsion.
	var kicked_reason: Array = []
	b.kicked.connect(func(r: String) -> void: kicked_reason.append(r))
	_check(host.kick(2, "test"), "kick d'un joueur existant")
	await _pump(host, [a, b, c], 0.3)
	_check(kicked_reason == ["test"] and host.player_count() == 2 and left.size() == 1, "joueur expulsé et retiré")
	_check(not host.kick(99, "x"), "kick d'un inconnu refusé")

	for cl in [a, b, c, full]:
		cl.leave()
	await _pump(host, [], 0.3)
	host.stop()

	# Refus : autre jeu, autre version, validateur du jeu, contenu différent.
	var h2 := _new_host(4)
	h2.hello_validator = func(info: Dictionary) -> String: return "nom interdit" if info["name"] == "Voldemort" else ""
	var reasons: Array = []
	var other_game := _new_client(h2, "X", "autre_jeu")
	var other_ver := _new_client(h2, "X", GAME, "2.0.0")
	var patch_ver := _new_client(h2, "Y", GAME, "1.2.9")
	var banned_name := _new_client(h2, "Voldemort")
	var wrong_content := _new_client(h2, "Z")
	wrong_content.content_checker = func(_l: String, _h: PackedByteArray) -> String: return "carte manquante"
	var wc_reason: Array = []
	wrong_content.disconnected.connect(func(r: String) -> void: wc_reason.append(r))
	for cl: McfClient in [other_game, other_ver, banned_name]:
		cl.kicked.connect(func(r: String) -> void: reasons.append(r))
	await _pump(h2, [other_game, other_ver, patch_ver, banned_name, wrong_content], 0.6)
	_check(reasons.size() == 3 and str(reasons[0]).contains("autre jeu"), "autre jeu refusé : %s" % str(reasons))
	_check(str(reasons[1]).contains("version"), "autre version refusée")
	_check(patch_ver.is_joined(), "même version majeure.mineure acceptée (correctif différent)")
	_check(str(reasons[2]) == "nom interdit", "validateur du jeu appliqué")
	_check(wc_reason == ["carte manquante"] and not wrong_content.is_joined(), "contenu local différent : le client refuse (%s)" % str(wc_reason))
	for cl: McfClient in [other_game, other_ver, patch_ver, banned_name, wrong_content]:
		cl.leave()
	await _pump(h2, [], 0.2)
	h2.stop()

	# Hôte qui joue : le joueur 1 est réservé.
	var h3 := _new_host(2, true)
	var d := _new_client(h3, "Dora")
	await _pump(h3, [d], 0.4)
	_check(d.player_id == 2, "hôte qui joue : le premier client est le joueur 2")
	var e := _new_client(h3, "Eve")
	var e_reason: Array = []
	e.kicked.connect(func(r: String) -> void: e_reason.append(r))
	await _pump(h3, [d, e], 0.4)
	_check(e_reason == ["Partie pleine"], "2 places = hôte + 1 client")
	d.leave()
	e.leave()
	await _pump(h3, [], 0.2)
	h3.stop()


# ------------------------------------------------------------------ hostilité

func _raw_peer(host: McfHost) -> Array:
	var conn := ENetConnection.new()
	conn.create_host(1, McfHost.CHANNELS)
	var peer := conn.connect_to_host("127.0.0.1", host.port(), McfHost.CHANNELS)
	return [conn, peer]


func _service_raw(conn: ENetConnection, host: McfHost, frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame
		host.poll(1.0 / 60.0)
		conn.service(0)


func _test_hostile() -> void:
	# Poignée de main trop lente.
	var host := _new_host(4)
	host.handshake_timeout = 0.3
	var refused: Array = []
	host.peer_refused.connect(func(_a: String, r: String) -> void: refused.append(r))
	var raw := _raw_peer(host)
	await _service_raw(raw[0], host, 60)
	_check(refused.has("poignée de main trop lente"), "pair silencieux coupé : %s" % str(refused))
	raw[0].destroy()
	host.handshake_timeout = McfHost.HANDSHAKE_TIMEOUT

	# Paquets gros / invalides avant et après la poignée de main : expulsion.
	var raw2 := _raw_peer(host)
	await _service_raw(raw2[0], host, 10)
	var junk := PackedByteArray()
	junk.resize(100)
	for i in 12:
		(raw2[1] as ENetPacketPeer).send(0, junk, ENetPacketPeer.FLAG_RELIABLE)
		await _service_raw(raw2[0], host, 2)
	await _service_raw(raw2[0], host, 20)
	_check(refused.any(func(r: String) -> bool: return r.begins_with("paquets invalides")), "paquets invalides : pair expulsé")
	raw2[0].destroy()

	var raw3 := _raw_peer(host)
	await _service_raw(raw3[0], host, 10)
	var huge := PackedByteArray()
	huge.resize(McfCodec.MAX_PACKET + 100)
	for i in 6:
		(raw3[1] as ENetPacketPeer).send(0, huge, ENetPacketPeer.FLAG_RELIABLE)
		await _service_raw(raw3[0], host, 2)
	await _service_raw(raw3[0], host, 20)
	_check(refused.has("paquets trop gros"), "paquets trop gros : pair expulsé")
	raw3[0].destroy()

	# Inondation par un joueur accepté + demandes en rafale.
	var a := _new_client(host, "Flood")
	var strikes := {"n": 0}
	host.request_received.connect(func(_id: int, _k: int, _p: PackedByteArray) -> void: strikes["n"] += 1)
	await _pump(host, [a], 0.4)
	for i in 100:
		a.send_request(1, PackedByteArray([1]))
	await _pump(host, [a], 0.5)
	_check(strikes["n"] <= 12, "demandes limitées à %.0f/s (%d passées sur 100)" % [host.request_per_second, strikes["n"]])
	var gone: Array = []
	a.disconnected.connect(func(r: String) -> void: gone.append(r))
	for i in 20:
		for j in 20:
			a.send_input(i * 20 + j, PackedByteArray([1]), true)
		await _pump(host, [a], 0.02)
	await _pump(host, [a], 0.5)
	_check(not a.is_joined() and host.player_count() == 0, "inondation d'intentions : joueur coupé (%s)" % str(gone))

	# Bannissement.
	var b := _new_client(host, "Banni")
	await _pump(host, [b], 0.4)
	_check(b.is_joined(), "joueur accepté avant bannissement")
	_check(host.ban(1, "triche") and host.banned.has("127.0.0.1"), "bannissement par adresse")
	await _pump(host, [b], 0.3)
	var c := _new_client(host, "Retour")
	await _pump(host, [c], 0.4)
	_check(not c.is_joined(), "adresse bannie : connexion refusée")
	_check(host.unban("127.0.0.1"), "débannissement")
	var d := _new_client(host, "Gracié")
	await _pump(host, [d], 0.4)
	_check(d.is_joined(), "après débannissement : accepté")
	d.leave()
	await _pump(host, [], 0.2)
	host.stop()

	# Trop de connexions depuis une même adresse.
	var h2 := _new_host(4)
	h2.max_connects_per_address = 3
	var limited: Array = []
	h2.peer_refused.connect(func(_a: String, r: String) -> void: limited.append(r))
	var many: Array = []
	for i in 6:
		many.append(_new_client(h2, "N%d" % i))
	await _pump(h2, many, 0.6)
	_check(limited.any(func(r: String) -> bool: return r.contains("trop de connexions")), "connexions en rafale limitées par adresse")
	for cl: McfClient in many:
		cl.leave()
	await _pump(h2, [], 0.2)
	h2.stop()


# ------------------------------------------------------------------ lobby

func _test_lobby() -> void:
	var hl := McfLobby.new()
	hl.game_id = GAME
	hl.game_version = VERSION
	add_child(hl)
	var statuses: Array = []
	hl.status_changed.connect(func(i: Dictionary) -> void: statuses.append(i["state"]))
	_check(not hl.host_game(80, 4, "A"), "port trop bas refusé")
	_check(not hl.host_game(2302, 1, "A"), "1 joueur refusé")
	_check(not hl.host_game(2302, 99, "A"), "99 joueurs refusés")
	_check(statuses.size() == 3 and statuses.all(func(s): return s == "error"), "erreurs publiées")
	var roles: Array = []
	hl.ready_to_play.connect(func(role: StringName) -> void: roles.append(role))
	var port := 24602
	_check(hl.host_game(port, 3, "Hôte", {"level_id": "lobby_lvl", "mode": 1}), "hébergement")
	_check(roles == [&"host"] and hl.host != null, "ready_to_play(host)")
	var host: McfHost = hl.take_host()
	_check(host != null and hl.host == null and host.level_id == "lobby_lvl", "le jeu prend possession de l'hôte")

	var cl := McfLobby.new()
	cl.game_id = GAME
	cl.game_version = VERSION
	add_child(cl)
	_check(not cl.join_game("bad host!", port, "C"), "adresse invalide refusée")
	_check(not cl.join_game("127.0.0.1", 0, "C"), "port invalide refusé")
	var cl_roles: Array = []
	cl.ready_to_play.connect(func(role: StringName) -> void: cl_roles.append(role))
	_check(cl.join_game("127.0.0.1", port, "Cli"), "connexion lancée")
	var t := 0.0
	while t < 1.5 and cl_roles.is_empty():
		await get_tree().physics_frame
		host.poll(1.0 / 60.0)
		t += 1.0 / 60.0
	_check(cl_roles == [&"client"], "ready_to_play(client)")
	var client: McfClient = cl.take_client()
	_check(client != null and client.is_joined() and client.player_id == 2, "client repris par le jeu")
	client.leave()
	host.stop()

	# Mauvaise version : message d'erreur côté client.
	var h2 := McfLobby.new()
	h2.game_id = GAME
	h2.game_version = "5.0.0"
	add_child(h2)
	h2.host_game(port + 1, 2, "H")
	var host2: McfHost = h2.take_host()
	var c2 := McfLobby.new()
	c2.game_id = GAME
	c2.game_version = "6.0.0"
	add_child(c2)
	var msgs: Array = []
	c2.status_changed.connect(func(i: Dictionary) -> void: msgs.append(i))
	c2.join_game("127.0.0.1", port + 1, "C")
	t = 0.0
	while t < 1.0:
		await get_tree().physics_frame
		host2.poll(1.0 / 60.0)
		t += 1.0 / 60.0
	_check(msgs.back()["state"] == "error" and str(msgs.back()["message"]).contains("version"), "version différente : message clair (%s)" % str(msgs.back()["message"]))
	host2.stop()
	hl.queue_free()
	cl.queue_free()
	h2.queue_free()
	c2.queue_free()

	# Utilitaires.
	_check(McfNetUtil.clean_name("  \u0001Zoé\n ") == "Zoé" and McfNetUtil.clean_name("") == "Joueur", "nom nettoyé")
	_check(McfNetUtil.clean_name("x".repeat(50)).length() == McfCodec.MAX_NAME, "nom borné")
	_check(McfNetUtil.is_valid_address("192.168.1.2") and McfNetUtil.is_valid_address("mon-serveur.fr") and not McfNetUtil.is_valid_address("a b") and not McfNetUtil.is_valid_address("x/y"), "adresses valides / invalides")
	_check(McfNetUtil.address_text(-1, 2302) == "" and McfNetUtil.address_text(0, 0) == "", "address_text borne ses entrées")


func _test_lobby_screen() -> void:
	var screen := (load("res://addons/mcf_coop/mcf_lobby_screen.tscn") as PackedScene).instantiate() as McfLobbyScreen
	add_child(screen)
	await screen.configure(GAME, {"level_id": "ecran"}, Callable(), VERSION)
	await get_tree().process_frame
	_check(screen.lobby.game_id == GAME, "l'écran configure son lobby")
	var roles: Array = []
	screen.ready_to_play.connect(func(role: StringName, _l: McfLobby) -> void: roles.append(role))
	(screen.get_node("%NameEdit") as LineEdit).text = "Écran"
	(screen.get_node("%PortSpin") as SpinBox).value = 24610
	(screen.get_node("%PlayersSpin") as SpinBox).value = 3
	(screen.get_node("%HostButton") as Button).pressed.emit()
	await get_tree().process_frame
	_check(roles == [&"host"], "bouton Héberger : partie ouverte")
	_check(str((screen.get_node("%StatusLabel") as Label).text).contains("24610"), "message d'état affiché")
	var host := screen.lobby.take_host()
	_check(host != null and host.max_players == 3 and host.level_id == "ecran", "options de l'écran transmises à l'hôte")
	host.stop()
	(screen.get_node("%AddressEdit") as LineEdit).text = "adresse invalide !"
	(screen.get_node("%JoinButton") as Button).pressed.emit()
	await get_tree().process_frame
	_check(str((screen.get_node("%StatusLabel") as Label).text).begins_with("Adresse invalide"), "bouton Rejoindre : adresse invalide signalée")
	screen.queue_free()


# ------------------------------------------------------------------ serveur dédié

func _test_dedicated() -> void:
	var server := McfDedicatedServer.new()
	server.auto_start = false
	server.game_id = GAME
	server.game_version = VERSION
	server.level_id = "serveur_lvl"
	server.schema = {"map": {"type": "regex", "pattern": "^[a-z_]+$", "default": "x"}}
	add_child(server)
	var cfg := McfServerConfig.parse(PackedStringArray(["--port=24620", "--max-players=2", "--bind=127.0.0.1", "--map=abc"]), server.schema)
	var config: McfServerConfig = cfg["config"]
	config.log_file = "user://test_coop_server.log"
	var started := {"n": 0}
	server.started.connect(func() -> void: started["n"] += 1)
	_check(server.start(config) == OK and started["n"] == 1 and server.running, "serveur dédié démarré")
	_check(config.extra["map"] == "abc", "arguments propres au jeu lus")
	var c := McfClient.new()
	var tags: Array[String] = []
	c.connect_to("127.0.0.1", 24620, "Joueur", tags, GAME, VERSION)
	var t := 0.0
	while t < 1.0 and not c.is_joined():
		await get_tree().physics_frame
		c.poll(1.0 / 60.0)
		t += 1.0 / 60.0
	_check(c.is_joined() and c.player_id == 1 and c.welcome["level_id"] == "serveur_lvl", "un client rejoint le serveur (sans joueur local : id 1)")

	# Console (sans entrée standard).
	server.extra_commands = func(command: String, args: PackedStringArray) -> Variant:
		return "salut %s" % ",".join(args) if command == "hello" else null
	var console := McfServerConsole.new(server)
	console.extra_commands = server.extra_commands
	_check(console.execute("status").begins_with("1 joueur(s) sur 2"), "console : status")
	_check(console.execute("players").contains("Joueur"), "console : players")
	_check(console.execute("hello a b") == "salut a,b", "console : commande du jeu")
	_check(console.execute("inconnue").begins_with("commande inconnue"), "console : commande inconnue")
	_check(console.execute("kick abc") .begins_with("usage"), "console : kick sans numéro valide")
	_check(console.execute("ban 1 triche").begins_with("ban"), "console : ban")
	_check(console.execute("bans").contains("127.0.0.1"), "console : bans")
	_check(console.execute("unban 127.0.0.1") == "adresse débannie", "console : unban")
	_check(console.execute("x\u0001\u0002").begins_with("commande inconnue"), "console : caractères de contrôle neutralisés")
	c.leave()
	server.shutdown()
	_check(not server.running, "serveur arrêté")
	server.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_coop_server.log"))


# ------------------------------------------------------------------ exemple du README (carrés qui se déplacent)

var _ex_host: McfHost
var _ex_positions: Dictionary = {}
var _ex_inputs: Dictionary = {}


func _ex_encode_input(axis: Vector2) -> PackedByteArray:
	var w := McfCodec.Writer.new()
	w.i8(roundi(clampf(axis.x, -1.0, 1.0) * 127.0))
	w.i8(roundi(clampf(axis.y, -1.0, 1.0) * 127.0))
	return w.buf


func _ex_on_input(id: int, _tick: int, payload: PackedByteArray) -> void:
	var r := McfCodec.Reader.new(payload)
	var axis := Vector2(r.i8() / 127.0, r.i8() / 127.0)
	if not r.ok() or r.remaining() != 0:
		_ex_host.strike(id, "intention invalide")
		return
	_ex_inputs[id] = axis.limit_length(1.0)


func _ex_encode_state() -> PackedByteArray:
	var w := McfCodec.Writer.new()
	w.u8(_ex_positions.size())
	for id: int in _ex_positions:
		w.u8(id)
		w.f32((_ex_positions[id] as Vector2).x)
		w.f32((_ex_positions[id] as Vector2).y)
	return w.buf


func _test_readme_example() -> void:
	_ex_host = _new_host(3, true)
	_ex_positions = {1: Vector2.ZERO}
	_ex_host.player_joined.connect(func(id: int, _i: Dictionary) -> void: _ex_positions[id] = Vector2.ZERO)
	_ex_host.input_received.connect(_ex_on_input)
	var client := _new_client(_ex_host, "Carré")
	var received := {"pos": {}}
	client.state_received.connect(func(_t: int, payload: PackedByteArray) -> void:
		var r := McfCodec.Reader.new(payload)
		var n := r.u8()
		var got: Dictionary = {}
		for i in mini(n, McfCodec.MAX_PLAYERS_LIMIT):
			var pid := r.u8()   # lire la clé AVANT la valeur : GDScript évalue la partie droite d'abord
			got[pid] = Vector2(r.f32(-5000.0, 5000.0, "x"), r.f32(-5000.0, 5000.0, "y"))
		if r.ok():
			received["pos"] = got)
	var tick := 0
	for i in 90:
		await get_tree().physics_frame
		tick += 1
		var dt := 1.0 / 60.0
		_ex_host.poll(dt)
		client.poll(dt)
		if client.is_joined():
			client.send_input(tick, _ex_encode_input(Vector2(1.0, 0.0)))
		for id: int in _ex_positions:
			_ex_positions[id] += (_ex_inputs.get(id, Vector2.ZERO) as Vector2) * 200.0 * dt
		if tick % 3 == 0:
			_ex_host.broadcast_state(tick, _ex_encode_state())
	var pos: Dictionary = received["pos"]
	_check(pos.has(2) and (pos[2] as Vector2).x > 50.0 and absf((pos[2] as Vector2).y) < 0.01, "exemple du README : le client voit son carré avancer (%s)" % str(pos.get(2)))
	_check(pos.has(1) and pos[1] == Vector2.ZERO, "exemple du README : le joueur local de l'hôte est le n° 1")
	# Une charge d'intention invalide est comptée comme paquet invalide.
	client.send_input(tick, PackedByteArray([1, 2, 3]))
	await get_tree().physics_frame
	client.leave()
	_ex_host.stop()
