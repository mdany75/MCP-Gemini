---
description: Demander quelque chose à Gemini (modèle et effort facultatifs) par le connecteur MCP-Gemini
argument-hint: [modèle] [effort] <question>   (modèles : argon, flash, opus, sonnet, gpt — efforts : low, medium, high)
allowed-tools: mcp__gemini__ask_gemini, mcp__gemini__gemini_result, mcp__gemini__gemini_status, mcp__gemini__reset_gemini_session
---

Délègue la demande suivante à Gemini avec l'outil `ask_gemini` du serveur MCP « gemini » :

$ARGUMENTS

Lecture des arguments, dans cet ordre :
1. Si le premier mot est un nom de modèle (`argon`, `flash`, `opus`, `sonnet`, `gpt`, ou un identifiant complet comme `gemini-3.8-flash-high`), c'est le paramètre `model` ; retire-le de la question.
2. Si le mot suivant (ou le premier, quand il n'y a pas de modèle) est `low`, `medium` ou `high`, c'est le paramètre `effort` ; retire-le de la question.
3. Le reste est la question. Sans modèle ni effort, ne passe ni `model` ni `effort` : le serveur applique ses valeurs par défaut.

Exemples : `/gemini flash high météo demain à Québec` · `/gemini argon low résume cette vidéo https://…` · `/gemini high compare ces deux options` · `/gemini quelle heure est-il à Tokyo ?`

Règles :
- Si la demande est vide, appelle `gemini_status` et affiche son résultat.
- Transmets la question de l'utilisateur telle quelle, complétée seulement du contexte utile (Gemini ne voit pas cette conversation).
- Si l'utilisateur pose une question de suivi sur le même sujet, repasse le `session_id` reçu ; s'il change de sujet, ouvre une nouvelle session.
- Si `ask_gemini` répond que Gemini travaille encore (avec un `job_id`), rappelle `gemini_result` jusqu'à la réponse : ce n'est pas une erreur.
- Réponds en français : donne la réponse de Gemini fidèlement, en gardant ses sources (adresses), sans l'enrichir de ton propre savoir. Si tu doutes d'un fait important, dis-le.
- Si l'outil renvoie une erreur (connexion, délai, limite), explique-la simplement et indique quoi faire.
