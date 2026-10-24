import Foundation

/// Ce que renvoie un appel au programme.
public struct BridgeReply: Equatable, Sendable {
    public var response: String
    /// Identifiant de conversation côté programme, pour poursuivre la session.
    public var conversationId: String?
    /// Message d'erreur lisible ; `nil` si l'appel a réussi.
    public var error: String?

    public init(response: String, conversationId: String? = nil, error: String? = nil) {
        self.response = response
        self.conversationId = conversationId
        self.error = error
    }
}

/// Différences entre `agy` et `gemini` : arguments, lecture de la sortie JSON, messages d'erreur.
public enum Backend {
    /// Textes qui signalent une connexion à refaire : le programme attendrait 60 s une saisie
    /// que personne ne fera, on l'arrête tout de suite.
    public static let authMarkers = ["Authentication required", "Please set an Auth method", "Error authenticating"]

    public static func arguments(kind: BackendKind, prompt rawPrompt: String, model rawModel: String?, mode: String?,
                                 effort: String? = nil, conversationId: String?, timeoutSeconds: Int) -> [String] {
        // Un octet nul dans un argument fait échouer (et même planter) le lancement d'un processus.
        let prompt = stripNUL(rawPrompt)
        let model = rawModel.map(stripNUL)
        switch kind {
        case .agy:
            var args = ["--print", prompt, "--output-format", "json", "--print-timeout", "\(timeoutSeconds)s"]
            if let mode, !mode.isEmpty { args += ["--mode", mode] }
            if let model, !model.isEmpty { args += ["--model", model] }
            if let effort, !effort.isEmpty { args += ["--effort", effort] }
            if let conversationId, !conversationId.isEmpty { args += ["--conversation", conversationId] }
            return args
        case .gemini:
            var args = ["-p", prompt, "--output-format", "json", "--skip-trust", "--approval-mode", "plan"]
            if let model, !model.isEmpty { args += ["-m", model] }
            return args
        }
    }

    static func stripNUL(_ text: String) -> String {
        text.contains("\0") ? text.replacingOccurrences(of: "\0", with: "") : text
    }

    public static func loginHint(_ kind: BackendKind) -> String {
        switch kind {
        case .agy:
            return "Antigravity CLI n'est pas connecté : lancer `agy` dans un terminal et suivre la connexion Google."
        case .gemini:
            return "gemini-cli n'est pas connecté (ou n'accepte plus ce compte : depuis juin 2026 il refuse les comptes Google personnels). Utiliser `agy` (réglage « backend »)."
        }
    }

    public static func parse(kind: BackendKind, result: ProcessResult, timeoutSeconds: Int) -> BridgeReply {
        if result.abortedOn != nil {
            return BridgeReply(response: "", error: loginHint(kind))
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = extractJSON(stdout)

        var reply = BridgeReply(response: "")
        switch kind {
        case .agy:
            if let json {
                reply.conversationId = json["conversation_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                reply.response = json["response"]?.string ?? ""
                let status = json["status"]?.string ?? ""
                if status != "SUCCESS" {
                    reply.error = json["error"]?.string ?? "état « \(status.isEmpty ? "inconnu" : status) »"
                }
            }
        case .gemini:
            if let json {
                // gemini-cli ne reprend une session que par son numéro d'ordre : on ne garde pas son
                // identifiant, l'historique est rejoué à chaque échange (voir ToolHandler.composePrompt).
                reply.response = json["response"]?.string ?? ""
                if let error = json["error"], !error.isNull {
                    reply.error = error["message"]?.string ?? error.string ?? "erreur"
                }
            }
        }

        if json == nil {
            // Pas de JSON exploitable : texte brut en dernier recours.
            reply.response = stdout
            if result.exitCode != 0 { reply.error = errorDetail(result) }
        } else if reply.error == nil, result.exitCode != 0, reply.response.isEmpty {
            reply.error = errorDetail(result)
        }

        if result.timedOut {
            let note = "délai de \(timeoutSeconds) s dépassé"
            reply.error = reply.error.map { "\(note) (\($0))" } ?? note
        }
        if reply.error == nil, reply.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reply.error = "réponse vide" + (stderrTail(result).map { " — \($0)" } ?? "")
        }
        if result.truncated, reply.error == nil {
            reply.response += "\n\n[sortie tronquée : trop volumineuse]"
        }
        return reply
    }

    /// Le JSON peut être précédé de lignes parasites (avertissements) : on prend de la première
    /// accolade à la dernière.
    static func extractJSON(_ text: String) -> JSONValue? {
        if let whole = try? JSONCoding.parse(text), whole.object != nil { return whole }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        if let value = try? JSONCoding.parse(String(text[start...end])), value.object != nil { return value }
        return nil
    }

    private static func errorDetail(_ result: ProcessResult) -> String {
        let tail = stderrTail(result)
        return "le programme s'est arrêté avec le code \(result.exitCode)" + (tail.map { " — \($0)" } ?? "")
    }

    private static func stderrTail(_ result: ProcessResult) -> String? {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return String(text.suffix(500))
    }
}

/// Noms courts des modèles d'agy et niveaux d'effort : `flash` + `high` -> `gemini-3.8-flash-high`.
public enum ModelCatalog {
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    /// Niveaux qui se collent à un identifiant de modèle (voir `agy models`).
    static let levels = ["low", "medium", "high"]

    public static let aliases: [String: String] = [
        "argon": "gemini-4-argon",
        "flash": "gemini-3.8-flash",
        "opus": "claude-opus-5-5",
        "sonnet": "claude-sonnet-5-5",
        "gpt": "gpt-oss-120b",
    ]

    public static func isEffort(_ text: String) -> Bool { efforts.contains(text.lowercased()) }

    /// Modèle et effort à passer au programme. Un nom court (ou un identifiant sans niveau) reçoit le
    /// niveau demandé ; un identifiant complet est gardé tel quel ; sans modèle, l'effort reste un réglage séparé.
    public static func resolve(model: String?, effort: String?) -> (model: String?, effort: String?) {
        let effort = effort?.lowercased().trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard let raw = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return (nil, effort) }
        let base = aliases[raw.lowercased()] ?? raw
        if levels.contains(where: { base.hasSuffix("-\($0)") }) { return (base, nil) }
        if let effort, levels.contains(effort), aliases.values.contains(base) {
            return (base == "gpt-oss-120b" ? "gpt-oss-120b-medium" : "\(base)-\(effort)", nil)
        }
        return (base, effort)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Recherche du programme et environnement de lancement (Claude Desktop ne transmet pas le PATH du shell).
public enum Locator {
    public static func searchDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.antigravity/bin",
         "\(home)/.volta/bin", "\(home)/.npm-global/bin", "/usr/bin"]
    }

    public static func executable(for kind: BackendKind, override: String?,
                                  home: String = NSHomeDirectory(),
                                  inheritedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                                  fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fileExists(expanded) ? expanded : nil
        }
        let extra = inheritedPath.split(separator: ":").map(String.init)
        for directory in searchDirectories(home: home) + extra {
            let path = "\(directory)/\(kind.binaryName)"
            if fileExists(path) { return path }
        }
        return nil
    }

    /// Environnement hérité, avec un PATH complet (gemini-cli est un script `#!/usr/bin/env node`).
    public static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment,
                                   home: String = NSHomeDirectory()) -> [String: String] {
        var env = inherited
        let extra = searchDirectories(home: home) + ["/bin", "/usr/sbin", "/sbin"]
        let current = (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (extra + current).filter { seen.insert($0).inserted }.joined(separator: ":")
        env["HOME"] = home
        // Pas de couleurs ni d'interface dans une sortie lue par une machine.
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }
}
