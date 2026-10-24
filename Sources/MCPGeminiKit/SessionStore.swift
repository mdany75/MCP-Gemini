import Foundation

public struct Exchange: Equatable, Sendable {
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
            return "La session \(id) traite déjà une demande : attendre sa réponse."
        case .unknown(let id):
            return "Session « \(id) » inconnue (expirée ou jamais créée). Omettre session_id pour en ouvrir une nouvelle."
        case .rateLimited(let max):
            return "Plus de \(max) appels à Gemini en 10 minutes : pause, rédige la réponse avec ce que tu as."
        }
    }
}

/// Mémoire des conversations (chaque appel au programme est sans état) et garde-fous : nombre
/// d'échanges par session et nombre d'appels par fenêtre de temps.
public actor SessionStore {
    private struct Session {
        var conversationId: String?
        var turns = 0
        var history: [Exchange] = []
        var busy = false
        var lastUsed: Date
    }

    private var sessions: [String: Session] = [:]
    private var callTimes: [Date] = []
    private let maxTurns: Int
    private let maxCalls: Int
    private let window: TimeInterval
    private let idleLimit: TimeInterval
    private let maxSessions = 20
    private let now: @Sendable () -> Date

    public init(maxTurns: Int, maxCalls: Int, window: TimeInterval = 600, idleLimit: TimeInterval = 7200,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxTurns = maxTurns
        self.maxCalls = maxCalls
        self.window = window
        self.idleLimit = idleLimit
        self.now = now
    }

    public var count: Int { sessions.count }

    /// Ouvre un échange : crée la session si `sessionId` est `nil`. Compte l'appel dans la fenêtre de temps.
    public func begin(sessionId: String?) throws -> SessionSnapshot {
        let current = now()
        evictIdle(current)
        try checkRate(current)

        let id: String
        if let sessionId, !sessionId.isEmpty {
            guard let existing = sessions[sessionId] else { throw SessionError.unknown(id: sessionId) }
            guard !existing.busy else { throw SessionError.busy(id: sessionId) }
            guard existing.turns < maxTurns else { throw SessionError.turnLimit(id: sessionId, max: maxTurns) }
            id = sessionId
        } else {
            evictOldest()
            id = Self.newID(existing: sessions)
            sessions[id] = Session(lastUsed: current)
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
        session.history.append(Exchange(prompt: prompt, response: response))
        if let conversationId { session.conversationId = conversationId }
        session.lastUsed = now()
        sessions[id] = session
    }

    /// Échange raté (erreur, délai, annulation) : ne compte pas dans la limite d'échanges.
    public func abort(id: String) {
        sessions[id]?.busy = false
    }

    public func reset(id: String) -> Bool {
        sessions.removeValue(forKey: id) != nil
    }

    public func turns(of id: String) -> Int? {
        sessions[id]?.turns
    }

    /// Compte un appel qui ne passe pas par une session (test de connexion) dans la fenêtre de temps.
    public func noteCall() throws {
        let current = now()
        try checkRate(current)
        callTimes.append(current)
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

    private static func newID(existing: [String: Session]) -> String {
        while true {
            let id = String(UUID().uuidString.prefix(6)).lowercased()
            if existing[id] == nil { return id }
        }
    }
}
