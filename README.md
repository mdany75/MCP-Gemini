# MCP Gemini

Pont local entre Claude et Gemini : un serveur MCP natif (Swift, sans API payante, sans Node) qui permet à Claude Desktop et à Claude Code de déléguer une demande à Gemini par la ligne de commande installée sur le Mac, puis de rédiger la réponse finale avec ce que Gemini a trouvé. Le but : travailler avec Gemini depuis Claude comme on le ferait dans agy.

## Fonctions

- `ask_gemini` : Claude envoie une demande à Gemini (recherche Google en temps réel avec sources, analyse de fichiers, génération d'images, très gros volumes de texte) et reçoit sa réponse brute.
- Comme dans agy, on voit ce que fait Gemini :
  - pendant la demande, la progression affiche chaque recherche et chaque page lue (Claude Code) ;
  - le message « Gemini travaille encore » dit ce qui est déjà fait ;
  - le pied de chaque réponse donne le modèle qui a vraiment répondu, la durée, les jetons, la démarche (recherches, pages lues) et les actions refusées.
- Images : une demande d'image (« Génère une image : … ») renvoie l'image elle-même à Claude, qui la voit et l'affiche. Le fichier reste dans le dossier de la conversation d'agy (`~/.gemini/antigravity-cli/brain/…`).
- Plans : si Gemini rédige un plan à approuver, Claude le reçoit (jusqu'à 12 000 caractères, avec le chemin du fichier) et peut le valider (« Plan approuvé : exécute-le. ») avec l'accord de l'utilisateur, comme le bouton « Proceed » d'agy. Si le plan fait exactement ce que l'utilisateur a demandé (par exemple générer l'image demandée), sa demande vaut accord. En lecture seule, un plan ne peut aboutir qu'à des recherches, une analyse, un document ou une image.
- Fichiers joints : `ask_gemini` accepte `files` (5 au plus, 20 Mo chacun) : images (png, jpg, gif, webp, heic), PDF, texte (txt, md, csv, tsv, json, log) et code source (swift, py, js, ts, html, css, sql, yaml…).
  - Dossiers acceptés : Bureau, Documents, Téléchargements, Images, ainsi que /tmp (premier niveau) et les brouillons de Claude Code.
  - Fichiers refusés : les fichiers cachés, ceux dont le chemin évoque un secret (mot de passe, clé, jeton…, en français ou en anglais), ceux qui contiennent une clé privée ou un jeton d'accès (dans le texte, le code, le texte et les métadonnées d'un PDF, ou les métadonnées d'une image) et les PDF protégés par mot de passe.
  - Gemini lit les fichiers dans son dossier de travail ; les copies sont effacées après la demande. Leur contenu est envoyé à Google et reste dans l'historique local d'agy.
- Vidéos YouTube : `ask_gemini` avec `youtube_url` joint la transcription complète de la vidéo (sous-titres publiés, sinon automatiques, par `yt-dlp`) : Gemini analyse toute la vidéo, sans que le texte passe par Claude. `youtube_transcript` donne le texte lui-même (titre, chaîne, durée, repères de temps ; `save_to` l'enregistre en .txt). Aucune vidéo n'est téléchargée.
- Conversations suivies : chaque réponse porte un `session_id` que Claude repasse pour une question de suivi. Les sessions sont gardées sur le disque : elles survivent au redémarrage de Claude et se partagent entre Claude Desktop et Claude Code. `session_id` = `last` reprend la plus récente, comme `agy -c`. `gemini_status` donne pour chacune la commande `agy --conversation …` qui la rouvre dans un terminal.
- `cancel_gemini` : arrête une demande en cours, comme Échap dans agy. Ce qui était déjà fait est rendu, et la conversation reste reprenable.
- Garde-fou contre les boucles : 5 échanges au plus par session et 30 appels par 10 minutes (réglables). Au-delà, Claude doit conclure avec ce qu'il a.
- Aucun blocage : Claude Desktop coupe un appel à 60 s. Au-delà de 40 s, `ask_gemini` rend donc un `job_id`, et Claude récupère la réponse avec `gemini_result`. Claude Code n'a pas cette coupure : il attend la réponse en un seul appel.
- Lecture seule : Gemini travaille dans un dossier vide, en mode « plan » imposé, avec un environnement réduit (aucun jeton de la session de Claude) et un dossier temporaire privé. Comme ce mode n'est qu'une consigne donnée au modèle, le pont surveille aussi tout ce que fait agy. Il arrête la demande si :
  - le mode plan n'est pas appliqué ;
  - un outil interdit démarre (commande, écriture hors du dossier de la conversation, sous-agent autre que celui des images : son type réel est vérifié dans les fichiers d'agy, jamais d'après son seul rôle) ;
  - Gemini veut lire un fichier qui n'a pas été joint, ou ouvrir une adresse qui n'est pas une adresse web.
- Commande `/gemini` dans Claude Code (installée par `--install`) :
  - `/gemini météo demain à Québec` : Claude choisit lui-même le modèle et l'effort d'après la question (flash + low pour un fait simple, jusqu'à argon + high pour un raisonnement difficile) et dit pourquoi ;
  - `/gemini flash high météo demain à Québec` impose le modèle (`argon`, `flash`, `opus`, `sonnet`, `gpt`) et l'effort (`low`, `medium`, `high`) ;
  - `/gemini suite …` pose une question de suivi, `/gemini nouveau …` ouvre une nouvelle conversation ;
  - `/gemini ok` approuve un plan, `/gemini stop` arrête une demande ;
  - `/gemini image …` génère une image, `/gemini état` montre l'état et les modèles disponibles.
- `gemini_status` : programme utilisé, version, modèle réellement passé, demandes en cours, sessions récentes. Avec `test`, il liste aussi les modèles disponibles et vérifie la connexion Google.
- `reset_gemini_session` : efface la mémoire d'une session (et arrête sa demande en cours).
- Deux programmes pris en charge : **Antigravity CLI (`agy`)**, recommandé, et gemini-cli.

## Installer

Configuration requise : macOS 14 ou plus, Xcode (pour compiler), un compte Google, et `yt-dlp` pour les vidéos YouTube (`brew install yt-dlp`).

1. Installer Antigravity CLI et s'y connecter une fois :
   ```bash
   brew install --cask antigravity-cli
   agy
   ```
   (choisir la connexion Google dans le terminal, puis quitter).
2. Compiler et installer le serveur :
   ```bash
   swift build -c release
   .build/release/mcp-gemini --install
   ```
   `--install` copie l'exécutable (signé) dans `~/Library/Application Support/MCP Gemini/`. Il inscrit ce chemin dans Claude Desktop et dans Claude Code, qui lancent ainsi la même version. Il installe aussi la commande `/gemini` dans `~/.claude/commands/`, sans jamais écraser une copie modifiée à la main. Une copie de sécurité de chaque configuration de Claude est rangée dans `~/Library/Application Support/MCP Gemini/backups/` (3 au plus).
3. Redémarrer Claude Desktop (Claude Code le voit à sa prochaine session).
4. Vérifier : `.build/release/mcp-gemini --test`.

Depuis juin 2026, gemini-cli n'accepte plus les comptes Google personnels : avec ce type de compte, utiliser `agy`. `mcp-gemini --backend gemini` bascule vers gemini-cli (clé API ou licence Entreprise).

## Réglages

Fichier `~/Library/Application Support/MCP Gemini/settings.json` (tous les champs sont facultatifs ; relancer Claude après un changement) :

| Champ | Défaut | Rôle |
| --- | --- | --- |
| `backend` | `agy` | `agy` ou `gemini` |
| `executable` | recherche auto | chemin complet du programme |
| `ytDlp` | recherche auto | chemin complet de `yt-dlp` |
| `model` | celui du programme | nom court (`flash`, `argon`…) ou identifiant de `agy models` ; seulement si Claude n'en choisit pas (il le fait d'après la demande) |
| `effort` | celui du programme | `low`, `medium`, `high` (`xhigh`, `max` pour les modèles qui les ont) ; même remarque |
| `mode` | `plan` | imposé : toute autre valeur est ignorée (lecture seule) |
| `waitSeconds` | 40 | attente par appel avant de rendre un `job_id` (au plus 50 ; Claude Code attend la réponse) |
| `timeoutSeconds` | 240 | durée maximale d'une demande (10 à 1800) |
| `maxTurnsPerSession` | 5 | échanges par session (1 à 20) |
| `maxCallsPer10Minutes` | 30 | appels par fenêtre de 10 minutes (1 à 200) |
| `preamble` | consigne de style | texte ajouté au premier message (la consigne de lecture seule du pont, elle, n'est pas réglable) |

Un réglage ignoré (mode, modèle mal formé, effort inconnu) est signalé par `gemini_status`.

## Limites

- 3 demandes à Gemini en même temps au plus.
- Une demande fait au plus 100 000 caractères : au-delà, joindre le texte en fichier.
- Une réponse renvoyée à Claude est coupée à 45 000 caractères.
- Avec gemini-cli, l'historique de la session est rejoué à chaque échange : la première demande et les échanges les plus récents sont gardés, dans une limite d'environ 60 000 caractères.
- Les sessions inutilisées depuis 7 jours sont effacées.
- Une réponse non récupérée est oubliée au bout de 30 minutes, et une réponse remise au bout de 10 minutes.

## Reconstruire

Outils : Xcode (Swift 6). `swift build -c release` produit `.build/release/mcp-gemini`. `swift test` lance les tests, qui utilisent un faux programme et n'appellent jamais Gemini.

## Organisation

- `Sources/MCPGeminiKit/` : le serveur (protocole MCP, lancement des processus, lecture du flux d'agy et garde-fou, sessions, outils, réglages).
- `Sources/MCPGemini/` : le point d'entrée (`--install`, `--status`, `--test`…).
- `Tests/` : tests unitaires avec un faux `agy`.
- `commands/` : la commande `/gemini` de Claude Code.
- `docs/conception.md` : notes de conception.
