# StreamingTribeAPI — verrou « seul le lanceur MCF Studio peut démarrer le jeu »

Addon Godot 4 : au démarrage, le jeu fait vérifier par **Streaming Tribe** le jeton que lui passe le lanceur MCF Studio. **Jeton absent, refusé, compte banni, réponse invalide ou serveur injoignable : le jeu affiche un message puis se ferme.** Quand c'est accepté, le nom de l'utilisateur (et le reste de sa fiche) est disponible dans l'autoload `ST_API`.

But : qu'un acheteur ne puisse pas simplement envoyer le jeu à un tiers. C'est un verrou « lanceur obligatoire », pas une protection inviolable (voir [Limites](#limites)).

Testé avec Godot **4.7.2**.

## Installation (à suivre à la lettre, y compris par une IA)

1. Copier `addons/StreamingTribeAPI/` dans le dossier `addons/` du projet (chemin final : `res://addons/StreamingTribeAPI/main.gd`).
2. Déclarer l'autoload — au choix :
   - activer le plugin **Streaming Tribe API** (Projet > Paramètres du projet > Plugins) : il ajoute l'autoload `ST_API` ;
   - ou écrire dans `project.godot`, section `[autoload]` : `ST_API="*res://addons/StreamingTribeAPI/main.gd"` (nécessaire dans tous les cas pour les exports : le plugin n'existe pas dans le jeu exporté, mais la ligne d'autoload, elle, est lue).
3. **Faire attendre le jeu** : ne rien lancer d'important (menu, chargement de partie) avant `ST_API.authenticated`. Sans cela le menu s'affiche une ou deux secondes avant la fermeture si le jeton est mauvais :
   ```gdscript
   func _ready() -> void:
       if not ST_API.authenticated:
           $LoadingLabel.text = "Vérification de votre licence…"   # évite de faire croire à un plantage
           await ST_API.auth_finished                              # un refus ferme le jeu : on ne revient pas
       start_menu()
   ```
4. Le **lanceur** doit démarrer le jeu avec `--token=<jeton>` (ou la variable d'environnement `STREAMINGTRIBE_TOKEN`).
5. Vérifier : lancer le test (voir [Tests](#tests)) → `== OK (0 échec(s))`. Puis lancer l'**export** (pas l'éditeur) sans jeton : une alerte « Ce jeu doit être lancé depuis le lanceur MCF Studio » doit s'afficher puis le jeu se ferme.

## API

Autoload `ST_API` :

| Membre | Rôle |
|---|---|
| `authenticated: bool` | vrai quand le jeton est validé |
| `username: String` | nom de l'utilisateur (≤ 40 caractères) |
| `user: Dictionary` | réponse complète de l'API pour l'utilisateur (id, avatar…) |
| `signal auth_finished(ok: bool)` | émis à la fin de la vérification (sur refus, l'alerte est affichée puis le jeu se ferme) |
| `static evaluate_response(code, body_text) -> {ok, message, user}` | interprétation de la réponse de `/api/game/verify` (testable) |

Réglages (constantes de `main.gd`) : `API_BASE_URL` (`https://streamingtribe.fr`), `VERIFY_PATH` (`/api/game/verify`), `REQUEST_TIMEOUT_S` (10 s).

Contrat attendu de l'API : `POST /api/game/verify`, en-tête `Authorization: Bearer <jeton>` ; réponse 200 avec `{"authenticated": true, "canPlay": true, "user": {"username": "…"}}`. Refus : `{"error": "banned", "banReason": "…"}` ou `{"message": "…"}`. **Tout ce qui n'est pas un « oui » explicite (booléens vrais) est un refus.**

## Exceptions (voulues)

- **Éditeur Godot** (`OS.has_feature("editor")`) : pas de vérification, identité « User Debug » (sinon impossible de développer ni de lancer les tests). Un export, même en debug, exige le jeton.
- **Serveur dédié** (feature `dedicated_server` ou argument `--server`) : pas de vérification, identité « Serveur » (il ne joue pas, il est lancé sans lanceur). **À retirer si le serveur dédié doit aussi être réservé au lanceur.**

## Limites

- Quelqu'un qui modifie l'exécutable ou le `.pck` peut retirer le verrou : il décourage le partage simple, il ne l'empêche pas.
- Le jeton est lu dans la ligne de commande (visible dans le gestionnaire de tâches) : pour durcir, le lanceur peut passer le jeton par la variable d'environnement du seul processus fils.
- Pour aller plus loin (côté serveur / lanceur) : jeton à usage unique et de courte durée lié à la machine, re-vérification périodique, refus d'une seconde session simultanée, chiffrement du `.pck`. À traiter avec le site, pas dans cet addon.
- Cet addon ne contient **plus** de serveur de webhooks TikTok / TikFinity (retiré : les jeux concernés ne sont pas interactifs).

## Tests

```
cd test_project
mklink /J addons\StreamingTribeAPI ..\addons\StreamingTribeAPI     (une seule fois, cmd Windows ; ou New-Item -ItemType Junction en PowerShell)
Godot --headless --import --path .
Godot --headless --audio-driver Dummy --path . res://tests/TestStreamingApi.tscn
```
Vérifie l'interprétation de la réponse (réponse valide ; `canPlay` faux, non authentifié, sans utilisateur, valeurs non booléennes, corps illisible ou vide, mauvais code, tableau, bannissement avec raison, message du serveur) et l'identité de développement dans l'éditeur. Le test ne contacte pas streamingtribe.fr.

## Contenu

```
addons/StreamingTribeAPI/
  main.gd        autoload ST_API (vérification du jeton, fermeture du jeu en cas de refus)
  plugin.cfg/.gd plugin d'éditeur : ajoute l'autoload
test_project/    projet de test (jonction addons/StreamingTribeAPI → ../addons/StreamingTribeAPI)
```
