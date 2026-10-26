import Foundation

/// Ce que renvoie un appel au programme.
public struct BridgeReply: Equatable, Sendable {
    public var response: String
    /// Identifiant de conversation côté programme, pour poursuivre la session.
    public var conversationId: String?
    /// Message d'erreur lisible ; `nil` si l'appel a réussi.
    public var error: String?
    /// Réponse incomplète : le délai d'agy est tombé pendant qu'il travaillait encore.
    public var partial = false
    /// Modèle qui a vraiment répondu (événement `init` d'agy).
    public var model: String?
    public var durationSeconds: Double?
    public var totalTokens: Int?
    /// Actions qu'agy a refusées faute de pouvoir demander l'accord (lecture seule, pas de terminal).
    public var deniedActions: [String] = []
    /// Le garde-fou de lecture seule a arrêté agy : sa conversation contient une action interdite.
    public var stoppedByGuard = false
    /// Le compte Google a épuisé son quota d'utilisation (l'erreur le dit en clair).
    public var quotaReached = false

    public init(response: String, conversationId: String? = nil, error: String? = nil) {
        self.response = response
        self.conversationId = conversationId
        self.error = error
    }
}

/// Différences entre `agy` et `gemini` : arguments, lecture de la sortie, messages d'erreur.
public enum Backend {
    /// Textes qui signalent une connexion à refaire : le programme attendrait 60 s une saisie
    /// que personne ne fera, on l'arrête tout de suite.
    public static let authMarkers = ["Authentication required", "Please set an Auth method", "Error authenticating"]
    /// Avertissement d'agy quand son délai (`--print-timeout`) tombe : il rend ce qu'il a déjà écrit.
    static let printTimeoutMarker = "print timeout after"

    /// agy tourne toujours en mode plan (lecture seule) et en sortie continue (`stream-json`), que le pont
    /// lit au fil de l'eau ; gemini-cli toujours en `--approval-mode plan`.
    public static func arguments(kind: BackendKind, prompt rawPrompt: String, model rawModel: String?,
                                 effort: String? = nil, conversationId: String?, timeoutSeconds: Int) -> [String] {
        // Un octet nul dans un argument fait échouer (et même planter) le lancement d'un processus.
        var prompt = stripNUL(rawPrompt)
        // Une demande qui commence par « - » serait lue comme une option par le programme.
        if prompt.hasPrefix("-") { prompt = "Demande : " + prompt }
        let model = rawModel.map(stripNUL)
        switch kind {
        case .agy:
            var args = ["--print", prompt, "--output-format", "stream-json", "--print-timeout", "\(timeoutSeconds)s", "--mode", "plan"]
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

    /// `activity` : ce que le pont a lu du flux d'agy pendant la demande (texte partiel, modèle, conversation).
    public static func parse(kind: BackendKind, result: ProcessResult, timeoutSeconds: Int,
                             activity: ActivityLog? = nil) -> BridgeReply {
        if result.abortedOn != nil {
            return BridgeReply(response: "", error: loginHint(kind))
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: JSONValue?
        var reply = BridgeReply(response: "")
        switch kind {
        case .agy:
            json = finalAgyObject(stdout)
            reply.conversationId = activity?.conversationId
            reply.model = activity?.model
            if let json {
                if let id = json["conversation_id"]?.string, !id.isEmpty { reply.conversationId = id }
                reply.response = json["response"]?.string ?? ""
                reply.durationSeconds = json["duration_seconds"]?.double
                reply.totalTokens = json["usage"]?["total_tokens"]?.int
                reply.deniedActions = (json["denied_actions"]?.array ?? []).compactMap {
                    $0["display_name"]?.string ?? $0["action"]?.string ?? $0.string
                }
                let status = json["status"]?.string ?? ""
                if status != "SUCCESS" {
                    reply.error = json["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                        ?? agyError(result.stderr) ?? "état « \(status.isEmpty ? "inconnu" : status) »"
                }
            }
        case .gemini:
            json = extractJSON(stdout)
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
            // Pas de résultat exploitable : le texte déjà reçu (flux d'agy), sinon la sortie brute, en réponse partielle.
            let streamed = activity?.partialText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if kind == .agy {
                reply.response = streamed
                if result.stopReason == nil, !result.timedOut {
                    reply.error = agyError(result.stderr)
                        ?? (result.truncated ? "sortie trop volumineuse" : result.exitCode != 0 ? errorDetail(result) : "sortie illisible")
                    if streamed.isEmpty, !stdout.hasPrefix("{") { reply.response = String(stdout.prefix(4000)) }
                }
            } else {
                reply.response = stdout
                if result.exitCode != 0 { reply.error = errorDetail(result) }
            }
        } else if reply.error == nil, result.exitCode != 0, reply.response.isEmpty {
            reply.error = agyError(result.stderr) ?? errorDetail(result)
        }

        if let reason = result.stopReason {
            reply.error = reason
            reply.stoppedByGuard = true
            if reply.response.isEmpty { reply.response = activity?.partialText ?? "" }
        } else if result.timedOut {
            let note = "délai de \(timeoutSeconds) s dépassé"
            reply.error = reply.error.map { "\(note) (\($0))" } ?? note
            if reply.response.isEmpty { reply.response = activity?.partialText ?? "" }
        } else if kind == .agy, result.stderr.contains(printTimeoutMarker) {
            // agy a rendu ce qu'il avait au bout de son délai : réponse partielle (vide s'il cherchait encore).
            reply.partial = true
            if reply.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reply.error == nil {
                reply.error = "Gemini n'a pas fini dans le délai de \(timeoutSeconds) s (réglage timeoutSeconds)"
            }
        }
        if reply.error == nil, reply.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reply.error = "réponse vide" + (stderrTail(result).map { " — \($0)" } ?? "")
        }
        if result.truncated, reply.error == nil {
            reply.response += "\n\n[sortie tronquée : trop volumineuse]"
        }
        if !reply.stoppedByGuard, let error = reply.error, isQuotaError(error) {
            reply.quotaReached = true
            reply.error = "limite d'utilisation de Gemini atteinte (quota du compte Google épuisé) : attendre la recharge, "
                + "en quelques heures ou à la fin de la semaine ; où on en est : \(usagePage) — détail : \(error)"
        }
        return reply
    }

    /// Page des limites d'utilisation du compte Google (pourcentage et heure de recharge). Elle demande une connexion
    /// Google dans un navigateur : le pont ne la lit pas, et agy ne donne son quota que dans son mode interactif (`/usage`).
    public static let usagePage = "https://gemini.google.com/usage"
    /// Textes d'une erreur de quota (agy, gemini-cli, API Google), comparés en minuscules. Des expressions plutôt que
    /// « quota » seul : les journaux d'agy parlent aussi de quota en temps normal (« doRefreshQuota »).
    static let quotaMarkers = ["quota exceeded", "quota reached", "quota limit", "exceeded your", "out of quota", "quota exhausted",
                               "resource_exhausted", "resource exhausted", "rate limit", "ratelimit", "too many requests",
                               "usage limit", "http 429", "code 429", "status 429", "error 429", "429 too"]

    static func isQuotaError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return quotaMarkers.contains { lowered.contains($0) }
    }

    /// Dernier objet final d'agy : l'événement `result` du flux, ou l'objet unique de `--output-format json`.
    static func finalAgyObject(_ text: String) -> JSONValue? {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if case .result(let json)? = StreamEvent.decode(String(line)) { return json }
        }
        guard let json = extractJSON(text), json["event"] == nil else { return nil }
        return json
    }

    /// Message d'une ligne `AGY_ERROR: {…}` qu'agy écrit sur stderr en cas d'erreur du modèle.
    static func agyError(_ stderr: String) -> String? {
        for line in stderr.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: "AGY_ERROR:") else { continue }
            let payload = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let json = try? JSONCoding.parse(payload) else { return String(payload.prefix(300)) }
            let message = ["short_error", "message", "error", "status"].lazy.compactMap { json[$0]?.string }.first { !$0.isEmpty }
            guard let message else { return nil }
            let retry = json["retryable"]?.bool == true ? " (passager : réessayer dans un moment)" : ""
            return String(message.prefix(300)) + retry
        }
        return nil
    }

    /// Le JSON peut être entouré de lignes parasites (avertissements, plusieurs objets) : le texte entier
    /// d'abord, puis la dernière ligne qui est un objet, puis le dernier objet complet trouvé en balayant
    /// les accolades (hors chaînes).
    static func extractJSON(_ text: String) -> JSONValue? {
        if let whole = try? JSONCoding.parse(text), whole.object != nil { return whole }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let value = try? JSONCoding.parse(trimmed), value.object != nil else { continue }
            return value
        }
        return balancedObjects(text).last
    }

    /// Objets JSON complets de premier niveau trouvés dans un texte mêlé.
    static func balancedObjects(_ text: String) -> [JSONValue] {
        var objects: [JSONValue] = []
        let bytes = Array(text.utf8)
        var depth = 0
        var start = 0
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                if depth > 0 { inString = true }
            case UInt8(ascii: "{"):
                if depth == 0 { start = index }
                depth += 1
            case UInt8(ascii: "}"):
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let value = try? JSONCoding.parse(Data(bytes[start...index])), value.object != nil {
                    objects.append(value)
                }
            default:
                break
            }
        }
        return objects
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
    static let gpt = "gpt-oss-120b"

    public static let aliases: [String: String] = [
        "argon": "gemini-4-argon",
        "flash": "gemini-3.8-flash",
        "opus": "claude-opus-5-5",
        "sonnet": "claude-sonnet-5-5",
        "gpt": gpt,
    ]
    static var knownBases: Set<String> { Set(aliases.values) }

    /// Nom en minuscules, sans espaces autour ; `nil` s'il est vide ou mal formé (lettres, chiffres, « . », « _ »,
    /// « - » seulement, sans tiret au début : jamais une option déguisée).
    public static func normalize(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = value.unicodeScalars.first, value.count <= 64,
              CharacterSet.lowercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first),
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) })
        else { return nil }
        return value
    }

    public static func isEffort(_ text: String) -> Bool { efforts.contains(text.lowercased().trimmingCharacters(in: .whitespaces)) }

    /// Base et niveau d'un nom : « flash-high » -> (gemini-3.8-flash, high), « gemini-4-argon-low » -> (gemini-4-argon, low).
    static func split(_ name: String) -> (base: String, level: String?) {
        for level in levels where name.hasSuffix("-\(level)") {
            let head = String(name.dropLast(level.count + 1))
            let base = aliases[head] ?? head
            if knownBases.contains(base) { return (base, level) }
        }
        return (aliases[name] ?? name, nil)
    }

    /// Modèle et effort à passer au programme. Un nom court (ou un identifiant sans niveau) reçoit le
    /// niveau demandé ; un identifiant avec niveau est gardé tel quel ; sans modèle, l'effort reste un réglage séparé.
    public static func resolve(model: String?, effort: String?) -> (model: String?, effort: String?) {
        let effort = effort.flatMap(normalize)
        guard let raw = model.flatMap(normalize) else { return (nil, effort) }
        let (base, level) = split(raw)
        if let level { return (base == gpt ? "\(gpt)-medium" : "\(base)-\(level)", nil) }
        if levels.contains(where: { raw.hasSuffix("-\($0)") }) { return (raw, nil) }
        if let effort, levels.contains(effort), knownBases.contains(base) {
            return (base == gpt ? "\(gpt)-medium" : "\(base)-\(effort)", nil)
        }
        return (base, effort)
    }

    public struct Choice: Equatable, Sendable {
        public var model: String?
        public var effort: String?
        /// Ce qui a été ajusté, pour le pied de la réponse.
        public var notes: [String] = []
    }

    /// Choix final d'une demande : le modèle et l'effort de l'appel l'emportent sur ceux des réglages, et un
    /// effort demandé à l'appel remplace le niveau collé au modèle des réglages. Erreur (avant tout lancement)
    /// pour un nom mal formé, un effort inconnu ou une combinaison qui n'existe pas.
    public static func choose(kind: BackendKind, model asked: String?, effort askedEffort: String?,
                              settings: Settings) throws -> Choice {
        var model: String?
        if let asked, !asked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let valid = normalize(asked) else {
                throw BridgeError.invalid("Modèle « \(asked) » invalide : nom court (\(aliases.keys.sorted().joined(separator: ", "))) ou identifiant de `agy models`.")
            }
            model = valid
        }
        var effort: String?
        if let askedEffort, !askedEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let valid = normalize(askedEffort), efforts.contains(valid) else {
                throw BridgeError.invalid("Effort « \(askedEffort) » inconnu : \(efforts.joined(separator: ", ")).")
            }
            effort = valid
        }
        var notes: [String] = []
        if kind == .gemini {
            let name = model ?? settings.effectiveModel
            if let name {
                let (base, level) = split(name)
                if ["claude-opus-5-5", "claude-sonnet-5-5", gpt].contains(base) || level != nil {
                    throw BridgeError.invalid("Le modèle « \(name) » n'existe que dans agy (réglage « backend »).")
                }
            }
            if effort ?? settings.effectiveEffort != nil { notes.append("effort ignoré par gemini-cli") }
            return Choice(model: name, effort: nil, notes: notes)
        }

        var name = model ?? settings.effectiveModel
        if model == nil, effort != nil, let current = name {
            // L'effort de la demande remplace le niveau du modèle des réglages (gemini-4-argon-high + low -> -low).
            let (base, level) = split(current)
            if level != nil { name = base }
        } else if model != nil, effort != nil, split(model!).level != nil {
            notes.append("effort ignoré : le modèle précise déjà son niveau")
        }
        var wanted = effort ?? settings.effectiveEffort
        if let name, let level = wanted, !levels.contains(level), knownBases.contains(split(name).base) {
            // Erreur seulement si l'appel a demandé cet effort ; celui des réglages est ignoré pour ce modèle.
            if effort != nil {
                throw BridgeError.invalid("« \(name) » n'existe qu'en \(levels.joined(separator: ", ")) (effort « \(level) » demandé).")
            }
            notes.append("effort « \(level) » des réglages ignoré : « \(name) » n'existe qu'en \(levels.joined(separator: ", "))")
            wanted = nil
        }
        if let name, split(name).base == gpt, let wanted, wanted != "medium" {
            notes.append("gpt n'existe qu'en medium")
        }
        let resolved = resolve(model: name, effort: wanted)
        return Choice(model: resolved.model, effort: resolved.effort, notes: notes)
    }
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
        let extra = inheritedPath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for directory in searchDirectories(home: home) + extra {
            let path = "\(directory)/\(kind.binaryName)"
            if fileExists(path) { return path }
        }
        return nil
    }

    /// N'importe quel outil en ligne de commande (ex. `yt-dlp`) : réglage explicite, sinon dossiers usuels et PATH.
    public static func tool(named name: String, override: String?,
                            home: String = NSHomeDirectory(),
                            inheritedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                            fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fileExists(expanded) ? expanded : nil
        }
        let extra = inheritedPath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for directory in searchDirectories(home: home) + extra {
            let path = "\(directory)/\(name)"
            if fileExists(path) { return path }
        }
        return nil
    }

    /// Variables transmises aux programmes : le strict nécessaire (chemins, langue, réseau d'entreprise), jamais
    /// les jetons et clés de l'environnement de Claude (GITHUB_TOKEN, SSH_AUTH_SOCK…). `GEMINI_*` et `GOOGLE_*`
    /// ne servent qu'à gemini-cli (voir `restricted`).
    static let keptVariables: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TZ", "__CF_USER_TEXT_ENCODING",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
    ]
    static let keptPrefixes = ["LC_", "XDG_", "GEMINI_", "GOOGLE_", "ANTIGRAVITY_"]

    /// Environnement de lancement, avec un PATH complet (gemini-cli est un script `#!/usr/bin/env node`) fait
    /// d'entrées absolues seulement, et `temporaryDirectory` comme TMPDIR s'il est donné.
    public static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment,
                                   home: String = NSHomeDirectory(), temporaryDirectory: String? = nil) -> [String: String] {
        var env = inherited.filter { key, _ in keptVariables.contains(key) || keptPrefixes.contains { key.hasPrefix($0) } }
        let extra = searchDirectories(home: home) + ["/bin", "/usr/sbin", "/sbin"]
        let current = (inherited["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var seen = Set<String>()
        env["PATH"] = (extra + current).filter { seen.insert($0).inserted }.joined(separator: ":")
        env["HOME"] = home
        if let temporaryDirectory { env["TMPDIR"] = temporaryDirectory.hasSuffix("/") ? temporaryDirectory : temporaryDirectory + "/" }
        // Pas de couleurs ni d'interface dans une sortie lue par une machine.
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    /// Environnement pour un programme donné : les clés Google (`GEMINI_*`, `GOOGLE_*`) ne vont qu'à gemini-cli.
    public static func restricted(_ env: [String: String], for kind: BackendKind?) -> [String: String] {
        guard kind != .gemini else { return env }
        return env.filter { key, _ in !key.hasPrefix("GEMINI_") && !key.hasPrefix("GOOGLE_") }
    }
}
