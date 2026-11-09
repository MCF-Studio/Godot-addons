extends Node
## Test de l'addon StreamingTribeAPI : interprétation de la réponse du serveur d'authentification (tout ce qui n'est pas
## un « oui » explicite est un refus) et identité « User Debug » dans l'éditeur.
##   Godot_console.exe --headless --audio-driver Dummy --path . res://tests/TestStreamingApi.tscn

var _failures: int = 0


func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures += 1
		print("ÉCHEC : ", what)


func _ready() -> void:
	var ok := ST_API.evaluate_response(200, '{"authenticated":true,"canPlay":true,"user":{"username":"Bob","id":3}}')
	_check(ok["ok"] and ok["user"]["username"] == "Bob", "réponse valide acceptée")

	_check(not ST_API.evaluate_response(200, '{"authenticated":true,"canPlay":false,"user":{}}')["ok"], "canPlay faux refusé")
	_check(not ST_API.evaluate_response(200, '{"authenticated":false,"canPlay":true,"user":{}}')["ok"], "non authentifié refusé")
	_check(not ST_API.evaluate_response(200, '{"authenticated":true,"canPlay":true}')["ok"], "sans utilisateur refusé")
	_check(not ST_API.evaluate_response(200, '{"authenticated":"true","canPlay":1,"user":{}}')["ok"], "valeurs non booléennes refusées")
	_check(not ST_API.evaluate_response(200, "pas du json")["ok"], "corps illisible refusé")
	_check(not ST_API.evaluate_response(200, "")["ok"], "corps vide refusé")
	_check(not ST_API.evaluate_response(401, '{"authenticated":true,"canPlay":true,"user":{}}')["ok"], "code 401 refusé")
	_check(not ST_API.evaluate_response(500, "[]")["ok"], "tableau refusé")

	var ban := ST_API.evaluate_response(403, '{"error":"banned","banReason":"triche"}')
	_check(not ban["ok"] and String(ban["message"]).contains("triche"), "banni : raison affichée")
	var msg := ST_API.evaluate_response(401, '{"message":"Jeton expiré"}')
	_check(msg["message"] == "Jeton expiré", "message du serveur repris")

	_check(ST_API.authenticated and ST_API.username == "User Debug", "éditeur : identité de développement")

	print("== %s (%d échec(s))" % ["OK" if _failures == 0 else "ÉCHEC", _failures])
	get_tree().quit(0 if _failures == 0 else 1)
