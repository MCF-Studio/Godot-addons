# MCF Todo — liste de tâches dans l'éditeur Godot

Addon Godot 4 : un dock **Todo** pensé pour rester ouvert pendant qu'on travaille. Ajout en une frappe, édition sur place, suppression avec annulation, glisser-déposer, textes longs lisibles. Il fonctionne **seul**, sans rien d'autre.

Testé avec Godot **4.5.1**, **4.6.2** et **4.7.2**. Avec Godot 4.6+ le dock est un vrai dock Godot (déplaçable, flottant) ; avant, il utilise l'ancienne API de docks.

Il s'associe, sans en dépendre, à l'addon [Godot MCP](../Godot-MCP/) : Claude peut alors lire et cocher la liste, et chaque tâche gagne « Demander à Claude » (voir [Avec Godot MCP](#avec-godot-mcp)). Les deux s'installent séparément ou ensemble (voir le [bundle](../Bundle-Todo-MCP/)).

## Installation

1. Copier `addons/mcf_todo/` dans le dossier `addons/` du projet (chemin final : `res://addons/mcf_todo/plugin.cfg`).
2. *Projet > Paramètres du projet > Plugins* : activer **MCF Todo**.
3. Le dock **Todo** apparaît en bas à gauche. Glisse son onglet pour le mettre ailleurs, ou passe-le en fenêtre flottante : Godot retient la position d'une session à l'autre. Il se rouvre depuis le menu *Éditeur*.

## Utilisation

| Action | Comment |
|---|---|
| Ajouter | Zone de saisie en bas : `Entrée` ajoute, `Maj+Entrée` passe à la ligne. La liste défile sur la nouvelle tâche. |
| Modifier | Double-clic, `F2` ou `Entrée` sur une tâche. `Entrée` valide, `Échap` annule, perdre le focus valide. |
| Supprimer | Bouton ✕ ou touche `Suppr`. Une barre « Annuler » reste quelques secondes : pas de confirmation à valider. |
| Cocher | La case, ou `Espace`. |
| « En cours » | Clic droit > *Marquer « en cours »* : la tâche reçoit un ▶ et un liseré. |
| Réordonner | Glisser la poignée `⋮⋮`. Un trait indique où la tâche va atterrir. |
| Naviguer | `↑` / `↓` entre les tâches. |
| Filtrer | *Toutes* / *À faire* / *Faites* ; compteur « faites/total » ; bouton pour vider les tâches faites (annulable). |

**Textes longs** : le texte passe à la ligne selon la largeur du dock, sans défilement horizontal (même une URL de 300 caractères). Au-delà de 6 lignes, la tâche est repliée avec « Afficher tout (+N lignes) ». Les URL `http(s)://…` et les chemins `res://dossier/fichier.gd:12` sont cliquables (ouvrent le navigateur, la scène ou le script à la bonne ligne).

## Données

La liste est enregistrée dans **`res://.mcf_todo/todo.json`**. Le dossier est caché : Godot ne l'importe pas, et il se versionne avec le projet (ou s'ajoute au `.gitignore` pour une liste personnelle).

```json
{ "version": 1, "items": [
  { "id": "t4mzs0", "text": "Corriger le saut", "status": "doing", "created": 1794270000, "updated": 1794270500 }
] }
```

`status` vaut `open`, `doing` ou `done`. Le dock suit les modifications faites à la main dans le fichier (vérifiées chaque seconde) sans casser une édition en cours. Écriture atomique (fichier temporaire puis renommage). Si le JSON est illisible, il n'est **jamais écrasé** : une copie `todo.json.bak-<date>` est conservée et le dock affiche un avertissement.

## Avec Godot MCP

Quand l'addon [Godot MCP](../Godot-MCP/) est actif dans le même projet :
- les tools MCP `todo_list`, `todo_add`, `todo_update`, `todo_remove` agissent sur cette liste (le dock se met à jour en direct) ;
- le menu contextuel d'une tâche propose **Demander à Claude**.

Rien à configurer. Sans Godot MCP, ces entrées n'existent pas et le dock fonctionne à l'identique.

## Brancher un autre addon

Aucun import de code entre addons : le contrat tient en deux métadonnées d'`Engine`, lues au moment de l'action (l'ordre d'activation des plugins n'a pas d'importance).

| Métadonnée | Contenu |
|---|---|
| `Engine.get_meta("mcf_todo_store", null)` | Le `TodoStore` (`todo_store.gd`) tant que l'addon est actif, sinon `null`. |
| `Engine.get_meta("mcf_todo_actions", [])` | Tableau de `{"label": String, "callable": Callable}` : chaque entrée valide s'ajoute au menu contextuel d'une tâche ; le `Callable` reçoit la tâche (`Dictionary` : `id`, `text`, `status`, `created`, `updated`). |

Ajouter une entrée de menu depuis un autre plugin :

```gdscript
var actions: Array = Engine.get_meta("mcf_todo_actions", [])
actions.append({"label": "Envoyer au tracker", "callable": func(task): print(task["text"])})
Engine.set_meta("mcf_todo_actions", actions)
# à la désactivation du plugin : retirer son entrée de la liste
```

API du `TodoStore` : `items`, `find_index(id)`, `get_item(id)`, `counts()`, `add(text, status, index, source)`, `update(id, {text, status}, source)`, `move(id, to_index, source)`, `remove(ids, source)`, `clear_done(source)`, `undo_remove(source)`, `flush()` ; signaux `changed(source)` (`"ui"`, `"mcp"` ou `"external"`) et `warning(message)`. Après une modification, appeler `flush()` pour écrire tout de suite (sinon l'écriture est différée d'environ 300 ms).

## Tests

`test_project/` est un petit projet Godot qui pointe vers `addons/mcf_todo` via une jonction non versionnée. Après un clone :

```powershell
New-Item -ItemType Junction -Path test_project\addons\mcf_todo -Target addons\mcf_todo
```

```bash
godot --headless --path test_project -s tests/unit.gd
```

Les tests couvrent le store (ajout, déplacement, suppression et annulation, persistance, reprise après un crash entre écriture et renommage, JSON corrompu, BOM de Notepad, modification externe), l'UI du dock (ajout, case à cocher sans reconstruction des lignes, filtres, glisser-déposer, suppression + annulation, édition sur place, texte long replié, édition protégée contre les changements externes) et les entrées de menu ajoutées par d'autres addons.

## Structure

```
addons/mcf_todo/
  plugin.cfg / plugin.gd   EditorPlugin : crée le store et le dock, publie le contrat ci-dessus
  todo_store.gd            données + fichier (sans interface)
  todo_panel.gd            contenu du dock : liste, filtres, annulation, saisie, menu
  todo_row.gd              une tâche : case, texte replié, édition, suppression, poignée
  dock_host.gd             ajoute le dock (EditorDock 4.6+, ancienne API avant)  — copie partagée
  ui/auto_text_edit.gd     saisie multi-lignes qui grandit (Entrée / Maj+Entrée)  — copie partagée
  ui/text_links.gd         URL et res:// cliquables                               — copie partagée
```

Les trois fichiers « copie partagée » sont **identiques** à ceux de `Godot-MCP/addons/godot_mcp/` (chaque addon reste autonome) ; `Bundle-Todo-MCP/build.mjs` vérifie qu'ils n'ont pas divergé. Modifier un de ces fichiers = le modifier dans les deux addons.
