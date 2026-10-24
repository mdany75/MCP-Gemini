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
        let script = try make("Documents/run.sh")
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
        XCTAssertTrue(Attachments.promptNote(["attachments/x/1-a.pdf"]).contains("attachments/x/1-a.pdf"))
        XCTAssertEqual(Attachments.promptNote([]), "")
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

    func testCaptionFetchRefusesForeignHosts() async {
        for bad in ["http://www.youtube.com/x", "https://evil.com/x", "https://youtube.com.evil.com/x", "file:///etc/hosts"] {
            do {
                _ = try await ToolHandler.fetchCaptions(URL(string: bad)!)
                XCTFail(bad)
            } catch {}
        }
    }
}
