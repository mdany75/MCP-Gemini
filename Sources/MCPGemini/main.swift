import Foundation
import MCPGeminiKit

// Point d'entrée : sans argument, le serveur MCP parle JSON-RPC sur stdin/stdout.
// Les journaux vont sur stderr, jamais sur stdout (réservé au protocole).

func log(_ message: String) {
    FileHandle.standardError.write(Data("[mcp-gemini] \(message)\n".utf8))
}

/// Écritures sur stdout sérialisées : plusieurs appels d'outils répondent en parallèle.
let outputLock = NSLock()

func print(line: String) {
    outputLock.lock()
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
    outputLock.unlock()
}

func executablePath() -> String {
    let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return url.resolvingSymlinksInPath().path
}

func usage() {
    print(line: """
    mcp-gemini \(ServerInfo.version) — pont MCP entre Claude et Gemini (par la ligne de commande locale)

    Usage : mcp-gemini                       lance le serveur (stdio, pour Claude)
            mcp-gemini --install             inscrit cet exécutable dans Claude Desktop et Claude Code
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
    ToolHandler(settings: settings,
                store: SessionStore(maxTurns: settings.effectiveMaxTurns, maxCalls: settings.effectiveMaxCalls))
}

/// Arrêt propre : les programmes lancés sont arrêtés (puis tués s'ils résistent) avant de quitter,
/// pour ne laisser aucun `agy` orphelin qui continuerait à consommer le quota.
func shutdown(_ reason: String) -> Never {
    log("\(reason) : arrêt")
    ProcessRegistry.terminateAll(grace: 3)
    exit(0)
}

func serve() {
    let settings = loadSettings()
    let server = MCPServer(name: ServerInfo.name, version: ServerInfo.version,
                           instructions: ServerInfo.instructions(settings: settings), tools: makeHandler(settings))
    log("démarré (version \(ServerInfo.version), programme : \(settings.backend.rawValue))")

    // Écrire sur un tube fermé ne doit pas tuer le serveur sans nettoyage ; les signaux d'arrêt passent par shutdown.
    signal(SIGPIPE, SIG_IGN)
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { shutdown("signal \(sig)") }
        source.resume()
        signalSources.append(source)
    }

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
    Task {
        let code = await work()
        exit(code)
    }
    dispatchMain()
}

func status() -> Never {
    let settings = loadSettings()
    print(line: "Version : \(ServerInfo.version)")
    print(line: "Exécutable : \(executablePath())")
    for target in ClaudeRegistration.defaultTargets() {
        let command = ClaudeRegistration.registeredCommand(in: target)
        print(line: "\(target.label) : \(command.map { "inscrit (\($0))" } ?? "non inscrit")")
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
        for line in try ClaudeRegistration.register(executable: executablePath(), targets: ClaudeRegistration.defaultTargets()) {
            print(line: line)
        }
        print(line: "Redémarrer Claude Desktop pour que le connecteur apparaisse ; Claude Code le voit à sa prochaine session.")
    } catch {
        log("échec de l'inscription : \(error.localizedDescription)")
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
        var settings = try Settings.load(from: Settings.defaultURL())
        settings.backend = kind
        try settings.save(to: Settings.defaultURL())
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
