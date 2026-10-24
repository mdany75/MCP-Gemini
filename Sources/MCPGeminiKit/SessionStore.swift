import Foundation

public struct Exchange: Codable, Equatable, Sendable {
    public var prompt: String
    public var response: String
}

/// Une session telle que la voit un appel en cours.
public struct SessionSnapshot: Equatable, Sendable {
    public var id: String
    public var conversationId: String?
    /// Numéro (à partir de 1) de l'échange qui commence.
    public var turn: Int
    public var maxTurns: Int
    public var history: [Exchange]
}

/// Une session récente, pour `gemini_status`.
public struct SessionSummary: Equatable, Sendable {
    public var id: String
    public var turns: Int
    public var conversationId: String?
    public var lastUsed: Date
    public var lastPrompt: String?
}

public enum SessionError: Error, LocalizedError, Equatable {
    case turnLimit(id: String, max: Int)
    case busy(id: String)
    case unknown(id: String)
    case rateLimited(max: Int)

    public var errorDescription: String? {
        switch self {
        case .turnLimit(let id, let max):
            return "Limite de \(max) échanges atteinte pour la session \(id). Pour éviter une boucle entre les deux IA, "
                + "rédige maintenant la réponse finale avec ce que Gemini a déjà donné (ou, si l'utilisateur le demande, ouvre une nouvelle session sans session_id)."
        case .busy(let id):
            return "La session \(id) traite déjà une demande : appelle gemini_result pour récupérer sa réponse (ou cancel_gemini pour l'arrêter)."
        case .unknown(let id):
            return "Session « \(id) » inconnue (expirée, effacée ou jamais créée). Omettre session_id pour en ouvrir une nouvelle."
        case .rateLimited(let max):
            return "Plus de \(max) appels à Gemini en 10 minutes : pause, rédige la réponse avec ce que tu as."
        }
    }
}

/// Mémoire des conversations (chaque appel au programme est sans état) et garde-fous : nombre
/// d'échanges par session et nombre d'appels par fenêtre de temps.
///
/// Avec `directory`, chaque session est aussi gardée dans un fichier (`<id>.json`, droits 0600) : elle
/// survit au redémarrage de Claude et se partage entre Claude Desktop et Claude Code, comme les
/// conversations d'agy. Le nombre d'échanges y est gardé aussi : la limite tient après un redémarrage.
/// Pendant un échange, un verrou (`<id>.lock`, avec le pid) empêche un autre processus de reprendre la
/// même session en même temps ; un verrou dont le processus est mort est ignoré.
public actor SessionStore {
    private struct Session: Codable {
        var conversationId: String?
        var turns = 0
        var history: [Exchange] = []
        var lastUsed: Date
        var busy = false
        /// Déjà écrite sur disque : si son fichier disparaît (effacée par un autre processus), elle est oubliée.
        var persisted = false

        enum CodingKeys: String, CodingKey { case conversationId, turns, history, lastUsed }
    }

    /// Mots acceptés comme `session_id` pour reprendre la session la plus récente (comme `agy --continue`).
    public static let latestAliases: Set<String> = ["last", "latest", "derniere", "dernière"]
    /// Une session sur disque inutilisée depuis ce délai est effacée.
    public static let keepOnDisk: TimeInterval = 7 * 86_400
    /// Taille gardée d'une demande et d'une réponse dans l'historique (sert au rejeu).
    static let maxStoredPrompt = 30_000
    static let maxStoredResponse = 8_000

    private var sessions: [String: Session] = [:]
    private var callTimes: [Date] = []
    private let maxTurns: Int
    private let maxCalls: Int
    private let window: TimeInterval
    private let idleLimit: TimeInterval
    private let maxSessions = 20
    private let directory: URL?
    private let now: @Sendable () -> Date

    public init(maxTurns: Int, maxCalls: Int, window: TimeInterval = 600, idleLimit: TimeInterval = 7200,
                directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxTurns = maxTurns
        self.maxCalls = maxCalls
        self.window = window
        self.idleLimit = idleLimit
        self.directory = directory
        self.now = now
    }

    public var count: Int { sessions.count }

    /// Ouvre un échange : crée la session si `sessionId` est `nil`. Compte l'appel dans la fenêtre de temps.
    public func begin(sessionId requested: String?) throws -> SessionSnapshot {
        let current = now()
        evictIdle(current)
        try checkRate(current)

        var sessionId = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wanted = sessionId, Self.latestAliases.contains(wanted.lowercased()) {
            guard let latest = latestID() else { throw SessionError.unknown(id: wanted) }
            sessionId = latest
        }
        let id: String
        if let sessionId, !sessionId.isEmpty {
            refresh(sessionId)
            guard let existing = sessions[sessionId] else { throw SessionError.unknown(id: sessionId) }
            guard !existing.busy else { throw SessionError.busy(id: sessionId) }
            guard existing.turns < maxTurns else { throw SessionError.turnLimit(id: sessionId, max: maxTurns) }
            guard lock(sessionId) else { throw SessionError.busy(id: sessionId) }
            id = sessionId
        } else {
            evictOldest()
            id = newID()
            sessions[id] = Session(lastUsed: current)
            _ = lock(id)
        }
        callTimes.append(current)
        sessions[id]!.busy = true
        sessions[id]!.lastUsed = current
        let session = sessions[id]!
        return SessionSnapshot(id: id, conversationId: session.conversationId, turn: session.turns + 1,
                               maxTurns: maxTurns, history: session.history)
    }

    /// Échange réussi : il compte dans la limite et entre dans l'historique.
    public func finish(id: String, prompt: String, response: String, conversationId: String?) {
        guard var session = sessions[id] else { return }
        session.busy = false
        session.turns += 1
        session.history.append(Exchange(prompt: Self.clip(prompt, Self.maxStoredPrompt),
                                        response: Self.clip(response, Self.maxStoredResponse)))
        if let conversationId { session.conversationId = conversationId }
        session.lastUsed = now()
        sessions[id] = session
        persist(id)
        unlock(id)
    }

    /// Échange raté (erreur, délai, annulation) : ne compte pas dans la limite d'échanges. `conversationId`
    /// (agy) garde la conversation commencée, pour qu'une relance reprenne ce que Gemini avait déjà trouvé.
    public func abort(id: String, conversationId: String? = nil) {
        sessions[id]?.busy = false
        if let conversationId, sessions[id] != nil {
            sessions[id]!.conversationId = conversationId
            persist(id)
        }
        unlock(id)
    }

    public func reset(id: String) -> Bool {
        let inMemory = sessions.removeValue(forKey: id) != nil
        unlock(id)
        var onDisk = false
        if let url = fileURL(id), FileManager.default.fileExists(atPath: url.path) {
            onDisk = (try? FileManager.default.removeItem(at: url)) != nil
        }
        return inMemory || onDisk
    }

    public func turns(of id: String) -> Int? {
        refresh(id)
        return sessions[id]?.turns
    }

    /// Sessions les plus récentes (mémoire et disque), de la plus récente à la plus ancienne.
    /// La session que reprend `session_id` = "last" (`nil` s'il n'y en a pas).
    public func latest() -> String? { latestID() }

    public func recent(limit: Int = 5) -> [SessionSummary] {
        var all: [String: Session] = loadAll()
        for (id, session) in sessions where (all[id]?.lastUsed ?? .distantPast) <= session.lastUsed { all[id] = session }
        return all.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(limit).map { id, session in
            SessionSummary(id: id, turns: session.turns, conversationId: session.conversationId,
                           lastUsed: session.lastUsed, lastPrompt: session.history.last.map { String($0.prompt.prefix(80)) })
        }
    }

    /// Compte un appel qui ne passe pas par une session (test de connexion, relance) dans la fenêtre de temps.
    public func noteCall() throws {
        let current = now()
        try checkRate(current)
        callTimes.append(current)
    }

    /// Efface les fichiers de session trop vieux.
    public func purgeDisk() {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let current = now()
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard let session = load(id) else { continue }
            if current.timeIntervalSince(session.lastUsed) > Self.keepOnDisk, sessions[id] == nil {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    private func checkRate(_ current: Date) throws {
        callTimes.removeAll { current.timeIntervalSince($0) > window }
        guard callTimes.count < maxCalls else { throw SessionError.rateLimited(max: maxCalls) }
    }

    private func evictIdle(_ current: Date) {
        sessions = sessions.filter { $0.value.busy || current.timeIntervalSince($0.value.lastUsed) <= idleLimit }
    }

    /// Avant d'ouvrir une nouvelle session seulement : jamais au détriment d'une session qu'on reprend.
    private func evictOldest() {
        while sessions.count >= maxSessions,
              let oldest = sessions.filter({ !$0.value.busy }).min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            sessions.removeValue(forKey: oldest.key)
        }
    }

    private func newID() -> String {
        while true {
            let id = String(UUID().uuidString.prefix(6)).lowercased()
            if sessions[id] == nil, fileURL(id).map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true { return id }
        }
    }

    /// La plus récente, occupée comprise (`begin` dit alors qu'elle est occupée : jamais de recul silencieux vers
    /// une session plus ancienne). Une session neuve sans échange ni conversation n'est pas reprenable.
    private func latestID() -> String? {
        var best: (String, Date)?
        for (id, session) in sessions where session.turns > 0 || session.busy || session.conversationId != nil {
            if session.persisted, let url = fileURL(id), !FileManager.default.fileExists(atPath: url.path) { continue }
            if session.lastUsed > (best?.1 ?? .distantPast) { best = (id, session.lastUsed) }
        }
        for (id, session) in loadAll() where session.lastUsed > (best?.1 ?? .distantPast) {
            best = (id, session.lastUsed)
        }
        return best?.0
    }

    // MARK: - Fichiers

    /// Seuls les identifiants créés par `newID` (6 caractères hexadécimaux) désignent un fichier : un
    /// `session_id` venu de Claude ne peut pas sortir du dossier.
    static func isValidID(_ id: String) -> Bool {
        id.count == 6 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    private func fileURL(_ id: String) -> URL? {
        guard let directory, Self.isValidID(id) else { return nil }
        return directory.appendingPathComponent("\(id).json")
    }

    /// Met la session en mémoire à jour depuis son fichier (un autre processus a pu s'en servir, ou l'effacer).
    private func refresh(_ id: String) {
        guard var stored = load(id) else {
            // Effacée par un autre processus (reset) : elle n'existe plus.
            if let session = sessions[id], session.persisted, !session.busy { sessions.removeValue(forKey: id) }
            return
        }
        stored.persisted = true
        guard var session = sessions[id] else {
            if now().timeIntervalSince(stored.lastUsed) <= Self.keepOnDisk { sessions[id] = stored }
            return
        }
        guard !session.busy else { return }
        if stored.turns > session.turns {
            session.turns = stored.turns
            session.history = stored.history
            session.conversationId = stored.conversationId ?? session.conversationId
        }
        session.lastUsed = max(session.lastUsed, stored.lastUsed)
        sessions[id] = session
    }

    private func load(_ id: String) -> Session? {
        guard let url = fileURL(id), let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Session.self, from: data)
    }

    private func loadAll() -> [String: Session] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var all: [String: Session] = [:]
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            if let session = load(id) { all[id] = session }
        }
        return all
    }

    private func persist(_ id: String) {
        guard let directory, let url = fileURL(id), let session = sessions[id] else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(session) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sessions[id]?.persisted = true
        } catch {
            // Sans fichier, la session reste utilisable en mémoire.
        }
    }

    /// Verrou d'échange entre processus : `false` si un autre processus vivant tient la session.
    private func lock(_ id: String) -> Bool {
        guard let directory, Self.isValidID(id) else { return true }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("\(id).lock").path
        let mine = Data("\(getpid())".utf8)
        for _ in 0..<2 {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                _ = mine.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
                return true
            }
            // Déjà pris : par ce processus, par un processus vivant, ou périmé (processus mort).
            let owner = FileManager.default.contents(atPath: path).flatMap { Int32(String(decoding: $0, as: UTF8.self)) }
            if owner == getpid() { return true }
            if let owner, owner > 0, kill(owner, 0) == 0 || errno == EPERM { return false }
            try? FileManager.default.removeItem(atPath: path)
        }
        return false
    }

    private func unlock(_ id: String) {
        guard let directory, Self.isValidID(id) else { return }
        let path = directory.appendingPathComponent("\(id).lock").path
        if FileManager.default.contents(atPath: path).flatMap({ Int32(String(decoding: $0, as: UTF8.self)) }) == getpid() {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + " […]" : text
    }
}
