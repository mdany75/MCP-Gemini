---
description: Demander quelque chose à Gemini par le connecteur MCP-Gemini
argument-hint: <ta question pour Gemini>
allowed-tools: mcp__gemini__ask_gemini, mcp__gemini__gemini_status, mcp__gemini__reset_gemini_session
---

Délègue la demande suivante à Gemini avec l'outil `ask_gemini` du serveur MCP « gemini » :

$ARGUMENTS

Règles :
- Si la demande est vide, appelle `gemini_status` et affiche son résultat.
- Transmets la demande de l'utilisateur telle quelle, complétée seulement du contexte utile (Gemini ne voit pas cette conversation).
- Si l'utilisateur pose une question de suivi sur le même sujet, repasse le `session_id` reçu ; s'il change de sujet, ouvre une nouvelle session.
- Réponds en français : donne la réponse de Gemini fidèlement, en gardant ses sources (adresses), sans l'enrichir de ton propre savoir. Si tu doutes d'un fait important, dis-le.
- Si l'outil renvoie une erreur (connexion, délai, limite), explique-la simplement et indique quoi faire.
