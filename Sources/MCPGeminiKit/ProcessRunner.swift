import Foundation

public struct ProcessResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool
    /// Texte d'un marqueur d'arrêt anticipé (ex. « Authentication required »), s'il a été vu.
    public var abortedOn: String?
    public var truncated: Bool
}

public enum ProcessError: Error, LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return message
        }
    }
}

/// Programmes en cours : permet de les arrêter tous (arrêt du serveur) avant de quitter.
public enum ProcessRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids = Set<Int32>()

    static func add(_ pid: Int32) { lock.lock(); pids.insert(pid); lock.unlock() }
    static func remove(_ pid: Int32) { lock.lock(); pids.remove(pid); lock.unlock() }

    public static var runningCount: Int { lock.lock(); defer { lock.unlock() }; return pids.count }

    /// SIGTERM à tous, attente jusqu'à `grace` secondes, puis SIGKILL des survivants.
    public static func terminateAll(grace: TimeInterval = 3) {
        lock.lock()
        let snapshot = pids
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        snapshot.forEach { kill($0, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            lock.lock()
            let remaining = !pids.isEmpty
            lock.unlock()
            if !remaining { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock()
        let survivors = pids
        lock.unlock()
        survivors.forEach { kill($0, SIGKILL) }
    }
}

/// Lance un programme externe sans bloquer : lecture simultanée de stdout et stderr (pas
/// d'interblocage sur les gros volumes), délai maximal, annulation, arrêt anticipé sur marqueur.
public enum ProcessRunner {
    /// Au-delà, la sortie est coupée (le résultat est signalé `truncated`).
    public static let maxOutputBytes = 8 * 1024 * 1024

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval,
        abortMarkers: [String] = []
    ) async throws -> ProcessResult {
        let state = RunState(abortMarkers: abortMarkers)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                state.start(executable: executable, arguments: arguments, environment: environment,
                            workingDirectory: workingDirectory, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Un lancement : tout l'état partagé entre les fils (lecture, fin du processus, délai, annulation)
/// est protégé par un seul verrou, et la continuation n'est reprise qu'une fois.
private final class RunState: @unchecked Sendable {
    private static let markerWindow = 4096
    private let lock = NSLock()
    private let abortMarkers: [String]
    private var process: Process?
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var timedOut = false
    private var abortedOn: String?
    private var truncated = false
    private var cancelled = false
    private var exited = false
    private var exitCode: Int32 = 0
    private var finished = false

    init(abortMarkers: [String]) {
        self.abortMarkers = abortMarkers
    }

    func start(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL,
               timeout: TimeInterval, continuation: CheckedContinuation<ProcessResult, Error>) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        // Entrée fermée : un programme qui attendrait une saisie reçoit immédiatement la fin de fichier.
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        lock.lock()
        self.continuation = continuation
        if cancelled {
            lock.unlock()
            finish(throwing: CancellationError())
            return
        }
        self.process = process
        lock.unlock()

        let readers = DispatchGroup()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            readers.enter()
            let once = OnceFlag()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if once.fire() { readers.leave() }
                    return
                }
                self?.append(chunk, isOut: isOut)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            self.exited = true
            self.exitCode = proc.terminationStatus
            self.lock.unlock()
            ProcessRegistry.remove(proc.processIdentifier)
            // Les données restantes arrivent avant la fin de fichier ; un petit-enfant qui garderait le
            // tube ouvert ne doit pas bloquer : on attend au plus 2 s.
            let waiter = DispatchGroup()
            waiter.enter()
            let once = OnceFlag()
            readers.notify(queue: .global()) { if once.fire() { waiter.leave() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if once.fire() { waiter.leave() } }
            waiter.notify(queue: .global()) {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.finish(throwing: nil)
            }
        }

        do {
            try process.run()
            ProcessRegistry.add(process.processIdentifier)
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            finish(throwing: ProcessError.launchFailed("Lancement impossible de \(executable) : \(error.localizedDescription)"))
            return
        }

        // Une annulation arrivée entre l'inscription du processus et son lancement n'a rien arrêté.
        lock.lock()
        let cancelledMeanwhile = cancelled
        lock.unlock()
        if cancelledMeanwhile { stop(timedOut: false) }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stop(timedOut: true)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        stop(timedOut: false)
    }

    private func append(_ chunk: Data, isOut: Bool) {
        lock.lock()
        let current = isOut ? stdout : stderr
        var marker: String?
        if current.count + chunk.count > ProcessRunner.maxOutputBytes {
            truncated = true
        } else {
            if isOut { stdout.append(chunk) } else { stderr.append(chunk) }
            if abortedOn == nil, !abortMarkers.isEmpty {
                // Un message de connexion est court et n'est pas du JSON : une vraie réponse (qui
                // commence par « { ») ou un long texte ne doit jamais être prise pour une erreur.
                let stream = String(decoding: isOut ? stdout : stderr, as: UTF8.self)
                let head = stream.trimmingCharacters(in: .whitespacesAndNewlines)
                if (isOut ? stdout : stderr).count <= Self.markerWindow, !head.hasPrefix("{") {
                    marker = abortMarkers.first { stream.contains($0) }
                    if let marker { abortedOn = marker }
                }
            }
        }
        lock.unlock()
        if marker != nil { stop(timedOut: false) }
    }

    /// Demande l'arrêt, puis force au bout de 3 s si le processus ne part pas.
    private func stop(timedOut: Bool) {
        lock.lock()
        if timedOut { self.timedOut = true }
        let process = self.process
        let alreadyExited = exited
        lock.unlock()
        guard let process, !alreadyExited, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let done = self.exited
            self.lock.unlock()
            if !done { kill(pid, SIGKILL) }
        }
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let wasCancelled = cancelled
        let result = ProcessResult(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            exitCode: exitCode, timedOut: timedOut, abortedOn: abortedOn, truncated: truncated)
        lock.unlock()
        if let error {
            continuation.resume(throwing: error)
        } else if wasCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(returning: result)
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// `true` la première fois seulement.
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
