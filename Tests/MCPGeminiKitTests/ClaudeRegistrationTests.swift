import XCTest
@testable import MCPGeminiKit

/// Inscription dans Claude, copies de sécurité, exécutable et commande : uniquement dans des dossiers
/// temporaires (jamais `defaultTargets()` ni le vrai dossier personnel).
final class ClaudeRegistrationTests: XCTestCase {
    private var root: URL!
    private var backups: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("registration-\(UUID().uuidString)")
        backups = root.appendingPathComponent("support/backups")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private let original = #"{"mcpServers":{"autre":{"command":"x","env":{"K":"v"}}},"x":1,"n":3.25}"#

    private func file(_ relative: String, _ content: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let content { try content.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func backupNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).sorted()
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: - Inscription

    func testRegisterKeepsEverythingElseAndBacksUpPrivately() throws {
        let config = try file("Claude/claude_desktop_config.json", original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let target = ClaudeRegistration.Target(label: "Test", url: config)
        let report = try ClaudeRegistration.register(executable: "/chemin/mcp-gemini", targets: [target], backupDirectory: backups)

        let object = try json(config)
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let other = try XCTUnwrap(servers["autre"] as? [String: Any])
        XCTAssertEqual(other["command"] as? String, "x")
        XCTAssertEqual((other["env"] as? [String: Any])?["K"] as? String, "v")
        XCTAssertEqual((object["x"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((object["n"] as? NSNumber)?.doubleValue, 3.25)
        let gemini = try XCTUnwrap(servers["gemini"] as? [String: Any])
        XCTAssertEqual(gemini["command"] as? String, "/chemin/mcp-gemini")
        XCTAssertEqual((gemini["args"] as? [Any])?.count, 0)
        XCTAssertEqual(ClaudeRegistration.registeredCommand(in: target), "/chemin/mcp-gemini")
        XCTAssertEqual(try permissions(config), 0o600, "les droits du fichier sont conservés")

        let names = backupNames()
        XCTAssertEqual(names.count, 1)
        let backup = backups.appendingPathComponent(names[0])
        XCTAssertTrue(names[0].hasPrefix("claude_desktop_config.json.2"), names[0])
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original, "copie octet pour octet de l'ancien fichier")
        XCTAssertEqual(try permissions(backup), 0o600)
        XCTAssertEqual(try permissions(backups), 0o700)
        XCTAssertEqual(report.count, 1)
        XCTAssertTrue(report[0].contains("inscrit") && report[0].contains(backup.path), report[0])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config.deletingLastPathComponent().path),
                       ["claude_desktop_config.json"], "aucune copie à côté du fichier")

        let removed = try ClaudeRegistration.unregister(targets: [target], backupDirectory: backups)
        XCTAssertTrue(removed[0].contains("retiré") && removed[0].contains("copie de sécurité"), removed[0])
        let after = try XCTUnwrap(try json(config)["mcpServers"] as? [String: Any])
        XCTAssertNil(after["gemini"])
        XCTAssertNotNil(after["autre"])
        XCTAssertNil(ClaudeRegistration.registeredCommand(in: target))
        XCTAssertEqual(try ClaudeRegistration.unregister(targets: [target], backupDirectory: backups), ["Test : rien à retirer"])
    }

    func testNonObjectFileIsRefusedAndLeftUntouched() throws {
        for content in ["[1]", "{ pas du json"] {
            let config = try file("bad-\(UUID().uuidString).json", content)
            let target = ClaudeRegistration.Target(label: "Test", url: config)
            XCTAssertThrowsError(try ClaudeRegistration.register(executable: "/e", targets: [target], backupDirectory: backups), content)
            XCTAssertThrowsError(try ClaudeRegistration.unregister(targets: [target], backupDirectory: backups), content)
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), content)
        }
        XCTAssertTrue(backupNames().isEmpty, "rien n'a été écrit, donc aucune copie")
    }

    func testSymlinkStaysALinkAndNoBackupLandsNextToItsTarget() throws {
        let real = try file("dotfiles/claude.json", original)
        let link = try file("home/.claude.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let target = ClaudeRegistration.Target(label: "Claude Code", url: link)
        try ClaudeRegistration.register(executable: "/e", targets: [target], backupDirectory: backups)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "le lien reste un lien")
        let servers = try XCTUnwrap(try json(real)["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["gemini"], "la cible est modifiée")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.deletingLastPathComponent().path), ["claude.json"],
                       "rien de plus dans le dossier de la cible (souvent un dépôt git)")
        XCTAssertEqual(backupNames().count, 1)
        XCTAssertTrue(backupNames()[0].hasPrefix("claude.json."), "nom visible, sans point initial : \(backupNames()[0])")
    }

    func testMissingFileIsCreatedWithoutBackup() throws {
        let config = root.appendingPathComponent("nouveau/dossier/config.json")
        let target = ClaudeRegistration.Target(label: "Test", url: config)
        let report = try ClaudeRegistration.register(executable: "/e", targets: [target], backupDirectory: backups)
        XCTAssertEqual(ClaudeRegistration.registeredCommand(in: target), "/e")
        XCTAssertFalse(report[0].contains("copie"), report[0])
        XCTAssertTrue(backupNames().isEmpty)
        XCTAssertEqual(try ClaudeRegistration.unregister(targets: [ClaudeRegistration.Target(label: "Absent", url: root.appendingPathComponent("absent.json"))],
                                                         backupDirectory: backups), [])
    }

    func testAtMostThreeBackupsPerFile() throws {
        let config = try file("config.json", original)
        let other = try file("autre.json", "{}")
        try ClaudeRegistration.register(executable: "/autre", targets: [ClaudeRegistration.Target(label: "Autre", url: other)], backupDirectory: backups)
        for index in 1...5 {
            try ClaudeRegistration.register(executable: "/e\(index)", targets: [ClaudeRegistration.Target(label: "Test", url: config)],
                                            backupDirectory: backups)
        }
        let names = backupNames()
        XCTAssertEqual(names.filter { $0.hasPrefix("config.json.") }.count, ClaudeRegistration.maxBackups, "\(names)")
        XCTAssertEqual(names.filter { $0.hasPrefix("autre.json.") }.count, 1, "les copies d'un autre fichier ne sont pas touchées")
        // Les plus récentes restent : la dernière copie contient l'avant-dernière inscription.
        let newest = try XCTUnwrap(names.filter { $0.hasPrefix("config.json.") }.last)
        XCTAssertTrue(try String(contentsOf: backups.appendingPathComponent(newest), encoding: .utf8).contains("/e4"))
    }

    // MARK: - Commande /gemini

    func testInstallCommandNeverOverwritesUserChanges() throws {
        let command = root.appendingPathComponent("commands/gemini.md")
        let first = try ClaudeRegistration.installCommand(text: "v2", to: command, knownPreviousHashes: [ClaudeRegistration.sha256(Data("v1".utf8))])
        XCTAssertTrue(first.contains("installée"), first)
        XCTAssertEqual(try String(contentsOf: command, encoding: .utf8), "v2")

        let same = try ClaudeRegistration.installCommand(text: "v2", to: command, knownPreviousHashes: [ClaudeRegistration.sha256(Data("v1".utf8))])
        XCTAssertTrue(same.contains("déjà à jour"), same)

        try "v1".write(to: command, atomically: true, encoding: .utf8)
        let updated = try ClaudeRegistration.installCommand(text: "v2", to: command, knownPreviousHashes: [ClaudeRegistration.sha256(Data("v0".utf8)), ClaudeRegistration.sha256(Data("v1".utf8))])
        XCTAssertTrue(updated.contains("mise à jour"), updated)
        XCTAssertEqual(try String(contentsOf: command, encoding: .utf8), "v2")

        try "v1 + mes notes".write(to: command, atomically: true, encoding: .utf8)
        let kept = try ClaudeRegistration.installCommand(text: "v3", to: command, knownPreviousHashes: [ClaudeRegistration.sha256(Data("v1".utf8)), ClaudeRegistration.sha256(Data("v2".utf8))])
        XCTAssertTrue(kept.contains("laissée telle quelle") && kept.contains("/gemini"), kept)
        XCTAssertEqual(try String(contentsOf: command, encoding: .utf8), "v1 + mes notes")

        try "v1\n".write(to: command, atomically: true, encoding: .utf8)
        _ = try ClaudeRegistration.installCommand(text: "v3", to: command, knownPreviousHashes: [ClaudeRegistration.sha256(Data("v1".utf8))])
        XCTAssertEqual(try String(contentsOf: command, encoding: .utf8), "v1\n", "comparaison octet pour octet")

        let source = try file("depot/gemini.md", "v1")
        let link = root.appendingPathComponent("commands/lien.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let linked = try ClaudeRegistration.installCommand(text: "v2", to: link, knownPreviousHashes: [ClaudeRegistration.sha256(Data("v1".utf8))])
        XCTAssertTrue(linked.contains("lien symbolique"), linked)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "v1")
    }

    // MARK: - Exécutable

    private func program(_ relative: String, _ text: String = "#!/bin/sh\necho ok\n") throws -> URL {
        let url = try file(relative, text)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testInstallExecutableCopiesAndSigns() throws {
        let source = try program("build/mcp-gemini")
        let destination = root.appendingPathComponent("support/mcp-gemini")
        try ClaudeRegistration.installExecutable(from: source.path, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))

        // Nouvelle version : l'ancienne copie est supprimée puis remplacée.
        try "#!/bin/sh\necho v2\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try ClaudeRegistration.installExecutable(from: source.path, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "#!/bin/sh\necho v2\n")

        // Lancé depuis l'emplacement stable : rien n'est effacé.
        try ClaudeRegistration.installExecutable(from: destination.path, to: destination)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
    }

    func testInstallExecutableReportsFailures() throws {
        let source = try program("build/mcp-gemini")
        let destination = root.appendingPathComponent("support/mcp-gemini")
        XCTAssertThrowsError(try ClaudeRegistration.installExecutable(from: source.path, to: destination, codesign: "/usr/bin/false")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Signature"), error.localizedDescription)
        }
        XCTAssertThrowsError(try ClaudeRegistration.installExecutable(from: source.path, to: destination, codesign: "/nonexistent/codesign"))
        XCTAssertThrowsError(try ClaudeRegistration.installExecutable(from: root.appendingPathComponent("absent").path, to: destination))
    }

    func testStableLocations() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(ClaudeRegistration.stableExecutableURL(home: home).path, "/Users/test/Library/Application Support/MCP Gemini/mcp-gemini")
        XCTAssertEqual(ClaudeRegistration.defaultBackupDirectory(home: home).path, "/Users/test/Library/Application Support/MCP Gemini/backups")
    }
}
