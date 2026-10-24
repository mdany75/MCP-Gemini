import XCTest
@testable import MCPGeminiKit

final class ToolHandlerTests: XCTestCase {
    func testFirstCallAddsPreambleAndReturnsSession() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let result = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "Quelle heure ?"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.hasPrefix("Bonjour de Gemini"))
        XCTAssertTrue(result.text.contains("échange 1/5"))
        let args = try XCTUnwrap(agent.calls.first)
        let prompt = args[args.firstIndex(of: "--print")! + 1]
        XCTAssertTrue(prompt.hasSuffix("Quelle heure ?"))
        XCTAssertTrue(prompt.contains("Claude"), "la consigne doit précéder la question")
        XCTAssertFalse(args.contains("--conversation"))
        XCTAssertTrue(args.contains("plan"))
    }

    func testFollowUpResumesConversationWithoutPreamble() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let handler = agent.handler()
        let first = await handler.call(name: "ask_gemini", arguments: ["prompt": "un"])
        let sid = first.text.components(separatedBy: "session_id: ")[1].components(separatedBy: " ")[0]
        let second = await handler.call(name: "ask_gemini", arguments: ["prompt": "deux", "session_id": .string(sid)])
        XCTAssertFalse(second.isError, second.text)
        XCTAssertTrue(second.text.contains("échange 2/5"))
        let args = agent.calls[1]
        XCTAssertEqual(args[args.firstIndex(of: "--print")! + 1], "deux")
        XCTAssertEqual(args[args.firstIndex(of: "--conversation")! + 1], "conv-1")
    }

    func testTurnLimitRefusesAndNeverCallsTheProgram() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let handler = agent.handler(settings: agent.settings { $0.maxTurnsPerSession = 2 })
        var sid: JSONValue = .null
        for _ in 0..<2 {
            var args: [String: JSONValue] = ["prompt": "q"]
            if case .string = sid { args["session_id"] = sid }
            let r = await handler.call(name: "ask_gemini", arguments: args)
            XCTAssertFalse(r.isError, r.text)
            sid = .string(r.text.components(separatedBy: "session_id: ")[1].components(separatedBy: " ")[0])
        }
        let refused = await handler.call(name: "ask_gemini", arguments: ["prompt": "q", "session_id": sid])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Limite de 2"))
        XCTAssertEqual(agent.calls.count, 2)
    }

    func testGeminiBackendReplaysHistory() async throws {
        let agent = try FakeAgent(body: #"printf '%s' '{"session_id":"s","response":"réponse G"}'"#)
        let handler = agent.handler(settings: agent.settings { $0.backend = .gemini })
        // Le faux programme s'appelle « agy » : on l'indique par `executable`.
        let first = await handler.call(name: "ask_gemini", arguments: ["prompt": "première"])
        XCTAssertFalse(first.isError, first.text)
        let sid = first.text.components(separatedBy: "session_id: ")[1].components(separatedBy: " ")[0]
        _ = await handler.call(name: "ask_gemini", arguments: ["prompt": "seconde", "session_id": .string(sid)])
        let args = agent.calls[1]
        let prompt = args[args.firstIndex(of: "-p")! + 1]
        XCTAssertTrue(prompt.contains("première"))
        XCTAssertTrue(prompt.contains("réponse G"))
        XCTAssertTrue(prompt.hasSuffix("seconde"))
    }

    func testErrorIsReportedAndDoesNotCountAsATurn() async throws {
        let agent = try FakeAgent(body: #"printf '%s' '{"conversation_id":"","status":"ERROR","response":"","error":"quota"}'; exit 3"#)
        let handler = agent.handler(settings: agent.settings { $0.maxTurnsPerSession = 1 })
        let r = await handler.call(name: "ask_gemini", arguments: ["prompt": "q"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("quota"))
        XCTAssertTrue(r.text.contains("ne compte pas"))
    }

    func testAuthFailureGivesLoginHintQuickly() async throws {
        let agent = try FakeAgent(body: "echo 'Authentication required. Please visit the URL to log in:'; sleep 60")
        let start = Date()
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "q"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("lancer `agy`"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testMissingExecutable() async {
        var settings = Settings()
        settings.executable = "/nonexistent/agy"
        let handler = ToolHandler(settings: settings, store: SessionStore(maxTurns: 5, maxCalls: 5))
        let r = await handler.call(name: "ask_gemini", arguments: ["prompt": "q"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("/nonexistent/agy"))
    }

    func testInvalidArguments() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let handler = agent.handler()
        let empty = await handler.call(name: "ask_gemini", arguments: ["prompt": "   "])
        let wrongType = await handler.call(name: "ask_gemini", arguments: ["prompt": 42])
        let huge = await handler.call(name: "ask_gemini", arguments: ["prompt": .string(String(repeating: "a", count: ToolHandler.maxPromptCharacters + 1))])
        let unknown = await handler.call(name: "nope", arguments: [:])
        XCTAssertTrue(empty.isError && wrongType.isError && huge.isError && unknown.isError)
        XCTAssertTrue(agent.calls.isEmpty)
    }

    func testPromptWithShellMetacharactersIsPassedVerbatim() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let nasty = "$(touch /tmp/pwned); `id` \"quote\" 'apos' ; rm -rf ~"
        _ = await agent.handler(settings: agent.settings { $0.preamble = "" }).call(name: "ask_gemini", arguments: ["prompt": .string(nasty)])
        let args = try XCTUnwrap(agent.calls.first)
        XCTAssertEqual(args[args.firstIndex(of: "--print")! + 1], nasty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }

    func testVeryLongResponseIsCapped() async throws {
        let agent = try FakeAgent(body: #"printf '{"conversation_id":"c","status":"SUCCESS","response":"'; head -c 120000 /dev/zero | tr '\000' 'a'; printf '"}'"#)
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "q"])
        XCTAssertFalse(r.isError, String(r.text.prefix(200)))
        XCTAssertLessThan(r.text.count, ToolHandler.maxResponseCharacters + 500)
        XCTAssertTrue(r.text.contains("réponse tronquée"))
    }

    func testReplayedHistoryIsBounded() async throws {
        let agent = try FakeAgent(body: #"printf '{"response":"'; head -c 30000 /dev/zero | tr '\000' 'b'; printf '"}'"#)
        let handler = agent.handler(settings: agent.settings { $0.backend = .gemini; $0.maxTurnsPerSession = 20 })
        var sid: JSONValue = .null
        for _ in 0..<8 {
            var args: [String: JSONValue] = ["prompt": "q"]
            if case .string = sid { args["session_id"] = sid }
            let r = await handler.call(name: "ask_gemini", arguments: args)
            XCTAssertFalse(r.isError, String(r.text.prefix(200)))
            sid = .string(r.text.components(separatedBy: "session_id: ")[1].components(separatedBy: " ")[0])
        }
        let last = try XCTUnwrap(agent.calls.last)
        let prompt = last[last.firstIndex(of: "-p")! + 1]
        XCTAssertLessThan(prompt.count, ToolHandler.maxReplayCharacters + 5_000)
    }

    func testStatusTestCountsInTheRateLimit() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let handler = agent.handler(settings: agent.settings { $0.maxCallsPer10Minutes = 1 })
        let first = await handler.call(name: "gemini_status", arguments: ["test": true])
        XCTAssertFalse(first.isError, first.text)
        let second = await handler.call(name: "gemini_status", arguments: ["test": true])
        XCTAssertTrue(second.isError)
        XCTAssertTrue(second.text.contains("en 10 minutes"))
    }

    func testSlowAnswerReturnsAJobIdThenTheResult() async throws {
        let agent = try FakeAgent(body: "sleep 3; " + FakeAgent.okJSON)
        let handler = agent.handler(settings: agent.settings { $0.waitSeconds = 1 })
        let first = await handler.call(name: "ask_gemini", arguments: ["prompt": "q"])
        XCTAssertFalse(first.isError, first.text)
        XCTAssertTrue(first.text.contains("travaille encore"))
        let id = try XCTUnwrap(first.text.components(separatedBy: "job_id = \"").dropFirst().first?.components(separatedBy: "\"").first)
        let still = await handler.call(name: "gemini_result", arguments: ["job_id": .string(id)])
        XCTAssertTrue(still.text.contains("travaille encore") || still.text.hasPrefix("Bonjour"))
        let done = await handler.call(name: "gemini_result", arguments: ["job_id": .string(id)])
        let final = done.text.hasPrefix("Bonjour de Gemini") ? done : await handler.call(name: "gemini_result", arguments: ["job_id": .string(id)])
        XCTAssertTrue(final.text.hasPrefix("Bonjour de Gemini"), final.text)
        XCTAssertTrue(final.text.contains("session_id"))
        let again = await handler.call(name: "gemini_result", arguments: ["job_id": .string(id)])
        XCTAssertTrue(again.isError, "une réponse n'est remise qu'une fois")
    }

    func testTooManyRunningJobsAreRefused() async throws {
        let agent = try FakeAgent(body: "sleep 4; " + FakeAgent.okJSON)
        let handler = agent.handler(settings: agent.settings { $0.waitSeconds = 1; $0.maxCallsPer10Minutes = 50 })
        for _ in 0..<JobBoard.maxRunning {
            let r = await handler.call(name: "ask_gemini", arguments: ["prompt": "q"])
            XCTAssertFalse(r.isError, r.text)
        }
        let refused = await handler.call(name: "ask_gemini", arguments: ["prompt": "q"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("en cours"))
        ProcessRegistry.terminateAll(grace: 3)
    }

    func testModelAndEffortArgumentsReachTheProgram() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let handler = agent.handler(settings: agent.settings { $0.effort = "low" })
        _ = await handler.call(name: "ask_gemini", arguments: ["prompt": "q", "model": "flash", "effort": "high"])
        _ = await handler.call(name: "ask_gemini", arguments: ["prompt": "q"])
        let withModel = agent.calls[0]
        XCTAssertEqual(withModel[withModel.firstIndex(of: "--model")! + 1], "gemini-3.8-flash-high")
        XCTAssertFalse(withModel.contains("--effort"))
        let byDefault = agent.calls[1]
        XCTAssertFalse(byDefault.contains("--model"))
        XCTAssertEqual(byDefault[byDefault.firstIndex(of: "--effort")! + 1], "low")
    }

    func testInvalidEffortIsRefused() async throws {
        let agent = try FakeAgent(body: FakeAgent.okJSON)
        let r = await agent.handler().call(name: "ask_gemini", arguments: ["prompt": "q", "effort": "turbo"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(agent.calls.isEmpty)
    }

    func testResultWithoutAnyJob() async throws {
        let handler = try FakeAgent(body: "true").handler()
        let r = await handler.call(name: "gemini_result", arguments: [:])
        XCTAssertTrue(r.isError)
    }

    func testResetAndStatus() async throws {
        let agent = try FakeAgent(body: "echo 'agy 9.9'")
        let handler = agent.handler()
        let unknown = await handler.call(name: "reset_gemini_session", arguments: ["session_id": "nope"])
        XCTAssertTrue(unknown.isError)
        let status = await handler.call(name: "gemini_status", arguments: [:])
        XCTAssertFalse(status.isError)
        XCTAssertTrue(status.text.contains("agy 9.9"))
    }

    func testToolDefinitionsAreWellFormed() throws {
        let handler = try FakeAgent(body: "true").handler()
        let names = handler.definitions.compactMap { $0["name"]?.string }
        XCTAssertEqual(names, ["ask_gemini", "gemini_result", "gemini_status", "reset_gemini_session"])
        for definition in handler.definitions {
            XCTAssertEqual(definition["inputSchema"]?["type"]?.string, "object")
            XCTAssertNotNil(definition["description"]?.string)
        }
    }
}

final class MCPServerTests: XCTestCase {
    private func server(_ agent: FakeAgent, progressInterval: TimeInterval = 10) -> MCPServer {
        MCPServer(name: "t", version: "1", instructions: "i", tools: agent.handler(), progressInterval: progressInterval)
    }

    private func reply(_ server: MCPServer, _ line: String) async throws -> JSONValue {
        let text = await server.handle(line: line)
        return try JSONCoding.parse(try XCTUnwrap(text))
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [JSONValue] = []
        var send: @Sendable (JSONValue) -> Void { { [self] value in lock.lock(); messages.append(value); lock.unlock() } }
        var all: [JSONValue] { lock.lock(); defer { lock.unlock() }; return messages }
        func response(id: Int) -> JSONValue? { all.first { $0["id"]?.int == id } }
        func waitForResponse(id: Int, timeout: TimeInterval = 20) async -> JSONValue? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let r = response(id: id) { return r }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return nil
        }
    }

    func testInitializeNegotiatesVersion() async throws {
        let s = server(try FakeAgent(body: "true"))
        let line = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#
        let response = try await reply(s, line)
        XCTAssertEqual(response["result"]?["protocolVersion"]?.string, "2024-11-05")
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"]?.string, "t")
        let unknown = try await reply(s, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999"}}"#)
        XCTAssertEqual(unknown["result"]?["protocolVersion"]?.string, MCPServer.supportedProtocolVersions[0])
    }

    func testProtocolErrors() async throws {
        let s = server(try FakeAgent(body: "true"))
        let bad = try await reply(s, "{pas du json")
        XCTAssertEqual(bad["error"]?["code"]?.int, JSONRPCError.parseError)
        let unknown = try await reply(s, #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)
        XCTAssertEqual(unknown["error"]?["code"]?.int, JSONRPCError.methodNotFound)
        let noName = try await reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{}}"#)
        XCTAssertEqual(noName["error"]?["code"]?.int, JSONRPCError.invalidParams)
        let note = await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(note)
        let nonObject = try await reply(s, "[1,2]")
        XCTAssertEqual(nonObject["error"]?["code"]?.int, JSONRPCError.invalidRequest)
    }

    func testPingAnswersWhileAToolCallIsRunning() async throws {
        let agent = try FakeAgent(body: "sleep 3; " + FakeAgent.okJSON)
        let s = server(agent)
        let sink = Sink()
        s.receive(line: #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"ask_gemini","arguments":{"prompt":"q"}}}"#, send: sink.send)
        try await Task.sleep(nanoseconds: 500_000_000)
        s.receive(line: #"{"jsonrpc":"2.0","id":11,"method":"ping"}"#, send: sink.send)
        let ping = await sink.waitForResponse(id: 11, timeout: 2)
        XCTAssertNotNil(ping, "ping doit répondre sans attendre Gemini")
        XCTAssertNil(sink.response(id: 10))
        let call = await sink.waitForResponse(id: 10)
        XCTAssertEqual(call?["result"]?["isError"]?.bool, false)
    }

    func testCancelledRequestStopsWaitingButGeminiKeepsWorking() async throws {
        // Claude Desktop annule l'appel à ~60 s : la réponse doit rester récupérable.
        let agent = try FakeAgent(body: "sleep 3; " + FakeAgent.okJSON)
        let s = server(agent)
        let sink = Sink()
        let start = Date()
        s.receive(line: #"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"ask_gemini","arguments":{"prompt":"q"}}}"#, send: sink.send)
        try await Task.sleep(nanoseconds: 700_000_000)
        s.receive(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":20}}"#, send: sink.send)
        _ = await sink.waitForResponse(id: 20, timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "l'attente s'arrête dès l'annulation")
        // Le travail continue : sans job_id (jamais reçu), gemini_result prend la demande la plus récente.
        s.receive(line: #"{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"gemini_result","arguments":{}}}"#, send: sink.send)
        let result = await sink.waitForResponse(id: 21, timeout: 15)
        XCTAssertTrue(result?["result"]?["content"]?.array?.first?["text"]?.string?.hasPrefix("Bonjour de Gemini") ?? false,
                      "\(String(describing: result))")
    }

    func testProgressNotificationsWhenTokenGiven() async throws {
        let agent = try FakeAgent(body: "sleep 2; " + FakeAgent.okJSON)
        let s = server(agent, progressInterval: 0.4)
        let sink = Sink()
        s.receive(line: #"{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"ask_gemini","arguments":{"prompt":"q"},"_meta":{"progressToken":"tok"}}}"#, send: sink.send)
        _ = await sink.waitForResponse(id: 30)
        let progress = sink.all.filter { $0["method"]?.string == "notifications/progress" }
        XCTAssertGreaterThanOrEqual(progress.count, 2)
        XCTAssertEqual(progress.first?["params"]?["progressToken"]?.string, "tok")
    }

    func testNoProgressWithoutToken() async throws {
        let agent = try FakeAgent(body: "sleep 1; " + FakeAgent.okJSON)
        let s = server(agent, progressInterval: 0.2)
        let sink = Sink()
        s.receive(line: #"{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"ask_gemini","arguments":{"prompt":"q"}}}"#, send: sink.send)
        _ = await sink.waitForResponse(id: 31)
        XCTAssertTrue(sink.all.filter { $0["method"]?.string == "notifications/progress" }.isEmpty)
    }
}
