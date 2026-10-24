import XCTest
@testable import MCPGeminiKit

final class BackendTests: XCTestCase {
    private func result(stdout: String = "", stderr: String = "", code: Int32 = 0, timedOut: Bool = false,
                        abortedOn: String? = nil, truncated: Bool = false) -> ProcessResult {
        ProcessResult(stdout: stdout, stderr: stderr, exitCode: code, timedOut: timedOut, abortedOn: abortedOn, truncated: truncated)
    }

    func testAgyArguments() {
        let args = Backend.arguments(kind: .agy, prompt: "salut", model: "m1", effort: "low",
                                     conversationId: "c-9", timeoutSeconds: 120)
        XCTAssertEqual(args, ["--print", "salut", "--output-format", "stream-json", "--print-timeout", "120s",
                              "--mode", "plan", "--model", "m1", "--effort", "low", "--conversation", "c-9"])
    }

    func testAgyArgumentsMinimalAlwaysPlan() {
        let args = Backend.arguments(kind: .agy, prompt: "x", model: nil, conversationId: nil, timeoutSeconds: 30)
        XCTAssertEqual(args, ["--print", "x", "--output-format", "stream-json", "--print-timeout", "30s", "--mode", "plan"])
    }

    func testPromptStartingWithDashIsNeverReadAsAnOption() {
        for kind in BackendKind.allCases {
            let args = Backend.arguments(kind: kind, prompt: "--dangerously-skip-permissions", model: nil,
                                         conversationId: nil, timeoutSeconds: 30)
            XCTAssertFalse(args[1].hasPrefix("-"), "\(kind)")
            XCTAssertTrue(args[1].hasSuffix("--dangerously-skip-permissions"))
        }
        let followUp = Backend.arguments(kind: .agy, prompt: "-5 °C, c'est normal ?", model: nil, conversationId: "c", timeoutSeconds: 30)
        XCTAssertEqual(followUp[1], "Demande : -5 °C, c'est normal ?")
    }

    func testNulBytesAreStrippedFromArguments() {
        let args = Backend.arguments(kind: .agy, prompt: "a\u{0}b", model: "m\u{0}x", conversationId: nil, timeoutSeconds: 30)
        XCTAssertEqual(args[1], "ab")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "mx")
    }

    func testGeminiArguments() {
        let args = Backend.arguments(kind: .gemini, prompt: "salut", model: "g", conversationId: "ignoré", timeoutSeconds: 30)
        XCTAssertEqual(args, ["-p", "salut", "--output-format", "json", "--skip-trust", "--approval-mode", "plan", "-m", "g"])
    }

    // MARK: - Flux d'agy (stream-json)

    private var stream: String {
        [StreamSample.initLine, StreamSample.search(2, "ACTIVE", "prix essence"), StreamSample.search(2, "DONE", "prix essence"),
         StreamSample.delta("Environ "), StreamSample.result].joined(separator: "\n") + "\n"
    }

    func testParseAgyStream() {
        let log = ActivityLog()
        log.consume(Data(stream.utf8))
        let reply = Backend.parse(kind: .agy, result: result(stdout: stream), timeoutSeconds: 60, activity: log)
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.response, "Environ 1,88 $ le litre.\n")
        XCTAssertEqual(reply.conversationId, "14e63800-6228")
        XCTAssertEqual(reply.model, "gemini-3.8-flash-low")
        XCTAssertEqual(reply.durationSeconds, 20.5)
        XCTAssertEqual(reply.totalTokens, 50011)
        XCTAssertFalse(reply.partial)
    }

    func testParseAgyStreamWithoutResultKeepsPartialText() {
        let cut = [StreamSample.initLine, StreamSample.delta("Le début")].joined(separator: "\n")
        let log = ActivityLog()
        log.consume(Data((cut + "\n").utf8))
        let killed = Backend.parse(kind: .agy, result: result(stdout: cut, timedOut: true), timeoutSeconds: 60, activity: log)
        XCTAssertEqual(killed.response, "Le début")
        XCTAssertEqual(killed.conversationId, "14e63800-6228")
        XCTAssertTrue(killed.error!.contains("60 s"))
        let unreadable = Backend.parse(kind: .agy, result: result(stdout: "du texte sans JSON"), timeoutSeconds: 60)
        XCTAssertEqual(unreadable.error, "sortie illisible")
    }

    func testAgyPrintTimeoutIsPartial() {
        // Sortie réelle d'agy quand --print-timeout tombe : SUCCESS, réponse vide, avertissement sur stderr.
        let empty = #"{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":""}}"#
        let warning = "[agy] print timeout after 8s with turn in progress; returning partial output"
        let none = Backend.parse(kind: .agy, result: result(stdout: empty, stderr: warning), timeoutSeconds: 240)
        XCTAssertTrue(none.partial)
        XCTAssertTrue(none.error!.contains("240 s"))
        XCTAssertEqual(none.conversationId, "c")
        let some = #"{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"moitié"}}"#
        let half = Backend.parse(kind: .agy, result: result(stdout: some, stderr: warning), timeoutSeconds: 240)
        XCTAssertTrue(half.partial)
        XCTAssertNil(half.error)
        XCTAssertEqual(half.response, "moitié")
    }

    func testAgyErrorLineAndDeniedActions() {
        let failed = #"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":""}}"#
        let stderr = #"AGY_ERROR: {"short_error":"Modèle saturé","retryable":true}"#
        let reply = Backend.parse(kind: .agy, result: result(stdout: failed, stderr: stderr, code: 3), timeoutSeconds: 60)
        XCTAssertEqual(reply.error, "Modèle saturé (passager : réessayer dans un moment)")
        let denied = #"{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"fait","denied_actions":[{"action":"command","display_name":"RunCommand"}]}}"#
        XCTAssertEqual(Backend.parse(kind: .agy, result: result(stdout: denied), timeoutSeconds: 60).deniedActions, ["RunCommand"])
    }

    func testStopReasonFromTheGuardWins() {
        var stopped = result(stdout: StreamSample.initLine, code: 15)
        stopped.stopReason = "outil interdit"
        let reply = Backend.parse(kind: .agy, result: stopped, timeoutSeconds: 60)
        XCTAssertEqual(reply.error, "outil interdit")
    }

    func testExtractJSONIsTolerant() {
        let ok = #"{"status":"SUCCESS","response":"ok"}"#
        XCTAssertEqual(Backend.extractJSON("{\"level\":\"warn\"}\n" + ok)?["response"]?.string, "ok")
        XCTAssertEqual(Backend.extractJSON("config {beta}\n" + ok)?["response"]?.string, "ok")
        XCTAssertEqual(Backend.extractJSON(ok + "\nUpdate available {v1.5}")?["response"]?.string, "ok")
        XCTAssertEqual(Backend.extractJSON("bruit " + #"{"a":"accolade } dans une chaîne"}"# + " fin")?["a"]?.string, "accolade } dans une chaîne")
        XCTAssertNil(Backend.extractJSON("aucun objet"))
    }

    func testParseAgySuccess() {
        let json = #"{"conversation_id":"abc","status":"SUCCESS","response":"ok\n","duration_seconds":3}"#
        let reply = Backend.parse(kind: .agy, result: result(stdout: json), timeoutSeconds: 60)
        XCTAssertEqual(reply.response, "ok\n")
        XCTAssertEqual(reply.conversationId, "abc")
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.durationSeconds, 3)
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

    func testEnvironmentKeepsOnlyWhatProgramsNeed() {
        let inherited = ["PATH": ".:/usr/bin:node_modules/.bin", "GITHUB_TOKEN": "x", "SSH_AUTH_SOCK": "/s", "LANG": "fr_CA.UTF-8",
                         "HTTPS_PROXY": "http://p", "GEMINI_API_KEY": "k", "LC_ALL": "fr_CA.UTF-8", "TMPDIR": "/var/folders/x/T/"]
        let env = Locator.environment(inherited: inherited, home: "/h", temporaryDirectory: "/h/prive")
        XCTAssertNil(env["GITHUB_TOKEN"])
        XCTAssertNil(env["SSH_AUTH_SOCK"])
        XCTAssertEqual(env["LANG"], "fr_CA.UTF-8")
        XCTAssertEqual(env["LC_ALL"], "fr_CA.UTF-8")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://p")
        XCTAssertEqual(env["TMPDIR"], "/h/prive/")
        XCTAssertFalse(env["PATH"]!.split(separator: ":").contains { !$0.hasPrefix("/") }, "PATH sans entrée relative")
        XCTAssertEqual(env["GEMINI_API_KEY"], "k")
        XCTAssertNil(Locator.restricted(env, for: .agy)["GEMINI_API_KEY"], "les clés Google ne vont qu'à gemini-cli")
        XCTAssertEqual(Locator.restricted(env, for: .gemini)["GEMINI_API_KEY"], "k")
        XCTAssertNil(Locator.executable(for: .agy, override: nil, home: "/h", inheritedPath: ".:bin", fileExists: { !$0.hasPrefix("/") }))
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

    func testEverySettingSurvivesARoundTrip() throws {
        var settings = Settings()
        settings.backend = .gemini
        settings.executable = "/e"
        settings.ytDlp = "/y"
        settings.model = "argon"
        settings.mode = "plan"
        settings.effort = "high"
        settings.waitSeconds = 25
        settings.timeoutSeconds = 100
        settings.maxTurnsPerSession = 7
        settings.maxCallsPer10Minutes = 9
        settings.preamble = "court"
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(#"{"waitSeconds":25}"#.utf8)).effectiveWait, 25)
    }

    func testModeIsAlwaysPlanAndBadValuesAreReported() throws {
        for json in [#"{"mode":""}"#, #"{"mode":"auto"}"#, #"{"mode":"PLAN "}"#, #"{"model":"--x","effort":"turbo"}"#] {
            let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.warnings.isEmpty, json.contains("PLAN"), json)
        }
        let bad = try JSONDecoder().decode(Settings.self, from: Data(#"{"model":"--x","effort":"turbo"}"#.utf8))
        XCTAssertNil(bad.effectiveModel)
        XCTAssertNil(bad.effectiveEffort)
    }

    func testUpdateChangesOnlyOneKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Settings.update("backend", to: "gemini", at: url)
        XCTAssertEqual(try JSONCoding.parse(Data(contentsOf: url)), ["backend": "gemini"])
        try Data(#"{"waitSeconds":25,"inconnu":true}"#.utf8).write(to: url)
        try Settings.update("backend", to: "agy", at: url)
        XCTAssertEqual(try JSONCoding.parse(Data(contentsOf: url)), ["backend": "agy", "waitSeconds": 25, "inconnu": true])
        try Data("[1]".utf8).write(to: url)
        XCTAssertThrowsError(try Settings.update("backend", to: "agy", at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[1]")
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

    func testModelCatalogResolution() {
        XCTAssertTrue(ModelCatalog.resolve(model: nil, effort: nil) == (nil, nil))
        XCTAssertTrue(ModelCatalog.resolve(model: nil, effort: "High") == (nil, "high"))
        XCTAssertTrue(ModelCatalog.resolve(model: "flash", effort: "high") == ("gemini-3.8-flash-high", nil))
        XCTAssertTrue(ModelCatalog.resolve(model: "Argon", effort: "low") == ("gemini-4-argon-low", nil))
        XCTAssertTrue(ModelCatalog.resolve(model: "gemini-4-argon-medium", effort: "high") == ("gemini-4-argon-medium", nil))
        XCTAssertTrue(ModelCatalog.resolve(model: "gpt", effort: "high") == ("gpt-oss-120b-medium", nil))
        XCTAssertTrue(ModelCatalog.resolve(model: "modele-inconnu", effort: "high") == ("modele-inconnu", "high"))
        XCTAssertTrue(ModelCatalog.resolve(model: "opus", effort: nil) == ("claude-opus-5-5", nil))
        XCTAssertTrue(ModelCatalog.resolve(model: "flash-high", effort: nil) == ("gemini-3.8-flash-high", nil))
        XCTAssertTrue(ModelCatalog.resolve(model: " Gemini-3.8-Flash\n", effort: "high") == ("gemini-3.8-flash-high", nil))
    }

    private func choose(_ model: String?, _ effort: String?, settingsModel: String? = nil, settingsEffort: String? = nil,
                        kind: BackendKind = .agy) throws -> ModelCatalog.Choice {
        var settings = Settings()
        settings.model = settingsModel
        settings.effort = settingsEffort
        return try ModelCatalog.choose(kind: kind, model: model, effort: effort, settings: settings)
    }

    func testChoiceGivesPriorityToTheCall() throws {
        // L'effort demandé remplace le niveau du modèle des réglages.
        XCTAssertEqual(try choose(nil, "low", settingsModel: "gemini-4-argon-high").model, "gemini-4-argon-low")
        XCTAssertEqual(try choose(nil, nil, settingsModel: "flash", settingsEffort: "low").model, "gemini-3.8-flash-low")
        XCTAssertEqual(try choose("argon", nil, settingsModel: "flash", settingsEffort: "high").model, "gemini-4-argon-high")
        let both = try choose("gemini-4-argon-medium", "high")
        XCTAssertEqual(both.model, "gemini-4-argon-medium")
        XCTAssertFalse(both.notes.isEmpty)
        XCTAssertEqual(try choose("gpt", "high").model, "gpt-oss-120b-medium")
        XCTAssertFalse(try choose("gpt", "high").notes.isEmpty)
        XCTAssertEqual(try choose(nil, "xhigh").effort, "xhigh")
    }

    func testChoiceRejectsBadInputBeforeAnyLaunch() {
        XCTAssertThrowsError(try choose("--dangerously-skip-permissions", nil))
        XCTAssertThrowsError(try choose("flash", "turbo"))
        XCTAssertThrowsError(try choose("flash", "max"), "flash n'a que low, medium, high")
        XCTAssertThrowsError(try choose("opus", nil, kind: .gemini))
        XCTAssertThrowsError(try choose("flash-high", nil, kind: .gemini))
        let gemini = try? choose("gemini-2.5-pro", "high", kind: .gemini)
        XCTAssertEqual(gemini?.model, "gemini-2.5-pro")
        XCTAssertNil(gemini?.effort)
        XCTAssertEqual(gemini?.notes, ["effort ignoré par gemini-cli"])
    }
}
