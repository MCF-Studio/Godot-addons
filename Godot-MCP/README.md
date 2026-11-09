# Godot MCP

Serveur [MCP](https://modelcontextprotocol.io) permettant à Claude (ou à n'importe quel client MCP) de piloter **Godot 4** : lire et modifier des scènes et des nœuds, écrire des scripts, lancer le jeu et lire ses erreurs.

```
Client MCP ──stdio──▶ server/ (Node/TypeScript)
                         ├── WebSocket ws://127.0.0.1:6505 ──▶ addons/godot_mcp (plugin éditeur)
                         └── child_process ──▶ godot --headless … (CLI, sans éditeur)
```

- **Tools éditeur** : passent par le plugin, qui doit être actif dans l'éditeur ouvert. Toutes les modifications passent par l'undo/redo de Godot, donc **Ctrl+Z fonctionne**.
- **Tools CLI** : lancent un processus Godot séparé et fonctionnent même éditeur fermé.

Testé avec Godot 4.7.2. Visé : 4.2+. `get_editor_log` nécessite la 4.5+.

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
claude mcp add godot -e GODOT_PATH="C:/chemin/Godot_v4.x-stable_win64.exe" -- node I:/game_dev/Godot-MCP/server/dist/index.js
```
Pour Claude Desktop (`claude_desktop_config.json`) :
```json
{
  "mcpServers": {
    "godot": {
      "command": "node",
      "args": ["I:/game_dev/Godot-MCP/server/dist/index.js"],
      "env": { "GODOT_PATH": "C:/chemin/Godot_v4.x-stable_win64.exe" }
    }
  }
}
```

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

Pour tester les tools à la main : `npm run inspector` (MCP Inspector).

### Structure
```
server/src/
  index.ts        point d'entrée (stdio)
  bridge.ts       client WebSocket vers le plugin
  cli.ts          wrapper de l'exécutable Godot
  tools/          définition des tools (zod)
addons/godot_mcp/
  plugin.gd       EditorPlugin
  ws_server.gd    serveur WebSocket et dispatch JSON
  mcp_logger.gd   capture du log éditeur (4.5+)
  commands/       implémentation des commandes (une classe par domaine)
```

Pour ajouter une commande : une méthode dans `addons/godot_mcp/commands/*.gd`, enregistrée dans `register()`, plus un `bridgeTool(...)` du même nom dans `server/src/tools/`.
