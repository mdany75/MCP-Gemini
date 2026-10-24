import Foundation
import ImageIO

/// Fichiers produits par agy pendant une demande : images de `generate_image`, plans et rapports qu'il
/// range dans `~/.gemini/antigravity-cli/brain/<conversation>/`. Son interface les montre à l'utilisateur ;
/// le pont les renvoie à Claude (images en contenu image, textes en clair) pour qu'il les voie aussi.
///
/// Lecture seule, dans le dossier de la conversation que le programme vient de renvoyer (jamais un chemin
/// venu de Claude) : fichiers ordinaires du premier niveau seulement, ni cachés ni liens symboliques.
public enum GeneratedFiles {
    public enum Kind: Equatable, Sendable {
        case image(mimeType: String)
        case document
        case other
    }

    public struct Item: Equatable, Sendable {
        public var url: URL
        public var kind: Kind
        public var size: Int
        /// Résumé donné par agy (fichier `.metadata.json` voisin).
        public var summary: String?
        /// agy attend une validation de ce document (un plan) avant d'agir.
        public var awaitsApproval: Bool
    }

    static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"]
    static let documentTypes: Set<String> = ["md", "txt"]
    /// Une image plus grosse n'est pas envoyée à Claude (seul son chemin l'est).
    public static let maxImageBytes = 3_500_000
    public static let maxImages = 4
    public static let maxDocumentCharacters = 12_000
    static let maxItems = 10

    public static func brainDirectory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
    }

    /// Identifiant de conversation sûr comme nom de dossier (lettres, chiffres, tirets).
    static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    /// Fichiers créés ou modifiés depuis `since` dans le dossier de la conversation, du plus ancien au plus récent.
    public static func collect(conversationId: String, since: Date, home: String) -> [Item] {
        guard isSafeIdentifier(conversationId) else { return [] }
        let directory = brainDirectory(home: home).appendingPathComponent(conversationId, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return [] }
        // Marge : l'horloge du fichier peut précéder de peu celle du lancement.
        let threshold = since.addingTimeInterval(-2)
        let found: [(URL, Date, Int)] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), !name.hasSuffix(".metadata.json"),
                  let info = try? url.resourceValues(forKeys: Set(keys)),
                  info.isRegularFile == true, info.isSymbolicLink != true,
                  let modified = info.contentModificationDate, modified >= threshold else { return nil }
            return (url, modified, info.fileSize ?? 0)
        }
        return found.sorted { $0.1 < $1.1 }.prefix(maxItems).map { url, _, size in
            let ext = url.pathExtension.lowercased()
            let kind: Kind = imageTypes[ext].map { .image(mimeType: $0) } ?? (documentTypes.contains(ext) ? .document : .other)
            let metadata = readMetadata(for: url)
            return Item(url: url, kind: kind, size: size, summary: metadata.summary, awaitsApproval: metadata.awaitsApproval)
        }
    }

    static func readMetadata(for url: URL) -> (summary: String?, awaitsApproval: Bool) {
        let path = url.path + ".metadata.json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? Int ?? 0) <= 64 * 1024,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONCoding.parse(data) else { return (nil, false) }
        let summary = json["summary"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) }
        return (summary, json["requestFeedback"]?.bool ?? false)
    }

    /// Contenu d'un document, coupé à `limit` caractères ; `nil` s'il est illisible.
    public static func documentText(_ item: Item, limit: Int = maxDocumentCharacters) -> String? {
        guard item.kind == .document, item.size <= 2 * 1024 * 1024,
              let data = FileManager.default.contents(atPath: item.url.path) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "\n[…document tronqué]" : text
    }

    /// Côté le plus long d'une image envoyée à Claude (au-delà, elle est réduite).
    public static let maxImagePixels = 1568
    /// Taille maximale d'une image lue sur le disque avant réduction.
    static let maxSourceImageBytes = 20 * 1024 * 1024

    /// Image prête à joindre : décodée puis réencodée (JPEG, ou PNG si elle a de la transparence), réduite à
    /// `maxImagePixels`. Un fichier qui n'est pas une vraie image n'est pas joint.
    public static func preparedImage(_ item: Item) -> (data: Data, mimeType: String)? {
        guard case .image = item.kind, item.size > 0, item.size <= maxSourceImageBytes,
              let data = FileManager.default.contents(atPath: item.url.path),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let alpha = image.alphaInfo
        let transparent = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let type = transparent ? "public.png" : "public.jpeg"
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0, output.length <= maxImageBytes else { return nil }
        return (output as Data, transparent ? "image/png" : "image/jpeg")
    }

    /// Dossier de la conversation lisible par l'utilisateur seul (agy le crée lisible par tous les comptes du Mac).
    public static func protect(conversationId: String, home: String) {
        guard isSafeIdentifier(conversationId) else { return }
        let directory = brainDirectory(home: home).appendingPathComponent(conversationId, isDirectory: true)
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Le dossier de toutes les conversations d'agy, lisible par l'utilisateur seul (couvre aussi une demande
    /// arrêtée ou une conversation abandonnée).
    public static func protectBrain(home: String) {
        let directory = brainDirectory(home: home)
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
