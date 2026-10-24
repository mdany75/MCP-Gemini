import Foundation
import XCTest
@testable import MCPGeminiKit

/// Faux programme `agy` : un script shell dans un dossier temporaire. Il note ses arguments dans
/// `args.log` (arguments terminés par NUL, « ---CALL--- » entre deux appels) avant d'exécuter `body`.
final class FakeAgent {
    let directory: URL
    let executable: String
    let argsLog: URL

    init(body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-gemini-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        argsLog = directory.appendingPathComponent("args.log")
        let script = directory.appendingPathComponent("agy")
        let text = """
        #!/bin/sh
        { for a in "$@"; do printf '%s\\0' "$a"; done; printf '%s\\0' '---CALL---'; } >> "\(argsLog.path)"
        \(body)
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        executable = script.path
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Arguments reçus, un tableau par appel.
    var calls: [[String]] {
        guard let data = try? Data(contentsOf: argsLog) else { return [] }
        var calls: [[String]] = []
        var current: [String] = []
        for part in data.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            let arg = String(decoding: part, as: UTF8.self)
            if arg == "---CALL---" { calls.append(current); current = [] } else { current.append(arg) }
        }
        return calls
    }

    func settings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
        var settings = Settings()
        settings.executable = executable
        change(&settings)
        return settings
    }

    func handler(settings: Settings? = nil) -> ToolHandler {
        let settings = settings ?? self.settings()
        return ToolHandler(settings: settings,
                           store: SessionStore(maxTurns: settings.effectiveMaxTurns, maxCalls: settings.effectiveMaxCalls),
                           workspace: directory.appendingPathComponent("workspace"),
                           environment: Locator.environment(), home: NSHomeDirectory())
    }

    static let okJSON = #"printf '%s' '{"conversation_id":"conv-1","status":"SUCCESS","response":"Bonjour de Gemini","duration_seconds":1,"num_turns":1}'"#
}

func text(of result: ToolResult) -> String { result.text }
