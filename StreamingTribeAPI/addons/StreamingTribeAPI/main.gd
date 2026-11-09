extends Node
## Autoload `ST_API` : seul le lanceur MCF Studio a le droit de démarrer le jeu.
##
## Le lanceur passe un jeton (`--token=...`, ou variable d'environnement `STREAMINGTRIBE_TOKEN`). Au démarrage on le
## fait vérifier par Streaming Tribe ; **jeton absent, refusé, banni, ou serveur injoignable : le jeu se ferme**.
## En cas de succès, `username` (et `user`) sont disponibles et `auth_finished(true)` est émis.
## Exceptions : l'éditeur Godot (identité « User Debug », pour développer) et l'exécutable serveur dédié
## (headless, ne joue pas, lancé sans lanceur).

signal auth_finished(ok: bool)

const API_BASE_URL := "https://streamingtribe.fr"
const VERIFY_PATH := "/api/game/verify"
const REQUEST_TIMEOUT_S := 10.0
const MAX_USERNAME_LEN := 40

var authenticated := false
var username := ""
## Réponse brute de l'API pour l'utilisateur (autres champs éventuels : id, avatar…).
var user: Dictionary = {}

var _http: HTTPRequest


func _ready() -> void:
	if OS.has_feature("editor"):
		_accept({"username": "User Debug"})
		return
	if OS.has_feature("dedicated_server") or OS.get_cmdline_user_args().has("--server"):
		_accept({"username": "Serveur"})
		return
	var token := _read_token()
	if token == "":
		_refuse("Ce jeu doit être lancé depuis le lanceur MCF Studio.")
		return
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT_S
	add_child(_http)
	_http.request_completed.connect(_on_verify_completed)
	var err := _http.request(API_BASE_URL + VERIFY_PATH, ["Authorization: Bearer " + token], HTTPClient.METHOD_POST)
	if err != OK:
		_refuse("Connexion au serveur d'authentification impossible (code %d)." % err)


func _read_token() -> String:
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--token="):
			return arg.trim_prefix("--token=").strip_edges()
	return OS.get_environment("STREAMINGTRIBE_TOKEN").strip_edges()


func _on_verify_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_refuse("Connexion au serveur d'authentification impossible (code %d)." % result)
		return
	var verdict := evaluate_response(code, body.get_string_from_utf8())
	if verdict["ok"]:
		_accept(verdict["user"])
	else:
		_refuse(verdict["message"])


## Interprète la réponse de `/api/game/verify`. Retourne { ok, message, user }. Tout ce qui n'est pas un « oui »
## explicite est un refus.
static func evaluate_response(code: int, body_text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(body_text)
	var r: Dictionary = parsed if parsed is Dictionary else {}
	var authenticated_ok: Variant = r.get("authenticated")
	var can_play: Variant = r.get("canPlay")
	if code == 200 and authenticated_ok is bool and authenticated_ok and can_play is bool and can_play \
			and r.get("user") is Dictionary:
		return {"ok": true, "message": "", "user": r["user"]}
	var message := "Accès refusé (code %d)." % code
	if r.get("error", "") == "banned":
		message = "Votre compte a été banni.\nRaison : %s" % str(r.get("banReason", "non précisée")).left(200)
	elif r.get("message") is String:
		message = String(r["message"]).left(200)
	return {"ok": false, "message": message, "user": {}}


func _accept(data: Dictionary) -> void:
	user = data
	username = str(data.get("username", "inconnu")).strip_edges().left(MAX_USERNAME_LEN)
	authenticated = true
	auth_finished.emit(true)


func _refuse(message: String) -> void:
	authenticated = false
	push_error("Streaming Tribe : " + message)
	auth_finished.emit(false)
	OS.alert(message, "Accès refusé")
	get_tree().quit(1)
