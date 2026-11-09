class_name McfServerConfig
extends RefCounted
## Réglages du serveur dédié, lus sur la ligne de commande (après « -- » avec Godot) et STRICTEMENT validés : un argument inconnu
## ou hors bornes arrête le démarrage avec un message, jamais de valeur silencieusement recadrée.
##
## Arguments génériques : --port (1024-65535, défaut 2302), --max-players (1-16, défaut 4), --name (≤ 32 caractères, nom affiché
## dans le journal), --bind (« * » ou adresse IPv4), --console (drapeau : commandes d'administration sur l'entrée standard).
## Le jeu ajoute ses propres arguments avec `schema` (voir `parse`) ; leurs valeurs validées sont dans `extra`.

const DEFAULT_PORT := 2302
const MIN_PORT := 1024

var port: int = DEFAULT_PORT
var max_players: int = 4
var server_name: String = "Serveur MCF"
var bind_address: String = "*"
## Console d'administration sur l'entrée standard (--console) : kick, ban, état… (McfServerConsole).
var console: bool = false
## Fichier de journal ("" = user://server_logs/server-AAAA-MM-JJ.log) : jamais réglable par la ligne de commande.
var log_file: String = ""
## Valeurs des arguments propres au jeu, clé sans « -- » (ex. extra["map"]). Les drapeaux valent `true` s'ils sont présents.
var extra: Dictionary = {}

static var _ipv4_regex: RegEx = RegEx.create_from_string("^(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})$")


## `schema` : arguments supplémentaires du jeu, { "map": {...}, ... } où chaque règle est :
##   {"type": "int", "min": 0, "max": 100, "default": 15}
##   {"type": "regex", "pattern": "^[a-z0-9_]{1,48}$", "default": "test"}
##   {"type": "enum", "values": ["skate", "zombie"], "default": "skate"}
##   {"type": "flag"}                      (--cle sans valeur)
## Renvoie {"ok": bool, "error": String, "config": McfServerConfig}.
static func parse(args: PackedStringArray, schema: Dictionary = {}) -> Dictionary:
	var c := McfServerConfig.new()
	for key: String in schema:
		var rule: Dictionary = schema[key]
		c.extra[key] = rule.get("default", false if rule.get("type") == "flag" else "")
	for arg: String in args:
		if arg == "--server" or arg == "--headless":
			continue # drapeaux de lancement, pas des réglages
		if arg == "--console":
			c.console = true
			continue
		if not arg.begins_with("--"):
			return _fail("argument inconnu : « %s » (forme attendue : --nom=valeur)" % arg.left(40))
		var eq: int = arg.find("=")
		var key: String = arg.substr(2) if eq == -1 else arg.substr(2, eq - 2)
		var value: String = "" if eq == -1 else arg.substr(eq + 1)
		if schema.has(key):
			var problem: String = _apply_rule(c, key, schema[key], value, eq != -1)
			if not problem.is_empty():
				return _fail(problem)
			continue
		if eq == -1:
			return _fail("argument inconnu : « %s » (forme attendue : --nom=valeur)" % arg.left(40))
		match key:
			"port":
				if not value.is_valid_int() or int(value) < MIN_PORT or int(value) > 65535:
					return _fail("--port : un entier entre %d et 65535" % MIN_PORT)
				c.port = int(value)
			"max-players":
				if not value.is_valid_int() or int(value) < 1 or int(value) > McfCodec.MAX_PLAYERS_LIMIT:
					return _fail("--max-players : un entier entre 1 et %d" % McfCodec.MAX_PLAYERS_LIMIT)
				c.max_players = int(value)
			"name":
				var clean: String = McfNetUtil.clean_text(value, 64)
				if clean.is_empty() or clean.length() > 32:
					return _fail("--name : de 1 à 32 caractères, sans caractères de contrôle")
				c.server_name = clean
			"bind":
				if value != "*" and not _valid_ipv4(value):
					return _fail("--bind : « * » ou une adresse IPv4")
				c.bind_address = value
			_:
				return _fail("argument inconnu : --%s" % key.left(30))
	return {"ok": true, "error": "", "config": c}


static func _apply_rule(c: McfServerConfig, key: String, rule: Dictionary, value: String, has_value: bool) -> String:
	match str(rule.get("type", "")):
		"flag":
			if has_value:
				return "--%s ne prend pas de valeur" % key
			c.extra[key] = true
		"int":
			var lo: int = int(rule.get("min", 0))
			var hi: int = int(rule.get("max", 1000000))
			if not value.is_valid_int() or int(value) < lo or int(value) > hi:
				return "--%s : un entier entre %d et %d" % [key, lo, hi]
			c.extra[key] = int(value)
		"regex":
			var re: RegEx = RegEx.create_from_string(str(rule.get("pattern", "^$")))
			if re == null or re.search(value) == null:
				return "--%s : valeur invalide" % key
			c.extra[key] = value
		"enum":
			var values: Array = rule.get("values", [])
			if not values.has(value):
				return "--%s : une de ces valeurs : %s" % [key, ", ".join(PackedStringArray(values))]
			c.extra[key] = value
		_:
			return "--%s : règle de validation inconnue (erreur du jeu)" % key
	return ""


static func _valid_ipv4(value: String) -> bool:
	var m: RegExMatch = _ipv4_regex.search(value)
	if m == null:
		return false
	for i: int in range(1, 5):
		if int(m.get_string(i)) > 255:
			return false
	return true


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message, "config": null}
