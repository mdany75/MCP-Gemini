import XCTest
@testable import MCPGeminiKit

final class AttachmentsTests: XCTestCase {
    private var home: URL!
    private var workspace: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        workspace = home.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func make(_ relative: String, _ content: String = "x") throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testCopiesAllowedFilesAndRemovesThem() throws {
        let pdf = try make("Documents/rapport final.pdf", "%PDF")
        let image = try make("Pictures/photo.JPG")
        let prepared = try Attachments.prepare(paths: [pdf, image], workspace: workspace, home: home.path, id: "abc")
        XCTAssertEqual(prepared.relativePaths.count, 2)
        for path in prepared.relativePaths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(path).path), path)
            XCTAssertTrue(path.hasPrefix("attachments/abc/"))
        }
        Attachments.remove(prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf), "l'original n'est jamais touché")
    }

    func testRefusals() throws {
        let ok = try make("Documents/a.txt")
        let key = try make(".ssh/id_rsa.txt")
        let hidden = try make("Documents/.secret.txt")
        let env = try make("Documents/projet/.env")
        let script = try make("Documents/run.command")
        let keychain = try make("Library/Keychains/x.txt")
        let tooMany = Array(repeating: ok, count: Attachments.maxFiles + 1)
        let cases: [[String]] = [[key], [hidden], [env], [script], [keychain], ["relatif/a.txt"], [home.path + "/Documents/absent.txt"], [home.path + "/Documents"], tooMany]
        for paths in cases {
            XCTAssertThrowsError(try Attachments.prepare(paths: paths, workspace: workspace, home: home.path, id: "x"), "\(paths.prefix(1))")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("attachments").path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "un refus ne laisse rien derrière lui : \(leftovers)")
    }

    func testOnlyDocumentFoldersAreAccepted() throws {
        let settings = try make("Library/Application Support/Claude/config.json", "{}")
        let other = try make("Projets/notes.txt")
        let token = try make("Documents/mes-tokens.txt")
        let password = try make("Downloads/Password list.csv")
        for path in [settings, other, token, password] {
            XCTAssertThrowsError(try Attachments.prepare(paths: [path], workspace: workspace, home: home.path, id: "x"), path)
        }
        for ok in ["Desktop/a.txt", "Documents/a.txt", "Downloads/a.txt", "Pictures/a.png"] {
            let path = try make(ok)
            XCTAssertNoThrow(try Attachments.prepare(paths: [path], workspace: workspace, home: home.path, id: UUID().uuidString), ok)
        }
    }

    func testSymlinkToSecretIsRefused() throws {
        _ = try make(".ssh/key.txt")
        let link = home.appendingPathComponent("Documents/innocent.txt")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent(".ssh/key.txt"))
        XCTAssertThrowsError(try Attachments.prepare(paths: [link.path], workspace: workspace, home: home.path, id: "x"))
    }

    func testTooBigFileIsRefused() throws {
        let big = home.appendingPathComponent("Documents/gros.pdf")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(Attachments.maxBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try Attachments.prepare(paths: [big.path], workspace: workspace, home: home.path, id: "x"))
    }

    func testSanitizeAndPromptNote() {
        XCTAssertEqual(Attachments.sanitize("b:c*d.PDF"), "b_c_d.pdf")
        let long = Attachments.sanitize(String(repeating: "x", count: 200) + ".pdf")
        XCTAssertTrue(long.hasSuffix(".pdf"), "l'extension survit à la troncature")
        XCTAssertLessThanOrEqual(long.count, 84)
        XCTAssertEqual(Attachments.sanitize("   "), "fichier")
        let agy = Attachments.promptNote(["attachments/x/1-a.pdf"], backend: .agy)
        XCTAssertTrue(agy.contains("attachments/x/1-a.pdf"))
        XCTAssertTrue(agy.contains("`view_file`") && !agy.contains("read_file"), agy)
        XCTAssertTrue(Attachments.promptNote(["attachments/x/1-a.pdf"], backend: .gemini).contains("`read_file`"))
        XCTAssertEqual(Attachments.promptNote([], backend: .agy), "")
    }

    // MARK: - Dossiers temporaires

    /// Crée un vrai fichier (sur macOS, /tmp est un lien vers /private/tmp) et le note pour l'effacer à la fin.
    private func makeAbsolute(_ path: String, _ content: String = "x") throws -> String {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return path
    }

    func testOutsideHomeOnlyTmpTopLevelAndClaudeScratchpadsAreAccepted() throws {
        let tag = UUID().uuidString
        let claudeRoot = "/tmp/claude-mcpgemini-test-\(tag)"
        let otherRoot = "/tmp/mcp-gemini-test-\(tag)"
        let topLevel = "/tmp/mcp-gemini-test-\(tag).txt"
        defer {
            for path in [claudeRoot, otherRoot, topLevel] { try? FileManager.default.removeItem(atPath: path) }
        }
        let systemTemp = try makeAbsolute(NSTemporaryDirectory() + "mcp-gemini-test-\(tag).txt")
        defer { try? FileManager.default.removeItem(atPath: systemTemp) }
        let refused = [
            systemTemp,
            try makeAbsolute("\(claudeRoot)/x/tasks/a.txt"),
            try makeAbsolute("\(otherRoot)/a.txt"),
            try makeAbsolute("\(otherRoot)/scratchpad/a.txt"),
        ]
        for path in refused {
            XCTAssertThrowsError(try Attachments.validate(path, home: home.path), path) { error in
                XCTAssertTrue(error.localizedDescription.contains("Bureau, Documents"), error.localizedDescription)
            }
        }
        let accepted = [
            try makeAbsolute(topLevel),
            "/private" + topLevel,
            try makeAbsolute("\(claudeRoot)/x/scratchpad/a.txt"),
            try makeAbsolute("\(claudeRoot)/-Users-x-Projet/0f3c/scratchpad/sous/b.md"),
        ]
        for path in accepted {
            XCTAssertNoThrow(try Attachments.validate(path, home: home.path), path)
        }
    }

    func testOutsideHomeRule() {
        func allowed(_ path: String) -> Bool { Attachments.isAllowedOutsideHome(path.split(separator: "/").map(String.init)) }
        XCTAssertTrue(allowed("/tmp/a.txt"))
        XCTAssertTrue(allowed("/private/tmp/a.txt"))
        XCTAssertTrue(allowed("/tmp/claude-501/x/scratchpad/a.txt"))
        XCTAssertFalse(allowed("/tmp/claude-501/x/tasks/a.txt"))
        XCTAssertFalse(allowed("/tmp/claude-501/x/scratchpad"), "le dossier lui-même n'est pas un fichier joint")
        XCTAssertFalse(allowed("/tmp/autre/scratchpad/a.txt"))
        XCTAssertFalse(allowed("/var/folders/ab/xyz/T/a.txt"))
        XCTAssertFalse(allowed("/private/var/folders/ab/xyz/T/a.txt"))
        XCTAssertFalse(allowed("/etc/hosts"))
    }

    // MARK: - Noms et contenus sensibles

    func testSensitivePathsAreRefused() throws {
        let paths = [
            try make("Documents/Mots de passe.txt"),
            try make("Documents/clés API.txt"),
            try make("Documents/Passwords/list.txt"),
            try make("Downloads/github-recovery-codes.txt"),
            try make("Downloads/bitwarden_export_2026.json"),
            try make("Documents/MDP banque.csv"),
            try make("Desktop/Trousseau/notes.md"),
            try make("Documents/Codes de secours.pdf"),
            try make("Downloads/projet-firebase-adminsdk-x1.json"),
            try make("Pictures/seed.png"),
        ]
        for path in paths {
            XCTAssertThrowsError(try Attachments.validate(path, home: home.path), path) { error in
                XCTAssertTrue(error.localizedDescription.contains("évoque un secret"), error.localizedDescription)
            }
        }
        for ok in ["Documents/rapport final.pdf", "Documents/Clément.txt", "Pictures/seedling.png", "Documents/Clef du succès.md"] {
            XCTAssertNoThrow(try Attachments.validate(try make(ok), home: home.path), ok)
        }
    }

    func testFilesContainingKeysAreRefused() throws {
        let awsKey = "AKIA" + "ABCDEFGHIJKLMNOP"
        let secrets = [
            "compte.json": #"{"type": "service_account", "project_id": "p"}"#,
            "prive.json": #"{"private_key": "abc"}"#,
            "serveur.txt": "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n",
            "aws.csv": "id,clé\n1,\(awsKey)\n",
            "github.md": "jeton : ghp_" + String(repeating: "a1B2", count: 9),
            "slack.txt": "xoxb-" + "123456789012-abcdef",
            "anthropic.txt": "ANTHROPIC=sk-ant-" + "api03-" + String(repeating: "Zz9", count: 10),
            "google.txt": "cle=AIza" + String(repeating: "x", count: 35),
        ]
        for (name, content) in secrets {
            let path = try make("Documents/\(name)", content)
            XCTAssertThrowsError(try Attachments.validate(path, home: home.path), name) { error in
                XCTAssertFalse(error.localizedDescription.contains(awsKey), "le secret n'est jamais recopié")
            }
        }
        let innocent = [
            "notes.txt": "Le préfixe ghp_ désigne un jeton GitHub ; une clé privée se range dans un coffre.",
            "donnees.json": #"{"type": "user", "private": true}"#,
            "scan.pdf": "%PDF -----BEGIN PRIVATE KEY-----",  // seuls les fichiers texte sont lus
        ]
        for (name, content) in innocent {
            XCTAssertNoThrow(try Attachments.validate(try make("Documents/\(name)", content), home: home.path), name)
        }
        // Une clé au-delà des 256 premiers Ko n'est pas cherchée (limite de lecture).
        let far = String(repeating: "a", count: Attachments.scannedBytes) + "-----BEGIN PRIVATE KEY-----"
        XCTAssertNoThrow(try Attachments.validate(try make("Documents/long.txt", far), home: home.path))
    }

    func testSensitiveWordRules() {
        for name in ["clés API.txt", "Mot-de-passe.md", "mes_tokens.txt", "Wallet.json", "id_ed25519.txt", "1Password Export.csv",
                     "KeePass.csv", "Backup codes.txt", "Recovery-Codes.txt", "service-account.json", "Mnemonic phrase.txt"] {
            XCTAssertTrue(Attachments.looksSensitive(name), name)
        }
        for name in ["Clément.txt", "seedling.png", "Rapport annuel.pdf", "Documents", "Downloads", "Passeport photo.png", "tokenisation.md"] {
            XCTAssertFalse(Attachments.looksSensitive(name), name)
        }
    }

    // MARK: - Fichiers produits et nettoyage

    func testGeneratedFilesAreJoined() throws {
        let file = Attachments.GeneratedFile(name: "transcription YouTube.txt", data: Data("Bonjour".utf8))
        let prepared = try Attachments.prepare(paths: [try make("Documents/a.txt")], generated: [file],
                                               workspace: workspace, home: home.path, id: "gen")
        XCTAssertEqual(prepared.relativePaths, ["attachments/gen/1-a.txt", "attachments/gen/2-transcription YouTube.txt"])
        let written = workspace.appendingPathComponent(prepared.relativePaths[1])
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "Bonjour")
        Attachments.remove(prepared)

        let bad = Attachments.GeneratedFile(name: "programme.exe", data: Data("x".utf8))
        XCTAssertThrowsError(try Attachments.prepare(paths: [], generated: [bad], workspace: workspace, home: home.path, id: "bad"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("attachments/bad").path))
    }

    func testRemoveNeverDeletesTheWorkspace() throws {
        let empty = try Attachments.prepare(paths: [], workspace: workspace, home: home.path, id: "vide")
        XCTAssertTrue(empty.relativePaths.isEmpty)
        Attachments.remove(empty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testRemoveAllPreparedClearsPendingCopies() throws {
        let first = try Attachments.prepare(paths: [try make("Documents/a.txt")], workspace: workspace, home: home.path, id: "un")
        let second = try Attachments.prepare(paths: [try make("Documents/b.txt")], workspace: workspace, home: home.path, id: "deux")
        let done = try Attachments.prepare(paths: [try make("Documents/c.txt")], workspace: workspace, home: home.path, id: "trois")
        Attachments.remove(done)
        Attachments.removeAllPrepared()
        for prepared in [first, second, done] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path), prepared.directory.lastPathComponent)
        }
        Attachments.remove(first)  // déjà effacé : sans effet
        Attachments.removeAllPrepared()
    }

    func testAskGeminiPassesFilesToTheProgramAndCleansUp() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let file = try make("Documents/notes.txt", "contenu")
        let handler = ToolHandler(settings: agent.settings(), store: SessionStore(maxTurns: 5, maxCalls: 10),
                                  workspace: workspace, environment: Locator.environment(), home: home.path)
        let result = await handler.call(name: "ask_gemini", arguments: ["prompt": "lis", "files": [.string(file)]])
        XCTAssertFalse(result.isError, result.text)
        let args = try XCTUnwrap(agent.calls.first)
        let prompt = args[args.firstIndex(of: "--print")! + 1]
        XCTAssertTrue(prompt.contains("Fichiers joints"))
        XCTAssertTrue(prompt.contains("attachments/"))
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("attachments").path)) ?? []
        XCTAssertTrue(remaining.isEmpty, "copies effacées après la demande")
    }

    func testAskGeminiRefusesBadFilesWithoutCallingTheProgram() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let secret = try make(".aws/credentials.txt")
        let handler = ToolHandler(settings: agent.settings(), store: SessionStore(maxTurns: 5, maxCalls: 10),
                                  workspace: workspace, environment: Locator.environment(), home: home.path)
        let refused = await handler.call(name: "ask_gemini", arguments: ["prompt": "lis", "files": [.string(secret)]])
        let wrongType = await handler.call(name: "ask_gemini", arguments: ["prompt": "lis", "files": "pas une liste"])
        XCTAssertTrue(refused.isError && wrongType.isError)
        XCTAssertTrue(agent.calls.isEmpty)
    }
}

final class YouTubeTests: XCTestCase {
    func testURLValidation() {
        XCTAssertEqual(YouTubeTranscript.validate("https://www.youtube.com/watch?v=abc"), "https://www.youtube.com/watch?v=abc")
        XCTAssertNotNil(YouTubeTranscript.validate("https://youtu.be/abc"))
        XCTAssertNil(YouTubeTranscript.validate("http://www.youtube.com/watch?v=abc"))
        XCTAssertNil(YouTubeTranscript.validate("https://evil.com/watch?v=abc"))
        XCTAssertNil(YouTubeTranscript.validate("https://youtube.com.evil.com/x"))
        XCTAssertNil(YouTubeTranscript.validate("--exec=touch /tmp/x"))
        XCTAssertNil(YouTubeTranscript.validate("https://www.youtube.com/watch?v=a b"))
        XCTAssertNil(YouTubeTranscript.validate("file:///etc/passwd"))
    }

    private let vtt = """
    WEBVTT
    Kind: captions
    Language: en

    00:00:00.000 --> 00:00:02.000 align:start position:0%
    Hello there
    and welcome

    00:00:02.000 --> 00:00:02.010 align:start position:0%
    Hello there
    and welcome

    00:00:02.010 --> 00:00:04.000 align:start position:0%
    and welcome
    to the <c>show</c> &amp; more

    00:00:40.000 --> 00:00:42.000
    Second part.
    """

    func testParseAndFormat() {
        let cues = YouTubeTranscript.parseVTT(vtt)
        XCTAssertEqual(cues.map(\.text), ["Hello there", "and welcome", "to the show & more", "Second part."])
        let formatted = YouTubeTranscript.format(cues, timestamps: true)
        XCTAssertTrue(formatted.hasPrefix("[00:00] Hello there and welcome to the show & more"))
        XCTAssertTrue(formatted.contains("[00:40] Second part."))
        XCTAssertFalse(YouTubeTranscript.format(cues, timestamps: false).contains("["))
    }

    func testManualTrackKeepsDuplicatesAndAutomaticDoesNot() {
        let text = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nNo.\n\n00:00:01.000 --> 00:00:02.000\nNo.\n"
        XCTAssertEqual(YouTubeTranscript.parseVTT(text, deduplicate: false).map(\.text), ["No.", "No."])
        XCTAssertEqual(YouTubeTranscript.parseVTT(text, deduplicate: true).map(\.text), ["No."])
    }

    func testWhitespaceOnlyLineDoesNotSplitABlock() {
        let text = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n  \nUne ligne\n\n"
        XCTAssertEqual(YouTubeTranscript.parseVTT(text).map(\.text), ["Une ligne"])
    }

    func testPickTrackIgnoresHLSAndForeignHosts() {
        let info = try! JSONCoding.parse(#"""
        {"language":"en","automatic_captions":{"en-orig":[{"ext":"vtt","protocol":"m3u8_native","url":"https://manifest.googlevideo.com/x"},
          {"ext":"vtt","url":"https://evil.example.com/x"},{"ext":"vtt","url":"https://www.youtube.com/api/timedtext?a=1"}]}}
        """#)
        XCTAssertEqual(YouTubeTranscript.pickTrack(json: info, language: nil)?.url, "https://www.youtube.com/api/timedtext?a=1")
    }

    func testPublishedTrackBeatsAutomaticWhenLanguageUnknownAndRegionFallsBack() {
        let info = try! JSONCoding.parse(#"""
        {"subtitles":{"de":[{"ext":"vtt","url":"https://www.youtube.com/de"}]},
         "automatic_captions":{"ja-orig":[{"ext":"vtt","url":"https://www.youtube.com/ja"}],"en":[{"ext":"vtt","url":"https://www.youtube.com/en"}]}}
        """#)
        XCTAssertEqual(YouTubeTranscript.pickTrack(json: info, language: nil)?.language, "de")
        XCTAssertEqual(YouTubeTranscript.pickTrack(json: info, language: "en-US")?.language, "en")
    }

    func testExclusiveWriteNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try YouTubeTranscript.writeExclusively(Data("un".utf8), to: file)
        XCTAssertThrowsError(try YouTubeTranscript.writeExclusively(Data("deux".utf8), to: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "un")
        let link = dir.appendingPathComponent("lien.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("cible.txt"))
        XCTAssertThrowsError(try YouTubeTranscript.writeExclusively(Data("x".utf8), to: link), "un lien symbolique n'est pas suivi")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cible.txt").path))
    }

    func testClock() {
        XCTAssertEqual(YouTubeTranscript.clock(75), "01:15")
        XCTAssertEqual(YouTubeTranscript.clock(3725), "1:02:05")
    }

    private func json(_ text: String) -> JSONValue { try! JSONCoding.parse(text) }

    func testPickTrack() {
        let info = json(#"""
        {"language":"en","subtitles":{"fr":[{"ext":"vtt","url":"https://www.youtube.com/m/fr"}]},
         "automatic_captions":{"en-orig":[{"ext":"json3","url":"x"},{"ext":"vtt","url":"https://www.youtube.com/a/en-orig"}],
                                "en":[{"ext":"vtt","url":"https://www.youtube.com/a/en"}],"de":[{"ext":"vtt","url":"https://www.youtube.com/a/de"}]}}
        """#)
        XCTAssertEqual(YouTubeTranscript.pickTrack(json: info, language: nil),
                       .init(language: "en-orig", url: "https://www.youtube.com/a/en-orig", isAutomatic: true))
        XCTAssertEqual(YouTubeTranscript.pickTrack(json: info, language: "fr"),
                       .init(language: "fr", url: "https://www.youtube.com/m/fr", isAutomatic: false))
        XCTAssertEqual(YouTubeTranscript.pickTrack(json: info, language: "de")?.url, "https://www.youtube.com/a/de")
        XCTAssertNil(YouTubeTranscript.pickTrack(json: info, language: "ja"))
        XCTAssertNil(YouTubeTranscript.pickTrack(json: json(#"{"subtitles":{},"automatic_captions":{}}"#), language: nil))
    }

    func testSavePathRules() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNoThrow(try YouTubeTranscript.validateSavePath(home.path + "/Downloads/t.txt", home: home.path))
        for bad in [home.path + "/Downloads/t.sh", home.path + "/.ssh/t.txt", home.path + "/Downloads/.t.txt", "/tmp/t.txt", "relatif.txt", home.path + "/absent/t.txt"] {
            XCTAssertThrowsError(try YouTubeTranscript.validateSavePath(bad, home: home.path), bad)
        }
        try "x".write(to: home.appendingPathComponent("Downloads/existe.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try YouTubeTranscript.validateSavePath(home.path + "/Downloads/existe.txt", home: home.path))
    }

    func testToolEndToEndWithFakeYtDlp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("yt-dlp")
        let info = #"{"title":"Titre test","channel":"Chaîne test","duration":75,"language":"en","automatic_captions":{"en-orig":[{"ext":"vtt","url":"https://www.youtube.com/api/timedtext?x=1"}]}}"#
        try "#!/bin/sh\nprintf '%s' '\(info)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var settings = Settings()
        settings.ytDlp = script.path
        let vttData = Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nBonjour le monde\n".utf8)
        let handler = ToolHandler(settings: settings, store: SessionStore(maxTurns: 5, maxCalls: 5),
                                  workspace: dir.appendingPathComponent("ws"), environment: Locator.environment(), home: dir.path,
                                  fetch: { _ in vttData })
        let save = dir.path + "/Downloads/out.txt"
        let result = await handler.call(name: "youtube_transcript", arguments: ["url": "https://youtu.be/abc", "save_to": .string(save)])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Titre : Titre test"))
        XCTAssertTrue(result.text.contains("[00:01] Bonjour le monde"))
        XCTAssertTrue(result.text.contains("sous-titres automatiques"))
        XCTAssertTrue(try String(contentsOfFile: save, encoding: .utf8).contains("Bonjour le monde"))

        let again = await handler.call(name: "youtube_transcript", arguments: ["url": "https://youtu.be/abc", "save_to": .string(save)])
        XCTAssertTrue(again.isError, "rien n'est écrasé")
        let badURL = await handler.call(name: "youtube_transcript", arguments: ["url": "https://example.com/x"])
        XCTAssertTrue(badURL.isError)
        let noLang = await handler.call(name: "youtube_transcript", arguments: ["url": "https://youtu.be/abc", "language": "ja"])
        XCTAssertTrue(noLang.isError)
    }

    func testMissingYtDlp() async {
        var settings = Settings()
        settings.ytDlp = "/nonexistent/yt-dlp"
        let handler = ToolHandler(settings: settings, store: SessionStore(maxTurns: 5, maxCalls: 5))
        let result = await handler.call(name: "youtube_transcript", arguments: ["url": "https://youtu.be/abc"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("yt-dlp"))
    }

    func testCaptionDownloadRefusesForeignHostsBeforeAnyRequest() async {
        for bad in ["http://www.youtube.com/x", "https://evil.com/x", "https://youtube.com.evil.com/x", "file:///etc/hosts"] {
            do {
                _ = try await YouTubeTranscript.downloadCaptions(URL(string: bad)!)
                XCTFail(bad)
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("hors YouTube"), error.localizedDescription)
            }
        }
    }

    func testCaptionURLRule() {
        func allowed(_ text: String) -> Bool { YouTubeTranscript.isAllowedCaptionURL(URL(string: text)!) }
        XCTAssertTrue(allowed("https://www.youtube.com/api/timedtext?v=abc&lang=fr"))
        XCTAssertTrue(allowed("https://youtube.com/api/timedtext"))
        XCTAssertTrue(allowed("HTTPS://WWW.YOUTUBE.COM/api/timedtext"))
        XCTAssertFalse(allowed("https://evil.com/api/timedtext"))
        XCTAssertFalse(allowed("http://www.youtube.com/api/timedtext"))
        XCTAssertFalse(allowed("https://youtube.com.evil.com/x"))
        XCTAssertFalse(allowed("https://notyoutube.com/x"))
        XCTAssertFalse(allowed("https://user:pass@www.youtube.com/x"))
        XCTAssertFalse(allowed("https://www.youtube.com:8443/x"))
    }

    func testRedirectsOutsideYouTubeAreRefused() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let start = URL(string: "https://www.youtube.com/api/timedtext")!
        let task = session.dataTask(with: start)  // jamais lancée : aucun accès réseau
        let response = try XCTUnwrap(HTTPURLResponse(url: start, statusCode: 302, httpVersion: nil, headerFields: nil))
        func follows(_ target: String) -> Bool {
            var followed: URLRequest?
            YouTubeTranscript.captionRedirectGuard.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                             newRequest: URLRequest(url: URL(string: target)!)) { followed = $0 }
            return followed != nil
        }
        XCTAssertTrue(follows("https://m.youtube.com/api/timedtext?x=1"))
        XCTAssertFalse(follows("https://evil.com/x"))
        XCTAssertFalse(follows("http://www.youtube.com/x"))
        XCTAssertFalse(follows("https://youtube.com.evil.com/x"))
    }

    // MARK: - Fins de ligne, paragraphes, extraits

    func testCRLFAndBOMCaptionsAreRead() {
        let lf = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nPremière ligne\nDeuxième ligne\n\n00:00:03.000 --> 00:00:04.000\nFin\n"
        let expected = ["Première ligne", "Deuxième ligne", "Fin"]
        XCTAssertEqual(YouTubeTranscript.parseVTT(lf).map(\.text), expected)
        XCTAssertEqual(YouTubeTranscript.parseVTT(lf.replacingOccurrences(of: "\n", with: "\r\n")).map(\.text), expected)
        XCTAssertEqual(YouTubeTranscript.parseVTT("\u{FEFF}" + lf.replacingOccurrences(of: "\n", with: "\r\n")).map(\.text), expected)
        XCTAssertEqual(YouTubeTranscript.parseVTT(lf.replacingOccurrences(of: "\n", with: "\r")).map(\.text), expected)
        XCTAssertEqual(YouTubeTranscript.parseVTT(lf.replacingOccurrences(of: "\n", with: "\r\n")).map(\.start), [0, 0, 3])
    }

    func testUnpunctuatedCaptionsAreSplitIntoParagraphs() {
        let cues = (0..<60).map { YouTubeTranscript.Cue(start: Double($0) * 2, text: "alors on continue sans ponctuation") }
        let text = YouTubeTranscript.format(cues, timestamps: false)
        XCTAssertEqual(text.components(separatedBy: "\n\n").count, 4, "un paragraphe par tranche de 30 s")
        XCTAssertFalse(text.contains("["))
        let stamped = YouTubeTranscript.format(cues, timestamps: true)
        XCTAssertEqual(stamped.components(separatedBy: "\n\n").map { String($0.prefix(7)) }, ["[00:00]", "[00:30]", "[01:00]", "[01:30]"])
    }

    func testLongTranscriptIsProcessedInLinearTime() {
        let vtt = "WEBVTT\n\n" + (0..<20_000).map { index in
            let seconds = index * 3 / 2
            let start = String(format: "%02d:%02d:%02d.%03d", seconds / 3600, seconds / 60 % 60, seconds % 60, index % 2 * 500)
            return "\(start) --> \(start)\nvoilà déjà ça été très réussi à Montréal \(index)\n"
        }.joined(separator: "\n")
        let parseStart = Date()
        let cues = YouTubeTranscript.parseVTT(vtt)
        let parsing = Date().timeIntervalSince(parseStart)
        // Lecture : marge large (compilation de débogage, machine chargée) ; un temps quadratique dépasserait de loin.
        XCTAssertLessThan(parsing, 2, "\(parsing) s")
        XCTAssertEqual(cues.count, 20_000)

        let transcript = YouTubeTranscript.Transcript(title: "t", channel: "c", duration: 30_000, source: "https://youtu.be/x",
                                                      language: "fr", isAutomatic: true, cues: cues)
        let start = Date()
        let plain = transcript.body(timestamps: false)
        let stamped = transcript.body(timestamps: true)
        let excerpt = transcript.excerpt(timestamps: true, maxCharacters: 45_000)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5, "\(elapsed) s")
        XCTAssertGreaterThan(plain.components(separatedBy: "\n\n").count, 900)
        XCTAssertTrue(stamped.hasPrefix("[00:00] voilà"))
        XCTAssertFalse(excerpt.isComplete)
    }

    func testExcerptStopsBetweenCuesAndReportsCoverage() {
        let cues = (0..<40).map { YouTubeTranscript.Cue(start: Double($0) * 10, text: "réplique numéro \($0)") }
        let transcript = YouTubeTranscript.Transcript(title: "t", channel: "c", duration: 400, source: "https://youtu.be/x",
                                                      language: "fr", isAutomatic: false, cues: cues)
        let full = transcript.excerpt(timestamps: true, maxCharacters: 100_000)
        XCTAssertTrue(full.isComplete)
        XCTAssertEqual(full.text, transcript.body(timestamps: true))
        XCTAssertEqual(full.percent, 100)

        for timestamps in [true, false] {
            let body = transcript.body(timestamps: timestamps)
            let part = transcript.excerpt(timestamps: timestamps, maxCharacters: body.count / 2)
            XCTAssertFalse(part.isComplete)
            XCTAssertLessThanOrEqual(part.text.count, body.count / 2)
            XCTAssertTrue(body.hasPrefix(part.text), "l'extrait est le début exact du texte complet")
            let last = try! XCTUnwrap(part.lastKeptStart)
            XCTAssertTrue(part.text.hasSuffix("réplique numéro \(Int(last / 10))"), part.text)
            XCTAssertEqual(part.percent, Int(last / 400 * 100))
            XCTAssertGreaterThan(part.percent ?? 0, 30)
            XCTAssertLessThan(part.percent ?? 100, 60)
        }

        let none = transcript.excerpt(timestamps: true, maxCharacters: 5)
        XCTAssertEqual(none.text, "")
        XCTAssertNil(none.lastKeptStart)
        XCTAssertEqual(none.percent, 0)
        var unknown = transcript
        unknown.duration = nil
        XCTAssertNil(unknown.excerpt(timestamps: true, maxCharacters: 50).percent)
        XCTAssertTrue(unknown.header.contains("Durée : inconnue"))
        XCTAssertTrue(transcript.header.contains("Durée : 06:40\n") && transcript.header.contains("(sous-titres publiés)"))
        XCTAssertTrue(transcript.header.hasSuffix("\n\n"))
    }

    // MARK: - yt-dlp et récupération complète

    func testYtDlpArgumentsIgnoreConfigurationAndEndWithTheURL() {
        let url = "https://www.youtube.com/watch?v=abc"
        let arguments = YouTubeTranscript.ytDlpArguments(url: url)
        XCTAssertEqual(arguments.first, "--ignore-config")
        XCTAssertEqual(Array(arguments.suffix(2)), ["--", url])
        for flag in ["--no-exec", "--no-cookies-from-browser", "--no-cache-dir", "--skip-download", "--dump-single-json", "--no-playlist"] {
            XCTAssertTrue(arguments.dropLast(2).contains(flag), flag)
        }
        XCTAssertEqual(arguments.filter { $0 == "--" }.count, 1)
    }

    /// Adresses reçues par le faux téléchargement.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private static let videoInfo = #"{"title":"Titre test","channel":"Chaîne test","duration":75,"language":"fr","subtitles":{"fr":[{"ext":"vtt","url":"https://www.youtube.com/api/timedtext?lang=fr"}]},"automatic_captions":{"en":[{"ext":"vtt","url":"https://www.youtube.com/api/timedtext?lang=en"}]}}"#

    private func fakeYtDlp(_ body: String = "printf '%s' '\(YouTubeTests.videoInfo)'") throws -> FakeAgent {
        // Le dossier courant est noté à côté du script, pour vérifier où yt-dlp a été lancé.
        try FakeAgent(body: "pwd -P > \"$(dirname \"$0\")/cwd.txt\"\n\(body)")
    }

    func testFetchRunsYtDlpInTheGivenFolderAndReturnsTheTranscript() async throws {
        let ytDlp = try fakeYtDlp()
        let folder = ytDlp.directory.appendingPathComponent("youtube-vide")
        let recorder = Recorder()
        let vtt = "WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nBonjour le monde\r\n\r\n00:00:40.000 --> 00:00:41.000\r\nSuite\r\n"
        let transcript = try await YouTubeTranscript.fetch(
            url: " https://youtu.be/abc ", language: nil, ytDlp: ytDlp.executable, environment: Locator.environment(),
            workingDirectory: folder, fetchCaptions: { url in recorder.add(url); return Data(vtt.utf8) })

        XCTAssertEqual(ytDlp.calls, [YouTubeTranscript.ytDlpArguments(url: "https://youtu.be/abc")])
        let cwd = try String(contentsOf: ytDlp.directory.appendingPathComponent("cwd.txt"), encoding: .utf8)
        XCTAssertEqual(URL(fileURLWithPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path,
                       folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(recorder.all.map(\.absoluteString), ["https://www.youtube.com/api/timedtext?lang=fr"])
        XCTAssertEqual(transcript.title, "Titre test")
        XCTAssertEqual(transcript.channel, "Chaîne test")
        XCTAssertEqual(transcript.duration, 75)
        XCTAssertEqual(transcript.source, "https://youtu.be/abc")
        XCTAssertEqual(transcript.language, "fr")
        XCTAssertFalse(transcript.isAutomatic)
        XCTAssertEqual(transcript.cues.map(\.text), ["Bonjour le monde", "Suite"])
        XCTAssertEqual(transcript.header, "Titre : Titre test\nChaîne : Chaîne test\nDurée : 01:15\nSource : https://youtu.be/abc\nLangue : fr (sous-titres publiés)\n\n")
        XCTAssertEqual(transcript.body(timestamps: true), "[00:01] Bonjour le monde\n\n[00:40] Suite")
    }

    func testFetchErrorMessages() async throws {
        func message(_ ytDlp: FakeAgent, executable: String? = nil, url: String = "https://youtu.be/abc", language: String? = nil,
                     captions: @escaping @Sendable (URL) async throws -> Data = { _ in Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx\n".utf8) }) async -> String {
            do {
                _ = try await YouTubeTranscript.fetch(url: url, language: language, ytDlp: executable ?? ytDlp.executable,
                                                      environment: Locator.environment(),
                                                      workingDirectory: ytDlp.directory.appendingPathComponent("vide"), fetchCaptions: captions)
                return "pas d'erreur"
            } catch {
                XCTAssertTrue(error is BridgeError, "\(error)")
                return error.localizedDescription
            }
        }
        let ok = try fakeYtDlp()
        let invalid = await message(ok, url: "https://example.com/x")
        XCTAssertTrue(invalid.contains("adresse https de vidéo YouTube"), invalid)
        XCTAssertTrue(ok.calls.isEmpty, "adresse refusée avant de lancer yt-dlp")

        let failing = try fakeYtDlp("echo 'ERROR: Video unavailable' >&2; exit 1")
        let unreadable = await message(failing)
        XCTAssertTrue(unreadable.contains("privée, supprimée") && unreadable.contains("Video unavailable"), unreadable)

        let noTrack = await message(ok, language: "ja")
        XCTAssertTrue(noTrack.contains("Aucun sous-titre « ja »") && noTrack.contains("Pistes vues : fr, en"), noTrack)

        let empty = await message(ok, captions: { _ in Data("WEBVTT\n\n".utf8) })
        XCTAssertEqual(empty, "Les sous-titres de la vidéo « Titre test » sont vides.")

        let cancelled = await message(ok, captions: { _ in throw CancellationError() })
        XCTAssertEqual(cancelled, "Appel annulé.")
        let urlCancelled = await message(ok, captions: { _ in throw URLError(.cancelled) })
        XCTAssertEqual(urlCancelled, "Appel annulé.")

        let network = await message(ok, captions: { _ in throw BridgeError.invalid("réponse HTTP 429") })
        XCTAssertEqual(network, "Téléchargement des sous-titres impossible : réponse HTTP 429")

        let launch = await message(ok, executable: "/nonexistent/yt-dlp")
        XCTAssertTrue(launch.contains("/nonexistent/yt-dlp"), launch)
    }
}
