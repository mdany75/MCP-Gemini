import Foundation

/// Sous-titres d'une vidéo YouTube : `yt-dlp` donne les métadonnées et les adresses des pistes, le serveur
/// télécharge la piste choisie (texte WebVTT seulement, jamais la vidéo) et la met en forme.
public enum YouTubeTranscript {
    static let allowedHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]

    /// Adresse normalisée, ou `nil` si ce n'est pas une adresse YouTube en https.
    public static func validate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: trimmed), url.scheme == "https",
              let host = url.host?.lowercased(), allowedHosts.contains(host) else { return nil }
        return url.absoluteString
    }

    public struct Track: Equatable {
        public var language: String
        public var url: String
        public var isAutomatic: Bool
    }

    /// Choisit la piste VTT : la langue demandée, sinon la langue d'origine de la vidéo (sous-titres
    /// publiés d'abord, puis automatiques), sinon anglais ou français, sinon la première disponible.
    public static func pickTrack(json: JSONValue, language: String?) -> Track? {
        let manual = json["subtitles"]?.object ?? [:]
        let automatic = json["automatic_captions"]?.object ?? [:]

        func vtt(_ tracks: [String: JSONValue], _ key: String) -> String? {
            tracks[key]?.array?.first { entry in
                guard entry["ext"]?.string == "vtt", let raw = entry["url"]?.string, let url = URL(string: raw),
                      url.scheme == "https", let host = url.host?.lowercased(),
                      host == "youtube.com" || host.hasSuffix(".youtube.com") else { return false }
                return !(entry["protocol"]?.string ?? "").contains("m3u8")
            }?["url"]?.string
        }
        func find(_ tracks: [String: JSONValue], _ wanted: String, auto: Bool) -> Track? {
            let keys = tracks.keys.sorted()
            let key = keys.first { $0.lowercased() == wanted.lowercased() }
                ?? keys.first { $0.lowercased().hasPrefix(wanted.lowercased() + "-") && !$0.hasSuffix("-orig") }
            guard let key, let url = vtt(tracks, key) else { return nil }
            return Track(language: key, url: url, isAutomatic: auto)
        }

        if let language = language?.lowercased(), !language.isEmpty {
            if let track = find(manual, language, auto: false) ?? find(automatic, language, auto: true) { return track }
            // « en-US » demandé : repli sur la langue de base « en ».
            if let base = language.split(separator: "-").first.map(String.init), base != language {
                return find(manual, base, auto: false) ?? find(automatic, base, auto: true)
            }
            return nil
        }
        if let original = json["language"]?.string, !original.isEmpty {
            if let track = find(manual, original, auto: false) { return track }
            if let url = vtt(automatic, "\(original)-orig") { return Track(language: "\(original)-orig", url: url, isAutomatic: true) }
            if let track = find(automatic, original, auto: true) { return track }
        }
        for key in manual.keys.sorted() where ["en", "fr"].contains(key) {
            if let url = vtt(manual, key) { return Track(language: key, url: url, isAutomatic: false) }
        }
        if let key = manual.keys.sorted().first(where: { vtt(manual, $0) != nil }), let url = vtt(manual, key) {
            return Track(language: key, url: url, isAutomatic: false)
        }
        if let key = automatic.keys.sorted().first(where: { $0.hasSuffix("-orig") }), let url = vtt(automatic, key) {
            return Track(language: key, url: url, isAutomatic: true)
        }
        for key in ["en", "fr"] {
            if let track = find(automatic, key, auto: true) { return track }
        }
        if let key = manual.keys.sorted().first, let url = vtt(manual, key) { return Track(language: key, url: url, isAutomatic: false) }
        return nil
    }

    public struct Cue: Equatable {
        public var start: Double
        public var text: String
    }

    /// Texte des sous-titres sans les doublons des sous-titres « défilants » de YouTube : chaque bloc
    /// répète les lignes du précédent, on ne garde que les lignes nouvelles.
    public static func parseVTT(_ vtt: String, deduplicate: Bool = true) -> [Cue] {
        var cues: [Cue] = []
        var previousLines: [String] = []
        var blockStart: Double?
        var blockLines: [String] = []

        func flush() {
            defer { blockStart = nil; blockLines = [] }
            guard let start = blockStart, !blockLines.isEmpty else { return }
            for line in blockLines where !deduplicate || !previousLines.contains(line) {
                cues.append(Cue(start: start, text: line))
            }
            previousLines = blockLines
        }

        for rawLine in vtt.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let time = parseTimeRange(line) {
                flush()
                blockStart = time
                continue
            }
            if rawLine.trimmingCharacters(in: .newlines).isEmpty { flush(); continue }
            if line.isEmpty { continue }
            guard blockStart != nil else { continue }
            let text = clean(line)
            if !text.isEmpty { blockLines.append(text) }
        }
        flush()
        return cues
    }

    /// Texte en paragraphes, avec un repère `[mm:ss]` toutes les `window` secondes si demandé.
    public static func format(_ cues: [Cue], timestamps: Bool, window: Double = 30) -> String {
        guard !cues.isEmpty else { return "" }
        if !timestamps {
            let text = cues.map(\.text).joined(separator: " ")
            return paragraphs(text).joined(separator: "\n\n")
        }
        var groups: [(Double, [String])] = []
        for cue in cues {
            if let last = groups.last, cue.start - last.0 < window {
                groups[groups.count - 1].1.append(cue.text)
            } else {
                groups.append((cue.start, [cue.text]))
            }
        }
        return groups.map { "[\(clock($0.0))] \($0.1.joined(separator: " "))" }.joined(separator: "\n\n")
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func paragraphs(_ text: String, size: Int = 600) -> [String] {
        var result: [String] = []
        var current = ""
        for sentence in text.components(separatedBy: " ") {
            current += sentence + " "
            if current.count > size, let last = sentence.last, ".!?".contains(last) {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }

    private static func parseTimeRange(_ line: String) -> Double? {
        guard let arrow = line.range(of: " --> ") else { return nil }
        let parts = line[..<arrow.lowerBound].split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func clean(_ line: String) -> String {
        var text = line
        while let open = text.range(of: "<"), let close = text.range(of: ">", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        for (entity, value) in [("&gt;", ">"), ("&lt;", "<"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func durationText(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return clock(seconds)
    }

    /// Chemin d'enregistrement accepté : absolu, `.txt`, hors dossiers cachés et sensibles, fichier inexistant.
    public static func validateSavePath(_ raw: String, home: String) throws -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded.lowercased().hasSuffix(".txt") else {
            throw BridgeError.invalid("save_to : donner un chemin complet se terminant par .txt.")
        }
        let url = URL(fileURLWithPath: expanded)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        guard parent.path.hasPrefix(homePath + "/") else {
            throw BridgeError.invalid("save_to : le fichier doit être dans ton dossier personnel (par exemple ~/Downloads).")
        }
        let relative = String(parent.path.dropFirst(homePath.count + 1))
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) || relative.hasPrefix("Library") {
            throw BridgeError.invalid("save_to : dossier caché ou système refusé.")
        }
        guard url.lastPathComponent.first != "." else { throw BridgeError.invalid("save_to : nom de fichier caché refusé.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BridgeError.invalid("save_to : le dossier \(parent.path) n'existe pas.")
        }
        let target = parent.appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw BridgeError.invalid("save_to : \(target.lastPathComponent) existe déjà ; choisir un autre nom (rien n'est écrasé).")
        }
        return target
    }

    /// Crée le fichier seulement s'il n'existe pas (`O_EXCL`), sans suivre de lien symbolique (`O_NOFOLLOW`).
    public static func writeExclusively(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw BridgeError.invalid("save_to : \(url.lastPathComponent) n'a pas pu être créé (existe déjà ou accès refusé).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
