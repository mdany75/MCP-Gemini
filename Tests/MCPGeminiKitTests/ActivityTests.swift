import ImageIO
import XCTest
@testable import MCPGeminiKit

/// Lignes réelles de `agy --output-format stream-json` (agy 1.4.7), raccourcies.
enum StreamSample {
    static let initLine = #"{"event":"init","conversation_id":"14e63800-6228","init":{"model":"gemini-3.8-flash-low","permission_mode":"request-review","expanded_commands":[{"name":"plan","type":"system"}],"tools":["search_web"]}}"#
    static let subagent = #"{"event":"step_update","step_update":{"conversation_id":"14e63800-6228","step_index":7,"state":"ACTIVE","step_type":"subagent","tool_name":"invoke_subagent","subagent_info":{"subagents":[{"type_name":"image-generator","role":"Image Generator"}]}}}"#
    static func search(_ index: Int, _ state: String, _ query: String) -> String {
        #"{"event":"step_update","step_update":{"conversation_id":"14e63800-6228","step_index":\#(index),"state":"\#(state)","step_type":"tool","tool_name":"search_web","tool_info":{"name":"search_web","parameters":{"query":"\#(query)"}}}}"#
    }
    static func delta(_ text: String) -> String {
        #"{"event":"step_update","step_update":{"conversation_id":"14e63800-6228","step_index":9,"state":"ACTIVE","step_type":"agent_response","text_delta":"\#(text)"}}"#
    }
    static let denied = #"{"event":"step_update","step_update":{"conversation_id":"14e63800-6228","step_index":11,"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"cp a b"}},"error":{"type":"TOOL_ERROR"}}}"#
    static let result = #"{"event":"result","result":{"conversation_id":"14e63800-6228","status":"SUCCESS","response":"Environ 1,88 $ le litre.\n","duration_seconds":20.5,"num_turns":1,"usage":{"total_tokens":50011}}}"#
}

final class ActivityTests: XCTestCase {
    func testDecodeEvents() {
        XCTAssertEqual(StreamEvent.decode(StreamSample.initLine), .started(StreamStart(conversationId: "14e63800-6228", model: "gemini-3.8-flash-low", permissionMode: "request-review", commands: ["plan"])))
        guard case .tool(let step, let key, let finished, let parameters) = StreamEvent.decode(StreamSample.search(2, "ACTIVE", "prix essence")) else {
            return XCTFail("étape d'outil attendue")
        }
        XCTAssertEqual(step, ActivityStep(tool: "search_web", detail: "prix essence"))
        XCTAssertEqual(key, "14e63800-6228#2")
        XCTAssertFalse(finished)
        XCTAssertEqual(parameters?["query"]?.string, "prix essence")
        XCTAssertEqual(StreamEvent.decode(StreamSample.delta("Le prix")), .text("Le prix"))
        guard case .result(let json) = StreamEvent.decode(StreamSample.result) else { return XCTFail("résultat attendu") }
        XCTAssertEqual(json["status"]?.string, "SUCCESS")
        // L'ancien format (un seul objet JSON) est lu comme un résultat.
        guard case .result = StreamEvent.decode(#"{"conversation_id":"c","status":"SUCCESS","response":"ok"}"#) else { return XCTFail() }
        guard case .tool(let sub, _, _, let subParameters) = StreamEvent.decode(StreamSample.subagent) else { return XCTFail("sous-agent attendu") }
        XCTAssertEqual(sub.label, "sous-agent image-generator")
        XCTAssertEqual(subParameters?["subagent_types"], ["image-generator"])
        XCTAssertNil(StreamEvent.decode("avertissement : quelque chose"))
        XCTAssertNil(StreamEvent.decode("{pas du json"))
    }

    func testLogKeepsEachStepOnceWithItsFinalState() {
        let log = ActivityLog()
        let lines = [StreamSample.initLine, StreamSample.search(2, "ACTIVE", "a"), StreamSample.search(3, "ACTIVE", "b"),
                     StreamSample.search(2, "DONE", "a"), StreamSample.search(3, "DONE", "b"), StreamSample.denied,
                     StreamSample.delta("Le "), StreamSample.delta("prix"), StreamSample.result]
        log.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(log.allSteps.map(\.detail), ["a", "b", "cp a b"])
        XCTAssertEqual(log.allSteps.last?.failed, true)
        XCTAssertEqual(log.partialText, "Le prix")
        XCTAssertEqual(log.conversationId, "14e63800-6228")
        XCTAssertEqual(log.current, "commande cp a b (3 étapes)")
        XCTAssertEqual(log.model, "gemini-3.8-flash-low")
    }

    func testLinesSplitAcrossChunks() {
        let log = ActivityLog()
        let line = Data((StreamSample.search(2, "ACTIVE", "météo Québec") + "\n").utf8)
        let cut = line.count / 2
        log.consume(line.prefix(cut))
        XCTAssertTrue(log.allSteps.isEmpty, "une ligne incomplète attend la suite")
        log.consume(line.suffix(from: cut))
        XCTAssertEqual(log.allSteps.first?.label, "recherche « météo Québec »")
    }

    func testSummary() {
        XCTAssertNil(ActivityLog.summary([]))
        let steps = [ActivityStep(tool: "search_web", detail: "a"), ActivityStep(tool: "search_web", detail: "b"),
                     ActivityStep(tool: "read_url_content", detail: "https://exemple.ca"),
                     ActivityStep(tool: "run_command", detail: "ls", failed: true)]
        XCTAssertEqual(ActivityLog.summary(steps),
                       "2 recherches web (« a », « b ») ; lecture de https://exemple.ca ; commande ls (refusé ou échoué)")
        let many = (1...9).map { ActivityStep(tool: "search_web", detail: "q\($0)") }
        XCTAssertTrue(ActivityLog.summary(many)!.hasPrefix("9 recherches web (« q1 »"))
        XCTAssertTrue(ActivityLog.summary(many)!.contains(", …"))
    }

    func testDetailPrefersMeaningfulParameterAndIsShortened() {
        XCTAssertEqual(ActivityStep.detail(of: ["domain": "meteo.gc.ca", "query": "Québec"]), "Québec")
        XCTAssertEqual(ActivityStep.detail(of: ["Prompt": "phare", "ImageName": "phare_rouge"]), "phare_rouge")
        XCTAssertEqual(ActivityStep.detail(of: ["Autre": "x"]), "x")
        XCTAssertNil(ActivityStep.detail(of: nil))
        let long = ActivityStep.detail(of: ["query": .string(String(repeating: "a", count: 200) + "\nligne 2")])!
        XCTAssertEqual(long.count, 91)
        XCTAssertTrue(long.hasSuffix("…"))
    }
}

final class GeneratedFilesTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-gemini-brain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func conversation(_ id: String) throws -> URL {
        let directory = GeneratedFiles.brainDirectory(home: home.path).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testCollectsNewFilesWithMetadataAndIgnoresTheRest() throws {
        let directory = try conversation("conv-1")
        let start = Date()
        let old = directory.appendingPathComponent("ancien.md")
        try "vieux".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-3600)], ofItemAtPath: old.path)
        try Data([0xFF, 0xD8, 0xFF]).write(to: directory.appendingPathComponent("phare_1.jpg"))
        try "# Plan\nÉtapes".write(to: directory.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try #"{"summary":"Plan de l'image","requestFeedback":true}"#.write(to: directory.appendingPathComponent("plan.md.metadata.json"), atomically: true, encoding: .utf8)
        try "caché".write(to: directory.appendingPathComponent(".secret.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".system_generated"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("lien.md"), withDestinationURL: old)

        let items = GeneratedFiles.collect(conversationId: "conv-1", since: start, home: home.path)
        XCTAssertEqual(Set(items.map(\.url.lastPathComponent)), ["phare_1.jpg", "plan.md"])
        let plan = try XCTUnwrap(items.first { $0.url.lastPathComponent == "plan.md" })
        XCTAssertTrue(plan.awaitsApproval)
        XCTAssertEqual(plan.summary, "Plan de l'image")
        XCTAssertEqual(GeneratedFiles.documentText(plan), "# Plan\nÉtapes")
        let image = try XCTUnwrap(items.first { $0.url.lastPathComponent == "phare_1.jpg" })
        XCTAssertEqual(image.kind, .image(mimeType: "image/jpeg"))
        XCTAssertNil(GeneratedFiles.preparedImage(image), "un faux JPEG n'est pas joint")
        XCTAssertFalse(image.awaitsApproval)
    }

    func testRejectsUnsafeConversationIdentifiers() throws {
        _ = try conversation("conv-2")
        for id in ["", "../conv-2", "conv-2/..", "a b", "é", String(repeating: "a", count: 81)] {
            XCTAssertTrue(GeneratedFiles.collect(conversationId: id, since: .distantPast, home: home.path).isEmpty, id)
        }
        XCTAssertTrue(GeneratedFiles.collect(conversationId: "inconnue", since: .distantPast, home: home.path).isEmpty)
    }

    func testConversationFolderThatIsASymlinkIsIgnored() throws {
        let real = try conversation("vrai")
        try "x".write(to: real.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: GeneratedFiles.brainDirectory(home: home.path).appendingPathComponent("lien"),
                                                   withDestinationURL: real)
        XCTAssertTrue(GeneratedFiles.collect(conversationId: "lien", since: .distantPast, home: home.path).isEmpty)
        XCTAssertEqual(GeneratedFiles.collect(conversationId: "vrai", since: .distantPast, home: home.path).count, 1)
    }

    func testLargeImageIsNotEmbeddedAndLongDocumentIsCut() throws {
        let directory = try conversation("conv-3")
        try Data(count: GeneratedFiles.maxImageBytes + 1).write(to: directory.appendingPathComponent("grande.png"))
        try String(repeating: "x", count: 20_000).write(to: directory.appendingPathComponent("rapport.md"), atomically: true, encoding: .utf8)
        let items = GeneratedFiles.collect(conversationId: "conv-3", since: .distantPast, home: home.path)
        let image = try XCTUnwrap(items.first { $0.url.pathExtension == "png" })
        XCTAssertNil(GeneratedFiles.preparedImage(image), "des zéros ne sont pas une image")
        let report = try XCTUnwrap(items.first { $0.url.pathExtension == "md" })
        let text = try XCTUnwrap(GeneratedFiles.documentText(report))
        XCTAssertTrue(text.hasSuffix("[…document tronqué]"))
        XCTAssertLessThan(text.count, GeneratedFiles.maxDocumentCharacters + 50)
    }

    func testRealImageIsDownscaledAndReencoded() throws {
        let directory = try conversation("conv-4")
        let width = 3000, height = 2000
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let source = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("grand.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let item = try XCTUnwrap(GeneratedFiles.collect(conversationId: "conv-4", since: .distantPast, home: home.path).first)
        let prepared = try XCTUnwrap(GeneratedFiles.preparedImage(item))
        XCTAssertEqual(prepared.mimeType, "image/jpeg", "sans transparence : JPEG")
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(max(decoded.width, decoded.height), GeneratedFiles.maxImagePixels)
        XCTAssertLessThanOrEqual(prepared.data.count, GeneratedFiles.maxImageBytes)
    }

    func testBrainFolderIsMadePrivate() throws {
        _ = try conversation("conv-5")
        GeneratedFiles.protectBrain(home: home.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: GeneratedFiles.brainDirectory(home: home.path).path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }
}
