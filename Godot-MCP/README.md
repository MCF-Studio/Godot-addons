# Godot MCP

Serveur [MCP](https://modelcontextprotocol.io) permettant à Claude (ou à n'importe quel client MCP) de piloter **Godot 4** : lire et modifier des scènes et des nœuds, écrire des scripts, lancer le jeu et lire ses erreurs.

Le plugin ajoute aussi deux docks dans l'éditeur : une **todo** partagée avec Claude et un **chat Claude** intégré (voir [Docks dans l'éditeur](#docks-dans-léditeur)).

```
Client MCP ──stdio──▶ server/ (Node/TypeScript)
                         ├── WebSocket ws://127.0.0.1:6505 ──▶ addons/godot_mcp (plugin éditeur)
                         └── child_process ──▶ godot --headless … (CLI, sans éditeur)
```

- **Tools éditeur** : passent par le plugin, qui doit être actif dans l'éditeur ouvert. Toutes les modifications passent par l'undo/redo de Godot, donc **Ctrl+Z fonctionne**.
- **Tools CLI** : lancent un processus Godot séparé et fonctionnent même éditeur fermé.

Testé avec Godot 4.7.2. Visé : 4.2+. `get_editor_log` nécessite la 4.5+. Les docks Todo et Chat ont été testés en 4.5.1, 4.6.2 et 4.7.2 ; le chat exige la 4.5+.

## Installation

### 1. Serveur
```bash
cd server
npm install
npm run build
```

### 2. Plugin Godot
Copie `addons/godot_mcp/` dans le dossier `addons/` de ton projet, puis active **Godot MCP** dans *Projet > Paramètres du projet > Plugins*. La sortie de l'éditeur doit afficher :
```
[Godot MCP] listening on 127.0.0.1:6505
```

### 3. Déclarer le serveur dans Claude Code
```bash
claude mcp add godot -e GODOT_PATH="C:/chemin/Godot_v4.x-stable_win64.exe" -- node /chemin/vers/Godot-MCP/server/dist/index.js
```
`/chemin/vers/Godot-MCP` est le dossier de cet addon sur ta machine (celui qui contient ce README).

Pour Claude Desktop (`claude_desktop_config.json`) :
```json
{
  "mcpServers": {
    "godot": {
      "command": "node",
      "args": ["/chemin/vers/Godot-MCP/server/dist/index.js"],
      "env": { "GODOT_PATH": "C:/chemin/Godot_v4.x-stable_win64.exe" }
    }
  }
}
```

## Docks dans l'éditeur

Deux docks apparaissent à l'activation du plugin. Ce sont de vrais docks Godot : glisse-les par leur onglet vers un autre emplacement, passe-les en fenêtre flottante, ferme-les et rouvre-les depuis le menu *Éditeur* ; Godot retient la position choisie d'une session à l'autre. Par défaut : **Todo** en bas à gauche, **Claude** dans le panneau du bas. Avant la Godot 4.6, les mêmes emplacements sont utilisés via l'ancienne API de docks (pas de fenêtre flottante).

### Todo
- **Ajouter** : zone de saisie en bas, `Entrée` ajoute, `Maj+Entrée` passe à la ligne.
- **Modifier** : double-clic, `F2` ou `Entrée` sur une tâche ; `Entrée` valide, `Échap` annule, perdre le focus valide.
- **Supprimer** : bouton ✕ ou touche `Suppr`, avec une barre « Annuler » pendant quelques secondes (pas de confirmation).
- **Cocher** : la case, ou `Espace`. Clic droit : marquer « en cours » (▶), *Demander à Claude* (envoie la tâche au chat), supprimer.
- **Réordonner** : glisser la poignée `⋮⋮`.
- **Textes longs** : retour à la ligne automatique (jamais de défilement horizontal), tâches de plus de 6 lignes repliées avec « Afficher tout », URL et chemins `res://fichier.gd:12` cliquables.
- Filtre Toutes / À faire / Faites, compteur, bouton pour vider les tâches faites.

La liste est enregistrée dans `res://.godot_mcp/todo.json` (dossier caché : ignoré par l'import Godot, versionnable ou à ajouter au `.gitignore`). Le dock suit les modifications faites à la main dans ce fichier. Claude peut la lire et la cocher via les tools `todo_*`, que ce soit depuis le chat ou depuis un Claude lancé dans un terminal.

### Chat Claude
Le dock lance **Claude Code** (`claude -p`, mode `stream-json`) comme processus fils et lui parle comme dans un terminal : mêmes comptes, mêmes MCP, y compris `godot`. Il ne démarre qu'au premier message envoyé et s'arrête avec l'éditeur.

- **Prérequis** : Claude Code installé et connecté (`claude` dans le PATH, ou `~/.local/bin/claude`) ; Godot 4.5+.
- **Serveur MCP Godot** : renseigne une fois `server/dist/index.js` (bouton *Choisir…* du bandeau, ou *Éditeur > Paramètres de l'éditeur > Godot Mcp > Server Path*). Valable pour tous les projets. Sans cela, le chat utilise les MCP que tu as déclarés avec `claude mcp add`.
- **Reprendre dans un terminal** : le menu `⋯` copie `claude --resume <id>` ; lance-le depuis le dossier du projet pour continuer la même conversation. Après un redémarrage de l'éditeur, le message suivant reprend automatiquement la conversation en cours (l'affichage de l'historique n'est pas restauré).
- **Stop** interrompt Claude sans perdre la conversation ; **Nouveau** démarre une nouvelle conversation (l'ancienne reste reprenable).
- Les réponses sont rendues en Markdown (blocs de code, listes, tableaux, liens). Les appels d'outils apparaissent comme des cartes repliables.

> ⚠️ **Le chat tourne sans demande d'autorisation** (`--permission-mode bypassPermissions`, comme `claude --dangerously-skip-permissions`) : Claude peut lire et écrire des fichiers et exécuter des commandes avec tes droits. N'active le plugin que si c'est ce que tu veux. Pour retirer des outils sans toucher au code, ajoute des arguments dans *Paramètres de l'éditeur > Godot Mcp > Claude Extra Args*, par exemple `--disallowedTools Bash`.

| Paramètre de l'éditeur (`godot_mcp/…`) | Rôle |
|---|---|
| `claude_path` | Chemin de l'exécutable `claude` (sinon détecté automatiquement) |
| `server_path` | Chemin de `server/dist/index.js`, déclaré à Claude comme serveur MCP `godot` |
| `claude_extra_args` | Arguments supplémentaires passés à `claude` (ex. `--model opus`) |

## Variables d'environnement

| Variable | Rôle | Défaut |
|---|---|---|
| `GODOT_PATH` | Exécutable Godot pour les tools CLI. Sous Windows, le `*_console.exe` voisin est utilisé automatiquement. | `godot` dans le PATH |
| `GODOT_PROJECT_PATH` | Projet par défaut des tools CLI | projet ouvert dans l'éditeur |
| `GODOT_MCP_PORT` | Port WebSocket (à définir aussi côté éditeur, ou via le paramètre projet `godot_mcp/port`) | `6505` |
| `GODOT_MCP_TOKEN` | Jeton partagé optionnel (même valeur côté éditeur, ou paramètre projet `godot_mcp/token`) | aucun |

Le plugin n'écoute que sur `127.0.0.1`.

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
| `todo_list` / `todo_add` / `todo_update` / `todo_remove` | La todo du dock Todo : lire, ajouter, changer le texte / le statut (`open`, `doing`, `done`) / la position, supprimer |

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

Pour lancer le test de bout en bout :

```bash
# Terminal 1 : éditeur headless avec le plugin
godot --headless --editor --path test_project
# Terminal 2
cd server && GODOT_PATH=... npm run test:e2e
```

Tests unitaires (store de la todo, UI du dock Todo, conversion Markdown, outils de session ; sans éditeur) :

```bash
godot --headless --path test_project -s tests/unit.gd
```

Pour tester les tools à la main : `npm run inspector` (MCP Inspector).

### Structure
```
server/src/
  index.ts        point d'entrée (stdio)
  bridge.ts       client WebSocket vers le plugin
  cli.ts          wrapper de l'exécutable Godot
  tools/          définition des tools (zod)
addons/godot_mcp/
  plugin.gd       EditorPlugin (serveur WebSocket + docks)
  ws_server.gd    serveur WebSocket et dispatch JSON
  mcp_logger.gd   capture du log éditeur (4.5+)
  dock_host.gd    ajoute un contrôle comme dock (EditorDock 4.6+, ancienne API avant)
  commands/       implémentation des commandes (une classe par domaine, dont todo_commands.gd)
  todo/           dock Todo : todo_store.gd (données + fichier), todo_panel.gd, todo_row.gd
  chat/           dock Claude : claude_session.gd (processus claude), chat_panel.gd, markdown.gd
  ui/             auto_text_edit.gd (saisie qui grandit), text_links.gd (URL et res:// cliquables)
```

Pour ajouter une commande : une méthode dans `addons/godot_mcp/commands/*.gd`, enregistrée dans `register()`, plus un `bridgeTool(...)` du même nom dans `server/src/tools/`.
