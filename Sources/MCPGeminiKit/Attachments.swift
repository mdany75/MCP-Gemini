import Foundation

/// Fichiers joints à une demande : copiés dans le dossier de travail de Gemini (qui ne voit rien d'autre
/// sur le Mac) pour qu'il les lise avec son outil de lecture, `view_file` (agy) ou `read_file` (gemini-cli),
/// puis effacés à la fin de la demande.
///
/// Les chemins viennent de Claude, donc potentiellement d'un contenu piégé : seuls des fichiers de
/// documents et d'images sont acceptés, jamais de dossiers cachés ni de secrets (clés, trousseau, `.env`…).
public enum Attachments {
    public static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "txt", "md", "csv", "tsv", "json", "log",
    ]
    public static let maxFiles = 5
    public static let maxBytes = 20 * 1024 * 1024
    static let folderName = "attachments"

    /// Mots (après repli de la casse et des accents, découpage sur espace, -, _ et .) qui font refuser
    /// un composant du chemin. Mots entiers seulement : « seedling » passe, « seed » non.
    static let sensitiveWords: Set<String> = [
        "cle", "cles", "mdp", "otp", "seed", "wallet", "jeton", "jetons", "token", "tokens", "secret", "secrets",
        "password", "passwords", "passwd", "credential", "credentials", "logins", "keychain", "trousseau", "mnemonic",
    ]
    /// Fragments cherchés dans un composant dont on a retiré les séparateurs (« Mots de passe » → « motsdepasse »).
    static let sensitiveFragments = [
        "motdepasse", "motsdepasse", "password", "apikey", "privatekey", "idrsa", "ided25519", "recoverycode",
        "backupcode", "codedesecours", "codesdesecours", "bitwarden", "1password", "keepass", "lastpass",
        "serviceaccount", "adminsdk",
    ]
    /// Fichiers texte dont le début est lu pour y chercher une clé ou un jeton.
    static let scannedExtensions: Set<String> = ["txt", "md", "csv", "tsv", "json", "log"]
    static let scannedBytes = 256 * 1024
    /// Clé privée PEM, compte de service Google, clés AWS, GitHub, Slack, Anthropic et Google.
    static let secretPattern = try! NSRegularExpression(pattern: [
        #"PRIVATE KEY-----"#, #""private_key""#, #""type"\s*:\s*"service_account""#, #"AKIA[0-9A-Z]{16}"#,
        #"\bghp_[A-Za-z0-9]{20,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#, #"\bxox[abp]-[A-Za-z0-9-]{10,}"#,
        #"\bsk-ant-[A-Za-z0-9_-]{20,}"#, #"AIza[0-9A-Za-z_-]{35}"#,
    ].joined(separator: "|"))

    public struct Prepared: Equatable {
        public var directory: URL
        /// Chemins relatifs au dossier de travail, à donner à Gemini.
        public var relativePaths: [String]
    }

    /// Fichier produit par le serveur (par exemple une transcription) et joint comme les fichiers de Claude.
    public struct GeneratedFile: Equatable, Sendable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// Dossiers préparés par ce processus et pas encore retirés : effacés à l'arrêt du serveur.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var preparedDirectories = Set<URL>()

    public static func prepare(paths: [String], generated: [GeneratedFile] = [], workspace: URL, home: String,
                               id: String) throws -> Prepared {
        guard !paths.isEmpty || !generated.isEmpty else { return Prepared(directory: workspace, relativePaths: []) }
        guard paths.count <= maxFiles else {
            throw BridgeError.invalid("Au plus \(maxFiles) fichiers joints par demande (reçu : \(paths.count)).")
        }
        let directory = workspace.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(id, isDirectory: true)
        let fileManager = FileManager.default
        var relative: [String] = []
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            register(directory)
            for (index, raw) in paths.enumerated() {
                let source = try validate(raw, home: home)
                let name = "\(index + 1)-\(sanitize(source.lastPathComponent))"
                try fileManager.copyItem(at: source, to: directory.appendingPathComponent(name))
                relative.append("\(folderName)/\(id)/\(name)")
            }
            for (offset, file) in generated.enumerated() {
                let name = "\(paths.count + offset + 1)-\(sanitize(file.name))"
                guard allowedExtensions.contains(URL(fileURLWithPath: name).pathExtension), file.data.count <= maxBytes else {
                    throw BridgeError.invalid("Fichier « \(file.name) » produit par le serveur : type refusé ou trop gros.")
                }
                try file.data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
                relative.append("\(folderName)/\(id)/\(name)")
            }
        } catch {
            remove(Prepared(directory: directory, relativePaths: relative))
            throw error
        }
        return Prepared(directory: directory, relativePaths: relative)
    }

    public static func remove(_ prepared: Prepared) {
        // Garde-fou : seul un sous-dossier de « attachments » est effacé, jamais le dossier de travail
        // (que rend `prepare` quand il n'y a rien à joindre).
        guard prepared.directory.deletingLastPathComponent().lastPathComponent == folderName else { return }
        try? FileManager.default.removeItem(at: prepared.directory)
        registryLock.lock()
        preparedDirectories.remove(prepared.directory)
        registryLock.unlock()
    }

    /// Arrêt du serveur : efface les copies des demandes encore en cours.
    public static func removeAllPrepared() {
        registryLock.lock()
        let directories = preparedDirectories
        preparedDirectories.removeAll()
        registryLock.unlock()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private static func register(_ directory: URL) {
        registryLock.lock()
        preparedDirectories.insert(directory)
        registryLock.unlock()
    }

    /// Efface les pièces jointes oubliées (arrêt brutal du serveur) de plus d'une heure.
    public static func purgeStale(workspace: URL, olderThan age: TimeInterval = 3600) {
        let root = workspace.appendingPathComponent(folderName, isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// Chemin réel d'un fichier acceptable, ou une erreur qui dit pourquoi il est refusé.
    static func validate(_ raw: String, home: String) throws -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw BridgeError.invalid("Fichier joint « \(raw) » : donner un chemin complet (commençant par / ou ~).")
        }
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        var path = url.path
        let inHome = path.hasPrefix(homePath + "/")
        if inHome { path = String(path.dropFirst(homePath.count + 1)) }
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { $0.hasPrefix(".") }) {
            throw BridgeError.invalid("Fichier joint « \(raw) » refusé : les fichiers et dossiers cachés ne sont pas envoyés à Gemini.")
        }
        // Liste blanche : seuls les dossiers où l'on range des documents. Le reste de ~/Library (réglages des
        // applications, jetons, courrier…) et du disque n'est jamais envoyé à Google.
        let allowed = inHome
            ? ["Desktop", "Documents", "Downloads", "Pictures"].contains(components.first ?? "")
            : isAllowedOutsideHome(components)
        guard allowed else {
            throw BridgeError.invalid("Fichier joint « \(raw) » refusé : seuls les dossiers Bureau, Documents, Téléchargements et Images "
                                      + "sont acceptés, ainsi qu'un fichier placé directement dans /tmp ou dans le brouillon (scratchpad) de Claude Code.")
        }
        if let component = components.first(where: looksSensitive) {
            throw BridgeError.invalid("Fichier joint « \(raw) » refusé : « \(component) » évoque un secret (mot de passe, jeton, clé…).")
        }
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw BridgeError.invalid("Fichier joint « \(raw) » refusé : seuls ces types sont acceptés : \(allowedExtensions.sorted().joined(separator: ", ")).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BridgeError.invalid("Fichier joint « \(raw) » introuvable.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxBytes else {
            throw BridgeError.invalid("Fichier joint « \(raw) » trop gros (\(size / 1_048_576) Mo ; maximum \(maxBytes / 1_048_576) Mo).")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw BridgeError.invalid("Fichier joint « \(raw) » illisible (autorisation).")
        }
        if scannedExtensions.contains(ext), containsSecret(url) {
            throw BridgeError.invalid("Fichier joint « \(raw) » refusé : il semble contenir une clé ou un jeton d'accès "
                                      + "(clé privée, compte de service, clé d'API…) ; il n'est pas envoyé à Gemini.")
        }
        return url
    }

    /// Hors du dossier personnel : un fichier placé directement dans /tmp, ou dans le brouillon d'une session
    /// de Claude Code (/tmp/claude-<uid>/…/scratchpad/…). Le reste de /tmp (dont les sorties d'outils de toutes
    /// les sessions de Claude Code) et le dossier temporaire des applications (/var/folders) sont refusés.
    static func isAllowedOutsideHome(_ components: [String]) -> Bool {
        var parts = components
        // `resolvingSymlinksInPath` retire d'ordinaire « /private » (/tmp est un lien vers /private/tmp).
        if parts.first == "private" { parts.removeFirst() }
        guard parts.first == "tmp" else { return false }
        if parts.count == 2 { return true }
        guard parts.count >= 4, parts[1].hasPrefix("claude-"), let scratchpad = parts.firstIndex(of: "scratchpad") else { return false }
        return scratchpad >= 2 && scratchpad < parts.count - 1
    }

    /// Un composant du chemin évoque-t-il un secret ? Casse et accents repliés (« Clés » → « cles »).
    static func looksSensitive(_ component: String) -> Bool {
        let folded = component.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-_."))).filter { !$0.isEmpty }
        if words.contains(where: sensitiveWords.contains) { return true }
        let joined = words.joined()
        return sensitiveFragments.contains { joined.contains($0) }
    }

    /// Le début d'un fichier texte contient-il une clé ou un jeton reconnaissable ?
    static func containsSecret(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: scannedBytes), !data.isEmpty else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return secretPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Nom sûr : l'extension (déjà contrôlée) est conservée même si le nom est tronqué.
    static func sanitize(_ name: String) -> String {
        func clean(_ text: String) -> String {
            String(text.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || "_- ".unicodeScalars.contains(scalar) ? Character(scalar) : "_"
            })
        }
        let url = URL(fileURLWithPath: name)
        let ext = clean(url.pathExtension.lowercased())
        var base = clean(url.deletingPathExtension().lastPathComponent).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "fichier" }
        base = String(base.prefix(80))
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Texte ajouté à la demande pour que Gemini lise les fichiers, avec le nom de l'outil de lecture du programme.
    public static func promptNote(_ relativePaths: [String], backend: BackendKind) -> String {
        guard !relativePaths.isEmpty else { return "" }
        let tool: String
        switch backend {
        case .agy: tool = "view_file"
        case .gemini: tool = "read_file"
        }
        let list = relativePaths.map { "- \($0)" }.joined(separator: "\n")
        return "\n\nFichiers joints (chemins relatifs à ton dossier de travail ; lis-les avec `\(tool)`) :\n\(list)"
    }
}
