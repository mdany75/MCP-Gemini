# Journal des versions

## 0.8 — 2026-10-24

- Claude consulte Gemini de lui-même, sans attendre qu'on le lui demande, quand Gemini apporte ce qu'il n'a pas : générer une image, analyser une vidéo YouTube, une information locale ou récente, un deuxième avis sur un fait important, un document trop long. Pour le raisonnement, le code et la rédaction, il répond seul. Il dit chaque fois qu'il a consulté Gemini et pourquoi. La règle est la même dans les instructions du serveur et la description d'`ask_gemini`.

## 0.7 — 2026-10-24

Six améliorations tirées de la comparaison entre les suggestions de Claude et celles de Gemini.

- Claude Code reconnu sous ses différents noms (« claude-code », « Claude Code »…) : il attend la réponse au lieu de recevoir un `job_id` après 40 s. Le serveur écrit dans son journal le nom de chaque client.
- Sous-agent d'images : son rôle, libellé libre, n'est plus jamais pris pour son type. Annoncé sans type, il est vérifié dans le fichier qu'agy écrit pour lui (`subagentDescriptor.typeName`), à chaque événement et à la fin.
- Après un arrêt par le garde-fou, la session oublie la conversation d'agy qui contient l'action interdite : la suite rejoue l'historique dans une nouvelle conversation.
- Fichiers de code source acceptés en pièce jointe (swift, py, js, ts, html, css, sql, yaml…), contrôlés comme le texte.
- Note d'approbation d'un plan : en lecture seule, un plan ne peut aboutir qu'à des recherches, une analyse, un document ou une image.
- Secrets cherchés aussi dans le texte et les métadonnées des PDF et dans les métadonnées des images ; un PDF protégé par mot de passe est refusé.

## 0.6 — 2026-10-24

- Choix automatique du modèle et de l'effort : avec `/gemini <question>`, Claude analyse la question et passe toujours `model` et `effort` (flash + low pour un fait simple, flash + medium pour une petite synthèse, argon + medium pour une recherche approfondie ou un long document, argon + high pour un raisonnement difficile). Plus de valeurs par défaut du serveur ; un modèle ou un effort tapé par l'utilisateur l'emporte toujours.
- Même règle dans les instructions du serveur et la description d'`ask_gemini`, pour Claude Desktop.

## 0.5 — 2026-10-24

Travailler avec Gemini depuis Claude comme dans agy.

- Suivi en direct : agy tourne en sortie continue (`stream-json`). La progression montre chaque recherche et chaque page lue. Le message « Gemini travaille encore » dit ce qui est fait. Le pied de chaque réponse donne le modèle réel, la durée, les jetons, la démarche et les actions refusées.
- Images générées par Gemini renvoyées à Claude en contenu image ; plans à approuver montrés à Claude (12 000 caractères au plus), avec la marche à suivre pour les valider.
- `ask_gemini` accepte `youtube_url` : la transcription complète de la vidéo est jointe en fichier, sans passer par Claude.
- `youtube_transcript` prévient en tête quand le texte est coupé.
- Nouvel outil `cancel_gemini` (comme Échap dans agy) ; `reset_gemini_session` arrête aussi la demande en cours.
- Sessions gardées sur le disque : elles survivent au redémarrage de Claude. `session_id` = `last` reprend la plus récente. `gemini_status` donne la commande `agy --conversation …` de chacune.
- Claude Code attend la réponse en un seul appel (seul Claude Desktop coupe à 60 s).
- Une réponse n'est plus perdue quand un appel est annulé, et une requête annulée ne reçoit plus de réponse.
- Conversation d'agy introuvable : relance automatique avec l'historique rejoué.
- `/gemini` : mots `suite`, `nouveau`, `ok`, `stop`, `état`, `image`, et affichage de la réponse telle que la donne Gemini.
- Sécurité :
  - le mode plan est imposé : le réglage `mode` est ignoré, et `accept-edits` / `auto` ne sont plus acceptés ;
  - un garde-fou lit le flux d'agy et arrête toute action hors de la lecture seule ;
  - consigne fixe du pont, en plus du préambule réglable ;
  - environnement réduit et dossier temporaire privé pour agy ;
  - yt-dlp sans fichiers de configuration, sous-titres téléchargés sans cache disque ;
  - fichiers joints : secrets repérés dans le chemin (en français aussi) et dans le contenu, /var/folders refusé ;
  - copies de sécurité des configurations de Claude rangées à part ;
  - dossier de conversation d'agy lisible par l'utilisateur seul.
- `--install` copie l'exécutable à un emplacement stable et signé, l'inscrit dans Claude Desktop et Claude Code, et installe `/gemini`.
- Corrections :
  - `--test` ne passait pas le nom court du modèle (`flash`) ;
  - `waitSeconds` n'était pas lu ;
  - un effort demandé était ignoré avec un modèle des réglages qui porte déjà un niveau ;
  - `--backend` réécrivait tout le fichier de réglages ;
  - le serveur plantait quand Claude fermait le tube ;
  - les petits-enfants d'agy n'étaient pas arrêtés ;
  - un programme sorti à temps était parfois noté hors délai ;
  - la sortie tronquée gardait des trous ;
  - les sous-titres en CRLF étaient vides ;
  - la transcription sans repères tenait en un seul paragraphe ;
  - l'historique rejoué perdait le premier échange.

## 0.4 — 2026-10-24

- Fichiers joints : `ask_gemini` accepte `files` (images, PDF, texte) ; liste blanche de dossiers (Bureau, Documents, Téléchargements, Images), noms sensibles et fichiers cachés refusés, copies temporaires effacées.
- Nouvel outil `youtube_transcript` : sous-titres d'une vidéo YouTube avec repères de temps, enregistrables dans un fichier .txt (`save_to`).

## 0.3 — 2026-10-23

- `/gemini [modèle] [effort] question` : choix du modèle (`argon`, `flash`, `opus`, `sonnet`, `gpt` ou identifiant complet) et de l'effort (`low`, `medium`, `high`) ; sans eux, les valeurs par défaut des réglages. `ask_gemini` accepte les paramètres `model` et `effort`.

## 0.2 — 2026-10-23

- Corrige « Request timed out » dans Claude Desktop : une demande qui dépasse 40 s (réglage `waitSeconds`) rend un `job_id` au lieu d'échouer ; Gemini continue en arrière-plan et la réponse se récupère avec le nouvel outil `gemini_result`.
- Une annulation du client n'arrête plus Gemini : la réponse reste récupérable (30 minutes). Trois demandes simultanées au plus.
- Commande `/gemini` pour Claude Code (`commands/gemini.md`).

## 0.1 — 2026-10-23

- Première version : serveur MCP `ask_gemini`, `gemini_status`, `reset_gemini_session`.
- Prend en charge Antigravity CLI (`agy`) et gemini-cli ; sessions avec reprise de conversation.
- Garde-fous : échanges par session, appels par fenêtre de 10 minutes, délai maximal, annulation.
