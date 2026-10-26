import Foundation

public enum ServerInfo {
    public static let name = "mcp-gemini"
    public static let version = "0.9"

    /// Quand consulter Gemini de soi-même : la même règle dans les instructions et la description d'`ask_gemini`.
    public static let whenToConsult = """
    Consulte Gemini de toi-même, sans attendre qu'on te le demande, quand il apporte ce que tu n'as pas : générer une \
    image ; résumer ou analyser une vidéo YouTube (`youtube_url`) ; une information locale ou récente (actualité, prix, \
    horaires, météo, commerces, lieux), par la recherche Google avec sources ; un deuxième avis sur un fait important \
    (santé, argent, droit, sécurité), à recouper avec ta propre réponse ; un document trop long pour toi (`files`). \
    Pour le raisonnement, le code, la rédaction ou les questions sur le projet en cours, réponds seul. Quand tu l'as \
    consulté, dis-le à l'utilisateur en une ligne avec la raison, cite ses sources et signale tout désaccord.
    """

    public static func instructions(settings: Settings) -> String {
        """
        Pont vers Gemini (Google, par agy en lecture seule). \(whenToConsult) Capacités : recherche Google en temps \
        réel avec sources, analyse de fichiers joints (paramètre `files` : images, PDF, texte, code), génération d'images \
        (renvoyées en image), très gros volumes de texte. Vidéo YouTube : `ask_gemini` \
        avec `youtube_url` (Gemini reçoit la transcription complète) ; `youtube_transcript` seulement pour le texte \
        lui-même ; Gemini ne lit pas une vidéo par son adresse dans la demande. \
        Appelle `ask_gemini` avec une demande complète et autonome (Gemini ne voit pas cette conversation), et choisis \
        toujours `model` et `effort` d'après la demande (\(ToolHandler.choiceGuide)) ; si l'utilisateur en impose, les \
        siens. Garde le \
        `session_id` renvoyé pour une question de suivi ; au plus \(settings.effectiveMaxTurns) échanges par session : \
        ensuite, rédige la réponse finale avec ce que tu as. session_id = "last" reprend la session la plus récente, même \
        après un redémarrage. Si Gemini attend l'accord sur un plan, montre-le à l'utilisateur et, avec son accord (sa \
        demande vaut accord si le plan fait exactement ce qu'il a demandé, comme l'image demandée), repasse le session_id \
        avec « Plan approuvé : exécute-le. ». Si `ask_gemini` répond « Gemini travaille encore » \
        avec un `job_id`, appelle `gemini_result` avec ce `job_id` jusqu'à la réponse ; après un appel interrompu, appelle \
        `gemini_result` sans job_id avant de relancer quoi que ce soit ; `cancel_gemini` arrête une demande si \
        l'utilisateur le veut. Gemini peut se tromper : recoupe les faits importants et cite les sources qu'il donne.
        """
    }
}
