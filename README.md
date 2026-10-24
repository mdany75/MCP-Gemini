# MCP Gemini

Pont local entre Claude et Gemini : un serveur MCP natif (Swift, sans API payante, sans Node) qui permet à Claude Desktop et à Claude Code de déléguer une demande à Gemini par la ligne de commande installée sur le Mac, puis de rédiger la réponse finale avec ce que Gemini a trouvé.

## Fonctions

- `ask_gemini` : Claude envoie une demande à Gemini (recherche web ou Google Maps en temps réel, analyse d'une chaîne ou d'une vidéo YouTube, très gros volumes de texte) et reçoit la réponse brute.
- Conversations suivies : chaque réponse porte un `session_id` ; Claude le repasse pour une question de suivi et Gemini se souvient de l'échange.
- Garde-fou contre les boucles : 5 échanges au plus par session et 30 appels par 10 minutes (réglables) ; au-delà, Claude doit conclure avec ce qu'il a.
- Aucun blocage : les appels longs tournent en arrière-plan, avec signes de vie réguliers et annulation prise en charge.
- Lecture seule : Gemini travaille dans un dossier de travail vide, en mode « plan » (il ne peut ni modifier de fichier ni lancer de commande). Il tourne avec ton compte : ce mode, pas le dossier, est la protection.
- Commande `/gemini <question>` dans Claude Code : pose directement une question à Gemini (fichier `commands/gemini.md`, à copier dans `~/.claude/commands/`).
- `gemini_result` : récupère la réponse d'une recherche longue. Au-delà de 40 s, `ask_gemini` rend un `job_id` au lieu d'échouer (Claude Desktop coupe les appels à 60 s) ; Gemini continue en arrière-plan.
- `gemini_status` : programme utilisé, version, réglages, et test de la connexion Google.
- `reset_gemini_session` : efface la mémoire d'une session.
- Deux programmes pris en charge : **Antigravity CLI (`agy`)**, recommandé, et gemini-cli.

## Installer

Configuration requise : macOS 14 ou plus, Xcode (pour compiler), un compte Google.

1. Installer Antigravity CLI et s'y connecter une fois :
   ```bash
   brew install --cask antigravity-cli
   agy
   ```
   (choisir la connexion Google dans le terminal, puis quitter).
2. Compiler et inscrire le serveur dans Claude :
   ```bash
   swift build -c release
   .build/release/mcp-gemini --install
   ```
3. Redémarrer Claude Desktop (Claude Code le voit à sa prochaine session).
4. Vérifier : `.build/release/mcp-gemini --test`.

Depuis juin 2026, gemini-cli n'accepte plus les comptes Google personnels : avec ce type de compte, utiliser `agy`. `mcp-gemini --backend gemini` bascule vers gemini-cli (clé API ou licence Entreprise).

Délai : Claude Desktop coupe un appel d'outil au bout d'environ 60 s. Une recherche web de Gemini dure souvent plus longtemps : après 40 s, le serveur répond « Gemini travaille encore » avec un `job_id`, et Claude récupère la réponse avec `gemini_result`.

## Réglages

Fichier `~/Library/Application Support/MCP Gemini/settings.json` (tous les champs sont facultatifs) :

| Champ | Défaut | Rôle |
| --- | --- | --- |
| `backend` | `agy` | `agy` ou `gemini` |
| `executable` | recherche auto | chemin complet du programme |
| `model` | celui du programme | voir `agy models` |
| `mode` | `plan` | `plan` (lecture seule), `accept-edits`, `auto` |
| `effort` | celui du programme | `low`, `medium`, `high` |
| `waitSeconds` | 40 | attente par appel avant de rendre un `job_id` (au plus 50) |
| `timeoutSeconds` | 240 | durée maximale d'une demande |
| `maxTurnsPerSession` | 5 | échanges par session |
| `maxCallsPer10Minutes` | 30 | appels par fenêtre de 10 minutes |
| `preamble` | consigne de délégation | texte ajouté au premier message |

## Reconstruire

Outils : Xcode (Swift 6). `swift build -c release` produit `.build/release/mcp-gemini`. `swift test` lance les 66 tests, qui utilisent un faux programme et n'appellent jamais Gemini.

## Organisation

- `Sources/MCPGeminiKit/` : le serveur (protocole MCP, lancement des processus, sessions, outils, réglages).
- `Sources/MCPGemini/` : le point d'entrée (`--install`, `--status`, `--test`…).
- `Tests/` : tests unitaires avec un faux `agy`.
- `docs/` : notes de conception.
