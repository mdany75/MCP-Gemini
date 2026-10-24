# Journal des versions

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
