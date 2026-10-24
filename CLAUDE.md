# CLAUDE.md — MCP Gemini

Serveur MCP natif (Swift, SwiftPM, sans dépendance) qui enveloppe la ligne de commande Gemini du Mac (Antigravity CLI `agy`, ou gemini-cli) pour que Claude délègue des demandes à Gemini sans API payante. Trois outils : `ask_gemini`, `gemini_status`, `reset_gemini_session`. Le README décrit les fonctions du point de vue de l'utilisateur.

Ce projet suit le standard commun des projets de Dany (`/standard-projet` le vérifie).

## Commandes

| Action | Commande |
| --- | --- |
| Construire | `swift build -c release` |
| Tester | `swift test` |
| Essayer à la main | `swift build && ./.build/debug/mcp-gemini --status` (ou `--test` pour un appel réel) |
| Inscrire dans Claude | `.build/release/mcp-gemini --install` |

Les fichiers produits vont dans `.build/`, ignoré par git. Rien de compilé n'est commité.

## Publier une version

Dans cet ordre :

1. Mettre `ServerInfo.version` à jour (`Sources/MCPGeminiKit/ServerInfo.swift`) et ajouter la section `## X.Y — date` dans `CHANGELOG.md`.
2. `git add -A && git commit -m "Version X.Y" && git push origin main`
3. `git tag -a vX.Y -m "Version X.Y" && git push origin vX.Y`
4. `gh release create vX.Y --title "MCP Gemini X.Y" --notes "$(~/.claude/skills/standard-projet/scripts/notes-version.sh X.Y)"`

Pas de pièce jointe tant qu'il n'y a pas de `build.sh` signé et notarisé.

## Règles

- Répondre et écrire (commits, README, textes des outils et des erreurs) en français.
- `stdout` est réservé au protocole JSON-RPC : les journaux vont sur `stderr`.
- Le programme est toujours lancé avec un tableau d'arguments (jamais par un shell), stdin fermé, dans `~/Library/Application Support/MCP Gemini/workspace` (dossier vide), en mode `plan` : ne pas assouplir.
- Les tests n'appellent jamais le vrai `agy` ni Gemini : ils utilisent `FakeAgent` (script shell). Un essai réel passe par `--test`.
- Garde-fous (échanges par session, appels par 10 minutes, délai) : ne pas les retirer, ils évitent les boucles entre les deux IA. Un échange raté ne compte pas dans la limite d'échanges mais compte dans la limite d'appels.
- gemini-cli ne reprend pas une session par identifiant : son historique est rejoué (`composePrompt`). Ne pas stocker son `session_id`.
- Claude Desktop coupe un appel d'outil à environ 60 s (Claude Code non) : garder les signes de vie (`notifications/progress`) et le réglage `effort`.
- Avant de pousser une fonctionnalité : README et `CHANGELOG.md` à jour, et une nouvelle version si l'exécutable a changé.
- Pousser sur `main` directement.

## Organisation

- `Sources/MCPGeminiKit/` : `MCPServer` (JSON-RPC, annulation, progression), `Tools` (les trois outils), `Backend` (arguments et lecture de la sortie de `agy` / `gemini`, recherche du programme), `ProcessRunner` (lancement asynchrone, délai, annulation), `SessionStore` (mémoire et garde-fous), `Settings`, `ClaudeRegistration`.
- `Sources/MCPGemini/main.swift` : point d'entrée et commandes.
- `Tests/MCPGeminiKitTests/` : tests avec un faux programme.
- `docs/` : notes de conception.
