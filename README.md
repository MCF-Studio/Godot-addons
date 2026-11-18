# Godot addons — MCF Studio

Addons et outils Godot 4 de MCF Studio. **Un dossier par addon, une doc par addon** : le `README.md` de l'addon explique ce qu'il fait, comment l'installer et le tester.

| Addon | Dossier | Doc |
|---|---|---|
| Godot MCP — pilotage de Godot par Claude (serveur MCP), chat Claude dans l'éditeur et analyse GDScript (LSP de Godot) | [`Godot-MCP/`](Godot-MCP/) | [`Godot-MCP/README.md`](Godot-MCP/README.md) |
| MCF Todo — liste de tâches dans l'éditeur (dock déplaçable, textes longs, annulation, copie en Markdown pour une IA) ; fonctionne seul | [`MCF-Todo/`](MCF-Todo/) | [`MCF-Todo/README.md`](MCF-Todo/README.md) |
| MCF Coop — parties multijoueurs hébergées (hôte autoritaire ENet, lobby + écran, serveur dédié, codec borné) pour coop / mini-jeux | [`MCF-Coop/`](MCF-Coop/) | [`MCF-Coop/README.md`](MCF-Coop/README.md) |
| StreamingTribeAPI — seul le lanceur MCF Studio peut démarrer le jeu (jeton vérifié, sinon fermeture) | [`StreamingTribeAPI/`](StreamingTribeAPI/) | [`StreamingTribeAPI/README.md`](StreamingTribeAPI/README.md) |

## Bundle

**[`Bundle-Todo-MCP/`](Bundle-Todo-MCP/)** assemble MCF Todo et Godot MCP en un seul livrable, reliés entre eux (Claude lit et coche la todo). Il ne contient aucun code d'addon : chaque addon reste disponible séparément. [`Bundle-Todo-MCP/README.md`](Bundle-Todo-MCP/README.md) explique l'installation et la fabrication des livrables.

## Ajouter un addon

1. Mettre l'addon dans son propre dossier, avec un `README.md` (rôle, installation, utilisation).
2. Ajouter une ligne au tableau ci-dessus.
