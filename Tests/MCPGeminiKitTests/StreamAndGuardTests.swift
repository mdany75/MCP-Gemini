import XCTest
@testable import MCPGeminiKit

/// Le pont face au flux d'agy : suivi, garde-fou de la lecture seule, fichiers produits, conversation perdue, arrêt.
final class StreamAndGuardTests: XCTestCase {
    private func sessionID(_ text: String) -> String {
        text.components(separatedBy: "session_id: ")[1].components(separatedBy: " ")[0]
    }

    private func jobID(_ text: String) throws -> String {
        try XCTUnwrap(text.components(separatedBy: "job_id = \"").dropFirst().first?.components(separatedBy: "\"").first)
    }

    private static let resultLine = StreamSample.result

    func testStreamAnswerShowsModelDurationTokensAndSearches() async throws {
        let agent = try FakeAgent(body: FakeAgent.stream([StreamSample.initLine, StreamSample.search(2, "ACTIVE", "prix essence"),
                                                          StreamSample.search(2, "DONE", "prix essence"), Self.resultLine]))
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "Prix de l'essence ?"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.hasPrefix("Environ 1,88 $ le litre."))
        XCTAssertTrue(r.text.contains("gemini-3.8-flash-low · 20,5 s · 50 011 jetons"), r.text)
        XCTAssertTrue(r.text.contains("Démarche de Gemini : 1 recherche web (« prix essence »)."), r.text)
        let args = try XCTUnwrap(agent.calls.first)
        XCTAssertEqual(args[args.firstIndex(of: "--output-format")! + 1], "stream-json")
        XCTAssertEqual(args[args.firstIndex(of: "--mode")! + 1], "plan")
    }

    private func assertStopped(_ lines: [String], containing expected: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let agent = try FakeAgent(body: FakeAgent.stream(lines) + "; sleep 30")
        let start = Date()
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "q"])
        XCTAssertTrue(r.isError, r.text, file: file, line: line)
        XCTAssertTrue(r.text.contains(expected), r.text, file: file, line: line)
        XCTAssertTrue(r.text.contains("ne compte pas"), file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "arrêté sans attendre la fin", file: file, line: line)
    }

    func testGuardStopsWithoutPlanMode() async throws {
        let noPlan = #"{"event":"init","conversation_id":"c1","init":{"model":"m","permission_mode":"request-review","expanded_commands":[]}}"#
        try await assertStopped([noPlan], containing: "mode plan")
    }

    func testGuardStopsWithPermissiveSettings() async throws {
        let permissive = #"{"event":"init","conversation_id":"c1","init":{"model":"m","permission_mode":"always-proceed","expanded_commands":[{"name":"plan"}]}}"#
        try await assertStopped([permissive], containing: "always-proceed")
    }

    func testGuardStopsAForbiddenTool() async throws {
        try await assertStopped([StreamSample.initLine, StreamSample.search(2, "DONE", "a"), StreamSample.denied.replacingOccurrences(of: "\"ERROR\"", with: "\"ACTIVE\"")],
                                containing: "« run_command »")
    }

    func testGuardStopsAReadOutsideTheAttachments() async throws {
        let read = #"{"event":"step_update","step_update":{"conversation_id":"14e63800-6228","step_index":3,"state":"ACTIVE","step_type":"tool","tool_name":"view_file","tool_info":{"name":"view_file","parameters":{"AbsolutePath":"/Users/x/.ssh/id_rsa"}}}}"#
        try await assertStopped([StreamSample.initLine, read], containing: "/Users/x/.ssh/id_rsa")
    }

    func testGuardStopsAnUnknownSubagent() async throws {
        let sub = StreamSample.subagent.replacingOccurrences(of: "image-generator", with: "browser-agent")
        try await assertStopped([StreamSample.initLine, sub], containing: "browser-agent")
    }

    func testGuardRules() {
        let workspace = URL(fileURLWithPath: "/w/workspace")
        let guardian = ReadOnlyGuard(expectedConversation: nil, home: "/h", workspace: workspace,
                                     attachments: workspace.appendingPathComponent("attachments/abc"))
        XCTAssertNil(guardian.inspect(.started(StreamStart(conversationId: "conv", model: "m", permissionMode: "request-review", commands: ["plan"]))))
        XCTAssertNil(guardian.check(tool: "search_web", parameters: ["query": "x"]))
        XCTAssertNil(guardian.check(tool: "view_file", parameters: ["AbsolutePath": "/w/workspace/attachments/abc/1-a.pdf"]))
        XCTAssertNil(guardian.check(tool: "read_file", parameters: ["Path": "attachments/abc/1-a.pdf"]), "chemin relatif au dossier de travail")
        XCTAssertNil(guardian.check(tool: "list_dir", parameters: ["DirectoryPath": "/w/workspace"]))
        XCTAssertNotNil(guardian.check(tool: "view_file", parameters: ["AbsolutePath": "/w/workspace/attachments/autre/secret.pdf"]))
        XCTAssertNotNil(guardian.check(tool: "view_file", parameters: ["AbsolutePath": "/w/workspace/attachments/abc/../autre/x.pdf"]))
        XCTAssertNil(guardian.check(tool: "write_file", parameters: ["Path": "/h/.gemini/antigravity-cli/brain/conv/plan.md"]))
        XCTAssertNotNil(guardian.check(tool: "write_file", parameters: ["Path": "/h/.gemini/antigravity-cli/brain/autre/plan.md"]))
        XCTAssertNotNil(guardian.check(tool: "write_file", parameters: ["Path": "/h/.gemini/antigravity-cli/brain/conv/../../x.md"]))
        XCTAssertNotNil(guardian.check(tool: "write_file", parameters: ["Content": "sans chemin"]))
        XCTAssertNotNil(guardian.check(tool: "write_to_file", parameters: ["TargetFile": "/w/workspace/x.md"]))
        XCTAssertNil(guardian.check(tool: "invoke_subagent", parameters: ["subagent_types": ["image-generator"]]))
        XCTAssertNil(guardian.check(tool: "invoke_subagent", parameters: ["subagent_types": ["Image Generator"]]), "décrit par son rôle")
        XCTAssertNotNil(guardian.check(tool: "invoke_subagent", parameters: ["subagent_types": ["Browser Agent"]]))
        XCTAssertNotNil(guardian.check(tool: "invoke_subagent", parameters: ["Prompt": "x"]))
        // Le même appel décrit comme un outil, avec TypeName.
        let asTool = #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"invoke_subagent","tool_info":{"name":"invoke_subagent","parameters":{"Prompt":"x","Role":"Image Generator","TypeName":"image-generator"}}}}"#
        guard case .tool(_, _, _, let parameters)? = StreamEvent.decode(asTool) else { return XCTFail() }
        XCTAssertNil(guardian.check(tool: "invoke_subagent", parameters: parameters))
        let roleOnly = #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":5,"state":"ACTIVE","step_type":"subagent","tool_name":"invoke_subagent","subagent_info":{"subagents":[{"role":"Image Generator"}]}}}"#
        guard case .tool(_, _, _, let roleParameters)? = StreamEvent.decode(roleOnly) else { return XCTFail() }
        XCTAssertNil(guardian.check(tool: "invoke_subagent", parameters: roleParameters))
        // Recherche récursive à la racine : refusée dès qu'une autre demande a des fichiers joints.
        let other = workspace.appendingPathComponent("attachments/autre")
        XCTAssertNil(guardian.check(tool: "grep_search", parameters: ["SearchPath": "/w/workspace"]), "dossier inexistant : rien d'autre")
        XCTAssertNotNil(guardian.check(tool: "view_file", parameters: ["AbsolutePaths": ["/w/workspace/attachments/abc/a.pdf", "/Users/x/secret.txt"]]),
                        "chemins en tableau")
        XCTAssertNotNil(guardian.check(tool: "generate_image", parameters: ["Prompt": "copie", "ImagePaths": ["/Users/x/Desktop/releve.png"]]))
        XCTAssertNil(guardian.check(tool: "generate_image", parameters: ["Prompt": "un phare", "ImageName": "phare"]))
        XCTAssertNotNil(guardian.check(tool: "read_url_content", parameters: ["Url": "file:///Users/x/Documents/a.txt"]))
        XCTAssertNotNil(guardian.check(tool: "open_browser_url", parameters: ["Url": "chrome://settings"]))
        XCTAssertNil(guardian.check(tool: "read_url_content", parameters: ["Url": "https://meteo.gc.ca"]))
        _ = other
        for tool in ["run_command", "replace_file_content", "call_mcp_tool", "execute_browser_javascript", "browser_click_element", "outil_inconnu"] {
            XCTAssertNotNil(guardian.check(tool: tool, parameters: ["Path": "/h/.gemini/antigravity-cli/brain/conv/x.md"]), tool)
        }
    }

    func testPlanAwaitingApprovalIsShownToClaude() async throws {
        let agent = try FakeAgent(make: { home in
            let brain = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-plan").path
            let write = #"{"event":"step_update","step_update":{"conversation_id":"conv-plan","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"write_file","tool_info":{"name":"write_file","parameters":{"Path":"\#(brain)/plan.md"}}}}"#
            let initLine = StreamSample.initLine.replacingOccurrences(of: "14e63800-6228", with: "conv-plan")
            let result = #"{"event":"result","result":{"conversation_id":"conv-plan","status":"SUCCESS","response":"Validez ce plan (Proceed)."}}"#
            return """
            mkdir -p "\(brain)"
            printf '# Plan\\nGénérer un phare.' > "\(brain)/plan.md"
            printf '{"summary":"Plan du phare","requestFeedback":true,"userFacing":true}' > "\(brain)/plan.md.metadata.json"
            """ + "\n" + FakeAgent.stream([initLine, write, result])
        })
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "Génère un phare"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("# Plan\nGénérer un phare."), r.text)
        XCTAssertTrue(r.text.contains("Plan du phare"))
        XCTAssertTrue(r.text.contains("Plan approuvé : exécute-le."))
        let protected = try FileManager.default.attributesOfItem(atPath: agent.home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-plan").path)
        XCTAssertEqual(protected[.posixPermissions] as? Int, 0o700, "dossier de conversation lisible par l'utilisateur seul")
    }

    func testGeneratedImageIsReturnedAsImageContent() async throws {
        // PNG de 1 × 1 pixel, et un faux PNG (du texte) qui ne doit pas être joint.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
        let agent = try FakeAgent(make: { home in
            let brain = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-img").path
            let initLine = StreamSample.initLine.replacingOccurrences(of: "14e63800-6228", with: "conv-img")
            let result = #"{"event":"result","result":{"conversation_id":"conv-img","status":"SUCCESS","response":"Voici le phare."}}"#
            return """
            mkdir -p "\(brain)"
            printf '%s' '\(png)' | base64 -D > "\(brain)/phare_1.png"
            printf 'pas une image' > "\(brain)/faux.png"
            """ + "\n" + FakeAgent.stream([initLine, StreamSample.subagent, result])
        })
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "Un phare"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(r.images.count, 1)
        XCTAssertEqual(r.images.first?.mimeType, "image/png")
        XCTAssertNotNil(Data(base64Encoded: r.images.first?.data ?? ""))
        XCTAssertTrue(r.text.contains("Image (jointe) : "))
        XCTAssertTrue(r.text.contains("faux.png"), "le faux est cité, pas joint")
        XCTAssertTrue(r.text.contains("sous-agent image-generator"))
    }

    func testLostConversationIsReplayedOnce() async throws {
        // 1er appel : conv-1. 2e appel (--conversation conv-1) : agy ouvre conv-2 (perdue). 3e : relance avec l'historique.
        let first = StreamSample.initLine.replacingOccurrences(of: "14e63800-6228", with: "conv-1")
        let lost = StreamSample.initLine.replacingOccurrences(of: "14e63800-6228", with: "conv-2")
        let answer1 = #"{"event":"result","result":{"conversation_id":"conv-1","status":"SUCCESS","response":"Première réponse"}}"#
        let answer2 = #"{"event":"result","result":{"conversation_id":"conv-2","status":"SUCCESS","response":"Réponse rejouée"}}"#
        let agent = try FakeAgent(body: """
        n=$(cat "$DIR/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$DIR/n"
        if [ $n = 1 ]; then \(FakeAgent.stream([first, answer1])); fi
        if [ $n = 2 ]; then \(FakeAgent.stream([lost])); sleep 30; fi
        if [ $n = 3 ]; then \(FakeAgent.stream([lost, answer2])); fi
        """)
        let handler = agent.handler()
        let one = await handler.call(name: "ask_gemini", arguments: ["prompt": "Sujet : les phares"])
        let start = Date()
        let two = await handler.call(name: "ask_gemini", arguments: ["prompt": "Et le plus haut ?", "session_id": .string(sessionID(one.text))])
        XCTAssertFalse(two.isError, two.text)
        XCTAssertTrue(two.text.hasPrefix("Réponse rejouée"))
        XCTAssertTrue(two.text.contains("l'historique a été rejoué"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "la tentative perdue est arrêtée dès l'événement init")
        XCTAssertEqual(agent.calls.count, 3)
        let replay = agent.calls[2]
        XCTAssertFalse(replay.contains("--conversation"))
        let prompt = replay[replay.firstIndex(of: "--print")! + 1]
        XCTAssertTrue(prompt.contains("Sujet : les phares") && prompt.contains("Première réponse") && prompt.hasSuffix("Et le plus haut ?"))
    }

    func testCancelStopsTheRequestAndKeepsTheConversation() async throws {
        let agent = try FakeAgent(body: """
        n=$(cat "$DIR/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$DIR/n"
        if [ $n = 1 ]; then \(FakeAgent.stream([StreamSample.initLine, StreamSample.search(2, "ACTIVE", "phares"), StreamSample.delta("Le début")])); sleep 30; fi
        if [ $n = 2 ]; then \(FakeAgent.stream([StreamSample.initLine, Self.resultLine])); fi
        """)
        let handler = agent.handler(settings: agent.settings { $0.waitSeconds = 1 })
        let started = await handler.call(name: "ask_gemini", arguments: ["prompt": "Les phares"])
        XCTAssertTrue(started.text.contains("travaille encore"), started.text)
        XCTAssertTrue(started.text.contains("recherche web (« phares »)"), "le message d'attente dit ce que fait Gemini")
        let start = Date()
        let stopped = await handler.call(name: "cancel_gemini", arguments: ["job_id": .string(try jobID(started.text))])
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        XCTAssertTrue(stopped.text.contains("Demande arrêtée"), stopped.text)
        XCTAssertTrue(stopped.text.contains("Le début"))
        let next = await handler.call(name: "ask_gemini", arguments: ["prompt": "Continue", "session_id": .string(sessionID(stopped.text))])
        XCTAssertFalse(next.isError, next.text)
        XCTAssertTrue(next.text.contains("échange 1/5"), "l'arrêt ne comptait pas")
        let args = agent.calls[1]
        XCTAssertEqual(args[args.firstIndex(of: "--conversation")! + 1], "14e63800-6228", "la conversation commencée est reprise")
        let nothing = await handler.call(name: "cancel_gemini", arguments: [:])
        XCTAssertTrue(nothing.isError)
    }

    func testDeniedActionsAndNonGeminiModelInFooter() async throws {
        let initOpus = StreamSample.initLine.replacingOccurrences(of: "gemini-3.8-flash-low", with: "claude-opus-5-5-low")
        let result = #"{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"Fait.","denied_actions":[{"action":"command","display_name":"RunCommand"}]}}"#
        let agent = try FakeAgent(body: FakeAgent.stream([initOpus, result]))
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "q", "model": "opus"])
        XCTAssertTrue(r.text.contains("Actions refusées à Gemini (lecture seule, aucune question possible) : RunCommand"), r.text)
        XCTAssertTrue(r.text.contains("Réponse de claude-opus-5-5-low par Antigravity"))
    }

    func testSessionsSurviveARestartAndLastResumesTheLatest() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let directory = agent.directory.appendingPathComponent("sessions")
        let store = { SessionStore(maxTurns: 5, maxCalls: 50, directory: directory) }
        let first = await agent.handler(store: store()).call(name: "ask_gemini", arguments: ["prompt": "un"])
        let sid = sessionID(first.text)
        let file = directory.appendingPathComponent("\(sid).json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        // Nouveau processus (nouvelle mémoire) : la session et son nombre d'échanges sont retrouvés.
        let second = await agent.handler(store: store()).call(name: "ask_gemini", arguments: ["prompt": "deux", "session_id": .string(sid)])
        XCTAssertTrue(second.text.contains("échange 2/5"), second.text)
        XCTAssertEqual(agent.calls[1][agent.calls[1].firstIndex(of: "--conversation")! + 1], "conv-1")
        let third = await agent.handler(store: store()).call(name: "ask_gemini", arguments: ["prompt": "trois", "session_id": "last"])
        XCTAssertTrue(third.text.contains("session_id: \(sid) — échange 3/5"), third.text)
        let escape = await agent.handler(store: store()).call(name: "ask_gemini", arguments: ["prompt": "x", "session_id": "../../x"])
        XCTAssertTrue(escape.isError)
        let reset = await agent.handler(store: store()).call(name: "reset_gemini_session", arguments: ["session_id": .string(sid)])
        XCTAssertFalse(reset.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testStatusResolvesTheModelAndListsModelsAndSessions() async throws {
        let agent = try FakeAgent(body: """
        if [ "$1" = models ]; then printf 'Fetching available models...\\ngemini-3.8-flash-high\\tGemini 3.8 Flash (High)\\ngemini-3.8-flash-low\\tGemini 3.8 Flash (Low)\\ngpt-oss-120b-medium\\tGPT\\n'; exit 0; fi
        if [ "$1" = --version ]; then echo 'agy 9.9'; exit 0; fi
        \(FakeAgent.stream([StreamSample.initLine, Self.resultLine]))
        """)
        let handler = agent.handler(settings: agent.settings { $0.model = "flash"; $0.effort = "low"; $0.mode = "auto" })
        _ = await handler.call(name: "ask_gemini", arguments: ["prompt": "Une question"])
        let status = await handler.call(name: "gemini_status", arguments: ["test": true])
        XCTAssertFalse(status.isError, status.text)
        XCTAssertTrue(status.text.contains("flash → gemini-3.8-flash-low"), status.text)
        XCTAssertTrue(status.text.contains("mode : plan (imposé)"))
        XCTAssertTrue(status.text.contains("réglage « mode » = « auto » ignoré"))
        XCTAssertTrue(status.text.contains("Modèles disponibles : gemini-3.8-flash (high, low), gpt-oss-120b (medium)"), status.text)
        XCTAssertTrue(status.text.contains("agy --conversation 14e63800-6228"))
        XCTAssertTrue(status.text.contains("gemini : introuvable"), "le vrai gemini-cli n'est jamais lancé par les tests")
        let test = try XCTUnwrap(agent.calls.last)
        XCTAssertEqual(test[test.firstIndex(of: "--model")! + 1], "gemini-3.8-flash-low")
        XCTAssertFalse(test.contains("--effort"))
        XCTAssertTrue(status.text.contains("Test : réussi"))
    }

    func testResultWithoutJobIdNeverPicksAmongSeveral() async throws {
        let agent = try FakeAgent(body: FakeAgent.waitForRelease + FakeAgent.okJSON)
        let handler = agent.handler(settings: agent.settings { $0.waitSeconds = 1; $0.maxCallsPer10Minutes = 50 })
        _ = await handler.call(name: "ask_gemini", arguments: ["prompt": "a"])
        _ = await handler.call(name: "ask_gemini", arguments: ["prompt": "b"])
        let ambiguous = await handler.call(name: "gemini_result", arguments: [:])
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains("préciser job_id"), ambiguous.text)
        agent.release()
    }

    func testReplayKeepsTheFirstExchangeAndReportsOmissions() async throws {
        let agent = try FakeAgent(body: #"printf '{"response":"'; head -c 9000 /dev/zero | tr '\000' 'r'; printf '"}'"#)
        let handler = agent.handler(settings: agent.settings { $0.backend = .gemini; $0.maxTurnsPerSession = 20 })
        var sid: JSONValue = .null
        for index in 0..<9 {
            var args: [String: JSONValue] = ["prompt": .string(index == 0 ? "CONTEXTE " + String(repeating: "c", count: 15_000) + " QUESTION" : "q\(index)")]
            if case .string = sid { args["session_id"] = sid }
            let r = await handler.call(name: "ask_gemini", arguments: args)
            XCTAssertFalse(r.isError, String(r.text.prefix(200)))
            sid = .string(sessionID(r.text))
            if index == 8 { XCTAssertTrue(r.text.contains("historique rejoué abrégé")) }
        }
        let last = try XCTUnwrap(agent.calls.last)
        let prompt = last[last.firstIndex(of: "-p")! + 1]
        XCTAssertTrue(prompt.contains("— Demande 1 : CONTEXTE"), "le premier échange reste")
        XCTAssertTrue(prompt.contains("QUESTION"), "fin de la première demande gardée")
        XCTAssertTrue(prompt.contains("omis faute de place"))
        XCTAssertTrue(prompt.hasSuffix("Nouvelle demande : q8"))
        XCTAssertLessThan(prompt.count, ToolHandler.maxReplayCharacters + 5_000)
    }

    func testYouTubeURLAttachesTheFullTranscriptWithoutSendingItToClaude() async throws {
        // Le faux agy recopie la transcription jointe (qu'il voit dans son dossier de travail) pour la vérifier.
        let agent = try FakeAgent(body: #"cat "$DIR"/workspace/attachments/*/1-transcription-youtube.txt > "$DIR/vue.txt"; "#
                                  + FakeAgent.stream([StreamSample.initLine, StreamSample.result]))
        let ytDlp = agent.directory.appendingPathComponent("yt-dlp")
        let info = #"{"title":"Conférence","channel":"Chaîne","duration":7200,"language":"fr","subtitles":{"fr":[{"ext":"vtt","url":"https://www.youtube.com/api/timedtext?x=1"}]}}"#
        try "#!/bin/sh\nprintf '%s' '\(info)'\n".write(to: ytDlp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ytDlp.path)
        // Deux heures de sous-titres : bien plus que ce qu'une réponse d'outil peut porter.
        var vtt = "WEBVTT\n\n"
        for second in stride(from: 0, to: 7200, by: 4) {
            vtt += String(format: "%02d:%02d:%02d.000 --> %02d:%02d:%02d.500\nphrase numéro %d de la conférence\n\n",
                          second / 3600, second / 60 % 60, second % 60, second / 3600, second / 60 % 60, second % 60, second)
        }
        let captions = Data(vtt.utf8)
        let executable = agent.executable
        let handler = ToolHandler(settings: agent.settings(), store: SessionStore(maxTurns: 5, maxCalls: 10),
                                  workspace: agent.workspace, environment: Locator.environment(), home: agent.home.path,
                                  fetch: { _ in captions }, locate: { $0 == .agy ? executable : nil },
                                  locateTool: { $0 == "yt-dlp" ? ytDlp.path : nil })
        let r = await handler.call(name: "ask_gemini", arguments: ["prompt": "Résume la conférence", "youtube_url": "https://youtu.be/abc"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertLessThan(r.text.count, 5_000, "la transcription ne repasse pas par Claude")
        let seen = try String(contentsOf: agent.directory.appendingPathComponent("vue.txt"), encoding: .utf8)
        XCTAssertTrue(seen.contains("Titre : Conférence"))
        XCTAssertTrue(seen.contains("phrase numéro 7196 de la conférence"), "transcription complète, jusqu'à la fin")
        let args = try XCTUnwrap(agent.calls.first)
        let prompt = args[args.firstIndex(of: "--print")! + 1]
        XCTAssertTrue(prompt.contains("view_file"))
        XCTAssertTrue(prompt.contains("transcription complète de la vidéo YouTube « Conférence »"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent.workspace.appendingPathComponent("attachments").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: agent.workspace.appendingPathComponent("attachments").path), [],
                       "la copie est effacée après la demande")

        let bad = await handler.call(name: "ask_gemini", arguments: ["prompt": "x", "youtube_url": "https://example.com/v"])
        XCTAssertTrue(bad.isError)
    }

    func testEmbeddedCommandMatchesTheRepositoryFile() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("commands/gemini.md")
        XCTAssertEqual(GeminiCommand.text, try String(contentsOf: file, encoding: .utf8),
                       "GeminiCommand.swift doit être régénéré depuis commands/gemini.md")
        XCTAssertFalse(GeminiCommand.previousHashes.contains(ClaudeRegistration.sha256(Data(GeminiCommand.text.utf8))))
    }

    func testInstructionsAndDescriptionsAgreeOnYouTube() throws {
        let instructions = ServerInfo.instructions(settings: Settings())
        XCTAssertTrue(instructions.contains("youtube_transcript") && instructions.contains("files") && instructions.contains("gemini_result"))
        let handler = try FakeAgent(body: "true").handler()
        let ask = try XCTUnwrap(handler.definitions.first { $0["name"]?.string == "ask_gemini" })
        XCTAssertNotNil(ask["inputSchema"]?["properties"]?["youtube_url"])
        XCTAssertFalse(ask["description"]?.string?.contains("analyse d'une chaîne ou d'une vidéo YouTube") ?? true)
        XCTAssertFalse(instructions.contains("Google Maps"))
        // Le modèle et l'effort se choisissent d'après la demande, partout (serveur et commande /gemini).
        XCTAssertTrue(instructions.contains(ToolHandler.choiceGuide))
        XCTAssertTrue(ask["inputSchema"]?["properties"]?["model"]?["description"]?.string?.contains(ToolHandler.choiceGuide) ?? false)
        XCTAssertTrue(GeminiCommand.text.contains("Passe toujours `model` et `effort`"))
        XCTAssertFalse(GeminiCommand.text.contains("le serveur applique ses valeurs par défaut"))
    }

    func testScheduleIsOnlyAllowedToWaitForTheImageSubagent() {
        let guardian = ReadOnlyGuard(expectedConversation: nil, home: "/h", workspace: URL(fileURLWithPath: "/w/workspace"), attachments: nil)
        let wait: JSONValue = ["DurationSeconds": "60", "Prompt": "Vérifier si le sous-agent a terminé"]
        XCTAssertNotNil(guardian.check(tool: "schedule", parameters: wait), "sans sous-agent : rien à attendre")
        XCTAssertNil(guardian.check(tool: "invoke_subagent", parameters: ["subagent_types": ["image-generator"]]))
        XCTAssertNil(guardian.check(tool: "schedule", parameters: wait))
        XCTAssertNil(guardian.check(tool: "schedule", parameters: ["DurationSeconds": 30, "Prompt": "x"]))
        XCTAssertNotNil(guardian.check(tool: "schedule", parameters: ["DurationSeconds": "86400", "Prompt": "x"]), "délai borné")
        XCTAssertNotNil(guardian.check(tool: "schedule", parameters: ["DurationSeconds": "60", "Prompt": "x", "Cron": "* * * * *"]), "jamais répété")
        XCTAssertNotNil(guardian.check(tool: "schedule", parameters: ["Prompt": "x"]))
    }

    func testRecursiveSearchAtTheRootIsRefusedWhenOtherRequestsHaveFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("garde-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("attachments/moi"), withIntermediateDirectories: true)
        let guardian = ReadOnlyGuard(expectedConversation: nil, home: root.path, workspace: workspace,
                                     attachments: workspace.appendingPathComponent("attachments/moi"))
        XCTAssertNil(guardian.check(tool: "grep_search", parameters: ["SearchPath": .string(workspace.path), "Query": "x"]))
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("attachments/autre"), withIntermediateDirectories: true)
        XCTAssertNotNil(guardian.check(tool: "grep_search", parameters: ["SearchPath": .string(workspace.path), "Query": "x"]))
        XCTAssertNotNil(guardian.check(tool: "find_by_name", parameters: ["Pattern": "*"]), "sans chemin : le dossier de travail")
        XCTAssertNil(guardian.check(tool: "list_dir", parameters: ["DirectoryPath": .string(workspace.path)]), "list_dir n'est pas récursif")
        XCTAssertNil(guardian.check(tool: "grep_search", parameters: ["SearchPath": .string(workspace.appendingPathComponent("attachments/moi").path)]))
    }

    func testCancelWithASessionNeverStopsAnotherSession() async throws {
        let agent = try FakeAgent(body: """
        n=$(cat "$DIR/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$DIR/n"
        if [ $n = 1 ]; then \(FakeAgent.okJSON); else \(FakeAgent.waitForRelease) \(FakeAgent.okJSON); fi
        """)
        let handler = agent.handler(settings: agent.settings { $0.waitSeconds = 1 })
        let finished = await handler.call(name: "ask_gemini", arguments: ["prompt": "A"])
        let sessionA = sessionID(finished.text)
        let other = await handler.call(name: "ask_gemini", arguments: ["prompt": "B"])
        XCTAssertTrue(other.text.contains("travaille encore"))
        let refused = await handler.call(name: "cancel_gemini", arguments: ["session_id": .string(sessionA)])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Aucune demande en cours pour la session \(sessionA)"), refused.text)
        agent.release()
        let result = await handler.call(name: "gemini_result", arguments: ["job_id": .string(try jobID(other.text))])
        XCTAssertTrue(result.text.hasPrefix("Bonjour de Gemini"), "la demande de B n'a pas été arrêtée : \(result.text)")
    }

    func testLastNeverFallsBackToAnOlderSessionAndResetHoldsAcrossProcesses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = SessionStore(maxTurns: 5, maxCalls: 50, directory: directory)
        let older = try await a.begin(sessionId: nil)
        await a.finish(id: older.id, prompt: "ancienne", response: "r", conversationId: "c-old")
        try await Task.sleep(nanoseconds: 20_000_000)
        let recent = try await a.begin(sessionId: nil)
        await a.finish(id: recent.id, prompt: "récente", response: "r", conversationId: "c-new")
        _ = try await a.begin(sessionId: recent.id)
        // La plus récente est occupée : « last » le dit, il ne recule pas vers l'ancienne.
        do {
            _ = try await a.begin(sessionId: "last")
            XCTFail("occupée attendu")
        } catch let error as SessionError {
            XCTAssertEqual(error, .busy(id: recent.id))
        }
        await a.abort(id: recent.id)
        // Un autre processus vivant tient la session (verrou avec son pid) : elle est occupée…
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        let lock = directory.appendingPathComponent("\(recent.id).lock")
        try Data("\(other.processIdentifier)".utf8).write(to: lock)
        let b = SessionStore(maxTurns: 5, maxCalls: 50, directory: directory)
        do {
            _ = try await b.begin(sessionId: recent.id)
            XCTFail("verrou attendu")
        } catch let error as SessionError {
            XCTAssertEqual(error, .busy(id: recent.id))
        }
        // … et dès que ce processus est mort, son verrou est ignoré.
        other.terminate()
        other.waitUntilExit()
        let resumed = try await b.begin(sessionId: recent.id)
        await b.abort(id: resumed.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path), "verrou retiré à la fin de l'échange")
        // … et un reset fait ailleurs tient.
        let wasReset = await b.reset(id: recent.id)
        XCTAssertTrue(wasReset)
        do {
            _ = try await a.begin(sessionId: recent.id)
            XCTFail("session effacée attendue")
        } catch let error as SessionError {
            XCTAssertEqual(error, .unknown(id: recent.id))
        }
        let latest = try await a.begin(sessionId: "last")
        XCTAssertEqual(latest.id, older.id)
    }

    func testSettingsEffortIncompatibleWithTheCalledModelIsIgnored() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let handler = agent.handler(settings: agent.settings { $0.effort = "xhigh" })
        let r = await handler.call(name: "ask_gemini", arguments: ["prompt": "q", "model": "flash"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("effort « xhigh » des réglages ignoré"), r.text)
        let args = try XCTUnwrap(agent.calls.first)
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "gemini-3.8-flash")
        XCTAssertFalse(args.contains("--effort"))
        let refused = await handler.call(name: "ask_gemini", arguments: ["prompt": "q", "model": "flash", "effort": "max"])
        XCTAssertTrue(refused.isError, "demandé à l'appel : refusé")
    }

    func testAgySessionResumedWithGeminiCliReplaysTheHistory() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let directory = agent.directory.appendingPathComponent("sessions")
        let first = await agent.handler(store: SessionStore(maxTurns: 5, maxCalls: 50, directory: directory))
            .call(name: "ask_gemini", arguments: ["prompt": "Sujet : les phares"])
        let gemini = agent.handler(settings: agent.settings { $0.backend = .gemini },
                                   store: SessionStore(maxTurns: 5, maxCalls: 50, directory: directory))
        _ = await gemini.call(name: "ask_gemini", arguments: ["prompt": "Et le plus haut ?", "session_id": .string(sessionID(first.text))])
        let args = try XCTUnwrap(agent.calls.last)
        let prompt = args[args.firstIndex(of: "-p")! + 1]
        XCTAssertTrue(prompt.contains("Cadre fixé par le pont") && prompt.contains("Sujet : les phares"), prompt)
    }

    func testCompactModels() {
        XCTAssertEqual(ToolHandler.compactModels("Fetching...\ngemini-4-argon-medium\tA\ngemini-4-argon-high\tB\nautre\n"), "gemini-4-argon (medium, high)")
        XCTAssertNil(ToolHandler.compactModels("rien"))
    }
}

final class ClientAndProgressTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [JSONValue] = []
        var send: @Sendable (JSONValue) -> Void { { [self] value in lock.lock(); messages.append(value); lock.unlock() } }
        var all: [JSONValue] { lock.lock(); defer { lock.unlock() }; return messages }
        func waitForResponse(id: Int, timeout: TimeInterval = 20) async -> JSONValue? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let r = all.first(where: { $0["id"]?.int == id }) { return r }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return nil
        }
    }

    private func run(client: String, agent: FakeAgent, progressInterval: TimeInterval = 10) async -> (JSONValue?, [JSONValue]) {
        let server = MCPServer(name: "t", version: "1", instructions: "i",
                               tools: agent.handler(settings: agent.settings { $0.waitSeconds = 1 }), progressInterval: progressInterval)
        let sink = Sink()
        server.receive(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"\#(client)","version":"1"}}}"#, send: sink.send)
        _ = await sink.waitForResponse(id: 1)
        server.receive(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_gemini","arguments":{"prompt":"q"},"_meta":{"progressToken":"tok"}}}"#, send: sink.send)
        let response = await sink.waitForResponse(id: 2)
        return (response, sink.all)
    }

    private func text(_ response: JSONValue?) -> String {
        response?["result"]?["content"]?.array?.first?["text"]?.string ?? ""
    }

    func testClaudeCodeWaitsForTheAnswerOthersGetAJobId() async throws {
        let slow = FakeAgent.stream([StreamSample.initLine, StreamSample.search(2, "ACTIVE", "phares")]) + "; sleep 2.5; "
            + FakeAgent.stream([StreamSample.result])
        let (code, messages) = await run(client: "claude-code", agent: try FakeAgent(body: slow), progressInterval: 0.5)
        XCTAssertTrue(text(code).hasPrefix("Environ 1,88 $"), "Claude Code n'a pas la coupure de 60 s : une seule réponse")
        let progress = messages.filter { $0["method"]?.string == "notifications/progress" }
        XCTAssertTrue(progress.contains { $0["params"]?["message"]?.string?.contains("recherche « phares »") == true },
                      "la progression dit ce que fait Gemini : \(progress)")
        let steps = progress.compactMap { $0["params"]?["progress"]?.double }
        XCTAssertEqual(steps, steps.sorted(), "compteur croissant")
        let responseIndex = try XCTUnwrap(messages.firstIndex { $0["id"]?.int == 2 })
        XCTAssertFalse(messages[(responseIndex + 1)...].contains { $0["method"]?.string == "notifications/progress" }, "rien après la réponse")

        let (desktop, _) = await run(client: "claude-ai", agent: try FakeAgent(body: slow))
        XCTAssertTrue(text(desktop).contains("travaille encore"))
    }

    func testImagesBecomeImageContent() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
        let agent = try FakeAgent(make: { home in
            let brain = home.appendingPathComponent(".gemini/antigravity-cli/brain/14e63800-6228").path
            return """
            mkdir -p "\(brain)"; printf '%s' '\(png)' | base64 -D > "\(brain)/a.png"
            """ + "\n" + FakeAgent.stream([StreamSample.initLine, StreamSample.result])
        })
        let (response, _) = await run(client: "claude-code", agent: agent)
        let content = response?["result"]?["content"]?.array ?? []
        XCTAssertEqual(content.map { $0["type"]?.string }, ["text", "image"])
        XCTAssertEqual(content.last?["mimeType"]?.string, "image/png")
    }
}

final class JobBoardTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    func testDeliveryPruningAndCancellation() async throws {
        let clock = Clock()
        let board = JobBoard(now: { clock.now })
        let id = try XCTUnwrap(board.start(label: "rapide") { _ in .ok("fini") })
        guard case .finished(let result, let again) = await board.wait(id: id, seconds: 2) else { return XCTFail() }
        XCTAssertEqual(result.text, "fini")
        XCTAssertFalse(again)
        guard case .finished(_, true) = await board.wait(id: id, seconds: 0) else { return XCTFail("remise une seconde fois") }
        clock.advance(601)
        let expired = await board.wait(id: id, seconds: 0)
        XCTAssertEqual(expired, .unknown, "oubliée 10 minutes après la remise")

        let forgotten = try XCTUnwrap(board.start { _ in .ok("jamais réclamée") })
        while board.runningCount > 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(board.soleUndeliveredID, forgotten)
        clock.advance(1801)
        XCTAssertNil(board.soleUndeliveredID, "oubliée 30 minutes après la fin")

        let long = try XCTUnwrap(board.start { _ in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return .fail("arrêtée") }
            return .ok("trop tard")
        })
        XCTAssertTrue(board.cancel(id: long))
        guard case .finished(let stopped, _) = await board.wait(id: long, seconds: 5) else { return XCTFail() }
        XCTAssertEqual(stopped.text, "arrêtée")
        XCTAssertFalse(board.cancel(id: long), "déjà finie")
    }

    func testCancelledWaitDoesNotConsumeTheAnswer() async throws {
        let board = JobBoard()
        let id = try XCTUnwrap(board.start { _ in .ok("réponse") })
        while board.runningCount > 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        let waiting = Task { await board.wait(id: id, seconds: 5) }
        waiting.cancel()
        _ = await waiting.value
        guard case .finished(_, let again) = await board.wait(id: id, seconds: 1) else { return XCTFail() }
        XCTAssertFalse(again, "l'attente annulée n'a pas consommé la réponse")
    }

    func testRefusesAFourthRequest() throws {
        let board = JobBoard()
        for _ in 0..<JobBoard.maxRunning {
            XCTAssertNotNil(board.start { _ in try? await Task.sleep(nanoseconds: 5_000_000_000); return .ok("") })
        }
        XCTAssertNil(board.start { _ in .ok("") })
        XCTAssertEqual(board.runningCount, JobBoard.maxRunning)
        board.summaries.forEach { _ = board.cancel(id: $0.id) }
    }
}

final class StdioAndProcessTests: XCTestCase {
    func testWritingToAClosedPipeFailsWithoutCrashing() {
        signal(SIGPIPE, SIG_IGN)
        let pipe = Pipe()
        try? pipe.fileHandleForReading.close()
        XCTAssertFalse(StdioWriter.writeAll(fd: pipe.fileHandleForWriting.fileDescriptor, data: Data("x".utf8)))
        let open = Pipe()
        XCTAssertTrue(StdioWriter.writeAll(fd: open.fileHandleForWriting.fileDescriptor, data: Data("bonjour".utf8)))
    }

    private func sh(_ script: String, timeout: TimeInterval = 20, onStdout: (@Sendable (Data) -> String?)? = nil) async throws -> ProcessResult {
        try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], environment: Locator.environment(),
                                    workingDirectory: FileManager.default.temporaryDirectory, timeout: timeout, onStdout: onStdout)
    }

    func testTimeoutKillsTheWholeProcessGroup() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("petit-enfant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // Le petit-enfant ignore SIGTERM : seul un SIGKILL du groupe l'arrête.
        _ = try await sh("trap '' TERM; (trap '' TERM; exec sleep 25) & echo $! > '\(pidFile.path)'; wait", timeout: 1)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertFalse(alive, "aucun petit-enfant orphelin")
    }

    func testProgramThatExitedIsNotMarkedTimedOut() async throws {
        let r = try await sh(#"(sleep 3 &) ; printf '{"status":"SUCCESS","response":"ok"}'; sleep 0.6"#, timeout: 1)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertFalse(r.timedOut)
    }

    func testTruncatedOutputStaysContiguous() async throws {
        let max = ProcessRunner.maxOutputBytes
        let r = try await sh("head -c \(max - 10) /dev/zero | tr '\\000' 'a'; sleep 0.2; head -c 100 /dev/zero | tr '\\000' 'b'; sleep 0.2; printf FIN")
        XCTAssertTrue(r.truncated)
        XCTAssertFalse(r.stdout.hasSuffix("FIN"), "rien n'est ajouté après un bloc refusé")
    }

    func testOutputReaderCanStopTheProgram() async throws {
        let start = Date()
        let r = try await sh("echo debut; echo INTERDIT; sleep 30", onStdout: { chunk in
            String(decoding: chunk, as: UTF8.self).contains("INTERDIT") ? "arrêt demandé" : nil
        })
        XCTAssertEqual(r.stopReason, "arrêt demandé")
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }
}
