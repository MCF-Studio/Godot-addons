class_name McfLobbyScreen
extends Control
## Écran natif « Jouer en réseau » prêt à l'emploi (scène `mcf_lobby_screen.tscn`) : nom du joueur, héberger (port, joueurs,
## adresses locales avec bouton Copier), rejoindre (adresse, port), message d'état. Il pilote un McfLobby (nœud enfant `Lobby`).
## Modifiable dans l'éditeur (thème, mise en page) : seuls les noms de nœuds uniques (%…) comptent.
##
## Usage :
##   var screen := preload("res://addons/mcf_coop/mcf_lobby_screen.tscn").instantiate() as McfLobbyScreen
##   add_child(screen)
##   screen.configure("mon_jeu", {"level_id": "niveau_1"}, my_content_checker)
##   screen.ready_to_play.connect(func(role, lobby): ...)   # role = &"host" ou &"client" ; lobby.take_host() / take_client()

signal ready_to_play(role: StringName, lobby: McfLobby)

## Options passées à McfLobby.host_game (level_id, content_hash, mode, hello_validator…).
var host_options: Dictionary = {}
## Étiquettes envoyées par un client qui rejoint (identifiants : équipement, couleur…).
var join_tags: Array[String] = []

@onready var lobby: McfLobby = $Lobby
@onready var _name_edit: LineEdit = %NameEdit
@onready var _port_spin: SpinBox = %PortSpin
@onready var _players_spin: SpinBox = %PlayersSpin
@onready var _host_button: Button = %HostButton
@onready var _addresses: VBoxContainer = %Addresses
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _join_port_spin: SpinBox = %JoinPortSpin
@onready var _join_button: Button = %JoinButton
@onready var _status: Label = %StatusLabel
@onready var _cancel_button: Button = %CancelButton


func _ready() -> void:
	var data: Dictionary = lobby.menu_data(_name_edit.text)
	_port_spin.min_value = McfLobby.MIN_PORT
	_port_spin.max_value = 65535
	_port_spin.value = data["port"]
	_join_port_spin.min_value = 1
	_join_port_spin.max_value = 65535
	_join_port_spin.value = data["port"]
	_players_spin.min_value = 2
	_players_spin.max_value = mini(lobby.max_players_limit, McfCodec.MAX_PLAYERS_LIMIT)
	_players_spin.value = data["max_players"]
	_name_edit.max_length = McfCodec.MAX_NAME
	_fill_addresses(data["addresses"])
	_set_status("", false)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	lobby.status_changed.connect(_on_status_changed)
	lobby.ready_to_play.connect(func(role: StringName) -> void: ready_to_play.emit(role, lobby))


## À appeler juste après l'instanciation (avant ou après add_child).
func configure(game_id: String, p_host_options: Dictionary = {}, content_checker: Callable = Callable(), game_version: String = "") -> void:
	if not is_node_ready():
		await ready
	lobby.game_id = game_id
	if not game_version.is_empty():
		lobby.game_version = game_version
	lobby.content_checker = content_checker
	host_options = p_host_options


func _fill_addresses(addresses: Array) -> void:
	for child in _addresses.get_children():
		child.queue_free()
	if addresses.is_empty():
		var none := Label.new()
		none.text = "Aucune adresse réseau trouvée."
		_addresses.add_child(none)
		return
	for slot: int in addresses.size():
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = str(addresses[slot])
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var copy := Button.new()
		copy.text = "Copier"
		copy.pressed.connect(_on_copy_pressed.bind(slot))
		row.add_child(label)
		row.add_child(copy)
		_addresses.add_child(row)


## Le texte copié est fabriqué ici (adresse + port validés), jamais pris tel quel dans un champ.
func _on_copy_pressed(slot: int) -> void:
	var text: String = McfNetUtil.address_text(slot, int(_port_spin.value))
	if not text.is_empty():
		DisplayServer.clipboard_set(text)
		_set_status("Adresse copiée : %s" % text, false)


func _on_host_pressed() -> void:
	lobby.host_game(int(_port_spin.value), int(_players_spin.value), _name_edit.text, host_options)


func _on_join_pressed() -> void:
	lobby.join_game(_address_edit.text, int(_join_port_spin.value), _name_edit.text, join_tags)


func _on_cancel_pressed() -> void:
	lobby.cancel()
	_set_status("", false)


func _on_status_changed(info: Dictionary) -> void:
	var busy: bool = info["state"] == "connecting"
	_join_button.disabled = busy
	_host_button.disabled = busy
	_cancel_button.visible = busy
	_set_status(str(info["message"]), info["state"] == "error")


func _set_status(message: String, is_error: bool) -> void:
	_status.text = message
	_status.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45) if is_error else Color(0.8, 0.9, 1.0))
