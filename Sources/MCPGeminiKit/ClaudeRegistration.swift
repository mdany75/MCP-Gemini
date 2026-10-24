import CryptoKit
import Foundation

/// Inscrit (ou retire) le serveur dans les configurations de Claude Desktop et de Claude Code ; installe
/// l'exécutable à un emplacement stable et la commande `/gemini` de Claude Code.
public enum ClaudeRegistration {
    public static let serverKey = "gemini"
    /// Copies de sécurité gardées par fichier de configuration.
    public static let maxBackups = 3

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

    /// Emplacement stable de l'exécutable inscrit dans Claude (indépendant du dossier de compilation).
    public static func stableExecutableURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        Settings.supportDirectory(home: home).appendingPathComponent("mcp-gemini")
    }

    /// Dossier privé des copies de sécurité des configurations.
    public static func defaultBackupDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        Settings.supportDirectory(home: home).appendingPathComponent("backups", isDirectory: true)
    }

    /// Ajoute `mcpServers.gemini` dans chaque fichier ; le crée s'il manque.
    @discardableResult
    public static func register(executable: String, targets: [Target],
                                backupDirectory: URL = ClaudeRegistration.defaultBackupDirectory()) throws -> [String] {
        var report: [String] = []
        for target in targets {
            var root = try load(target.url)
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[serverKey] = ["command": executable, "args": [String]()]
            root["mcpServers"] = servers
            let backup = try write(root, to: target.url, backupDirectory: backupDirectory)
            report.append("\(target.label) : serveur « \(serverKey) » inscrit dans \(target.url.path)\(backupNote(backup))")
        }
        return report
    }

    /// Retire `mcpServers.gemini` de chaque fichier existant.
    @discardableResult
    public static func unregister(targets: [Target],
                                  backupDirectory: URL = ClaudeRegistration.defaultBackupDirectory()) throws -> [String] {
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
            let backup = try write(root, to: target.url, backupDirectory: backupDirectory)
            report.append("\(target.label) : serveur « \(serverKey) » retiré de \(target.url.path)\(backupNote(backup))")
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

    // MARK: - Exécutable et commande

    /// Copie l'exécutable à `destination` puis le signe (signature ad hoc). L'ancien fichier est supprimé
    /// d'abord : recopié par-dessus, un exécutable garde une signature en cache invalide et macOS le tue (code 137).
    public static func installExecutable(from source: String, to destination: URL) throws {
        try installExecutable(from: source, to: destination, codesign: "/usr/bin/codesign")
    }

    static func installExecutable(from source: String, to destination: URL, codesign: String) throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: source).resolvingSymlinksInPath()
        guard fileManager.isExecutableFile(atPath: sourceURL.path) else {
            throw BridgeError.invalid("Exécutable introuvable : \(source)")
        }
        // Lancé depuis l'emplacement stable lui-même : déjà installé (le supprimer effacerait la source).
        if sourceURL.standardizedFileURL.path == destination.resolvingSymlinksInPath().standardizedFileURL.path { return }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `attributesOfItem` ne suit pas un lien symbolique : un lien, même cassé, est retiré aussi.
        if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        try sign(destination, tool: codesign)
    }

    /// `codesign --force --sign - <fichier>`, lancé directement (tableau d'arguments, jamais de shell).
    static func sign(_ url: URL, tool: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["--force", "--sign", "-", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw BridgeError.invalid("Signature impossible : \(tool) n'a pas pu être lancé (\(error.localizedDescription)).")
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.invalid("Signature de \(url.path) impossible (codesign, code \(process.terminationStatus))"
                                      + (detail.isEmpty ? "." : " : \(String(detail.suffix(300)))"))
        }
    }

    /// Installe une commande de Claude Code (ex. `~/.claude/commands/gemini.md`) : le fichier est écrit s'il
    /// manque ou s'il est identique, octet pour octet, à une version publiée ; une version modifiée par
    /// l'utilisateur (ou un lien symbolique) n'est jamais écrasée. Les versions publiées sont données par leur
    /// empreinte SHA-256 (`sha256`). Rend une ligne de rapport.
    public static func installCommand(text: String, to url: URL, knownPreviousHashes: Set<String>) throws -> String {
        let fileManager = FileManager.default
        let name = "/" + url.deletingPathExtension().lastPathComponent
        let wanted = Data(text.utf8)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wanted.write(to: url, options: .withoutOverwriting)
            return "Commande \(name) installée dans \(url.path)"
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return "Commande \(name) : \(url.path) est un lien symbolique, laissé tel quel"
        }
        let current = try Data(contentsOf: url)
        if current == wanted { return "Commande \(name) déjà à jour (\(url.path))" }
        guard knownPreviousHashes.contains(sha256(current)) else {
            return "Commande \(name) laissée telle quelle : \(url.path) a été modifié à la main (nouvelle version non installée)"
        }
        try wanted.write(to: url, options: .atomic)
        return "Commande \(name) mise à jour dans \(url.path)"
    }

    /// Empreinte SHA-256 en hexadécimal.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lecture et écriture

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.invalid("Le fichier \(url.path) n'est pas un objet JSON ; il n'a pas été modifié.")
        }
        return object
    }

    /// Écrit le fichier après en avoir rangé une copie ; rend l'emplacement de la copie (`nil` : fichier nouveau).
    private static func write(_ object: [String: Any], to original: URL, backupDirectory: URL) throws -> URL? {
        // Un lien symbolique (réglages gérés ailleurs) doit rester un lien : on écrit dans sa cible.
        let url = original.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        var permissions: Int?
        if fileManager.fileExists(atPath: url.path) {
            backup = try saveBackup(of: url, in: backupDirectory)
            permissions = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        // L'écriture atomique crée un nouveau fichier : on lui rend les droits de l'ancien (souvent 0600).
        if let permissions { try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        return backup
    }

    private static func backupNote(_ backup: URL?) -> String {
        backup.map { " (copie de sécurité : \($0.path))" } ?? ""
    }

    /// Copie de sécurité dans un dossier privé (0700), en 0600 : ces fichiers contiennent souvent des clés
    /// d'autres serveurs MCP, ils ne doivent pas traîner à côté d'une cible suivie par git (dépôt de réglages).
    /// Nom : nom du fichier (sans point initial) + horodatage ; seules les `maxBackups` plus récentes restent.
    static func saveBackup(of url: URL, in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var base = String(url.lastPathComponent.drop(while: { $0 == "." }))
        if base.isEmpty { base = "config" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        var backup = directory.appendingPathComponent("\(base).\(stamp)")
        var counter = 2
        while (try? fileManager.attributesOfItem(atPath: backup.path)) != nil {
            backup = directory.appendingPathComponent("\(base).\(stamp)-\(counter)")
            counter += 1
        }
        try writeExclusively(try Data(contentsOf: url), to: backup, permissions: 0o600)
        pruneBackups(base: base, in: directory)
        return backup
    }

    /// Efface les copies d'un même fichier au-delà des `maxBackups` plus récentes (l'horodatage se trie comme du texte).
    private static func pruneBackups(base: String, in directory: URL) {
        let prefix = base + "."
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.dropFirst(prefix.count).first?.isNumber == true }
            .sorted()
        for name in names.dropLast(maxBackups) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Création exclusive (`O_EXCL`), sans suivre de lien symbolique (`O_NOFOLLOW`), avec les droits donnés.
    private static func writeExclusively(_ data: Data, to url: URL, permissions: mode_t) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard descriptor >= 0 else {
            throw BridgeError.invalid("Copie de sécurité impossible : \(url.path) n'a pas pu être créé.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
