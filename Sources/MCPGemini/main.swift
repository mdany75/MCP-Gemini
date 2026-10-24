import Foundation
import MCPGeminiKit

// Point d'entrée : sans argument, le serveur MCP parle JSON-RPC sur stdin/stdout.
// Les journaux vont sur stderr, jamais sur stdout (réservé au protocole).

func log(_ message: String) {
    StdioWriter.writeAll(fd: STDERR_FILENO, data: Data("[mcp-gemini] \(message)\n".utf8))
}

/// Écritures sur stdout sérialisées : plusieurs appels d'outils répondent en parallèle.
let outputLock = NSLock()
/// stdout fermé (le client est parti) : plus aucune écriture, et arrêt propre.
nonisolated(unsafe) var outputClosed = false

func print(line: String) {
    outputLock.lock()
    let wasOpen = !outputClosed
    if wasOpen, !StdioWriter.writeAll(fd: STDOUT_FILENO, data: Data((line + "\n").utf8)) { outputClosed = true }
    let justClosed = wasOpen && outputClosed
    outputLock.unlock()
    if justClosed { DispatchQueue.global().async { shutdown("sortie fermée") } }
}

func executablePath() -> String {
    let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return url.resolvingSymlinksInPath().path
}

func usage() {
    print(line: """
    mcp-gemini \(ServerInfo.version) — pont MCP entre Claude et Gemini (par la ligne de commande locale)

    Usage : mcp-gemini                       lance le serveur (stdio, pour Claude)
            mcp-gemini --install             installe cet exécutable (emplacement stable), l'inscrit dans Claude Desktop
                                             et Claude Code, et installe la commande /gemini de Claude Code
            mcp-gemini --uninstall           retire l'inscription
            mcp-gemini --status              programmes trouvés, versions, réglages, inscriptions
            mcp-gemini --test                envoie une petite demande à Gemini (vérifie la connexion)
            mcp-gemini --backend agy|gemini  choisit le programme (agy = Antigravity CLI, recommandé)
            mcp-gemini --version

    Les réglages sont dans \(Settings.defaultURL().path).
    """)
}

func loadSettings() -> Settings {
    do {
        return try Settings.load(from: Settings.defaultURL())
    } catch {
        log("\(error.localizedDescription) ; réglages par défaut utilisés")
        return Settings()
    }
}

func makeHandler(_ settings: Settings) -> ToolHandler {
    // Dossier temporaire privé pour agy (créé 0700) : il ne voit pas celui, partagé, des autres applications.
    let temporary = Settings.temporaryURL()
    try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return ToolHandler(settings: settings,
                       store: SessionStore(maxTurns: settings.effectiveMaxTurns, maxCalls: settings.effectiveMaxCalls,
                                           directory: Settings.sessionsURL()),
                       environment: Locator.environment(temporaryDirectory: temporary.path))
}

let shutdownOnce = OnceFlag()

/// Arrêt propre, une seule fois (fin de l'entrée et signal peuvent arriver ensemble) : les programmes lancés
/// sont arrêtés (puis tués s'ils résistent) avant toute écriture, pour ne laisser aucun `agy` orphelin qui
/// continuerait à consommer le quota même si stderr est déjà fermé.
func shutdown(_ reason: String) -> Never {
    guard shutdownOnce.fire() else {
        // Un second appelant attend que le premier quitte.
        while true { pause() }
    }
    ProcessRegistry.terminateAll(grace: 3)
    Attachments.removeAllPrepared()
    log("\(reason) : arrêt")
    exit(0)
}

/// SIGTERM, SIGINT et SIGHUP passent par `shutdown` (aussi pour `--test` : Ctrl-C n'atteint pas agy, qui a son
/// propre groupe de processus). Les sources doivent rester en vie.
func installSignalHandlers() -> [DispatchSourceSignal] {
    // Écrire sur un tube fermé ne doit pas tuer le serveur sans nettoyage.
    signal(SIGPIPE, SIG_IGN)
    return [SIGTERM, SIGINT, SIGHUP].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { shutdown("signal \(sig)") }
        source.resume()
        return source
    }
}

func serve() {
    let settings = loadSettings()
    let handler = makeHandler(settings)
    let server = MCPServer(name: ServerInfo.name, version: ServerInfo.version,
                           instructions: ServerInfo.instructions(settings: settings), tools: handler,
                           log: { log($0) })
    log("démarré (version \(ServerInfo.version), programme : \(settings.backend.rawValue))")
    settings.warnings.forEach { log($0) }
    // Pièces jointes oubliées par un arrêt brutal (les instances partagent le dossier : seulement les vieilles).
    Attachments.purgeStale(workspace: Settings.workspaceURL(), olderThan: TimeInterval(settings.effectiveTimeout + 120))
    Task.detached {
        await SessionStore(maxTurns: 1, maxCalls: 1, directory: Settings.sessionsURL()).purgeDisk()
    }

    let signalSources = installSignalHandlers()

    let send: @Sendable (JSONValue) -> Void = { print(line: JSONCoding.line($0)) }
    let reader = Thread {
        while let line = readLine(strippingNewline: true) {
            server.receive(line: line, send: send)
        }
        server.cancelAll()
        shutdown("fin de l'entrée")
    }
    reader.name = "stdio"
    reader.stackSize = 1 << 22
    reader.start()
    withExtendedLifetime(signalSources) { dispatchMain() }
}

/// Exécute une commande asynchrone depuis le code synchrone du point d'entrée.
func runBlocking(_ work: @escaping @Sendable () async -> Int32) -> Never {
    let signalSources = installSignalHandlers()
    Task {
        let code = await work()
        // Après la commande, plus de signal à traiter : quitter directement.
        _ = shutdownOnce.fire()
        exit(code)
    }
    withExtendedLifetime(signalSources) { dispatchMain() }
}

func status() -> Never {
    let settings = loadSettings()
    print(line: "Version : \(ServerInfo.version)")
    print(line: "Exécutable : \(executablePath())")
    var commands = Set<String>()
    for target in ClaudeRegistration.defaultTargets() {
        let command = ClaudeRegistration.registeredCommand(in: target)
        if let command { commands.insert(command) }
        print(line: "\(target.label) : \(command.map { "inscrit (\($0))" } ?? "non inscrit")")
    }
    if commands.count > 1 {
        print(line: "⚠️ Claude Desktop et Claude Code ne lancent pas le même exécutable : relancer `mcp-gemini --install`.")
    }
    if commands.contains(where: { $0.contains("/.build/") }) {
        print(line: "⚠️ Un exécutable inscrit est dans le dossier de compilation (il change à chaque compilation) : relancer `mcp-gemini --install`.")
    }
    runBlocking {
        let result = await makeHandler(settings).call(name: "gemini_status", arguments: [:])
        print(line: result.text)
        return result.isError ? 1 : 0
    }
}

func test() -> Never {
    let settings = loadSettings()
    runBlocking {
        let result = await makeHandler(settings).call(name: "gemini_status", arguments: ["test": true])
        print(line: result.text)
        return result.isError ? 1 : 0
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil:
    serve()
case "--version", "-v":
    print(line: ServerInfo.version)
case "--help", "-h":
    usage()
case "--install":
    do {
        // Copie à un emplacement stable (indépendant du dossier de compilation), signée : c'est ce chemin
        // qui est inscrit dans Claude Desktop et Claude Code, qui lancent donc la même version.
        let stable = ClaudeRegistration.stableExecutableURL()
        try ClaudeRegistration.installExecutable(from: executablePath(), to: stable)
        print(line: "Exécutable installé : \(stable.path)")
        for line in try ClaudeRegistration.register(executable: stable.path, targets: ClaudeRegistration.defaultTargets()) {
            print(line: line)
        }
        let command = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/commands/gemini.md")
        print(line: try ClaudeRegistration.installCommand(text: GeminiCommand.text, to: command,
                                                          knownPreviousHashes: GeminiCommand.previousHashes))
        print(line: "Redémarrer Claude Desktop pour que le connecteur apparaisse ; Claude Code le voit à sa prochaine session.")
    } catch {
        log("échec de l'installation : \(error.localizedDescription)")
        exit(1)
    }
case "--uninstall":
    do {
        for line in try ClaudeRegistration.unregister(targets: ClaudeRegistration.defaultTargets()) {
            print(line: line)
        }
    } catch {
        log("échec du retrait : \(error.localizedDescription)")
        exit(1)
    }
case "--status":
    status()
case "--test":
    test()
case "--backend":
    guard arguments.count == 2, let kind = BackendKind(rawValue: arguments[1]) else {
        log("il faut « agy » ou « gemini » (ex. --backend agy)")
        exit(2)
    }
    do {
        // Seule la clé « backend » change : les autres réglages et les valeurs par défaut restent tels quels.
        try Settings.update("backend", to: .string(kind.rawValue), at: Settings.defaultURL())
        print(line: "Programme choisi : \(kind.rawValue). Relancer Claude Desktop (ou une nouvelle session Claude Code) pour appliquer.")
    } catch {
        log(error.localizedDescription)
        exit(1)
    }
default:
    log("option inconnue : \(arguments[0])")
    usage()
    exit(2)
}
