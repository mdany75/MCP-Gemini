---
description: Demander quelque chose à Gemini par le connecteur MCP-Gemini (modèle et effort choisis d'après la question, ou imposés)
argument-hint: [suite|nouveau|ok|stop|état|image] [modèle] [effort] <question>   (modèles : argon, flash, opus, sonnet, gpt — efforts : low, medium, high)
allowed-tools: mcp__gemini__ask_gemini, mcp__gemini__youtube_transcript, mcp__gemini__gemini_result, mcp__gemini__cancel_gemini, mcp__gemini__gemini_status, mcp__gemini__reset_gemini_session
---

Délègue la demande suivante à Gemini avec l'outil `ask_gemini` du serveur MCP « gemini », comme si l'utilisateur la tapait dans agy :

$ARGUMENTS

Mot de commande (premier mot, facultatif) :
- `suite` ou `+` : question de suivi. Repasse le dernier `session_id` vu dans cette conversation ; s'il n'y en a pas, `session_id` = "last" (la session la plus récente, même d'une session Claude précédente).
- `nouveau` : nouvelle conversation, sans `session_id`.
- `ok` ou `approuve` : seulement si la dernière réponse de Gemini attend l'accord sur un plan. Rappelle alors `ask_gemini` avec ce `session_id` et « Plan approuvé : exécute-le. ». En lecture seule, un plan ne peut aboutir qu'à des recherches, une analyse, un document ou une image : s'il prévoit une commande ou la modification de fichiers, n'approuve pas et explique que le pont l'arrêterait. Sans plan en attente, `ok` fait partie de la question.
- `stop` : arrête la demande en cours avec `cancel_gemini`.
- `état` ou `modèles` : appelle `gemini_status` avec `test` = true et affiche le résultat (modèles disponibles, sessions récentes).
- `image` : génère une image. Appelle `ask_gemini` avec « Génère une image : <description> ».

Puis, dans cet ordre :
1. Si le mot suivant est un nom de modèle (`argon`, `flash`, `opus`, `sonnet`, `gpt`, ou un identifiant complet comme `gemini-3.8-flash-high`), c'est le paramètre `model` imposé par l'utilisateur ; retire-le de la question.
2. Si le mot suivant est `low`, `medium` ou `high`, c'est le paramètre `effort` imposé ; retire-le de la question.
3. Le reste est la question.
4. Choisis toi-même ce que l'utilisateur n'a pas imposé, d'après la question. Passe toujours `model` et `effort` à `ask_gemini` : jamais les valeurs par défaut du serveur.
   - `flash` + `low` : un fait simple trouvé en une recherche (météo, heure, prix, horaires, adresse, définition, conversion, courte traduction).
   - `flash` + `medium` : quelques recherches ou une petite synthèse (comparer deux ou trois options, recommandations, résumé d'une page, d'un court document ou d'une courte vidéo), lecture d'une image.
   - `argon` + `medium` : recherche approfondie à plusieurs sources, analyse d'un long document, d'un PDF ou d'une longue vidéo, comparaison nuancée, plan ou texte structuré.
   - `argon` + `high` : raisonnement difficile (calculs, logique, code, sources contradictoires), rapport détaillé, ou exactitude importante (santé, argent, droit).
   - Image (`image`, ou une demande d'image) : `flash` + `low` : c'est le sous-agent d'images qui dessine.
   - Suite (`suite`) : garde le modèle et l'effort de l'échange précédent, sauf si la nouvelle question est nettement plus simple ou plus difficile.
   - Si tu hésites entre deux niveaux, prends le plus élevé. N'utilise `opus`, `sonnet` ou `gpt` que si l'utilisateur les nomme.

Exemples : `/gemini météo demain à Québec` (flash low) · `/gemini compare trois forfaits cellulaires au Québec` (flash medium) · `/gemini analyse ce rapport ~/Documents/bilan.pdf` (argon medium) · `/gemini flash high météo demain à Québec` (imposé) · `/gemini suite et pour lundi ?` · `/gemini image un phare rouge à l'aquarelle` · `/gemini argon low résume cette vidéo https://…` · `/gemini quelle heure est-il à Tokyo ?`

Règles :
- Fichiers : si la question contient des chemins de fichiers (images, PDF, texte, code source), passe-les dans le paramètre `files` d'`ask_gemini` et retire-les de la question.
- YouTube, pour résumer ou analyser une vidéo : passe son adresse dans `youtube_url` d'`ask_gemini`, avec la question dans `prompt`. Gemini reçoit alors la transcription complète. Si l'utilisateur veut seulement la transcription, appelle `youtube_transcript` (`save_to` pour un fichier .txt).
- Demande vide : appelle `gemini_status` et affiche son résultat.
- Transmets la question de l'utilisateur telle quelle, complétée seulement du contexte utile (Gemini ne voit pas cette conversation).
- Suivi : pour une question sur le même sujet, repasse le `session_id` reçu ; pour un autre sujet, ouvre une nouvelle session.
- Attente : si `ask_gemini` répond que Gemini travaille encore (avec un `job_id`), rappelle `gemini_result` jusqu'à la réponse. Ce n'est pas une erreur. Entre deux appels, dis en une ligne ce que Gemini a déjà fait (le message l'indique).
- Affichage, comme dans agy :
  - donne la réponse de Gemini telle quelle (texte, listes, sources et adresses), sans la réécrire ni l'enrichir de ton propre savoir ;
  - ajoute une ligne qui reprend du pied de réponse la démarche (recherches, pages lues), le modèle et la durée, avec le modèle et l'effort choisis et pourquoi, en quelques mots (ou « imposé ») ;
  - si Gemini a produit des images, montre-les et donne leur chemin ;
  - si Gemini attend l'accord sur un plan, montre le plan et propose `/gemini ok` (seulement s'il reste en lecture seule). Exception : si le plan fait exactement ce que l'utilisateur a demandé (par exemple générer l'image demandée), approuve-le tout de suite ;
  - dis quelles actions ont été refusées à Gemini, s'il y en a.
- Si tu doutes d'un fait important, dis-le.
- Si l'outil renvoie une erreur (connexion, délai, limite, demande arrêtée par le garde-fou), explique-la simplement et indique quoi faire.
- Réponds en français.
