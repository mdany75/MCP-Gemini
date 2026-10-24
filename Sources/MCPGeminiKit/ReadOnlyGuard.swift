import Foundation

/// Garde-fou de la lecture seule, pour agy.
///
/// `--mode plan` n'est qu'une consigne (`/plan`) donnée au modèle : un « plan approuvé » le fait passer à
/// l'action, et des réglages d'agy plus permissifs (choisis par l'utilisateur pour son propre usage)
/// pourraient lever les demandes d'accord. Le pont lit donc le flux d'agy : il exige le mode plan au départ,
/// puis arrête la demande dès qu'un outil hors liste démarre ou qu'une lecture sort des dossiers permis.
/// L'arrêt arrive au début de l'étape : il limite les dégâts, il ne remplace pas le refus d'agy lui-même
/// (sans terminal, toute action qui demande un accord est refusée d'office).
public final class ReadOnlyGuard: @unchecked Sendable {
    /// Autorisations d'agy acceptées : chaque action sensible demande un accord, refusé d'office sans terminal.
    static let acceptedPermissionModes: Set<String> = ["request-review"]
    /// Outils qui cherchent, lisent ou attendent ; les chemins lus sont contrôlés à part.
    static let allowedTools: Set<String> = [
        "search_web", "read_url_content", "view_file", "read_file", "list_dir", "grep_search", "find_by_name",
        "generate_image", "finish", "wait", "wait_5_seconds", "ask_question", "ask_permission",
        "ask_custom_permission", "list_permissions", "list_resources", "read_resource",
        "open_browser_url", "read_browser_page", "list_browser_pages", "capture_browser_screenshot",
        "capture_browser_console_logs", "browser_get_dom", "browser_scroll", "browser_scroll_dom",
        "browser_resize_window", "browser_refresh_page", "browser_list_network_requests", "browser_get_network_request",
    ]
    /// Outils qui lisent des fichiers (`generate_image` peut prendre des images de référence) : leurs chemins
    /// doivent rester dans les dossiers permis.
    static let readers: Set<String> = ["view_file", "read_file", "list_dir", "grep_search", "find_by_name",
                                       "generate_image", "read_resource", "list_resources"]
    /// Lectures récursives : la racine du dossier de travail les mènerait aux fichiers joints des autres demandes.
    static let recursiveReaders: Set<String> = ["grep_search", "find_by_name"]
    /// Outils qui ouvrent une adresse : web seulement (pas de file://, chrome://…).
    static let urlOpeners: Set<String> = ["read_url_content", "open_browser_url", "read_browser_page"]
    /// Écritures permises seulement dans le dossier de la conversation (plans et rapports d'agy).
    static let artifactWriters: Set<String> = ["write_file", "write_to_file"]
    /// Sous-agents permis (leurs propres étapes n'apparaissent pas dans le flux).
    static let allowedSubagents: Set<String> = ["image-generator"]
    /// Nom de sous-agent comparable : « Image Generator », « image_generator » -> « image-generator ».
    static func subagentName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
    }
    /// `schedule` : réveil ponctuel qu'agy utilise pour attendre un sous-agent. Permis seulement après un sous-agent
    /// permis, avec ces seuls paramètres et un délai borné (jamais une tâche répétée).
    static let scheduleParameters: Set<String> = ["DurationSeconds", "Prompt"]
    static let maxScheduleSeconds = 600.0
    /// Texte de la raison d'arrêt quand agy a ouvert une autre conversation que celle demandée.
    public static let lostConversation = "conversation agy introuvable"

    private let lock = NSLock()
    private let expectedConversation: String?
    private let brain: URL
    private let workspace: URL
    private let attachments: URL?
    private var conversation: String?
    private var lost = false
    private var subagentStarted = false
    /// Un sous-agent annoncé sans son type : son type réel est lu dans le dossier d'agy.
    private var subagentToVerify = false
    private var verifiedSubagents = Set<String>()
    private let startedAt: Date

    /// - Parameters:
    ///   - expectedConversation: conversation reprise (`--conversation`), pour repérer une conversation perdue.
    ///   - attachments: dossier des fichiers joints à cette demande, seul sous-dossier du dossier de travail lisible.
    public init(expectedConversation: String?, home: String, workspace: URL, attachments: URL?, startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.expectedConversation = expectedConversation
        brain = GeneratedFiles.brainDirectory(home: home).standardizedFileURL
        self.workspace = workspace.standardizedFileURL
        self.attachments = attachments?.standardizedFileURL
    }

    /// `true` si agy a ouvert une autre conversation que celle demandée (supprimée de son côté).
    public var conversationLost: Bool { lock.lock(); defer { lock.unlock() }; return lost }

    /// Raison d'arrêter la demande, ou `nil` pour la laisser continuer.
    public func inspect(_ event: StreamEvent) -> String? {
        // Un sous-agent annoncé par son seul rôle : son type réel (écrit par agy) est vérifié à chaque événement.
        if let reason = verifySubagents() { return reason }
        switch event {
        case .started(let start):
            lock.lock()
            if let id = start.conversationId { conversation = id }
            lock.unlock()
            guard start.commands.contains("plan") else {
                return "agy n'a pas appliqué le mode plan (lecture seule) : demande arrêtée par le pont."
            }
            guard let mode = start.permissionMode, Self.acceptedPermissionModes.contains(mode) else {
                return "agy tourne avec les autorisations « \(start.permissionMode ?? "inconnues") » au lieu de « request-review » "
                    + "(réglages d'agy plus permissifs ?) : demande arrêtée par sécurité."
            }
            if let expected = expectedConversation, let id = start.conversationId, id != expected {
                lock.lock()
                lost = true
                lock.unlock()
                return Self.lostConversation
            }
            return nil
        case .tool(let step, _, _, let parameters):
            return check(tool: step.tool, parameters: parameters)
        default:
            return nil
        }
    }

    func check(tool: String, parameters: JSONValue?) -> String? {
        if tool == "invoke_subagent" {
            let types = parameters?["subagent_types"]?.array?.compactMap(\.string) ?? []
            let roles = parameters?["subagent_roles"]?.array?.compactMap(\.string) ?? []
            if !types.isEmpty, types.allSatisfy({ Self.allowedSubagents.contains(Self.subagentName($0)) }) {
                lock.lock()
                subagentStarted = true
                lock.unlock()
                return nil
            }
            if types.isEmpty, !roles.isEmpty {
                // Type absent de l'événement : le rôle ne prouve rien (libellé libre). On laisse partir, et le type
                // réel est vérifié dans le dossier d'agy dès maintenant puis à chaque événement et à la fin.
                lock.lock()
                subagentStarted = true
                subagentToVerify = true
                lock.unlock()
                return verifySubagents()
            }
            let names = types.isEmpty ? "" : " (\(types.joined(separator: ", ")))"
            return "Gemini a voulu lancer un sous-agent\(names), interdit en lecture seule : demande arrêtée par le pont."
        }
        if tool == "schedule" {
            lock.lock()
            let waiting = subagentStarted
            lock.unlock()
            let keys = Set(parameters?.object?.keys.map { $0 } ?? [])
            let seconds = parameters?["DurationSeconds"].flatMap { $0.double ?? $0.string.flatMap(Double.init) }
            if waiting, keys.isSubset(of: Self.scheduleParameters), let seconds, seconds > 0, seconds <= Self.maxScheduleSeconds {
                return nil
            }
            return "Gemini a voulu programmer une tâche (« schedule ») hors de l'attente d'un sous-agent d'image : demande arrêtée par le pont."
        }
        if Self.artifactWriters.contains(tool) {
            let paths = Self.paths(in: parameters)
            if !paths.isEmpty, paths.allSatisfy(isInConversation) { return nil }
            return "Gemini a voulu écrire un fichier hors de son dossier de conversation (\(paths.first ?? "chemin inconnu")) : demande arrêtée par le pont."
        }
        guard Self.allowedTools.contains(tool) else {
            let detail = ActivityStep.detail(of: parameters).map { " (\($0))" } ?? ""
            return "Gemini a voulu utiliser l'outil « \(tool) »\(detail), interdit en lecture seule : demande arrêtée par le pont."
        }
        if Self.urlOpeners.contains(tool), let address = Self.addresses(in: parameters).first(where: { !Self.isWebAddress($0) }) {
            return "Gemini a voulu ouvrir « \(address) », qui n'est pas une adresse web : demande arrêtée par le pont."
        }
        if Self.readers.contains(tool) {
            let paths = Self.paths(in: parameters)
            if let outside = paths.first(where: { !isReadable($0, recursive: Self.recursiveReaders.contains(tool)) }) {
                return "Gemini a voulu lire « \(outside) », hors des fichiers joints à cette demande : demande arrêtée par le pont."
            }
            // Sans chemin, une recherche récursive part du dossier de travail.
            if paths.isEmpty, Self.recursiveReaders.contains(tool), !workspaceHoldsOnlyThisRequest() {
                return "Gemini a voulu chercher dans tout le dossier de travail, qui contient les fichiers joints d'autres demandes : demande arrêtée par le pont."
            }
        }
        return nil
    }

    /// Chaînes rangées sous une clé dont le nom contient l'un de `markers`, y compris dans des tableaux ou des objets.
    static func values(in parameters: JSONValue?, keyedBy markers: [String]) -> [String] {
        func strings(_ value: JSONValue) -> [String] {
            switch value {
            case .string(let text): return text.isEmpty ? [] : [text]
            case .array(let items): return items.flatMap(strings)
            case .object(let object): return object.values.flatMap(strings)
            default: return []
            }
        }
        func walk(_ value: JSONValue) -> [String] {
            switch value {
            case .object(let object):
                return object.keys.sorted().flatMap { key -> [String] in
                    let lower = key.lowercased()
                    return markers.contains { lower.contains($0) } ? strings(object[key]!) : walk(object[key]!)
                }
            case .array(let items): return items.flatMap(walk)
            default: return []
            }
        }
        return parameters.map(walk) ?? []
    }

    /// Type réel des sous-agents lancés pendant cette demande, d'après les fichiers qu'agy écrit dans
    /// `brain/<conversation>/.system_generated/subagents/` (`subagentDescriptor.typeName`). Rend une raison d'arrêter
    /// si l'un d'eux n'est pas permis. Sans effet tant qu'aucun sous-agent n'a été annoncé sans son type.
    public func verifySubagents() -> String? {
        lock.lock()
        let pending = subagentToVerify
        let id = conversation
        let known = verifiedSubagents
        lock.unlock()
        guard pending, let id, GeneratedFiles.isSafeIdentifier(id) else { return nil }
        let folder = brain.appendingPathComponent(id, isDirectory: true).appendingPathComponent(".system_generated/subagents", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        for entry in entries where entry.pathExtension == "json" && !known.contains(entry.lastPathComponent) {
            guard let info = try? entry.resourceValues(forKeys: Set(keys)), info.isRegularFile == true,
                  (info.contentModificationDate ?? .distantPast) >= startedAt.addingTimeInterval(-2),
                  (info.fileSize ?? 0) <= 1_048_576 else { continue }
            guard let data = FileManager.default.contents(atPath: entry.path), let json = try? JSONCoding.parse(data) else { continue }
            let type = json["subagentDescriptor"]?["typeName"]?.string ?? json["typeName"]?.string ?? ""
            guard Self.allowedSubagents.contains(Self.subagentName(type)) else {
                return "Gemini a lancé un sous-agent de type « \(type.isEmpty ? "inconnu" : type) », interdit en lecture seule : demande arrêtée par le pont."
            }
            lock.lock()
            verifiedSubagents.insert(entry.lastPathComponent)
            lock.unlock()
        }
        return nil
    }

    /// Valeurs des paramètres qui désignent un chemin (Path, AbsolutePath, SearchDirectory, TargetFile, ImagePaths, Uri…).
    static func paths(in parameters: JSONValue?) -> [String] {
        values(in: parameters, keyedBy: ["path", "dir", "file", "uri"]).map { value in
            value.hasPrefix("file://") ? URL(string: value)?.path ?? value : value
        }
    }

    /// Adresses que veut ouvrir un outil web.
    static func addresses(in parameters: JSONValue?) -> [String] {
        values(in: parameters, keyedBy: ["url", "uri"])
    }

    static func isWebAddress(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : workspace.appendingPathComponent(expanded)
        // Les liens symboliques sont résolus quand le chemin existe : un lien dans un dossier permis ne mène pas ailleurs.
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().path
        return url.path == rootPath || url.path.hasPrefix(rootPath + "/")
    }

    private func isInConversation(_ path: String) -> Bool {
        lock.lock()
        let id = conversation
        lock.unlock()
        guard let id, GeneratedFiles.isSafeIdentifier(id) else { return false }
        return Self.isInside(resolve(path), brain.appendingPathComponent(id, isDirectory: true))
    }

    /// Lecture permise : les fichiers joints à cette demande, le dossier de la conversation d'agy (ses plans, ses
    /// images), et la racine du dossier de travail (vide) : pour une lecture récursive, seulement si aucune autre
    /// demande n'y a de fichiers joints.
    private func isReadable(_ path: String, recursive: Bool) -> Bool {
        let url = resolve(path)
        if url.path == workspace.resolvingSymlinksInPath().path { return !recursive || workspaceHoldsOnlyThisRequest() }
        if let attachments, Self.isInside(url, attachments) { return true }
        return isInConversation(path)
    }

    /// `attachments/` ne contient que le dossier de cette demande (ou rien).
    private func workspaceHoldsOnlyThisRequest() -> Bool {
        let root = workspace.appendingPathComponent("attachments", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return true }
        let mine = attachments?.lastPathComponent
        return entries.allSatisfy { $0 == mine || $0.hasPrefix(".") }
    }
}
