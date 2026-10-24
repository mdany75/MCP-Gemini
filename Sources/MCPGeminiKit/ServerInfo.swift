import Foundation

public enum ServerInfo {
    public static let name = "mcp-gemini"
    public static let version = "0.1"

    public static func instructions(settings: Settings) -> String {
        """
        Pont vers Gemini (Google), pour ce que Gemini fait mieux que toi : recherche web et Google Maps en \
        temps réel, analyse d'une chaîne ou d'une vidéo YouTube, très gros volumes de texte. \
        Appelle `ask_gemini` avec une demande complète et autonome (Gemini ne voit pas cette conversation). \
        Garde le `session_id` renvoyé pour une question de suivi ; au plus \(settings.effectiveMaxTurns) échanges \
        par session : ensuite, rédige la réponse finale avec ce que tu as. Gemini peut se tromper : \
        recoupe les faits importants et cite les sources qu'il donne.
        """
    }
}
