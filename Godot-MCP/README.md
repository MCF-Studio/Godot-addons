# Godot MCP

Serveur [MCP](https://modelcontextprotocol.io) permettant à Claude (ou à n'importe quel client MCP) de piloter **Godot 4** : lire et modifier des scènes et des nœuds, écrire des scripts, lancer le jeu et lire ses erreurs.

Le plugin ajoute aussi un **chat Claude** intégré à l'éditeur (voir [Chat Claude](#chat-claude)). Il s'associe, sans en dépendre, à l'addon [**MCF Todo**](../MCF-Todo/) : si les deux sont actifs, Claude lit et coche ta todo, et chaque tâche gagne l'entrée « Demander à Claude ». Les deux addons s'installent séparément ou ensemble (voir le [bundle](../Bundle-Todo-MCP/)).

```
Client MCP ──stdio──▶ serveur MCP (Node ; livré en un seul fichier dans addons/godot_mcp/server/)
                         ├── WebSocket ws://127.0.0.1:6505 ──▶ addons/godot_mcp (plugin éditeur)
                         ├── TCP 127.0.0.1:6005 ──▶ serveur de langage GDScript de Godot (LSP)
                         └── child_process ──▶ godot --headless … (CLI, sans éditeur)

Claude Code ──stdio──▶ godot-mcp-server.mjs --lsp ──TCP──▶ LSP de Godot   (plugin « godot-gdscript-lsp »)
```

- **Tools éditeur** : passent par le plugin, qui doit être actif dans l'éditeur ouvert. Toutes les modifications passent par l'undo/redo de Godot, donc **Ctrl+Z fonctionne**.
- **Tools CLI** : lancent un processus Godot séparé et fonctionnent même éditeur fermé.

Testé avec Godot 4.7.2. Visé : 4.2+. `get_editor_log` nécessite la 4.5+. Le dock Chat a été testé en 4.5.1, 4.6.2 et 4.7.2 ; il exige la 4.5+.

## Installation

**Prérequis** : [Node.js](https://nodejs.org) 18+ (il fait tourner le serveur MCP ; l'addon le cherche dans le `PATH` puis dans ses dossiers d'installation habituels) et, pour le chat, Claude Code installé et connecté.

1. Copie `addons/godot_mcp/` dans le dossier `addons/` de ton projet. Le serveur MCP est **déjà dedans** (`addons/godot_mcp/server/`, un seul fichier : pas de `npm install`).
2. Active **Godot MCP** dans *Projet > Paramètres du projet > Plugins*. La sortie de l'éditeur doit afficher :
   ```
   [Godot MCP] listening on 127.0.0.1:6505
   ```
3. C'est tout : le dock **Claude** utilise le serveur livré dans l'addon, sans rien choisir ni configurer.

### Connecter un autre Claude (terminal, Claude Desktop)

Le chat est déjà branché. Pour qu'un Claude lancé **à côté** (dans un terminal, ou Claude Desktop) pilote aussi l'éditeur, ouvre le menu `⋯` du dock Claude :
- **Connecter Claude Code (terminal) à cet éditeur** copie la commande `claude mcp add godot -- node "…/godot-mcp-server.mjs"` ; colle-la dans un terminal ouvert dans le dossier du projet ;
- **Connecter Claude Desktop à cet éditeur** copie le bloc JSON à ajouter dans `claude_desktop_config.json`.

Le chemin du serveur est déjà rempli (et le port de l'éditeur si ce n'est pas 6505) : il n'y a rien à chercher. Le jeton de connexion n'a pas à être copié : le serveur le lit tout seul (voir [Sécurité](#sécurité)).

## Analyse GDScript (LSP)

Godot embarque un serveur de langage GDScript : le même moteur d'analyse que l'éditeur de scripts, qui connaît les `class_name`, les autoloads et toute l'API Godot. L'addon y donne accès de deux façons.

**1. Tools MCP**, pour tout client MCP :

| Tool | Description |
|---|---|
| `gdscript_diagnostics` | Erreurs et warnings d'un ou plusieurs scripts, ou de tout le projet (sans `paths` ; `addons/` exclu par défaut). Beaucoup plus rapide que `check_script` |
| `gdscript_symbols` | Plan d'un script : classe, signaux, variables, constantes, fonctions avec signature et ligne |
| `gdscript_definition` | Où un identifiant est déclaré, y compris dans un autre fichier |
| `gdscript_references` | Toutes les utilisations d'un identifiant dans le projet |
| `gdscript_hover` | Type, signature et documentation (API Godot comprise, dans la langue de l'éditeur) |

Les positions se donnent par nom (`"symbol": "take_damage"`, `line` facultative) ou par `line` + `column` (comptées à partir de 1). `create_script` renvoie aussi les erreurs du script écrit (`diagnostics`) quand un serveur de langage est déjà disponible.

**2. Plugin Claude Code `godot-gdscript-lsp`** : Claude Code reçoit les erreurs GDScript **automatiquement après chaque modification** d'un `.gd` et peut naviguer dans le code (outil `LSP` : définition, références, symboles…).
- **Chat de l'éditeur** : actif d'office, rien à faire.
- **Claude Code dans un terminal** : menu `⋯` du dock Claude > *Analyse GDScript (LSP) dans Claude Code (terminal)* copie deux commandes à lancer une fois ; le plugin vaut ensuite pour tous les projets :
  ```bash
  claude plugin marketplace add "<dossier de configuration>/Godot/godot_mcp/claude-plugins"
  claude plugin install godot-gdscript-lsp@godot-mcp-local
  ```
  L'addon écrit ce plugin dans le dossier de configuration de l'utilisateur (`%APPDATA%` sous Windows, `~/Library/Application Support` sous macOS, `~/.config` sous Linux), avec sa propre copie du serveur, rafraîchie à chaque démarrage du chat. Il faut `node` dans le `PATH` du terminal.

**Quel serveur de langage est utilisé**, dans cet ordre :
1. `GODOT_LSP_PORT` s'il est défini ;
2. celui de l'éditeur qui a **ce projet** ouvert (réglage *Réseau > Language Server > Remote Port*, 6005 par défaut) ;
3. le port 6005, seulement si le projet ouvert là-bas est le bon ;
4. sinon, un **éditeur headless** lancé pour l'occasion (`godot --headless --editor --lsp-port <port libre>`), avec l'exécutable de `GODOT_PATH` ou celui d'un éditeur déjà lancé. Compter quelques secondes au premier appel (plus si le projet n'a jamais été importé) ; ensuite les réponses sont immédiates. Pour les tools MCP, il s'arrête après 10 minutes sans requête ; pour le plugin, avec la session Claude Code. `GODOT_LSP_AUTOSTART=0` l'interdit.

Un serveur de langage qui a **un autre projet** ouvert n'est jamais utilisé : ses réponses porteraient sur d'autres fichiers. Le plugin trouve le projet à partir du dossier ouvert par Claude Code : ce dossier, un parent, ou un sous-dossier jusqu'à 3 niveaux. Sans projet Godot, il reste inactif, sans erreur.

Limites : un éditeur lancé avec `--lsp-port` n'est pas détectable (Godot cache ses propres options aux scripts) ; définir alors `GODOT_LSP_PORT`. Un éditeur headless ne surveille pas le disque : chaque requête relit le fichier interrogé, mais les références vers d'autres fichiers modifiés depuis son démarrage peuvent être en retard.

### Depuis les sources

Le fichier serveur est généré, pas versionné : après un clone, construis-le une fois.
```bash
cd server
npm ci
npm run build   # compile (tsc) puis écrit addons/godot_mcp/server/godot-mcp-server.mjs + THIRD-PARTY-LICENSES.txt
```
Sans ce fichier, le chat l'indique par un bandeau (il propose alors de désigner un fichier serveur à la main). Variante pour un client MCP sans passer par l'addon : `node server/dist/index.js` (sortie de `tsc`) fonctionne aussi.

## Dock dans l'éditeur

Le dock **Claude** apparaît à l'activation du plugin. C'est un vrai dock Godot : glisse-le par son onglet vers un autre emplacement, passe-le en fenêtre flottante, ferme-le et rouvre-le depuis le menu *Éditeur* ; Godot retient la position choisie d'une session à l'autre. Par défaut : le panneau du bas. Avant la Godot 4.6, le même emplacement est utilisé via l'ancienne API de docks (pas de fenêtre flottante).

### Chat Claude
Le dock lance **Claude Code** (`claude -p`, mode `stream-json`) comme processus fils et lui parle comme dans un terminal : mêmes comptes, mêmes MCP, y compris `godot`. Il ne démarre qu'au premier message envoyé et s'arrête avec l'éditeur.

- **Prérequis** : Claude Code installé et connecté (`claude` dans le PATH, ou `~/.local/bin/claude`) ; Godot 4.5+.
- **Serveur MCP Godot** : celui de l'addon est utilisé automatiquement, rien à choisir. Si Node.js est introuvable ou si le fichier serveur manque (installation depuis les sources sans `npm run build`), un bandeau le dit et explique quoi faire.
- **Reprendre dans un terminal** : le menu `⋯` > *Reprendre cette conversation dans un terminal* copie `claude --resume <id>` ; lance-le depuis le dossier du projet pour continuer la même conversation. Après un redémarrage de l'éditeur, le message suivant reprend automatiquement la conversation en cours (l'affichage de l'historique n'est pas restauré).
- **Stop** interrompt Claude sans perdre la conversation ; **Nouveau** démarre une nouvelle conversation (l'ancienne reste reprenable).
- Les réponses sont rendues en Markdown (blocs de code, listes, tableaux, liens). Les appels d'outils apparaissent comme des cartes repliables.

> ⚠️ **Le chat tourne sans demande d'autorisation** (`--permission-mode bypassPermissions`, comme `claude --dangerously-skip-permissions`) : Claude peut lire et écrire des fichiers et exécuter des commandes avec tes droits. N'active le plugin que si c'est ce que tu veux. Pour retirer des outils sans toucher au code, ajoute des arguments dans *Paramètres de l'éditeur > Godot Mcp > Claude Extra Args*, par exemple `--disallowedTools Bash`.

| Paramètre de l'éditeur (`godot_mcp/…`) | Rôle |
|---|---|
| `claude_path` | Chemin de l'exécutable `claude` (sinon détecté automatiquement) |
| `server_path` | Avancé : chemin d'un autre fichier serveur MCP, qui remplace celui de l'addon (utile pour tester une version en développement) |
| `claude_extra_args` | Arguments supplémentaires passés à `claude` (ex. `--model opus`) |

### Avec l'addon MCF Todo (facultatif)

[`MCF-Todo/`](../MCF-Todo/) est un addon indépendant (dock de tâches). Quand il est actif dans le même projet :
- les tools `todo_list`, `todo_add`, `todo_update` et `todo_remove` lisent et modifient la liste, que Claude soit lancé depuis le chat ou depuis un terminal ; le dock se met à jour en direct ;
- le clic droit sur une tâche propose **Demander à Claude** (envoie la tâche au chat).

Sans cet addon, les quatre tools répondent par une erreur explicite (« The MCF Todo addon is not installed or not enabled… ») et le reste fonctionne normalement. Le lien se fait uniquement par les métadonnées d'`Engine` décrites dans le README de MCF Todo : aucun des deux addons n'importe le code de l'autre.

## Variables d'environnement

| Variable | Rôle | Défaut |
|---|---|---|
| `GODOT_PATH` | Exécutable Godot pour les tools CLI et l'éditeur headless du LSP. Sous Windows, le `*_console.exe` voisin est utilisé automatiquement. | celui d'un éditeur lancé avec l'addon, sinon `godot` dans le PATH |
| `GODOT_PROJECT_PATH` | Projet par défaut des tools CLI et LSP | projet ouvert dans l'éditeur |
| `GODOT_MCP_PORT` | Port WebSocket (à définir aussi côté éditeur, ou via le paramètre projet `godot_mcp/port`) | `6505` |
| `GODOT_MCP_TOKEN` | Jeton fixe (même valeur côté éditeur, ou paramètre projet `godot_mcp/token`). Inutile en temps normal : voir [Sécurité](#sécurité) | jeton aléatoire à chaque démarrage |
| `GODOT_LSP_PORT` / `GODOT_LSP_HOST` | Serveur de langage GDScript à utiliser, sans recherche | recherche automatique (voir [Analyse GDScript](#analyse-gdscript-lsp)) |
| `GODOT_LSP_AUTOSTART` | `0` : ne jamais lancer d'éditeur headless pour le LSP | `1` |

## Sécurité

- **Le WebSocket exige un jeton.** Écouter sur `127.0.0.1` ne suffit pas : une page web ouverte dans le navigateur peut ouvrir un WebSocket vers `127.0.0.1:6505`, et Godot ne permet pas de vérifier l'en-tête `Origin`. Sans jeton, une telle page pouvait piloter l'éditeur, donc écrire un script puis le lancer. Désormais chaque éditeur tire un jeton aléatoire à son démarrage et l'écrit dans un fichier de session (`<dossier de configuration>/Godot/godot_mcp/editor-<port>.json`, lisible par l'utilisateur seul sous macOS et Linux), supprimé à la fermeture. Le serveur MCP le lit tout seul ; une page web ne peut pas lire de fichier local. Un client sans le bon jeton est refusé et déconnecté.
- **Les chemins restent dans le projet** : `create_script`, `read_script`, `create_scene`, `save_scene` et `list_files` refusent les chemins absolus et les `..`.
- **Le serveur de langage de Godot (port 6005) n'a pas d'authentification.** Cela ne dépend pas de l'addon. Il n'écrit aucun fichier et n'exécute rien, mais il permet de lire les scripts du projet. Il n'écoute que sur `127.0.0.1` par défaut : ne change pas *Remote Host*.
- **Le chat tourne sans demande d'autorisation** (voir l'avertissement de la section [Chat Claude](#chat-claude)).

## Tools

**Éditeur** (plugin requis)

| Tool | Description |
|---|---|
| `get_editor_state` | Version, projet, scène éditée, sélection, jeu en cours ou non |
| `get_scene_tree` | Arbre des nœuds de la scène éditée |
| `open_scene` / `create_scene` / `save_scene` | Gestion des scènes |
| `instantiate_scene` | Instancie un `.tscn` comme enfant |
| `add_node` / `delete_node` / `rename_node` / `reparent_node` | Édition des nœuds (annulable) |
| `get_node_properties` / `set_node_properties` | Lecture et écriture des propriétés, avec conversion JSON → Vector2, Color, ressources… |
| `create_script` / `read_script` / `attach_script` | Scripts GDScript (`create_script` et `read_script` marchent aussi sans éditeur) |
| `undo` / `redo` | Équivalents de Ctrl+Z et Ctrl+Shift+Z |
| `run_project` / `run_current_scene` / `stop_project` | F5 / F6 / Stop |
| `list_files` / `search_classes` / `get_class_info` | Exploration du projet et de l'API Godot |
| `get_editor_log` | Messages et erreurs de l'éditeur (4.5+) |
| `gdscript_diagnostics` / `gdscript_symbols` / `gdscript_definition` / `gdscript_references` / `gdscript_hover` | Analyse GDScript par le LSP de Godot (éditeur ouvert, ou headless lancé à la demande) : voir [Analyse GDScript](#analyse-gdscript-lsp) |
| `todo_list` / `todo_add` / `todo_update` / `todo_remove` | La todo de l'addon **MCF Todo** (si actif) : lire, ajouter, changer le texte / le statut (`open`, `doing`, `done`) / la position, supprimer |

**CLI** (sans éditeur)

| Tool | Description |
|---|---|
| `godot_version` | Version de l'exécutable utilisé |
| `run_and_capture` | Lance le jeu ou une scène et renvoie stdout/stderr (`print`, erreurs, stack traces) |
| `check_script` | Vérifie la syntaxe d'un script sans lancer le jeu |
| `export_project` | Export via un preset de `export_presets.cfg` |

> La sortie d'un jeu lancé avec `run_project` (F5) s'affiche dans l'éditeur mais n'est pas accessible par le plugin. Pour lire `print()` et les erreurs du jeu, utilise `run_and_capture`.

### Format des valeurs
- Vecteurs : `[100, 50]` ou `{"x": 100, "y": 50}`
- Couleurs : `"#ff8800"`, `"red"`, `[1, 0.5, 0, 1]`
- Ressources : `"res://textures/hero.png"`
- Tout le reste : un littéral Godot, par exemple `"Rect2(0, 0, 32, 32)"`
- Chemins de nœuds : relatifs à la racine de la scène, `"."` désignant la racine elle-même

## Développement

`test_project/` est un petit projet Godot qui pointe vers `addons/godot_mcp` via une jonction Windows. Cette jonction n'est pas versionnée ; après un clone, recrée-la :

```powershell
New-Item -ItemType Junction -Path test_project\addons\godot_mcp -Target addons\godot_mcp
```

Pour lancer le test de bout en bout (il teste le serveur **tel qu'il est livré**, le fichier embarqué dans l'addon) :

```bash
cd server && npm ci && npm run build     # une fois, et après chaque changement du serveur
# Terminal 1 : éditeur headless avec le plugin
godot --headless --editor --path test_project
# Terminal 2
cd server && GODOT_PATH=... npm run test:e2e
```

Si un autre éditeur Godot est déjà ouvert sur la machine, il occupe les ports 6505 et 6005 : lance l'éditeur de test avec `GODOT_MCP_PORT=6595 godot --headless --editor --lsp-port 6095 --path test_project`, puis le test avec `GODOT_MCP_PORT=6595 GODOT_LSP_PORT=6095`.

Ce test vérifie que les tools `todo_*` répondent par l'erreur « addon non installé ». Le cas où MCF Todo est actif se teste avec le projet du [bundle](../Bundle-Todo-MCP/) (`E2E_PROJECT` et `E2E_EXPECT_TODO=1`, voir son README).

Tests unitaires (conversion Markdown, liens, outils de session ; sans éditeur) :

```bash
godot --headless --path test_project -s tests/unit.gd
```

Pour tester les tools à la main : `npm run inspector` (MCP Inspector).

### Structure
```
server/                 sources du serveur MCP (TypeScript) — pas livré tel quel
  src/index.ts          point d'entrée : serveur MCP (défaut) ou pont LSP (--lsp)
  src/mcp.ts            serveur MCP (stdio)
  src/bridge.ts         client WebSocket vers le plugin (jeton lu dans le fichier de session)
  src/editors.ts        fichiers de session des éditeurs (jeton, projet, port LSP, exécutable)
  src/cli.ts            wrapper de l'exécutable Godot
  src/lsp/              client du LSP de Godot, choix du serveur / éditeur headless, pont stdio
  src/tools/            définition des tools (zod) ; lsp.ts = tools gdscript_*
  scripts/bundle.mjs    embarque le serveur et ses dépendances en UN fichier dans l'addon (esbuild) + licences
addons/godot_mcp/
  server/               serveur livré avec l'addon : godot-mcp-server.mjs et THIRD-PARTY-LICENSES.txt (générés,
                        non versionnés) ; .gdignore le cache à Godot
  plugin.gd       EditorPlugin (serveur WebSocket + dock Claude + lien facultatif avec MCF Todo)
  ws_server.gd    serveur WebSocket et dispatch JSON
  mcp_logger.gd   capture du log éditeur (4.5+)
  dock_host.gd    ajoute un contrôle comme dock (EditorDock 4.6+, ancienne API avant) — copie partagée avec MCF Todo
  commands/       implémentation des commandes (une classe par domaine ; todo_commands.gd = pont vers MCF Todo)
  chat/           dock Claude : claude_session.gd (processus claude), chat_panel.gd, markdown.gd,
                  lsp_plugin.gd (plugin Claude Code « godot-gdscript-lsp »)
  ui/             auto_text_edit.gd (saisie qui grandit), text_links.gd (URL et res:// cliquables) — copies partagées avec MCF Todo
```

Pour ajouter une commande : une méthode dans `addons/godot_mcp/commands/*.gd`, enregistrée dans `register()`, plus un `bridgeTool(...)` du même nom dans `server/src/tools/`.
