class_name McfServerLog
extends RefCounted
## Journal du serveur dédié : une ligne par événement, sur la sortie standard ET dans un fichier de user:// (un fichier par jour).
## Les textes viennent parfois de joueurs (noms) : caractères de contrôle retirés, longueur bornée (pas d'injection de lignes).
## Le fichier est plafonné (MAX_BYTES) : au-delà on n'écrit plus que sur la sortie standard, le serveur ne remplit jamais le disque.

const DIRECTORY := "user://server_logs"
const MAX_BYTES := 2 * 1024 * 1024
const MAX_LINE := 240

var path: String
var echo: bool = true

var _file: FileAccess
var _written: int = 0


func _init(p_path: String = "") -> void:
	path = p_path if not p_path.is_empty() else "%s/server-%s.log" % [DIRECTORY, Time.get_date_string_from_system()]
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_file = FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if _file != null:
		_file.seek_end()
		_written = _file.get_length()


func info(message: String) -> void:
	_write("info", message)


func warn(message: String) -> void:
	_write("avert", message)


func error(message: String) -> void:
	_write("erreur", message)


func close() -> void:
	if _file != null:
		_file.close()
		_file = null


static func clean(text: String) -> String:
	var out: String = ""
	for i: int in mini(text.length(), MAX_LINE):
		var code: int = text.unicode_at(i)
		out += text[i] if code >= 32 and code != 127 else " "
	return out


func _write(level: String, message: String) -> void:
	var line: String = "[%s] [%s] %s" % [Time.get_time_string_from_system(), level, clean(message)]
	if echo:
		print(line)
	if _file != null and _written + line.length() + 1 <= MAX_BYTES:
		_file.store_line(line)
		_file.flush()
		_written += line.length() + 1
