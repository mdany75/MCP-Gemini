import Foundation

/// Inscrit (ou retire) le serveur dans les configurations de Claude Desktop et de Claude Code.
public enum ClaudeRegistration {
    public static let serverKey = "gemini"

    public struct Target: Equatable {
        public var label: String
        public var url: URL

        public init(label: String, url: URL) {
            self.label = label
            self.url = url
        }
    }

    public static func defaultTargets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Target] {
        [
            Target(label: "Claude Desktop",
                   url: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")),
            Target(label: "Claude Code",
                   url: home.appendingPathComponent(".claude.json")),
        ]
    }

    /// Ajoute `mcpServers.gemini` dans chaque fichier ; le crée s'il manque.
    @discardableResult
    public static func register(executable: String, targets: [Target]) throws -> [String] {
        var report: [String] = []
        for target in targets {
            var root = try load(target.url)
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[serverKey] = ["command": executable, "args": [String]()]
            root["mcpServers"] = servers
            try write(root, to: target.url)
            report.append("\(target.label) : serveur « \(serverKey) » inscrit dans \(target.url.path)")
        }
        return report
    }

    /// Retire `mcpServers.gemini` de chaque fichier existant.
    @discardableResult
    public static func unregister(targets: [Target]) throws -> [String] {
        var report: [String] = []
        for target in targets {
            guard FileManager.default.fileExists(atPath: target.url.path) else { continue }
            var root = try load(target.url)
            guard var servers = root["mcpServers"] as? [String: Any], servers[serverKey] != nil else {
                report.append("\(target.label) : rien à retirer")
                continue
            }
            servers.removeValue(forKey: serverKey)
            root["mcpServers"] = servers
            try write(root, to: target.url)
            report.append("\(target.label) : serveur « \(serverKey) » retiré de \(target.url.path)")
        }
        return report
    }

    /// Chemin inscrit dans chaque fichier, ou `nil`.
    public static func registeredCommand(in target: Target) -> String? {
        guard let root = try? load(target.url),
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverKey] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.invalid("Le fichier \(url.path) n'est pas un objet JSON ; il n'a pas été modifié.")
        }
        return object
    }

    private static func write(_ object: [String: Any], to original: URL) throws {
        // Un lien symbolique (réglages gérés ailleurs) doit rester un lien : on écrit dans sa cible.
        let url = original.resolvingSymlinksInPath()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            // Copie de sécurité à côté, écrasée à chaque passage.
            let backup = url.appendingPathExtension("avant-mcp-gemini")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
