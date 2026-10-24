import XCTest
@testable import MCPGeminiKit

final class BackendTests: XCTestCase {
    private func result(stdout: String = "", stderr: String = "", code: Int32 = 0, timedOut: Bool = false,
                        abortedOn: String? = nil, truncated: Bool = false) -> ProcessResult {
        ProcessResult(stdout: stdout, stderr: stderr, exitCode: code, timedOut: timedOut, abortedOn: abortedOn, truncated: truncated)
    }

    func testAgyArguments() {
        let args = Backend.arguments(kind: .agy, prompt: "salut", model: "m1", mode: "plan", effort: "low",
                                     conversationId: "c-9", timeoutSeconds: 120)
        XCTAssertEqual(args, ["--print", "salut", "--output-format", "json", "--print-timeout", "120s",
                              "--mode", "plan", "--model", "m1", "--effort", "low", "--conversation", "c-9"])
    }

    func testAgyArgumentsMinimal() {
        let args = Backend.arguments(kind: .agy, prompt: "x", model: nil, mode: nil, conversationId: nil, timeoutSeconds: 30)
        XCTAssertEqual(args, ["--print", "x", "--output-format", "json", "--print-timeout", "30s"])
    }

    func testPromptStartingWithDashStaysAValue() {
        let args = Backend.arguments(kind: .agy, prompt: "--dangerously-skip-permissions", model: nil, mode: nil,
                                     conversationId: nil, timeoutSeconds: 30)
        XCTAssertEqual(args[0], "--print")
        XCTAssertEqual(args[1], "--dangerously-skip-permissions")
    }

    func testNulBytesAreStrippedFromArguments() {
        let args = Backend.arguments(kind: .agy, prompt: "a\u{0}b", model: "m\u{0}x", mode: nil, conversationId: nil, timeoutSeconds: 30)
        XCTAssertEqual(args[1], "ab")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "mx")
    }

    func testGeminiArguments() {
        let args = Backend.arguments(kind: .gemini, prompt: "salut", model: "g", mode: "plan", conversationId: "ignoré", timeoutSeconds: 30)
        XCTAssertEqual(args, ["-p", "salut", "--output-format", "json", "--skip-trust", "--approval-mode", "plan", "-m", "g"])
    }

    func testParseAgySuccess() {
        let json = #"{"conversation_id":"abc","status":"SUCCESS","response":"ok\n","duration_seconds":3}"#
        let reply = Backend.parse(kind: .agy, result: result(stdout: json), timeoutSeconds: 60)
        XCTAssertEqual(reply, BridgeReply(response: "ok\n", conversationId: "abc", error: nil))
    }

    func testParseAgyErrorStatus() {
        let json = #"{"conversation_id":"","status":"ERROR","response":"","error":"quota dépassé"}"#
        let reply = Backend.parse(kind: .agy, result: result(stdout: json, code: 3), timeoutSeconds: 60)
        XCTAssertEqual(reply.error, "quota dépassé")
        XCTAssertNil(reply.conversationId)
    }

    func testParseAgyNoiseBeforeJSON() {
        let out = "avertissement\n" + #"{"conversation_id":"abc","status":"SUCCESS","response":"salut"}"# + "\n"
        let reply = Backend.parse(kind: .agy, result: result(stdout: out), timeoutSeconds: 60)
        XCTAssertEqual(reply.response, "salut")
        XCTAssertNil(reply.error)
    }

    func testParseGemini() {
        let ok = Backend.parse(kind: .gemini, result: result(stdout: #"{"session_id":"s1","response":"yo","stats":{}}"#), timeoutSeconds: 60)
        XCTAssertEqual(ok.response, "yo")
        XCTAssertNil(ok.conversationId, "gemini-cli : l'historique est rejoué, pas de reprise par identifiant")
        let ko = Backend.parse(kind: .gemini, result: result(stdout: #"{"session_id":"s1","error":{"type":"Error","message":"pas connecté","code":41}}"#, code: 41), timeoutSeconds: 60)
        XCTAssertEqual(ko.error, "pas connecté")
    }

    func testAuthAbortGivesLoginHint() {
        let reply = Backend.parse(kind: .agy, result: result(stdout: "Authentication required", abortedOn: "Authentication required"), timeoutSeconds: 60)
        XCTAssertEqual(reply.error, Backend.loginHint(.agy))
        XCTAssertTrue(reply.error!.contains("agy"))
    }

    func testTimeoutKeepsPartialResponse() {
        let json = #"{"conversation_id":"abc","status":"SUCCESS","response":"début de réponse"}"#
        let reply = Backend.parse(kind: .agy, result: result(stdout: json, timedOut: true), timeoutSeconds: 90)
        XCTAssertEqual(reply.response, "début de réponse")
        XCTAssertTrue(reply.error!.contains("90 s"))
    }

    func testNonZeroExitWithoutJSONReportsStderr() {
        let reply = Backend.parse(kind: .agy, result: result(stderr: "boum", code: 7), timeoutSeconds: 60)
        XCTAssertTrue(reply.error!.contains("code 7"))
        XCTAssertTrue(reply.error!.contains("boum"))
    }

    func testEmptyResponseIsAnError() {
        let json = #"{"conversation_id":"abc","status":"SUCCESS","response":"  \n"}"#
        XCTAssertNotNil(Backend.parse(kind: .agy, result: result(stdout: json), timeoutSeconds: 60).error)
    }

    // MARK: - Locator

    func testLocatorOverride() {
        XCTAssertEqual(Locator.executable(for: .agy, override: "/x/agy", fileExists: { $0 == "/x/agy" }), "/x/agy")
        XCTAssertNil(Locator.executable(for: .agy, override: "/x/agy", fileExists: { _ in false }))
    }

    func testLocatorSearchOrder() {
        let found = Locator.executable(for: .agy, override: nil, home: "/h", fileExists: { $0 == "/usr/local/bin/agy" || $0 == "/h/.local/bin/agy" })
        XCTAssertEqual(found, "/usr/local/bin/agy")
        XCTAssertNil(Locator.executable(for: .gemini, override: nil, home: "/h", fileExists: { _ in false }))
    }

    func testEnvironmentHasHomebrewPathWithoutDuplicates() {
        let env = Locator.environment(inherited: ["PATH": "/usr/bin:/custom"], home: "/h")
        let parts = env["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.first, "/opt/homebrew/bin")
        XCTAssertTrue(parts.contains("/custom"))
        XCTAssertEqual(parts.count, Set(parts).count)
        XCTAssertEqual(env["NO_COLOR"], "1")
    }

    // MARK: - Réglages

    func testSettingsDefaultsAndClamping() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"timeoutSeconds":1,"maxTurnsPerSession":999,"maxCallsPer10Minutes":0}"#.utf8))
        XCTAssertEqual(decoded.backend, .agy)
        XCTAssertEqual(decoded.mode, "plan")
        XCTAssertEqual(decoded.effectiveTimeout, 10)
        XCTAssertEqual(decoded.effectiveMaxTurns, 20)
        XCTAssertEqual(decoded.effectiveMaxCalls, 1)
    }

    func testSettingsRoundTripAndMissingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString)/settings.json")
        XCTAssertEqual(try Settings.load(from: url), Settings())
        var settings = Settings()
        settings.backend = .gemini
        settings.model = "x"
        try settings.save(to: url)
        XCTAssertEqual(try Settings.load(from: url), settings)
        try Data("pas du json".utf8).write(to: url)
        XCTAssertThrowsError(try Settings.load(from: url))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testOneInvalidSettingKeepsTheOthers() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"backend":"nimporte","timeoutSeconds":"vite","model":"m","maxTurnsPerSession":3}"#.utf8))
        XCTAssertEqual(decoded.backend, .agy)
        XCTAssertEqual(decoded.timeoutSeconds, 240)
        XCTAssertEqual(decoded.model, "m")
        XCTAssertEqual(decoded.maxTurnsPerSession, 3)
    }

    func testLocatorFindsProgramsOnTheInheritedPath() {
        let found = Locator.executable(for: .gemini, override: nil, home: "/h", inheritedPath: "/Users/x/.nvm/bin:/y",
                                       fileExists: { $0 == "/Users/x/.nvm/bin/gemini" })
        XCTAssertEqual(found, "/Users/x/.nvm/bin/gemini")
    }
}
