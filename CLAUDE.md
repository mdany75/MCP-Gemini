# CLAUDE.md — MCP Gemini

Serveur MCP natif (Swift, SwiftPM, sans dépendance) qui enveloppe la ligne de commande Gemini du Mac (Antigravity CLI `agy`, ou gemini-cli) pour que Claude délègue des demandes à Gemini sans API payante. Six outils : `ask_gemini`, `youtube_transcript`, `gemini_result`, `cancel_gemini`, `gemini_status`, `reset_gemini_session`. Le README décrit les fonctions du point de vue de l'utilisateur.

Ce projet suit le standard commun des projets de Dany (`/standard-projet` le vérifie).

## Commandes

| Action | Commande |
| --- | --- |
| Construire | `swift build -c release` |
| Tester | `swift test` |
| Essayer à la main | `swift build && ./.build/debug/mcp-gemini --status` (ou `--test` pour un appel réel) |
| Installer et inscrire dans Claude | `.build/release/mcp-gemini --install` (copie signée dans `~/Library/Application Support/MCP Gemini/`, inscription dans Claude Desktop et Claude Code, commande `/gemini`) |

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
- Le programme est toujours lancé avec un tableau d'arguments (jamais par un shell), stdin fermé, dans `~/Library/Application Support/MCP Gemini/workspace` (dossier vide), en mode `plan` (imposé, quel que soit le réglage `mode`), avec un environnement réduit (`Locator.environment`) et un TMPDIR privé : ne pas assouplir.
- `--mode plan` n'est qu'une consigne pour agy : `ReadOnlyGuard` lit son flux (`stream-json`) et arrête la demande si le mode plan ou les autorisations « request-review » manquent, si un outil hors liste démarre, si une écriture sort du dossier de la conversation (`~/.gemini/antigravity-cli/brain/<id>/`) ou si une lecture sort des fichiers joints de la demande. Ne pas élargir ses listes sans essai réel. La consigne fixe `ToolHandler.bridgeRules` (non réglable) ouvre chaque premier message, un rappel chaque suite.
- Les tests n'appellent jamais le vrai `agy` ni Gemini : ils utilisent `FakeAgent` (script shell). Un essai réel passe par `--test`.
- Garde-fous (échanges par session, appels par 10 minutes, délai) : ne pas les retirer, ils évitent les boucles entre les deux IA. Un échange raté ne compte pas dans la limite d'échanges mais compte dans la limite d'appels.
- gemini-cli ne reprend pas une session par identifiant : son historique est rejoué (`composePrompt`). Ne pas stocker son `session_id`.
- Claude Desktop coupe un appel d'outil à environ 60 s : `ask_gemini` lance la demande en arrière-plan (`JobBoard`, tâche détachée, indépendante de l'appel) et rend un `job_id` après `waitSeconds` (40) ; la réponse se récupère par `gemini_result`. Claude Code (`clientInfo.name` = `claude-code`) n'a pas cette coupure : il attend jusqu'à la réponse. Ne jamais lier la vie du processus à l'annulation de la requête MCP : seul `cancel_gemini` (ou `reset_gemini_session`) arrête une demande. Une requête annulée par le client ne reçoit pas de réponse, et son résultat reste récupérable.
- Fichiers joints et `save_to` : les chemins viennent de Claude (donc d'un contenu potentiellement piégé). Types de fichiers en liste blanche, aucun fichier ou dossier caché, aucun écrasement, liens symboliques résolus avant contrôle : ne pas assouplir (`Attachments`, `YouTubeTranscript.validateSavePath`). `yt-dlp` reçoit l'adresse après `--`, jamais par un shell.
- Après avoir recopié l'exécutable dans `~/Library/Application Support/MCP Gemini/`, faire `rm` puis `cp` puis `codesign --force --sign -` : sinon macOS le tue (code 137). `--install` le fait (`ClaudeRegistration.installExecutable`).
- `commands/gemini.md` est embarqué dans `GeminiCommand.swift` (un test vérifie qu'ils sont identiques) : régénérer ce fichier après chaque changement de la commande, et ajouter l'empreinte de la version publiée précédente à `previousHashes`.
- Avant de pousser une fonctionnalité : README et `CHANGELOG.md` à jour, et une nouvelle version si l'exécutable a changé.
- Pousser sur `main` directement.

## Organisation

- `Sources/MCPGeminiKit/` : `MCPServer` (JSON-RPC, annulation, progression), `Tools` (les six outils), `Activity` (lecture du flux `stream-json` d'agy), `ReadOnlyGuard` (garde-fou de la lecture seule), `GeneratedFiles` (images et plans produits par agy), `Attachments` (fichiers joints), `YouTube` (sous-titres), `Jobs` (demandes en arrière-plan), `Backend` (arguments et lecture de la sortie de `agy` / `gemini`, choix du modèle, environnement), `ProcessRunner` (lancement asynchrone, délai, annulation, groupe de processus), `SessionStore` (sessions sur disque et garde-fous), `Settings`, `ClaudeRegistration` (installation), `GeminiCommand` (commande `/gemini` embarquée), `Stdio`.
- `Sources/MCPGemini/main.swift` : point d'entrée et commandes.
- `Tests/MCPGeminiKitTests/` : tests avec un faux programme.
- `commands/` : commande `/gemini` de Claude Code (copiée dans `~/.claude/commands/`).
- `docs/conception.md` : notes de conception.
