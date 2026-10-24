import Foundation

/// Fichiers joints à une demande : copiés dans le dossier de travail de Gemini (qui ne voit rien d'autre
/// sur le Mac) pour qu'il les lise avec son outil `read_file`, puis effacés à la fin de la demande.
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
    static let sensitiveNameParts = ["secret", "token", "credential", "password", "passwd", "apikey", "api_key", "api-key", "id_rsa", "id_ed25519", "private"]

    public struct Prepared: Equatable {
        public var directory: URL
        /// Chemins relatifs au dossier de travail, à donner à Gemini.
        public var relativePaths: [String]
    }

    public static func prepare(paths: [String], workspace: URL, home: String, id: String) throws -> Prepared {
        guard !paths.isEmpty else { return Prepared(directory: workspace, relativePaths: []) }
        guard paths.count <= maxFiles else {
            throw BridgeError.invalid("Au plus \(maxFiles) fichiers joints par demande (reçu : \(paths.count)).")
        }
        let directory = workspace.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(id, isDirectory: true)
        let fileManager = FileManager.default
        var relative: [String] = []
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, raw) in paths.enumerated() {
                let source = try validate(raw, home: home)
                let name = "\(index + 1)-\(sanitize(source.lastPathComponent))"
                try fileManager.copyItem(at: source, to: directory.appendingPathComponent(name))
                relative.append("\(folderName)/\(id)/\(name)")
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return Prepared(directory: directory, relativePaths: relative)
    }

    public static func remove(_ prepared: Prepared) {
        try? FileManager.default.removeItem(at: prepared.directory)
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
        let allowed: Bool
        if inHome {
            allowed = ["Desktop", "Documents", "Downloads", "Pictures"].contains(components.first ?? "")
        } else {
            allowed = path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/folders/")
        }
        guard allowed else {
            throw BridgeError.invalid("Fichier joint « \(raw) » refusé : seuls les dossiers Bureau, Documents, Téléchargements et Images (et /tmp) sont acceptés.")
        }
        let lowerName = url.lastPathComponent.lowercased()
        if sensitiveNameParts.contains(where: { lowerName.contains($0) }) {
            throw BridgeError.invalid("Fichier joint « \(raw) » refusé : le nom évoque un secret (mot de passe, jeton, clé…).")
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
        return url
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

    /// Texte ajouté à la demande pour que Gemini lise les fichiers.
    public static func promptNote(_ relativePaths: [String]) -> String {
        guard !relativePaths.isEmpty else { return "" }
        let list = relativePaths.map { "- \($0)" }.joined(separator: "\n")
        return "\n\nFichiers joints (chemins relatifs à ton dossier de travail ; lis-les avec `read_file`) :\n\(list)"
    }
}
