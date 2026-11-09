class_name McfNetUtil
extends RefCounted
## Petits outils réseau sans état : adresses locales, nettoyage des noms, validation d'adresse.

static var _address_regex: RegEx = RegEx.create_from_string("^[A-Za-z0-9.\\-]{1,253}$")


## Adresses IPv4 de cette machine sur le réseau local (à donner aux amis du même réseau).
static func lan_addresses() -> Array[String]:
	var out: Array[String] = []
	for ip: String in IP.get_local_addresses():
		var parts: PackedStringArray = ip.split(".")
		if parts.size() != 4 or ip.begins_with("127.") or ip.begins_with("169.254.") or ip == "0.0.0.0":
			continue
		out.append(ip)
	return out


## Texte « adresse:port » d'une adresse du réseau local (numéro dans `lan_addresses()`), vide si le numéro ou le port est invalide.
static func address_text(slot: int, port: int) -> String:
	var all: Array[String] = lan_addresses()
	if slot < 0 or slot >= all.size() or port < 1 or port > 65535:
		return ""
	return "%s:%d" % [all[slot], port]


## Une adresse IP ou un nom d'hôte (lettres, chiffres, point, tiret), pas d'espace ni de chemin.
static func is_valid_address(address: String) -> bool:
	return _address_regex.search(address) != null


## Texte sans caractères de contrôle, espaces de bord retirés, borné en nombre de caractères.
static func clean_text(raw: String, max_len: int) -> String:
	var out: String = ""
	for i: int in raw.length():
		var code: int = raw.unicode_at(i)
		if code >= 32 and code != 127:
			out += raw[i]
	return out.strip_edges().left(max_len).strip_edges()


## Nom de joueur : 1 à McfCodec.MAX_NAME caractères sans contrôle ; `fallback` si vide.
static func clean_name(raw: String, fallback: String = "Joueur") -> String:
	var out: String = clean_text(raw, McfCodec.MAX_NAME)
	return out if not out.is_empty() else fallback


## Version du projet (Paramètres du projet > Application > Config > Version).
static func project_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
