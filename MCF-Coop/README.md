# MCF Coop — parties multijoueurs hébergées (coop / mini-jeux)

Addon Godot 4 qui apporte **tout le socle réseau d'une partie hébergée par un joueur** (ou par un serveur dédié), sans aucune règle de jeu :

- **Hôte autoritaire** (`McfHost`) et **client** (`McfClient`) en ENet (UDP), poignée de main, refus propres, expulsion, bannissement, limites anti-abus.
- **Codec borné** (`McfCodec`) : le seul endroit qui transforme des octets reçus en données ; le jeu y met ses propres messages (charge utile) avec les mêmes garde-fous.
- **Lobby** sans interface (`McfLobby`) et **écran natif prêt à l'emploi** (`mcf_lobby_screen.tscn`) : nom, héberger, rejoindre, adresses locales avec bouton « Copier ».
- **Serveur dédié** générique (`McfDedicatedServer`) : ligne de commande validée, journal, console d'administration, sans fenêtre.

Issu du multijoueur de *MCF Tiny Skate* (hôte autoritaire, intentions → instantanés), débarrassé de tout ce qui était propre à ce jeu. Testé avec Godot **4.7.2** (visé : 4.2+, aucune API récente utilisée).

> **Ce que l'addon ne fait pas** : pas de simulation, pas de prédiction ni d'interpolation côté client, pas de lobby public / matchmaking, pas de chiffrement, pas de NAT-traversal (connexion directe IP:port, réseau local ou port ouvert). Voir [Limites](#limites).

---

## Installation (à suivre à la lettre, y compris par une IA)

1. **Copier** le dossier `addons/mcf_coop/` de ce dépôt dans le dossier `addons/` du projet cible (le chemin final doit être `res://addons/mcf_coop/mcf_host.gd`, etc.). Aucun plugin à activer, aucun autoload à déclarer : ce sont des classes globales (`class_name`).
2. Laisser Godot indexer les scripts : ouvrir l'éditeur une fois, ou lancer `Godot --headless --import --path <projet>` (nécessaire pour que les `class_name` soient connus en ligne de commande / export).
3. Poser la **version du projet** (Paramètres du projet > Application > Config > Version, ex. `0.1.0`) : elle sert à refuser les joueurs d'une autre version (voir `McfHost.same_version`).
4. Choisir l'**identifiant du jeu** : une constante `GAME_ID` (ex. `"mon_minijeu"`, ≤ 32 caractères : lettres, chiffres, `_ . : -`). Un client d'un autre jeu utilisant l'addon est refusé.
5. Écrire le code du jeu (voir [Démarrage rapide](#démarrage-rapide)) : charge utile des intentions / états / événements + boucle `poll`.
6. **Serveur dédié (facultatif)** : voir [Serveur dédié](#serveur-dédié).
7. **Vérifier** : copier `test_project/tests/test_coop.gd` + `TestCoop.tscn` dans le projet, ou lancer le test du dépôt (voir [Tests](#tests)) ; il doit finir par `== OK (0 échec(s))`.

Pare-feu : l'hôte écoute en **UDP** sur le port choisi (défaut 2302). Sous Windows, le pare-feu demandera l'autorisation au premier lancement.

---

## Principe

```
Client                                   Hôte (jeu ou serveur dédié)
  intentions (payload) ───────────────►   valide, simule (UNE seule vérité)
  demandes ponctuelles (payload) ─────►   revérifie (prix, droits…)
  affiche l'état reçu       ◄───────────  états (non fiables, ~20 Hz) + événements (fiables) + liste des joueurs
```

- Le client n'envoie que des **intentions** (ce qu'il veut faire : axes, boutons) et des **demandes** : jamais une position, un score ni un gain.
- L'hôte simule et diffuse l'**état** ; tout ce qui compte (dégâts, score, victoire) est décidé chez lui.
- **Hôte qui joue** (`reserve_local = true`) : le joueur 1 est le joueur local de l'hôte, il n'a pas de client ; les distants sont 2, 3…. **Serveur dédié** (`reserve_local = false`) : tous les joueurs sont des clients, à partir de 1.

### Canaux
| Quoi | Sens | Fiabilité |
|---|---|---|
| `INPUT` (`send_input`) | client → hôte | non fiable (la suivante arrive dans 1/60 s) ; `reliable = true` pour un appui unique qui ne doit pas se perdre |
| `REQUEST` (`send_request`) | client → hôte | fiable, limité à 5 / s par joueur |
| `STATE` (`broadcast_state`) | hôte → clients | non fiable, le client ignore tout état plus ancien que le dernier reçu |
| `EVENT` (`broadcast_event`) | hôte → clients | fiable et ordonné |
| `ROSTER` (`broadcast_roster`) | hôte → clients | fiable |

---

## Démarrage rapide

### 1. Écran de lobby (menu)

```gdscript
const GAME_ID := "mon_minijeu"

func _open_network_menu() -> void:
	var screen := preload("res://addons/mcf_coop/mcf_lobby_screen.tscn").instantiate() as McfLobbyScreen
	add_child(screen)
	# options d'hébergement : level_id (≤ 48 car.), content_hash (32 octets), mode (0-255), hello_validator
	screen.configure(GAME_ID, {"level_id": "niveau_1", "mode": 0}, _check_content)
	screen.ready_to_play.connect(_on_ready_to_play)

## Côté client : vérifie que le contenu local est le même que celui de l'hôte. "" = OK, sinon le message à afficher.
func _check_content(level_id: String, content_hash: PackedByteArray) -> String:
	if not LEVELS.has(level_id):
		return "niveau manquant : %s" % level_id
	return ""    # ou comparer content_hash (SHA-256 de ton contenu) avec celui du niveau local

func _on_ready_to_play(role: StringName, lobby: McfLobby) -> void:
	if role == &"host":
		$Game.start_as_host(lobby.take_host())
	else:
		$Game.start_as_client(lobby.take_client())
```

Sans écran : `McfLobby` (nœud) expose `host_game(port, max_players, name, options)` et `join_game(address, port, name, tags)` avec les mêmes signaux (`status_changed`, `ready_to_play`) ; construire son propre menu dessus.

L'écran `.tscn` est modifiable dans l'éditeur (thème, disposition) : seuls les noms de nœuds uniques `%NameEdit`, `%PortSpin`, `%PlayersSpin`, `%HostButton`, `%Addresses`, `%AddressEdit`, `%JoinPortSpin`, `%JoinButton`, `%StatusLabel`, `%CancelButton` et le nœud enfant `Lobby` doivent rester.

### 2. Boucle de jeu (hôte et client)

L'addon **ne poll pas tout seul** : le jeu appelle `poll(delta)` à chaque image physique.

```gdscript
# game.gd — un exemple minimal : des carrés qui se déplacent
extends Node

var host: McfHost
var client: McfClient
var tick: int = 0
var positions: Dictionary = {}   # id de joueur -> Vector2 (autorité : l'hôte)
var inputs: Dictionary = {}      # id -> dernier axe reçu (hôte)

func start_as_host(h: McfHost) -> void:
	host = h
	positions[1] = Vector2.ZERO                       # le joueur local de l'hôte est le n° 1
	host.player_joined.connect(func(id: int, info: Dictionary) -> void: positions[id] = Vector2.ZERO)
	host.player_left.connect(func(id: int, _why: String) -> void: positions.erase(id); inputs.erase(id))
	host.input_received.connect(_on_input)

func start_as_client(c: McfClient) -> void:
	client = c
	client.state_received.connect(_on_state)
	client.disconnected.connect(func(why: String) -> void: print("Déconnecté : ", why))   # retour au menu

func _physics_process(delta: float) -> void:
	tick += 1
	if host:
		host.poll(delta)
		inputs[1] = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")   # joueur local
		for id: int in positions:
			positions[id] += (inputs.get(id, Vector2.ZERO) as Vector2) * 200.0 * delta
		if tick % 3 == 0:                                       # ~20 Hz
			host.broadcast_state(tick, _encode_state())
	if client:
		client.poll(delta)
		client.send_input(tick, _encode_input(Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")))

# --- charges utiles : TOUJOURS décodées avec McfCodec.Reader (bornes strictes) ---
func _encode_input(axis: Vector2) -> PackedByteArray:
	var w := McfCodec.Writer.new()
	w.i8(roundi(clampf(axis.x, -1.0, 1.0) * 127.0))
	w.i8(roundi(clampf(axis.y, -1.0, 1.0) * 127.0))
	return w.buf

func _on_input(id: int, _tick: int, payload: PackedByteArray) -> void:
	var r := McfCodec.Reader.new(payload)
	var axis := Vector2(r.i8() / 127.0, r.i8() / 127.0)
	if not r.ok() or r.remaining() != 0:
		host.strike(id, "intention invalide")            # compte comme paquet invalide, expulsion si ça se répète
		return
	inputs[id] = axis.limit_length(1.0)                  # l'hôte recadre : ne jamais faire confiance

func _encode_state() -> PackedByteArray:
	var w := McfCodec.Writer.new()
	w.u8(positions.size())
	for id: int in positions:
		w.u8(id)
		w.f32((positions[id] as Vector2).x)
		w.f32((positions[id] as Vector2).y)
	return w.buf

func _on_state(_tick: int, payload: PackedByteArray) -> void:
	var r := McfCodec.Reader.new(payload)
	var n := r.u8()
	var received: Dictionary = {}
	for i in mini(n, McfCodec.MAX_PLAYERS_LIMIT):
		var pid := r.u8()   # lire la clé AVANT la valeur : GDScript évalue la partie droite d'une affectation en premier
		received[pid] = Vector2(r.f32(-5000.0, 5000.0, "x"), r.f32(-5000.0, 5000.0, "y"))
	if r.ok():
		positions = received                              # le client affiche ; interpolation = au jeu
```

### 3. Quitter proprement
- Client : `client.leave()`. Hôte : `host.stop()` (prévient les clients : « La partie est fermée »).
- Écouter `client.disconnected(reason)` et `client.kicked(reason)` pour revenir au menu avec un message.

---

## Référence

### `McfHost` (RefCounted)
Réglages avant `start(port, bind = "*")` : `game_id`, `game_version`, `level_id`, `content_hash` (32 octets ou vide), `mode`, `seed_value`, `max_players` (1-16), `reserve_local`, `handshake_timeout`, `max_connects_per_address`, `packets_per_second` (90), `bytes_per_second` (24000), `request_per_second` (5), `hello_validator` (`func(info: {name, tags}) -> String`, "" = accepter).
`start` renvoie `OK` ou une erreur ; `port()` donne le port réel (utile avec `start(0)`).
Signaux : `player_joined(id, {name, tags})`, `player_left(id, reason)`, `input_received(id, tick, payload)`, `request_received(id, kind, payload)`, `peer_refused(address, reason)`.
Envoi : `broadcast_state`, `send_state_to`, `broadcast_event`, `send_event_to`, `broadcast_roster`, `send_to` / `broadcast` (octets déjà encodés).
Administration : `kick(id, reason)`, `ban(id, reason)` (par adresse, le temps de la partie), `unban(address)`, `strike(id, why)`, `players_info()`, `rtt_ms(id)`, `player_name(id)`, `player_tags(id)`.

### `McfClient` (RefCounted)
`connect_to(address, port, name, tags, game_id, game_version)` · `poll(delta)` · `send_input(tick, payload, reliable = false)` · `send_request(kind, payload)` · `leave()` · `is_joined()` · `player_id`, `welcome` (`level_id`, `content_hash`, `mode`, `seed`, `max_players`), `rtt_ms`, `content_checker`.
Signaux : `joined(welcome)`, `disconnected(reason)`, `kicked(reason)`, `state_received(tick, payload)`, `event_received(tick, kind, payload)`, `roster_received(players)`, `rtt_updated(ms)`.

### `McfCodec`
`Writer` (`u8 i8 u16 i16 u32 f32 text raw`, tout est recadré) et `Reader` (`u8 i8 u16 i16 u32 f32(lo, hi, what) text(max, what) raw ok() error remaining()`). **Piège** : ne jamais écrire `d[r.u8()] = f(r.f32(…))` (la partie droite est évaluée avant la clé, la lecture se décale) : lire dans des variables, dans l'ordre. Un `Reader` qui échoue reste en erreur : tester `r.ok()` **une fois à la fin**, et `r.remaining() == 0` si la charge doit être consommée entièrement. Bornes : `MAX_PACKET` 8192, `MAX_CLIENT_PAYLOAD` 512, `MAX_PLAYERS_LIMIT` 16, `MAX_NAME` 20.
Un `encode_*` dont la charge est trop grande renvoie un paquet vide (rien n'est envoyé).

### `McfLobby` (Node) / `McfLobbyScreen` (Control)
`McfLobby` : `game_id` (obligatoire), `game_version`, `content_checker`, `max_players_limit`, `host_game(...)`, `join_game(...)`, `cancel()`, `take_host()`, `take_client()`, `menu_data()`. Messages d'erreur en français prêts à afficher.
`McfLobbyScreen` : `configure(game_id, host_options, content_checker, game_version)`, `host_options`, `join_tags`, signal `ready_to_play(role, lobby)`.

### `McfNetUtil`
`lan_addresses()`, `address_text(slot, port)`, `is_valid_address()`, `clean_text()`, `clean_name()`, `project_version()`.

---

## Serveur dédié

Une scène du jeu (ex. `res://scenes/Server.tscn`) avec un nœud `McfDedicatedServer` et le script du jeu :

```gdscript
extends Node
@onready var server: McfDedicatedServer = $McfDedicatedServer

func _ready() -> void:
	server.game_id = "mon_minijeu"
	server.level_id = "niveau_1"
	server.schema = {"mode": {"type": "enum", "values": ["coop", "versus"], "default": "coop"}}   # arguments propres au jeu
	server.extra_commands = func(cmd: String, args: PackedStringArray) -> Variant:
		return "manche relancée" if cmd == "round" else null                                       # null = pas ma commande
	server.extra_help = " · round"
	server.started.connect(func() -> void:
		server.host.input_received.connect(_on_input)      # puis simulation, comme l'hôte du jeu
		...)
```

Lancement :
```
Godot --headless --path . res://scenes/Server.tscn -- --port=2302 --max-players=4 --name="Mon serveur" --console --mode=coop
```
- Arguments génériques : `--port` (1024-65535), `--max-players` (1-16), `--name`, `--bind` (`*` ou IPv4), `--console`. Tout argument inconnu ou hors bornes **arrête le démarrage** avec un message (code 2).
- `McfDedicatedServer.requested()` vaut vrai avec `--server` ou la feature d'export `dedicated_server` : à utiliser dans la scène principale du jeu pour aiguiller vers la scène serveur.
- Console (`--console`) : `help status players kick <id> [raison] ban <id> [raison] unban <adresse> bans stop` + commandes du jeu. Toutes journalisées.
- Journal : sortie standard + `user://server_logs/server-AAAA-MM-JJ.log` (2 Mo max, caractères de contrôle neutralisés).
- **Export** (Godot 4.4+) : preset Windows dédié avec la feature personnalisée `dedicated_server` et l'option *Exporter en tant que serveur dédié* ; ne pas inclure les ressources d'interface inutiles. Après un export, **toujours lancer l'exécutable** avec `--headless -- --server` et regarder le journal (un export peut relire autrement certaines ressources que l'éditeur).

---

## Modèle de permissions (qui voit / peut quoi)

| Donnée / action | Client | Hôte |
|---|---|---|
| Ses intentions (INPUT) | **écrit** (borné, limité en débit) | lit, valide, applique |
| Position, score, état de partie | lit | **seul écrivain** |
| Demandes (REQUEST) | demande (5 / s) | **revérifie** (prix, droits, état) et décide |
| Nom affiché | propose (≤ 20 car., nettoyé) | nettoie, rend unique |
| Étiquettes (`tags`, ≤ 6 identifiants) | déclare | revalide (`hello_validator`) |
| Expulsion, bannissement, fermeture | – | oui |
| Fichiers locaux d'un joueur | seul accès | **aucun accès** (l'hôte ne reçoit jamais de sauvegarde) |

Un joueur est identifié par son **pair ENet**, jamais par un champ du paquet : un client ne peut pas parler au nom d'un autre.

## Menaces et mesures

| Menace | Mesure dans l'addon |
|---|---|
| Paquets malformés / géants (NaN, tableaux, texte invalide) | `McfCodec.decode` : types autorisés par sens, bornes, UTF-8 strict, rien en trop ; invalide = refusé et compté, expulsion au-delà de 8 |
| Inondation | seau à jetons par pair (paquets / s, octets / s), refus comptés puis expulsion ; plafond de bande passante ENet ; paquets > 8 Kio expulsés après 3 |
| Connexions en rafale / pairs fantômes | 12 connexions / 10 s par adresse, 8 poignées de main en attente max, coupure à 5 s, pair muet détecté par ENet |
| Mauvais jeu / mauvaise version | `game_id` et version majeure.mineure comparés à la poignée de main, refus explicite |
| Contenu différent (carte modifiée) | WELCOME porte l'empreinte ; le **client** compare avec son contenu local (`content_checker`) et refuse sinon |
| Hôte malveillant | rien d'exécutable ne transite (pas de scène, script ni `Variant`) ; le client décode tout avec des bornes ; le jeu ne doit appliquer que des valeurs bornées |
| Abus de demandes | `request_per_second` ; le jeu appelle `host.strike(id, …)` pour toute valeur invalide |
| Joueur indésirable | `kick`, `ban` (par adresse), console d'administration |
| Départs en rafale | jamais d'envoi vers un pair déconnecté |

## Limites

- **Pas de chiffrement** : ENet en clair. Ne jamais y faire passer de secret (mot de passe, jeton). Adresse IP de chaque joueur visible de l'hôte (inhérent à la connexion directe).
- **Pas de NAT-traversal** : réseau local, ou hôte avec port UDP redirigé / serveur dédié sur IP publique.
- **Prédiction, interpolation, réconciliation, lissage** : au jeu (l'addon fournit `tick` dans INPUT et STATE pour les implémenter ; mettre dans l'état l'« ack » du dernier INPUT appliqué par joueur).
- Jusqu'à 16 joueurs ; 1 hôte = 1 partie.

## Tests

```
cd test_project
mklink /J addons\mcf_coop ..\addons\mcf_coop     (une seule fois, cmd Windows ; ou New-Item -ItemType Junction en PowerShell)
Godot --headless --import --path .
Godot --headless --audio-driver Dummy --path . res://tests/TestCoop.tscn
```
Doit finir par `== OK (0 échec(s))` : codec (aller-retour, hostiles, 2000 paquets aléatoires), configuration, hôte + clients réels en boucle locale (poignée de main, refus, états / événements / demandes, expulsion), hôte hostile (silence, paquets invalides / géants, inondation, bannissement, connexions en rafale), lobby, écran de lobby, serveur dédié et console. Les lignes « Unicode parsing error » dans la sortie viennent du test de paquets aléatoires et sont normales.

## Contenu

```
addons/mcf_coop/
  mcf_codec.gd            codec borné (+ Writer / Reader pour les charges utiles du jeu)
  mcf_host.gd             hôte autoritaire
  mcf_client.gd           client
  mcf_rate_limiter.gd     seau à jetons
  mcf_net_util.gd         adresses locales, nettoyage des noms
  mcf_lobby.gd            lobby sans interface
  mcf_lobby_screen.gd/.tscn  écran natif héberger / rejoindre
  mcf_server_config.gd    arguments du serveur dédié (validation stricte)
  mcf_server_log.gd       journal plafonné
  mcf_server_console.gd   console d'administration
  mcf_dedicated_server.gd serveur dédié
test_project/             projet de test (jonction addons/mcf_coop → ../addons/mcf_coop)
```
