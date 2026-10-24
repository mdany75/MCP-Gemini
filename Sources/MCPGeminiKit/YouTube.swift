import Foundation

/// Sous-titres d'une vidéo YouTube : `yt-dlp` donne les métadonnées et les adresses des pistes, le serveur
/// télécharge la piste choisie (texte WebVTT seulement, jamais la vidéo) et la met en forme. `fetch` fait
/// tout le parcours, pour l'outil `youtube_transcript` comme pour une transcription jointe à `ask_gemini`.
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

    public struct Track: Equatable, Sendable {
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

    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var text: String

        public init(start: Double, text: String) {
            self.start = start
            self.text = text
        }
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

        // Fins de ligne Windows (« \r\n ») ou anciennes (« \r ») ramenées à « \n », BOM initial retiré : sinon
        // « \r\n » compte pour deux lignes, la ligne vide du milieu ferme chaque bloc et tout le texte est perdu.
        var normalized = vtt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.unicodeScalars.first == "\u{FEFF}" { normalized = String(normalized.unicodeScalars.dropFirst()) }
        for rawLine in normalized.components(separatedBy: "\n") {
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

    /// Texte en paragraphes de `window` secondes, avec un repère `[mm:ss]` en tête de chacun si demandé.
    /// Sans repères, même découpage : les sous-titres automatiques n'ont souvent aucune ponctuation.
    public static func format(_ cues: [Cue], timestamps: Bool, window: Double = 30) -> String {
        paragraphs(cues, window: window).map { range in
            let text = cues[range].map(\.text).joined(separator: " ")
            return timestamps ? "[\(clock(cues[range.lowerBound].start))] \(text)" : text
        }.joined(separator: "\n\n")
    }

    /// Répliques regroupées par fenêtre de temps (indices dans `cues`), en un seul passage.
    static func paragraphs(_ cues: [Cue], window: Double) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var start = 0
        for index in cues.indices.dropFirst() where cues[index].start - cues[start].start >= window {
            groups.append(start..<index)
            start = index
        }
        if !cues.isEmpty { groups.append(start..<cues.count) }
        return groups
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
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
        // Entités seulement si la ligne en contient (la plupart n'en ont pas : lecture plus rapide).
        if text.contains("&") {
            for (entity, value) in [("&gt;", ">"), ("&lt;", "<"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: value)
            }
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func durationText(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return clock(seconds)
    }

    // MARK: - Transcription complète

    /// Une transcription récupérée : métadonnées de la vidéo et répliques, à mettre en forme selon l'usage
    /// (réponse d'outil tronquée, fichier complet, pièce jointe pour Gemini).
    public struct Transcript: Equatable, Sendable {
        public var title: String
        public var channel: String
        /// Durée en secondes, si yt-dlp la connaît.
        public var duration: Double?
        /// Adresse normalisée de la vidéo.
        public var source: String
        public var language: String
        public var isAutomatic: Bool
        public var cues: [Cue]

        public init(title: String, channel: String, duration: Double?, source: String, language: String,
                    isAutomatic: Bool, cues: [Cue]) {
            self.title = title
            self.channel = channel
            self.duration = duration
            self.source = source
            self.language = language
            self.isAutomatic = isAutomatic
            self.cues = cues
        }

        /// En-tête : titre, chaîne, durée, source et nature des sous-titres, suivi d'une ligne vide.
        public var header: String {
            let kind = isAutomatic ? "sous-titres automatiques de YouTube, non relus" : "sous-titres publiés"
            return "Titre : \(title)\nChaîne : \(channel)\nDurée : \(YouTubeTranscript.durationText(duration) ?? "inconnue")\n"
                + "Source : \(source)\nLangue : \(language) (\(kind))\n\n"
        }

        /// Texte complet, en paragraphes de 30 s.
        public func body(timestamps: Bool) -> String {
            YouTubeTranscript.format(cues, timestamps: timestamps)
        }

        /// Début du texte qui tient en `maxCharacters` caractères, coupé entre deux répliques, avec la part
        /// de la vidéo couverte : de quoi prévenir Claude que la suite manque.
        public func excerpt(timestamps: Bool, maxCharacters: Int, window: Double = 30) -> Excerpt {
            var parts: [String] = []
            var used = 0
            var lastKept: Int?
            var complete = true
            paragraphs: for range in YouTubeTranscript.paragraphs(cues, window: window) {
                let prefix = timestamps ? "[\(YouTubeTranscript.clock(cues[range.lowerBound].start))] " : ""
                var length = (parts.isEmpty ? 0 : 2) + prefix.count
                var kept: [String] = []
                for index in range {
                    let added = cues[index].text.count + (kept.isEmpty ? 0 : 1)
                    if used + length + added > maxCharacters {
                        if !kept.isEmpty { parts.append(prefix + kept.joined(separator: " ")) }
                        complete = false
                        break paragraphs
                    }
                    kept.append(cues[index].text)
                    length += added
                    lastKept = index
                }
                parts.append(prefix + kept.joined(separator: " "))
                used += length
            }
            var percent: Int?
            if let duration, duration > 0 {
                let reached = lastKept.map { cues[$0].start } ?? 0
                // Incomplet : jamais « 100 % », même si la dernière réplique gardée commence tout à la fin.
                percent = complete ? 100 : min(99, max(0, Int(reached / duration * 100)))
            }
            return Excerpt(text: parts.joined(separator: "\n\n"), isComplete: complete,
                           lastKeptStart: lastKept.map { cues[$0].start }, percent: percent)
        }
    }

    public struct Excerpt: Equatable, Sendable {
        public var text: String
        /// `false` : des répliques ont été laissées de côté.
        public var isComplete: Bool
        /// Début de la dernière réplique gardée, en secondes (`nil` si aucune ne tenait).
        public var lastKeptStart: Double?
        /// Part de la vidéo couverte, de 0 à 100 (début de la dernière réplique gardée / durée), si la durée est connue.
        public var percent: Int?
    }

    /// Arguments de yt-dlp : ses fichiers de configuration (yt-dlp.conf du dossier courant, ~/yt-dlp.conf,
    /// ~/.config/yt-dlp/config…) sont ignorés, car ils pourraient ajouter --exec, des cookies du navigateur
    /// ou une écriture de fichiers ; aucun cache, rien de téléchargé. L'adresse vient après `--`.
    public static func ytDlpArguments(url: String) -> [String] {
        ["--ignore-config", "--no-exec", "--no-cookies-from-browser", "--no-cache-dir", "--skip-download",
         "--dump-single-json", "--no-warnings", "--no-playlist", "--", url]
    }

    /// Délai maximal de yt-dlp pour lire les métadonnées.
    static let ytDlpTimeout: TimeInterval = 45

    /// Récupère la transcription complète : métadonnées et pistes par yt-dlp (lancé dans `workingDirectory`,
    /// un dossier privé vide), choix de la piste, téléchargement par `fetchCaptions`, lecture du WebVTT.
    /// Les erreurs sont des `BridgeError.invalid` au message prêt à rendre à Claude.
    public static func fetch(url raw: String, language: String?, ytDlp: String, environment: [String: String],
                             workingDirectory: URL,
                             fetchCaptions: @Sendable (URL) async throws -> Data) async throws -> Transcript {
        guard let url = validate(raw) else {
            throw BridgeError.invalid("« url » doit être une adresse https de vidéo YouTube (youtube.com ou youtu.be).")
        }
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let info: ProcessResult
        do {
            info = try await ProcessRunner.run(executable: ytDlp, arguments: ytDlpArguments(url: url), environment: environment,
                                               workingDirectory: workingDirectory, timeout: ytDlpTimeout)
        } catch is CancellationError {
            throw BridgeError.invalid("Appel annulé.")
        } catch {
            throw BridgeError.invalid(error.localizedDescription)
        }
        if info.timedOut { throw BridgeError.invalid("yt-dlp a dépassé 45 s : réessayer (YouTube est peut-être lent ou bloque la requête).") }
        guard info.exitCode == 0, let json = Backend.extractJSON(info.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let detail = info.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.invalid("yt-dlp n'a pas pu lire la vidéo (privée, supprimée, restreinte ou adresse erronée ?)"
                                      + (detail.isEmpty ? "" : " : \(String(detail.suffix(300)))"))
        }

        let title = json["title"]?.string ?? "(sans titre)"
        let channel = json["channel"]?.string ?? json["uploader"]?.string ?? "(inconnue)"
        guard let track = pickTrack(json: json, language: language) else {
            let available = ((json["subtitles"]?.object ?? [:]).keys.sorted()
                             + (json["automatic_captions"]?.object ?? [:]).keys.sorted().prefix(8)).joined(separator: ", ")
            throw BridgeError.invalid("Aucun sous-titre\(language.map { " « \($0) »" } ?? "") pour la vidéo « \(title) » (\(channel)). "
                                      + "Pistes vues : \(available.isEmpty ? "aucune" : available).")
        }
        guard let trackURL = URL(string: track.url) else { throw BridgeError.invalid("Adresse de sous-titres invalide.") }

        let vtt: String
        do {
            vtt = String(decoding: try await fetchCaptions(trackURL), as: UTF8.self)
        } catch let error as URLError where error.code == .cancelled {
            throw BridgeError.invalid("Appel annulé.")
        } catch is CancellationError {
            throw BridgeError.invalid("Appel annulé.")
        } catch {
            throw BridgeError.invalid("Téléchargement des sous-titres impossible : \(error.localizedDescription)")
        }
        let cues = parseVTT(vtt, deduplicate: track.isAutomatic)
        guard !cues.isEmpty else { throw BridgeError.invalid("Les sous-titres de la vidéo « \(title) » sont vides.") }
        return Transcript(title: title, channel: channel, duration: json["duration"]?.double, source: url,
                          language: track.language, isAutomatic: track.isAutomatic, cues: cues)
    }

    // MARK: - Téléchargement des sous-titres

    /// Plafond d'une piste de sous-titres.
    public static let maxCaptionBytes = 5 * 1024 * 1024

    /// Adresse de sous-titres acceptée : https, sur youtube.com ou un de ses sous-domaines, sans identifiant ni port.
    static func isAllowedCaptionURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// Refuse toute redirection qui sortirait de YouTube (adresse recontrôlée à chaque saut).
    final class CaptionRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(YouTubeTranscript.isAllowedCaptionURL) == true ? request : nil)
        }
    }

    static let captionRedirectGuard = CaptionRedirectGuard()

    /// Session sans mémoire : ni cache disque (qui garderait l'historique des vidéos), ni cookies, ni identifiants.
    static let captionSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: captionRedirectGuard, delegateQueue: nil)
    }()

    /// Téléchargement d'une piste de sous-titres : https, domaine YouTube seulement (redirections comprises),
    /// réponse 200, lecture arrêtée au-delà de 5 Mo.
    @Sendable public static func downloadCaptions(_ url: URL) async throws -> Data {
        guard isAllowedCaptionURL(url) else { throw BridgeError.invalid("adresse de sous-titres hors YouTube refusée") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await captionSession.bytes(for: request, delegate: captionRedirectGuard)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw BridgeError.invalid("réponse inattendue")
        }
        guard http.statusCode == 200 else {
            bytes.task.cancel()
            throw BridgeError.invalid((300..<400).contains(http.statusCode)
                                      ? "redirection hors de YouTube refusée" : "réponse HTTP \(http.statusCode)")
        }
        guard let final = http.url, isAllowedCaptionURL(final) else {
            bytes.task.cancel()
            throw BridgeError.invalid("adresse de sous-titres hors YouTube refusée")
        }
        let tooBig = BridgeError.invalid("sous-titres trop volumineux (plus de \(maxCaptionBytes / 1_048_576) Mo)")
        if http.expectedContentLength > Int64(maxCaptionBytes) {
            bytes.task.cancel()
            throw tooBig
        }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < maxCaptionBytes else {
                bytes.task.cancel()
                throw tooBig
            }
            data.append(byte)
        }
        return data
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
