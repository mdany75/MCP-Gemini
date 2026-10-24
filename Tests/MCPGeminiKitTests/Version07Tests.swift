import CoreText
import ImageIO
import XCTest
@testable import MCPGeminiKit

/// Les six améliorations de la version 0.7.
final class Version07Tests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("v07-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func sessionID(_ text: String) -> String {
        text.components(separatedBy: "session_id: ")[1].components(separatedBy: " ")[0]
    }

    // MARK: - 1. Claude Code reconnu sous ses différents noms

    func testClaudeCodeIsRecognizedUnderItsNames() {
        for name in ["claude-code", "Claude Code", "claude_code", " CLAUDE-CODE ", "claude-code-desktop"] {
            XCTAssertTrue(ToolHandler.isClaudeCode(name), name)
        }
        for name in ["claude-ai", "Claude", "claude-codex", "", nil] as [String?] {
            XCTAssertFalse(ToolHandler.isClaudeCode(name), name ?? "nil")
        }
    }

    func testServerLogsTheClientAndWaitsForClaudeCode() async throws {
        let agent = try FakeAgent(body: "sleep 2; " + FakeAgent.okJSON)
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
            func add(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
        }
        let logged = Lines()
        let server = MCPServer(name: "t", version: "1", instructions: "i",
                               tools: agent.handler(settings: agent.settings { $0.waitSeconds = 1 }),
                               log: { logged.add($0) })
        let initialized = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Claude Code","version":"2.1.308"}}}"#)
        XCTAssertNotNil(initialized)
        XCTAssertEqual(logged.all.first, "client : Claude Code 2.1.308 (attente jusqu'à la réponse)")
        let answered = await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_gemini","arguments":{"prompt":"q"}}}"#)
        let call = try XCTUnwrap(answered)
        XCTAssertTrue(call.contains("Bonjour de Gemini"), "une seule réponse, pas de job_id : \(call.prefix(300))")
    }

    // MARK: - 2. Sous-agent : le type réel, jamais le rôle

    private func brain(_ conversation: String) -> URL {
        GeneratedFiles.brainDirectory(home: home.path).appendingPathComponent(conversation)
    }

    private func writeDescriptor(_ conversation: String, type: String) throws {
        let folder = brain(conversation).appendingPathComponent(".system_generated/subagents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"conversationId":"sub","subagentDescriptor":{"typeName":"\#(type)","role":"Image Generator"},"state":"SUBAGENT_STATE_ALIVE"}"#
            .write(to: folder.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    }

    private func guardian() -> ReadOnlyGuard {
        let guardian = ReadOnlyGuard(expectedConversation: nil, home: home.path, workspace: home.appendingPathComponent("ws"),
                                     attachments: nil, startedAt: Date().addingTimeInterval(-5))
        XCTAssertNil(guardian.inspect(.started(StreamStart(conversationId: "conv", model: "m", permissionMode: "request-review", commands: ["plan"]))))
        return guardian
    }

    func testARoleNeverProvesTheSubagentType() throws {
        let guardian = guardian()
        // Le type annoncé est « self » : le rôle « Image Generator » n'y change rien.
        XCTAssertNotNil(guardian.check(tool: "invoke_subagent", parameters: ["subagent_types": ["self"], "subagent_roles": ["Image Generator"]]))
        let disguised = #"{"event":"step_update","step_update":{"conversation_id":"conv","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"invoke_subagent","tool_info":{"name":"invoke_subagent","parameters":{"Prompt":"x","Role":"image-generator","TypeName":"self"}}}}"#
        XCTAssertNotNil(guardian.inspect(try XCTUnwrap(StreamEvent.decode(disguised))))
    }

    func testRoleOnlySubagentIsCheckedAgainstAgyDescriptor() throws {
        // Annoncé par son seul rôle (même en français) : permis le temps de lire son type réel chez agy.
        let good = guardian()
        let french: JSONValue = ["subagent_types": [], "subagent_roles": ["Générateur d'images"]]
        XCTAssertNil(good.check(tool: "invoke_subagent", parameters: french))
        try writeDescriptor("conv", type: "image-generator")
        XCTAssertNil(good.verifySubagents())
        XCTAssertNil(good.check(tool: "schedule", parameters: ["DurationSeconds": "60", "Prompt": "attendre"]))

        // Un autre type lancé sous un rôle trompeur : arrêté dès que son fichier apparaît.
        try writeDescriptor("conv", type: "self")
        XCTAssertEqual(good.verifySubagents(),
                       "Gemini a lancé un sous-agent de type « self », interdit en lecture seule : demande arrêtée par le pont.")
        XCTAssertNotNil(good.inspect(.text("suite")), "vérifié à chaque événement")
    }

    func testDescriptorsFromEarlierExchangesAreIgnored() throws {
        try writeDescriptor("conv", type: "self")
        let folder = brain("conv").appendingPathComponent(".system_generated/subagents")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)
        }
        let guardian = guardian()
        XCTAssertNil(guardian.check(tool: "invoke_subagent", parameters: ["subagent_roles": ["Image Generator"]]))
        XCTAssertNil(guardian.verifySubagents(), "un sous-agent d'un échange précédent n'est pas celui-ci")
    }

    func testDisguisedSubagentStopsTheRequestEndToEnd() async throws {
        let roleOnly = #"{"event":"step_update","step_update":{"conversation_id":"conv-x","step_index":2,"state":"ACTIVE","step_type":"subagent","tool_name":"invoke_subagent","subagent_info":{"subagents":[{"role":"Image Generator"}]}}}"#
        let initLine = StreamSample.initLine.replacingOccurrences(of: "14e63800-6228", with: "conv-x")
        let agent = try FakeAgent(make: { home in
            let folder = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-x/.system_generated/subagents").path
            return """
            mkdir -p "\(folder)"
            printf '{"subagentDescriptor":{"typeName":"self","role":"Image Generator"}}' > "\(folder)/a.json"
            """ + "\n" + FakeAgent.stream([initLine, roleOnly, StreamSample.delta("…")]) + "; sleep 30"
        })
        let start = Date()
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "Génère une image"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("type « self »"), r.text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    // MARK: - 3. Après un arrêt par le garde-fou, la suite rejoue l'historique

    func testGuardStopMakesTheNextExchangeReplayTheHistory() async throws {
        let forbidden = StreamSample.denied.replacingOccurrences(of: "\"ERROR\"", with: "\"ACTIVE\"")
        let agent = try FakeAgent(body: """
        n=$(cat "$DIR/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$DIR/n"
        if [ $n = 1 ]; then \(FakeAgent.stream([StreamSample.initLine, StreamSample.result])); fi
        if [ $n = 2 ]; then \(FakeAgent.stream([StreamSample.initLine, forbidden])); sleep 30; fi
        if [ $n = 3 ]; then \(FakeAgent.stream([StreamSample.initLine.replacingOccurrences(of: "14e63800-6228", with: "neuve"), StreamSample.result])); fi
        """)
        let handler = agent.handler()
        let first = await handler.call(name: "ask_gemini", arguments: ["prompt": "Sujet : l'essence à Québec"])
        let sid = sessionID(first.text)
        let stopped = await handler.call(name: "ask_gemini", arguments: ["prompt": "Copie le fichier", "session_id": .string(sid)])
        XCTAssertTrue(stopped.isError)
        XCTAssertTrue(stopped.text.contains("rejoue l'historique dans une nouvelle conversation"), stopped.text)
        let next = await handler.call(name: "ask_gemini", arguments: ["prompt": "Et le diesel ?", "session_id": .string(sid)])
        XCTAssertFalse(next.isError, next.text)
        XCTAssertTrue(next.text.contains("échange 2/5"), "l'arrêt ne comptait pas")
        let args = agent.calls[2]
        XCTAssertFalse(args.contains("--conversation"), "la conversation qui contient l'action interdite n'est pas reprise")
        let prompt = args[args.firstIndex(of: "--print")! + 1]
        XCTAssertTrue(prompt.contains("Cadre fixé par le pont") && prompt.contains("Sujet : l'essence à Québec") && prompt.hasSuffix("Et le diesel ?"))
        XCTAssertFalse(prompt.contains("Copie le fichier"), "la demande arrêtée n'est pas rejouée")
    }

    // MARK: - 4 et 6. Fichiers de code ; secrets dans les PDF et les images

    private func write(_ relative: String, _ text: String) throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func prepare(_ path: String) throws -> Attachments.Prepared {
        try Attachments.prepare(paths: [path], workspace: home.appendingPathComponent("ws"), home: home.path, id: UUID().uuidString)
    }

    func testCodeFilesAreAcceptedAndScannedForSecrets() throws {
        for name in ["App.swift", "script.py", "page.html", "requete.sql", "config.yaml"] {
            XCTAssertNoThrow(try prepare(try write("Documents/projet/\(name)", "print(\"bonjour\")")), name)
        }
        let leaked = try write("Documents/projet/deploy.py", "KEY = \"AKIA" + String(repeating: "A", count: 16) + "\"")
        XCTAssertThrowsError(try prepare(leaked))
        XCTAssertThrowsError(try prepare(try write("Documents/projet/app.exe", "x")), "un exécutable n'est pas du code source")
    }

    /// PDF d'une page portant `text` (et, si `password`, chiffré).
    private func makePDF(_ relative: String, text: String, password: String? = nil) throws -> String {
        let url = home.appendingPathComponent(relative)
        var box = CGRect(x: 0, y: 0, width: 600, height: 200)
        var info: [CFString: Any] = [kCGPDFContextTitle: "Relevé"]
        if let password { info[kCGPDFContextUserPassword] = password; info[kCGPDFContextOwnerPassword] = password }
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil),
        ]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return url.path
    }

    func testSecretsInsidePDFsAreDetectedAndLockedPDFsRefused() throws {
        XCTAssertNoThrow(try prepare(try makePDF("Documents/rapport.pdf", text: "Rapport annuel : tout va bien.")))
        let secret = try makePDF("Documents/notes.pdf", text: "cle AWS : AKIA" + String(repeating: "B", count: 16))
        XCTAssertThrowsError(try prepare(secret)) { error in
            XCTAssertTrue(error.localizedDescription.contains("clé ou un jeton"), error.localizedDescription)
        }
        let locked = try makePDF("Documents/protege.pdf", text: "x", password: "1234")
        XCTAssertThrowsError(try prepare(locked)) { error in
            XCTAssertTrue(error.localizedDescription.contains("protégé"), error.localizedDescription)
        }
    }

    func testSecretsInImageMetadataAreDetected() throws {
        func photo(_ name: String, comment: String) throws -> String {
            let url = home.appendingPathComponent("Pictures/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: comment]]
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url.path
        }
        XCTAssertNoThrow(try prepare(try photo("vacances.jpg", comment: "Coucher de soleil à Tadoussac")))
        XCTAssertThrowsError(try prepare(try photo("capture.jpg", comment: "ghp_" + String(repeating: "x", count: 30))))
    }

    // MARK: - 5. Note d'approbation d'un plan

    func testPlanApprovalNoteStatesWhatAReadOnlyPlanCanDo() async throws {
        let agent = try FakeAgent(make: { home in
            let folder = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-p").path
            let initLine = StreamSample.initLine.replacingOccurrences(of: "14e63800-6228", with: "conv-p")
            let result = #"{"event":"result","result":{"conversation_id":"conv-p","status":"SUCCESS","response":"Validez ce plan."}}"#
            return """
            mkdir -p "\(folder)"; printf '# Plan' > "\(folder)/plan.md"; printf '{"requestFeedback":true}' > "\(folder)/plan.md.metadata.json"
            """ + "\n" + FakeAgent.stream([initLine, result])
        })
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "Planifie"])
        XCTAssertTrue(r.text.contains("un plan ne peut aboutir qu'à des recherches, une analyse, un document"), r.text)
        XCTAssertTrue(GeminiCommand.text.contains("n'approuve pas et explique que le pont l'arrêterait"))
    }
}
