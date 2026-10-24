import Foundation

/// Programme en ligne de commande qui parle à Gemini.
public enum BackendKind: String, Codable, CaseIterable, Sendable {
    /// Antigravity CLI (`agy`) : le successeur officiel de gemini-cli pour les comptes Google personnels.
    case agy
    /// gemini-cli : n'accepte plus les comptes personnels depuis juin 2026 ; reste utilisable avec une clé API.
    case gemini

    public var binaryName: String { rawValue }
}

/// Réglages de l'utilisateur, dans `~/Library/Application Support/MCP Gemini/settings.json`. Un champ invalide
/// reprend sa valeur par défaut sans faire perdre les autres.
public struct Settings: Codable, Equatable, Sendable {
    public var backend: BackendKind = .agy
    /// Chemin complet du programme ; `nil` = recherche automatique.
    public var executable: String?
    /// Chemin complet de `yt-dlp` (transcriptions YouTube) ; `nil` = recherche automatique.
    public var ytDlp: String?
    /// Modèle imposé (voir `agy models`) ; `nil` = celui du programme.
    public var model: String?
    /// Ancien réglage du mode d'agy : le pont impose toujours `plan` (lecture seule) ; une autre valeur est ignorée.
    public var mode: String? = "plan"
    /// Effort de réflexion d'agy : `low`, `medium`, `high`… ; `nil` = celui du programme. Plus bas = plus rapide.
    public var effort: String?
    /// Attente maximale par appel d'outil avant de rendre un `job_id`, en secondes (sous les 60 s de Claude Desktop).
    /// Claude Code, qui n'a pas cette coupure, attend la réponse jusqu'au bout.
    public var waitSeconds: Int = 40
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
        ytDlp = (try? c.decodeIfPresent(String.self, forKey: .ytDlp)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? d.mode
        effort = (try? c.decodeIfPresent(String.self, forKey: .effort)) ?? nil
        waitSeconds = (try? c.decodeIfPresent(Int.self, forKey: .waitSeconds)) ?? d.waitSeconds
        timeoutSeconds = (try? c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)) ?? d.timeoutSeconds
        maxTurnsPerSession = (try? c.decodeIfPresent(Int.self, forKey: .maxTurnsPerSession)) ?? d.maxTurnsPerSession
        maxCallsPer10Minutes = (try? c.decodeIfPresent(Int.self, forKey: .maxCallsPer10Minutes)) ?? d.maxCallsPer10Minutes
        preamble = (try? c.decodeIfPresent(String.self, forKey: .preamble)) ?? d.preamble
    }

    /// Valeurs bornées : un réglage absurde ne doit ni bloquer le serveur ni supprimer les garde-fous.
    public var effectiveWait: Int { min(max(waitSeconds, 1), 50) }
    public var effectiveTimeout: Int { min(max(timeoutSeconds, 10), 1800) }
    public var effectiveMaxTurns: Int { min(max(maxTurnsPerSession, 1), 20) }
    public var effectiveMaxCalls: Int { min(max(maxCallsPer10Minutes, 1), 200) }

    /// Modèle des réglages, normalisé ; `nil` s'il est absent ou mal formé (voir `warnings`).
    public var effectiveModel: String? { model.flatMap(ModelCatalog.normalize) }
    /// Effort des réglages, normalisé ; `nil` s'il est absent ou inconnu (voir `warnings`).
    public var effectiveEffort: String? {
        effort.flatMap(ModelCatalog.normalize).flatMap { ModelCatalog.isEffort($0) ? $0 : nil }
    }

    /// Réglages ignorés, à signaler (journal au démarrage, `gemini_status`).
    public var warnings: [String] {
        var list: [String] = []
        if let mode, mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "plan" {
            list.append("réglage « mode » = « \(mode) » ignoré : le pont impose toujours plan (lecture seule)")
        }
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, effectiveModel == nil {
            list.append("réglage « model » = « \(model) » ignoré : nom de modèle mal formé")
        }
        if let effort, !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, effectiveEffort == nil {
            list.append("réglage « effort » = « \(effort) » ignoré : \(ModelCatalog.efforts.joined(separator: ", ")) seulement")
        }
        return list
    }

    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/MCP Gemini", isDirectory: true)
    }

    public static func defaultURL() -> URL {
        supportDirectory().appendingPathComponent("settings.json")
    }

    /// Sessions gardées sur disque (un fichier par session).
    public static func sessionsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("sessions", isDirectory: true)
    }

    /// Dossier temporaire privé donné à agy (TMPDIR) : il ne lit ni n'écrit dans celui, partagé, des autres applications.
    public static func temporaryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("tmp", isDirectory: true)
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

    /// Change une seule clé du fichier, sans réécrire les autres : les valeurs par défaut (dont la consigne)
    /// ne sont pas figées et suivent les versions suivantes. Un fichier illisible n'est pas touché.
    public static func update(_ key: String, to value: JSONValue, at url: URL) throws {
        var object: [String: JSONValue] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let existing = (try? JSONCoding.parse(data))?.object else {
                    throw BridgeError.invalid("Le fichier \(url.path) n'est pas un objet JSON ; il n'a pas été modifié.")
                }
                object = existing
            }
        }
        object[key] = value
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((JSONCoding.pretty(.object(object)) + "\n").utf8).write(to: url, options: .atomic)
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
