# Notes de conception

## Une demande, de bout en bout

1. `ask_gemini` lance la demande dans une tâche détachée (`JobBoard`), indépendante de l'appel d'outil.
   - Claude Desktop coupe un appel à 60 s : le serveur attend `waitSeconds` (40 s), puis rend un `job_id` que Claude réclame par `gemini_result`.
   - Claude Code (`clientInfo.name` = `claude-code`) n'a pas cette coupure : il attend jusqu'à la réponse.
   - Une annulation MCP n'arrête jamais Gemini : seul `cancel_gemini` le fait.
2. Avant d'ouvrir l'échange, le serveur vérifie le modèle et l'effort (`ModelCatalog.choose`), les fichiers joints (`Attachments`) et la transcription YouTube (`youtube_url`). Un refus à cette étape ne consomme rien.
3. agy est lancé :
   - avec un tableau d'arguments, stdin fermé ;
   - dans un dossier de travail vide ;
   - avec un environnement réduit et un TMPDIR privé ;
   - avec `--mode plan --output-format stream-json`.
4. Le flux NDJSON est lu au fil de l'eau :
   - `ActivityLog` retient les étapes (recherches, pages lues), le texte partiel, le modèle et la conversation ;
   - `ReadOnlyGuard` peut arrêter la demande ;
   - les notifications de progression lisent `ActivityLog`.
5. À la fin, `Backend.parse` lit l'événement `result` : réponse, durée, jetons, actions refusées. Si le délai d'agy est tombé, c'est une réponse partielle.
6. `GeneratedFiles` récupère ce qu'agy a rangé dans `~/.gemini/antigravity-cli/brain/<conversation>/` pendant la demande :
   - les images sont réencodées et renvoyées en contenu image MCP ;
   - les documents (plans) sont ajoutés au texte.

## Pourquoi un garde-fou en plus du mode plan

Avec `--mode plan`, agy ajoute seulement la commande `/plan` au message : c'est une consigne pour le modèle, pas une barrière. Un « plan approuvé » dans un message de suivi le fait passer à l'action. Sans terminal, agy refuse d'office les actions qui demandent un accord (`denied_actions`). Mais ses réglages persistants (`~/.gemini/antigravity-cli/settings.json`) peuvent lever ces demandes d'accord.

Le pont ajoute donc trois protections :

- une consigne fixe (`bridgeRules`) en tête du premier message, et un rappel en tête de chaque suite ;
- au démarrage, l'exigence du mode plan et des autorisations `request-review` (événement `init`) ;
- pendant la demande, une liste d'outils permis :
  - recherche, lecture et attente ;
  - écriture seulement dans le dossier de la conversation ;
  - lecture seulement des fichiers joints à cette demande ;
  - le seul sous-agent `image-generator`, reconnu par son type. Le rôle est un libellé libre, jamais une preuve : un sous-agent annoncé sans type est vérifié dans le fichier qu'agy écrit pour lui (`.system_generated/subagents/<id>.json`, `subagentDescriptor.typeName`), à chaque événement et à la fin ;
  - `schedule` seulement pour attendre ce sous-agent : délai de 10 minutes au plus, sans autre paramètre.

L'arrêt arrive au début d'une étape interdite : il limite les dégâts, il ne remplace pas le refus d'agy.

Limite connue : les étapes du sous-agent `image-generator` n'apparaissent pas dans le flux. Le garde-fou contrôle les appels visibles (`generate_image` est traité comme une lecture : ses images de référence doivent être des fichiers joints). La consigne fixe demande au sous-agent la même chose, et le refus d'agy reste la dernière barrière.

## Sessions

Une session du pont (6 caractères hexadécimaux) correspond à une conversation d'agy (`--conversation`).

- Elle est gardée en mémoire et dans `sessions/<id>.json` (0600). Le nombre d'échanges est conservé, donc la limite tient après un redémarrage.
- Si agy a perdu la conversation, la tentative est arrêtée dès l'événement `init`, puis relancée une fois avec l'historique rejoué.
- Après un arrêt par le garde-fou, la session oublie sa conversation d'agy (qui contient l'action interdite) : la suite rejoue l'historique dans une nouvelle conversation.
- Avec gemini-cli, l'historique est toujours rejoué : il ne reprend pas une session par identifiant.
