# Bundle MCF Todo + Godot MCP

Les deux addons ensemble, prêts à l'emploi : une **todo** dans l'éditeur et un **chat Claude** qui pilote Godot, reliés entre eux (Claude lit et coche la todo, « Demander à Claude » sur chaque tâche).

Ce dossier ne contient **aucun code d'addon** : le bundle est assemblé à partir des deux addons, qui restent disponibles séparément.

| Livrable | Contenu | Doc |
|---|---|---|
| MCF Todo seul | `addons/mcf_todo/` | [`MCF-Todo/README.md`](../MCF-Todo/README.md) |
| Godot MCP seul | `addons/godot_mcp/` + `server/` (serveur MCP compilé) | [`Godot-MCP/README.md`](../Godot-MCP/README.md) |
| **Bundle** | les deux addons + `server/` + la doc des deux | ce fichier |

Chacun fonctionne sans les autres. Le lien entre les deux est facultatif et automatique : s'ils sont actifs dans le même projet, ils se trouvent (métadonnées d'`Engine`, aucun import de code).

## Installer le bundle

1. Copier `addons/mcf_todo/` et `addons/godot_mcp/` dans le dossier `addons/` du projet.
2. Installer le serveur MCP : `cd server && npm ci --omit=dev` (Node 18+ ; le dossier `server/` peut rester où tu veux).
3. *Projet > Paramètres du projet > Plugins* : activer **MCF Todo** et **Godot MCP**.
4. Dans le dock **Claude**, cliquer sur *Choisir…* et désigner `server/dist/index.js` (une seule fois pour tous les projets), ou déclarer le serveur avec `claude mcp add` (voir la doc de Godot MCP).
5. Prérequis du chat : Claude Code installé et connecté, Godot 4.5+.

> ⚠️ Le chat lance Claude **sans demande d'autorisation** (voir l'avertissement de la doc de Godot MCP). N'active **Godot MCP** que si c'est ce que tu veux ; **MCF Todo** n'exécute rien et peut s'utiliser seul.

## Fabriquer les livrables

```bash
cd ../Godot-MCP/server && npm ci && npm run build   # une fois : compile le serveur MCP
cd ../../Bundle-Todo-MCP && node build.mjs
```

`build.mjs` écrit dans `dist/` (ignoré par git) : `mcf-todo/`, `godot-mcp/` et `bundle/`, prêts à être zippés. **Il refuse d'assembler** si l'un de ces contrôles échoue :

| Contrôle | Pourquoi |
|---|---|
| `dock_host.gd`, `ui/auto_text_edit.gd`, `ui/text_links.gd` identiques dans les deux addons | chaque addon est autonome et embarque sa copie ; elles ne doivent pas diverger |
| aucun UID Godot en double entre les deux addons | deux addons dans un même projet se marcheraient dessus |
| un `.uid` pour chaque `.gd`, et aucun `.uid` orphelin | Godot 4.4+ les attend dans le dépôt |
| noms de `plugin.cfg` distincts | deux entrées distinctes dans la liste des plugins |
| serveur MCP compilé | le livrable Godot MCP en a besoin |

## Tester l'intégration

`test_project/` active les deux addons via deux jonctions (non versionnées). Après un clone :

```powershell
New-Item -ItemType Junction -Path test_project\addons\mcf_todo   -Target ..\MCF-Todo\addons\mcf_todo
New-Item -ItemType Junction -Path test_project\addons\godot_mcp -Target ..\Godot-MCP\addons\godot_mcp
```

```bash
# Terminal 1 : éditeur headless avec les deux plugins
godot --headless --editor --path test_project
# Terminal 2 : le même test de bout en bout que Godot MCP, avec les outils todo_* pour de vrai
cd ../Godot-MCP/server
E2E_PROJECT=../../Bundle-Todo-MCP/test_project E2E_EXPECT_TODO=1 GODOT_PATH=... npm run test:e2e
```

Les tests de chaque addon seul se lancent dans leur propre dossier (`MCF-Todo/test_project`, `Godot-MCP/test_project`).
