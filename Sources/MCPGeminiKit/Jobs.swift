import Foundation

/// Demandes à Gemini en cours ou terminées mais pas encore récupérées.
///
/// Une demande tourne dans sa propre tâche, indépendante de l'appel d'outil qui l'a lancée : si le
/// client abandonne l'attente (Claude Desktop coupe un appel à environ 60 s et envoie une annulation),
/// Gemini continue et la réponse reste récupérable par `gemini_result`.
public final class JobBoard: @unchecked Sendable {
    public enum Outcome: Equatable {
        case finished(ToolResult)
        case running(elapsed: Int)
        case unknown
    }

    private final class Job {
        let id: String
        let startedAt: Date
        var result: ToolResult?
        var finishedAt: Date?

        init(id: String, startedAt: Date) {
            self.id = id
            self.startedAt = startedAt
        }
    }

    /// Demandes simultanées au plus (chacune est un `agy` qui consomme du quota).
    public static let maxRunning = 3
    /// Une réponse terminée non récupérée est oubliée au bout de ce délai.
    static let keepFinished: TimeInterval = 1800

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
    func start(_ work: @escaping @Sendable () async -> ToolResult) -> String? {
        lock.lock()
        prune()
        guard jobs.values.filter({ $0.result == nil }).count < Self.maxRunning else {
            lock.unlock()
            return nil
        }
        var id: String
        repeat { id = String(UUID().uuidString.prefix(5)).lowercased() } while jobs[id] != nil
        jobs[id] = Job(id: id, startedAt: now())
        lock.unlock()

        let jobID = id
        Task.detached { [self] in
            let result = await work()
            complete(jobID, result)
        }
        return id
    }

    /// La demande la plus récente (en cours ou terminée) : repli quand le client a perdu le `job_id`.
    var latestID: String? {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values.max { $0.startedAt < $1.startedAt }?.id
    }

    private func complete(_ id: String, _ result: ToolResult) {
        lock.lock()
        if let job = jobs[id] {
            job.result = result
            job.finishedAt = now()
        }
        lock.unlock()
    }

    /// Attend la fin de la demande jusqu'à `seconds` ; une demande terminée est remise une seule fois.
    func wait(id: String, seconds: TimeInterval) async -> Outcome {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let outcome = poll(id)
            if case .running = outcome, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            return outcome
        }
    }

    private func poll(_ id: String) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { return .unknown }
        if let result = job.result {
            jobs.removeValue(forKey: id)
            return .finished(result)
        }
        return .running(elapsed: Int(now().timeIntervalSince(job.startedAt)))
    }

    private func prune() {
        let current = now()
        jobs = jobs.filter { entry in
            guard let finished = entry.value.finishedAt else { return true }
            return current.timeIntervalSince(finished) <= Self.keepFinished
        }
    }
}
