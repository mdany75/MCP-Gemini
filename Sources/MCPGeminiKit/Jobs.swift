import Foundation

/// Demandes à Gemini en cours ou terminées mais pas encore récupérées.
///
/// Une demande tourne dans sa propre tâche, indépendante de l'appel d'outil qui l'a lancée : si le
/// client abandonne l'attente (Claude Desktop coupe un appel à environ 60 s et envoie une annulation),
/// Gemini continue et la réponse reste récupérable par `gemini_result`. Seul `cancel_gemini` (un ordre
/// explicite, jamais une annulation MCP) arrête une demande.
public final class JobBoard: @unchecked Sendable {
    public enum Outcome: Equatable {
        /// `again` : la réponse avait déjà été remise une fois.
        case finished(ToolResult, again: Bool)
        case running(elapsed: Int, activity: String?)
        case unknown
    }

    /// Ce que reçoit le travail d'une demande : son identifiant et son suivi d'activité.
    public struct Context: Sendable {
        public let id: String
        public let activity: ActivityLog
    }

    public struct Summary: Equatable, Sendable {
        public var id: String
        public var elapsed: Int
        public var label: String
        public var running: Bool
    }

    private final class Job {
        let id: String
        let label: String
        let startedAt: Date
        let activity: ActivityLog
        var task: Task<Void, Never>?
        var sessionId: String?
        var result: ToolResult?
        var finishedAt: Date?
        var deliveredAt: Date?

        init(id: String, label: String, startedAt: Date) {
            self.id = id
            self.label = label
            self.startedAt = startedAt
            activity = ActivityLog(startedAt: startedAt)
        }
    }

    /// Demandes simultanées au plus (chacune est un `agy` qui consomme du quota).
    public static let maxRunning = 3
    /// Une réponse terminée non récupérée est oubliée au bout de ce délai.
    static let keepFinished: TimeInterval = 1800
    /// Une réponse remise reste récupérable ce temps-là (client qui a perdu la réponse, appel annulé).
    static let keepDelivered: TimeInterval = 600

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values.filter { $0.result == nil }.count
    }

    /// Lance `work` en arrière-plan ; renvoie l'identifiant, ou `nil` si trop de demandes tournent déjà.
    /// `label` : début de la demande, pour la reconnaître dans les messages.
    func start(label: String = "", _ work: @escaping @Sendable (Context) async -> ToolResult) -> String? {
        lock.lock()
        prune()
        guard jobs.values.filter({ $0.result == nil }).count < Self.maxRunning else {
            lock.unlock()
            return nil
        }
        var id: String
        repeat { id = String(UUID().uuidString.prefix(5)).lowercased() } while jobs[id] != nil
        let job = Job(id: id, label: String(label.prefix(60)), startedAt: now())
        jobs[id] = job
        let context = Context(id: id, activity: job.activity)
        let jobID = id
        // Créée sous le verrou : `complete` (qui le prend aussi) ne peut pas passer avant l'inscription de la tâche.
        job.task = Task.detached { [self] in
            let result = await work(context)
            complete(jobID, result)
        }
        lock.unlock()
        return id
    }

    /// Note la session d'une demande (connue seulement une fois l'échange ouvert).
    func attach(id: String, sessionId: String) {
        lock.lock()
        jobs[id]?.sessionId = sessionId
        lock.unlock()
    }

    /// Demande en cours d'une session, s'il y en a une.
    func runningJob(ofSession sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values.first { $0.sessionId == sessionId && $0.result == nil }?.id
    }

    /// Arrête une demande en cours (le programme est arrêté par l'annulation de sa tâche) ; `false` si elle
    /// n'existe pas ou est déjà finie.
    func cancel(id: String) -> Bool {
        lock.lock()
        let job = jobs[id]
        let running = job?.result == nil
        lock.unlock()
        guard let job, running else { return false }
        job.task?.cancel()
        return true
    }

    /// La seule demande pas encore remise (en cours ou terminée) : repli quand le client a perdu le `job_id`.
    /// `nil` s'il y en a zéro ou plusieurs (Claude Desktop partage le serveur entre ses conversations : ne
    /// jamais remettre la réponse d'une autre).
    var soleUndeliveredID: String? {
        lock.lock()
        defer { lock.unlock() }
        prune()
        let waiting = jobs.values.filter { $0.deliveredAt == nil }
        return waiting.count == 1 ? waiting.first?.id : nil
    }

    /// Demandes connues, de la plus récente à la plus ancienne.
    var summaries: [Summary] {
        lock.lock()
        defer { lock.unlock() }
        prune()
        let current = now()
        return jobs.values.sorted { $0.startedAt > $1.startedAt }.map {
            Summary(id: $0.id, elapsed: Int(current.timeIntervalSince($0.startedAt)), label: $0.label, running: $0.result == nil)
        }
    }

    /// Ce que fait la demande en ce moment, pour une notification de progression (temps : âge de la demande).
    func describe(id: String) -> ProgressNote? {
        lock.lock()
        let job = jobs[id]
        let finished = job?.result != nil
        let current = now()
        lock.unlock()
        guard let job else { return nil }
        let elapsed = Int(current.timeIntervalSince(job.startedAt))
        if finished { return ProgressNote(text: "Gemini a terminé", elapsed: elapsed) }
        return ProgressNote(text: job.activity.current.map { "Gemini : \($0)" } ?? "Gemini réfléchit", elapsed: elapsed)
    }

    private func complete(_ id: String, _ result: ToolResult) {
        lock.lock()
        if let job = jobs[id] {
            job.result = result
            job.finishedAt = now()
        }
        lock.unlock()
    }

    /// Attend la fin de la demande jusqu'à `seconds`. Un appel annulé ne consomme pas la réponse : elle reste
    /// récupérable par le prochain `gemini_result`.
    func wait(id: String, seconds: TimeInterval) async -> Outcome {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if Task.isCancelled { return poll(id, consume: false) }
            let outcome = poll(id, consume: true)
            if case .running = outcome, Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            return outcome
        }
    }

    private func poll(_ id: String, consume: Bool) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        prune()
        guard let job = jobs[id] else { return .unknown }
        if let result = job.result {
            let again = job.deliveredAt != nil
            if consume, !again { job.deliveredAt = now() }
            return .finished(result, again: again)
        }
        return .running(elapsed: Int(now().timeIntervalSince(job.startedAt)),
                        activity: ActivityLog.summary(job.activity.allSteps, limit: 400))
    }

    /// Sous le verrou.
    private func prune() {
        let current = now()
        jobs = jobs.filter { entry in
            if let delivered = entry.value.deliveredAt { return current.timeIntervalSince(delivered) <= Self.keepDelivered }
            guard let finished = entry.value.finishedAt else { return true }
            return current.timeIntervalSince(finished) <= Self.keepFinished
        }
    }
}
