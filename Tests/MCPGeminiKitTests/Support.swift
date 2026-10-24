import Foundation
import XCTest
@testable import MCPGeminiKit

/// Faux programme `agy` : un script shell dans un dossier temporaire. Il note ses arguments dans
/// `args.log` (arguments terminés par NUL, « ---CALL--- » entre deux appels) avant d'exécuter `body`.
/// `FakeAgent.waitForRelease` dans `body` le fait attendre que le test appelle `release()` (au lieu d'un `sleep`).
final class FakeAgent {
    let directory: URL
    let executable: String
    let argsLog: URL
    /// Dossier personnel factice : jamais le vrai `~/.gemini` dans les tests.
    let home: URL

    convenience init(body: String) throws {
        try self.init(make: { _ in body })
    }

    /// `make` reçoit le dossier personnel factice (pour écrire dans son `.gemini`, comme agy).
    init(make: (URL) -> String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-gemini-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        argsLog = directory.appendingPathComponent("args.log")
        home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("agy")
        let text = """
        #!/bin/sh
        { for a in "$@"; do printf '%s\\0' "$a"; done; printf '%s\\0' '---CALL---'; } >> "\(argsLog.path)"
        DIR="\(directory.path)"
        \(make(home))
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

    var workspace: URL { directory.appendingPathComponent("workspace", isDirectory: true) }

    /// Seul le faux programme est trouvé : jamais le vrai `agy`, `gemini` ni `yt-dlp` de la machine.
    func handler(settings: Settings? = nil, store: SessionStore? = nil) -> ToolHandler {
        let settings = settings ?? self.settings()
        let executable = self.executable
        let backend = settings.backend
        return ToolHandler(settings: settings,
                           store: store ?? SessionStore(maxTurns: settings.effectiveMaxTurns, maxCalls: settings.effectiveMaxCalls),
                           workspace: workspace, environment: Locator.environment(), home: home.path,
                           locate: { $0 == backend ? executable : nil }, locateTool: { _ in nil })
    }

    /// Ligne de script qui attend `release()` (au plus 30 s).
    static let waitForRelease = #"i=0; while [ ! -e "$DIR/go" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done; "#

    func release() {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("go").path, contents: Data())
    }

    /// Script qui écrit ces lignes NDJSON une à une (comme agy en `stream-json`).
    static func stream(_ lines: [String], pause: Double = 0) -> String {
        lines.map { line in
            "printf '%s\\n' '\(line.replacingOccurrences(of: "'", with: "'\\''"))'" + (pause > 0 ? "; sleep \(pause)" : "")
        }.joined(separator: "; ")
    }

    static let okJSON = #"printf '%s' '{"conversation_id":"conv-1","status":"SUCCESS","response":"Bonjour de Gemini","duration_seconds":1,"num_turns":1}'"#
}

func text(of result: ToolResult) -> String { result.text }
