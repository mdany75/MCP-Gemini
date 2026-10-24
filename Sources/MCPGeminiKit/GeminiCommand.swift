import Foundation

/// Commande `/gemini` de Claude Code (copie de `commands/gemini.md`, installée par `--install`).
public enum GeminiCommand {
    /// Texte de la commande ; un test vérifie qu'il reste identique à `commands/gemini.md`.
    public static let text = #"""
---
description: Demander quelque chose à Gemini (modèle et effort facultatifs) par le connecteur MCP-Gemini
argument-hint: [suite|nouveau|ok|stop|état|image] [modèle] [effort] <question>   (modèles : argon, flash, opus, sonnet, gpt — efforts : low, medium, high)
allowed-tools: mcp__gemini__ask_gemini, mcp__gemini__youtube_transcript, mcp__gemini__gemini_result, mcp__gemini__cancel_gemini, mcp__gemini__gemini_status, mcp__gemini__reset_gemini_session
---

Délègue la demande suivante à Gemini avec l'outil `ask_gemini` du serveur MCP « gemini », comme si l'utilisateur la tapait dans agy :

$ARGUMENTS

Mot de commande (premier mot, facultatif) :
- `suite` ou `+` : question de suivi. Repasse le dernier `session_id` vu dans cette conversation ; s'il n'y en a pas, `session_id` = "last" (la session la plus récente, même d'une session Claude précédente).
- `nouveau` : nouvelle conversation, sans `session_id`.
- `ok` ou `approuve` : seulement si la dernière réponse de Gemini attend l'accord sur un plan. Rappelle alors `ask_gemini` avec ce `session_id` et « Plan approuvé : exécute-le. ». Sinon, `ok` fait partie de la question.
- `stop` : arrête la demande en cours avec `cancel_gemini`.
- `état` ou `modèles` : appelle `gemini_status` avec `test` = true et affiche le résultat (modèles disponibles, sessions récentes).
- `image` : génère une image. Appelle `ask_gemini` avec « Génère une image : <description> ».

Puis, dans cet ordre :
1. Si le mot suivant est un nom de modèle (`argon`, `flash`, `opus`, `sonnet`, `gpt`, ou un identifiant complet comme `gemini-3.8-flash-high`), c'est le paramètre `model` ; retire-le de la question.
2. Si le mot suivant est `low`, `medium` ou `high`, c'est le paramètre `effort` ; retire-le de la question.
3. Le reste est la question. Sans modèle ni effort, ne passe ni `model` ni `effort` : le serveur applique ses valeurs par défaut.

Exemples : `/gemini flash high météo demain à Québec` · `/gemini suite et pour lundi ?` · `/gemini image un phare rouge à l'aquarelle` · `/gemini argon low résume cette vidéo https://…` · `/gemini quelle heure est-il à Tokyo ?`

Règles :
- Fichiers : si la question contient des chemins de fichiers (images, PDF, texte), passe-les dans le paramètre `files` d'`ask_gemini` et retire-les de la question.
- YouTube, pour résumer ou analyser une vidéo : passe son adresse dans `youtube_url` d'`ask_gemini`, avec la question dans `prompt`. Gemini reçoit alors la transcription complète. Si l'utilisateur veut seulement la transcription, appelle `youtube_transcript` (`save_to` pour un fichier .txt).
- Demande vide : appelle `gemini_status` et affiche son résultat.
- Transmets la question de l'utilisateur telle quelle, complétée seulement du contexte utile (Gemini ne voit pas cette conversation).
- Suivi : pour une question sur le même sujet, repasse le `session_id` reçu ; pour un autre sujet, ouvre une nouvelle session.
- Attente : si `ask_gemini` répond que Gemini travaille encore (avec un `job_id`), rappelle `gemini_result` jusqu'à la réponse. Ce n'est pas une erreur. Entre deux appels, dis en une ligne ce que Gemini a déjà fait (le message l'indique).
- Affichage, comme dans agy :
  - donne la réponse de Gemini telle quelle (texte, listes, sources et adresses), sans la réécrire ni l'enrichir de ton propre savoir ;
  - ajoute une ligne qui reprend du pied de réponse la démarche (recherches, pages lues), le modèle et la durée ;
  - si Gemini a produit des images, montre-les et donne leur chemin ;
  - si Gemini attend l'accord sur un plan, montre le plan et propose `/gemini ok`. Exception : si le plan fait exactement ce que l'utilisateur a demandé (par exemple générer l'image demandée), approuve-le tout de suite ;
  - dis quelles actions ont été refusées à Gemini, s'il y en a.
- Si tu doutes d'un fait important, dis-le.
- Si l'outil renvoie une erreur (connexion, délai, limite, demande arrêtée par le garde-fou), explique-la simplement et indique quoi faire.
- Réponds en français.

"""#

    /// Empreintes SHA-256 des versions publiées (0.1 à 0.4) : seule une copie identique à l'une d'elles est remplacée.
    public static let previousHashes: Set<String> = [
        "7ae2c4f8ba130e0a3fa3966428d98cbb345a92c985b34c9081d752b08448967b",
        "c63f284e08dc606fd1034d54003f9dfdcdf61e89ca8553ac016791d1d7168f0b",
        "ac2778f98c603724f9d1e282b2b28fa0ba5c97c3c0a495bc40db6aaac0f3ae3f",
        "8c9367500c19a8cbb7543b8b1f2fefb4a6922fd24b65eb8a30d9ac9ef54f1a1b",
    ]
}
