import Foundation

/// Programme en ligne de commande qui parle à Gemini.
public enum BackendKind: String, Codable, CaseIterable, Sendable {
    /// Antigravity CLI (`agy`) : le successeur officiel de gemini-cli pour les comptes Google personnels.
    case agy
    /// gemini-cli : n'accepte plus les comptes personnels depuis juin 2026 ; reste utilisable avec une clé API.
    case gemini

    public var binaryName: String { rawValue }
}

/// Réglages de l'utilisateur ; un champ invalide reprend sa valeur par défaut sans faire perdre les autres,, dans `~/Library/Application Support/MCP Gemini/settings.json`.
public struct Settings: Codable, Equatable, Sendable {
    public var backend: BackendKind = .agy
    /// Chemin complet du programme ; `nil` = recherche automatique.
    public var executable: String?
    /// Modèle imposé (voir `agy models`) ; `nil` = celui du programme.
    public var model: String?
    /// Mode d'exécution d'agy : `plan` (lecture seule), `accept-edits` ou `auto`.
    public var mode: String? = "plan"
    /// Effort de réflexion d'agy : `low`, `medium`, `high`… ; `nil` = celui du programme.
    /// Plus bas = plus rapide (Claude Desktop coupe les appels qui dépassent environ 60 s).
    public var effort: String?
    /// Durée maximale d'un appel, en secondes.
    public var timeoutSeconds: Int = 240
    /// Nombre maximal d'échanges automatiques dans une même session (garde-fou contre les boucles).
    public var maxTurnsPerSession: Int = 5
    /// Nombre maximal d'appels, toutes sessions confondues, par fenêtre de 10 minutes.
    public var maxCallsPer10Minutes: Int = 30
    /// Consigne ajoutée au premier message de chaque session.
    public var preamble: String = Settings.defaultPreamble

    public static let defaultPreamble = """
    Tu réponds à une demande déléguée par un autre assistant (Claude), qui rédigera la réponse finale \
    pour l'utilisateur. Réponds de façon factuelle, structurée et complète. Quand tu cherches sur le web, \
    cite les sources (adresses). Ne pose pas de question : fais au mieux avec ce qui est écrit. \
    Ne modifie aucun fichier et n'exécute aucune commande.
    """

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        backend = (try? c.decodeIfPresent(BackendKind.self, forKey: .backend)) ?? d.backend
        executable = (try? c.decodeIfPresent(String.self, forKey: .executable)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? d.mode
        effort = (try? c.decodeIfPresent(String.self, forKey: .effort)) ?? nil
        timeoutSeconds = (try? c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)) ?? d.timeoutSeconds
        maxTurnsPerSession = (try? c.decodeIfPresent(Int.self, forKey: .maxTurnsPerSession)) ?? d.maxTurnsPerSession
        maxCallsPer10Minutes = (try? c.decodeIfPresent(Int.self, forKey: .maxCallsPer10Minutes)) ?? d.maxCallsPer10Minutes
        preamble = (try? c.decodeIfPresent(String.self, forKey: .preamble)) ?? d.preamble
    }

    /// Valeurs bornées : un réglage absurde ne doit ni bloquer le serveur ni supprimer les garde-fous.
    public var effectiveTimeout: Int { min(max(timeoutSeconds, 10), 1800) }
    public var effectiveMaxTurns: Int { min(max(maxTurnsPerSession, 1), 20) }
    public var effectiveMaxCalls: Int { min(max(maxCallsPer10Minutes, 1), 200) }

    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/MCP Gemini", isDirectory: true)
    }

    public static func defaultURL() -> URL {
        supportDirectory().appendingPathComponent("settings.json")
    }

    /// Dossier de travail du programme : vide, pour qu'il ne voie aucun projet de l'utilisateur.
    public static func workspaceURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("workspace", isDirectory: true)
    }

    /// Réglages par défaut si le fichier n'existe pas ; erreur s'il est illisible.
    public static func load(from url: URL) throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            throw BridgeError.invalid("Le fichier \(url.path) est illisible : \(error.localizedDescription)")
        }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum BridgeError: Error, LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}
