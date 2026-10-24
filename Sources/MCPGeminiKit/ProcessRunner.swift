import Foundation

public struct ProcessResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool
    /// Texte d'un marqueur d'arrêt anticipé (ex. « Authentication required »), s'il a été vu.
    public var abortedOn: String?
    /// Raison donnée par le lecteur de la sortie (`onStdout`) pour arrêter le programme, s'il l'a fait.
    public var stopReason: String?
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
///
/// `Process` place chaque programme dans son propre groupe (numéro de groupe = pid) : les signaux visent
/// le groupe entier (`kill(-pid, …)`), pour ne laisser aucun petit-enfant orphelin. Un numéro de groupe
/// n'est pas réutilisé tant que le groupe existe.
public enum ProcessRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids = Set<Int32>()

    static func add(_ pid: Int32) { lock.lock(); pids.insert(pid); lock.unlock() }
    static func remove(_ pid: Int32) { lock.lock(); pids.remove(pid); lock.unlock() }

    public static var runningCount: Int { lock.lock(); defer { lock.unlock() }; return pids.count }

    /// Signal au groupe du programme ; au processus seul si le groupe n'existe pas (ou plus).
    static func signal(_ pid: Int32, _ sig: Int32) {
        if kill(-pid, sig) != 0 { kill(pid, sig) }
    }

    /// SIGTERM à tous les groupes, attente jusqu'à `grace` secondes, puis SIGKILL des groupes restants.
    public static func terminateAll(grace: TimeInterval = 3) {
        lock.lock()
        let snapshot = pids
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        snapshot.forEach { signal($0, SIGTERM) }
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
        survivors.forEach { signal($0, SIGKILL) }
    }
}

/// Lance un programme externe sans bloquer : lecture simultanée de stdout et stderr (pas
/// d'interblocage sur les gros volumes), délai maximal, annulation, arrêt anticipé sur marqueur.
/// `onStdout` reçoit la sortie au fil de l'eau (hors verrou) et peut demander l'arrêt en rendant une raison.
public enum ProcessRunner {
    /// Au-delà, la sortie est coupée (le résultat est signalé `truncated`).
    public static let maxOutputBytes = 8 * 1024 * 1024

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval,
        abortMarkers: [String] = [],
        onStdout: (@Sendable (Data) -> String?)? = nil
    ) async throws -> ProcessResult {
        let state = RunState(abortMarkers: abortMarkers, onStdout: onStdout)
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
    private let onStdout: (@Sendable (Data) -> String?)?
    private var process: Process?
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var timedOut = false
    private var abortedOn: String?
    private var stopReason: String?
    private var truncated = false
    private var outFull = false
    private var errFull = false
    /// Le pid est inscrit dans ProcessRegistry (et doit en être retiré).
    private var registered = false
    private var cancelled = false
    private var exited = false
    private var exitCode: Int32 = 0
    private var finished = false

    init(abortMarkers: [String], onStdout: (@Sendable (Data) -> String?)?) {
        self.abortMarkers = abortMarkers
        self.onStdout = onStdout
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
            let wasRegistered = self.registered
            self.lock.unlock()
            if wasRegistered { ProcessRegistry.remove(proc.processIdentifier) }
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
            // Sous le verrou : un programme très court a pu finir (et passer son gestionnaire de fin)
            // avant cette ligne ; il ne faut alors pas laisser un pid périmé dans le registre.
            lock.lock()
            if !exited {
                ProcessRegistry.add(process.processIdentifier)
                registered = true
            }
            lock.unlock()
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
        if (isOut ? outFull : errFull) || current.count + chunk.count > ProcessRunner.maxOutputBytes {
            // Une fois plein, plus rien n'est ajouté à ce flux : la sortie gardée reste d'un seul tenant.
            truncated = true
            if isOut { outFull = true } else { errFull = true }
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
        // Hors du verrou : le lecteur peut prendre son temps sans bloquer la lecture de stderr.
        if isOut, let onStdout, let reason = onStdout(chunk) {
            lock.lock()
            let first = stopReason == nil
            if first { stopReason = reason }
            lock.unlock()
            if first { stop(timedOut: false) }
        }
    }

    /// Demande l'arrêt du groupe, puis force au bout de 3 s si le processus ne part pas.
    private func stop(timedOut: Bool) {
        lock.lock()
        // Un programme déjà sorti (on attend seulement la fin de ses tubes) n'a pas dépassé le délai.
        if timedOut && !exited { self.timedOut = true }
        let process = self.process
        let alreadyExited = exited
        lock.unlock()
        guard let process, !alreadyExited, process.isRunning else { return }
        let pid = process.processIdentifier
        ProcessRegistry.signal(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let done = self.exited
            self.lock.unlock()
            if !done { ProcessRegistry.signal(pid, SIGKILL) }
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
            exitCode: exitCode, timedOut: timedOut, abortedOn: abortedOn, stopReason: stopReason, truncated: truncated)
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

public final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    public init() {}

    /// `true` la première fois seulement.
    public func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
