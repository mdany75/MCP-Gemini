import Foundation

/// Une étape de travail de Gemini vue dans la sortie `stream-json` d'agy : une recherche, une page lue…
public struct ActivityStep: Equatable, Sendable {
    public var tool: String
    /// Paramètre le plus parlant (requête, adresse, fichier…), raccourci.
    public var detail: String?
    public var failed: Bool

    public init(tool: String, detail: String? = nil, failed: Bool = false) {
        self.tool = tool
        self.detail = detail
        self.failed = failed
    }

    /// Libellé lisible : « recherche « météo Québec » ».
    public var label: String {
        let name = Self.names[tool] ?? tool
        guard let detail else { return name }
        return tool == "search_web" ? "\(name) « \(detail) »" : "\(name) \(detail)"
    }

    static let names: [String: String] = [
        "search_web": "recherche",
        "read_url_content": "lecture de",
        "open_browser_url": "navigateur :",
        "read_browser_page": "lecture de la page",
        "view_file": "lecture du fichier",
        "read_file": "lecture du fichier",
        "list_dir": "liste du dossier",
        "grep_search": "recherche dans les fichiers",
        "find_by_name": "recherche de fichiers",
        "generate_image": "image",
        "invoke_subagent": "sous-agent",
        "browser_subagent": "sous-agent navigateur",
        "write_file": "écriture de",
        "write_to_file": "écriture de",
        "run_command": "commande",
    ]

    /// Paramètres essayés dans cet ordre pour décrire une étape (noms vus dans les journaux d'agy).
    static let detailKeys = ["query", "Url", "url", "AbsolutePath", "Path", "path", "ImageName", "Prompt", "CommandLine"]

    /// Paramètres qui désignent un fichier : seul son nom est montré.
    static let fileKeys: Set<String> = ["AbsolutePath", "Path", "path"]

    static func detail(of parameters: JSONValue?) -> String? {
        guard let object = parameters?.object else { return nil }
        let key = detailKeys.first { !(object[$0]?.string ?? "").isEmpty }
            ?? object.keys.sorted().first { !(object[$0]?.string ?? "").isEmpty }
        guard let key, var value = object[key]?.string else { return nil }
        if fileKeys.contains(key), value.contains("/") { value = (value as NSString).lastPathComponent }
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }
}

/// Un événement de la sortie `stream-json` d'agy (une ligne NDJSON).
public enum StreamEvent: Equatable {
    /// Début du tour : identifiant de conversation, modèle réel, autorisations et commandes appliquées (`plan`).
    case started(StreamStart)
    /// `key` identifie l'étape (conversation et numéro) : elle arrive deux fois, en cours puis finie.
    /// `parameters` : paramètres complets de l'outil (le garde-fou contrôle les chemins).
    case tool(ActivityStep, key: String, finished: Bool, parameters: JSONValue?)
    case text(String)
    case result(JSONValue)

    /// `nil` pour une ligne qui n'est pas un événement connu (avertissement, étape sans intérêt).
    public static func decode(_ line: String) -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let json = try? JSONCoding.parse(trimmed) else { return nil }
        switch json["event"]?.string {
        case "init":
            let info = json["init"]
            return .started(StreamStart(
                conversationId: json["conversation_id"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                model: info?["model"]?.string,
                permissionMode: info?["permission_mode"]?.string,
                commands: info?["expanded_commands"]?.array?.compactMap { $0["name"]?.string } ?? []))
        case "result":
            return json["result"].map { .result($0) }
        case "step_update":
            guard let step = json["step_update"] else { return nil }
            let state = step["state"]?.string ?? ""
            let key = "\(step["conversation_id"]?.string ?? "")#\(step["step_index"]?.int.map(String.init) ?? UUID().uuidString)"
            switch step["step_type"]?.string {
            case "tool":
                guard let name = step["tool_name"]?.string ?? step["tool_info"]?["name"]?.string else { return nil }
                let parameters = step["tool_info"]?["parameters"]
                if name == "invoke_subagent" {
                    // Même appel décrit comme un outil : son type est dans TypeName ; Role n'est qu'un libellé libre.
                    let type = parameters?["TypeName"]?.string
                    let role = parameters?["Role"]?.string
                    let activity = ActivityStep(tool: name, detail: type ?? role, failed: state == "ERROR")
                    return .tool(activity, key: key, finished: state != "ACTIVE", parameters: .object([
                        "subagent_types": .array(type.map { [.string($0)] } ?? []),
                        "subagent_roles": .array(role.map { [.string($0)] } ?? []),
                    ]))
                }
                let activity = ActivityStep(tool: name, detail: ActivityStep.detail(of: parameters), failed: state == "ERROR")
                return .tool(activity, key: key, finished: state != "ACTIVE", parameters: parameters)
            case "subagent":
                // Un sous-agent (ex. « image-generator ») : ses propres étapes n'apparaissent pas dans le flux.
                // Il est décrit par son type ou, selon les versions, seulement par son rôle (libellé libre, montré
                // mais jamais pris pour le type : le garde-fou lit alors le type réel dans le dossier d'agy).
                let subagents = step["subagent_info"]?["subagents"]?.array ?? []
                let types = subagents.compactMap { $0["type_name"]?.string ?? $0["typeName"]?.string }
                let roles = subagents.compactMap { $0["role"]?.string }
                let shown = types.isEmpty ? roles : types
                let activity = ActivityStep(tool: step["tool_name"]?.string ?? "invoke_subagent",
                                            detail: shown.isEmpty ? nil : shown.joined(separator: ", "), failed: state == "ERROR")
                return .tool(activity, key: key, finished: state != "ACTIVE", parameters: .object([
                    "subagent_types": .array(types.map { .string($0) }),
                    "subagent_roles": .array(roles.map { .string($0) }),
                ]))
            case "agent_response":
                guard let delta = step["text_delta"]?.string, !delta.isEmpty else { return nil }
                return .text(delta)
            default:
                return nil
            }
        default:
            // Format `--output-format json` (un seul objet) : c'est déjà le résultat.
            if json["status"] != nil || json["response"] != nil { return .result(json) }
            return nil
        }
    }
}

public struct StreamStart: Equatable, Sendable {
    public var conversationId: String?
    public var model: String?
    public var permissionMode: String?
    public var commands: [String]

    public init(conversationId: String?, model: String? = nil, permissionMode: String? = nil, commands: [String] = []) {
        self.conversationId = conversationId
        self.model = model
        self.permissionMode = permissionMode
        self.commands = commands
    }
}

/// Ce que Gemini a fait pendant une demande : rempli au fil de la sortie d'agy, lu par l'outil qui attend
/// (message « Gemini travaille encore ») et par les notifications de progression. Partagé entre fils.
public final class ActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ActivityStep] = []
    private var keys: [String] = []
    private var partial = ""
    private var buffer = Data()
    private var conversation: String?
    private var modelName: String?
    public let startedAt: Date

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    /// Morceau brut de la sortie standard : découpé en lignes complètes. Rend les événements reconnus.
    @discardableResult
    public func consume(_ chunk: Data) -> [StreamEvent] {
        lock.lock()
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        // Une ligne démesurée (pas du NDJSON) ne doit pas grossir sans fin.
        if buffer.count > 1_048_576 { buffer.removeAll() }
        lock.unlock()
        let events = lines.compactMap(StreamEvent.decode)
        events.forEach(apply)
        return events
    }

    public func apply(_ event: StreamEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .started(let start):
            if let id = start.conversationId { conversation = id }
            if let model = start.model { modelName = model }
        case .tool(let step, let key, _, _):
            // L'étape arrive deux fois (ACTIVE puis DONE ou ERROR) : on la garde une fois, avec son état final.
            if let index = keys.lastIndex(of: key) {
                steps[index] = step
            } else if steps.count < 500 {
                steps.append(step)
                keys.append(key)
            }
        case .text(let delta):
            if partial.count < 200_000 { partial += delta }
        case .result(let json):
            if let id = json["conversation_id"]?.string, !id.isEmpty { conversation = id }
        }
    }

    /// Nouvelle tentative (relance après une conversation perdue) : la conversation et la ligne incomplète de la
    /// tentative arrêtée sont oubliées ; les étapes restent, pour le suivi.
    public func beginAttempt() {
        lock.lock()
        conversation = nil
        buffer.removeAll()
        lock.unlock()
    }

    public var allSteps: [ActivityStep] { lock.lock(); defer { lock.unlock() }; return steps }
    public var partialText: String { lock.lock(); defer { lock.unlock() }; return partial }
    public var conversationId: String? { lock.lock(); defer { lock.unlock() }; return conversation }
    public var model: String? { lock.lock(); defer { lock.unlock() }; return modelName }
    public var elapsed: Int { Int(Date().timeIntervalSince(startedAt)) }

    /// État en une ligne, pour une notification de progression : « recherche « … » (3 étapes) ».
    public var current: String? {
        let steps = allSteps
        guard let last = steps.last else { return nil }
        return steps.count == 1 ? last.label : "\(last.label) (\(steps.count) étapes)"
    }

    /// Résumé des étapes : « 3 recherches (« a », « b », « c ») ; lecture de https://… ».
    public static func summary(_ steps: [ActivityStep], limit: Int = 700) -> String? {
        guard !steps.isEmpty else { return nil }
        let searches = steps.filter { $0.tool == "search_web" }
        var parts: [String] = []
        if !searches.isEmpty {
            let queries = searches.compactMap(\.detail).map { "« \($0) »" }
            let shown = queries.prefix(5).joined(separator: ", ") + (queries.count > 5 ? ", …" : "")
            parts.append("\(searches.count) recherche\(searches.count > 1 ? "s" : "") web" + (queries.isEmpty ? "" : " (\(shown))"))
        }
        var others: [String] = []
        for step in steps where step.tool != "search_web" {
            let label = step.label + (step.failed ? " (refusé ou échoué)" : "")
            if !others.contains(label) { others.append(label) }
        }
        parts += others.prefix(6)
        if others.count > 6 { parts.append("et \(others.count - 6) autre\(others.count - 6 > 1 ? "s" : "") étape\(others.count - 6 > 1 ? "s" : "")") }
        let text = parts.joined(separator: " ; ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
