import Foundation

public struct ToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public static func ok(_ text: String) -> ToolResult { ToolResult(text: text, isError: false) }
    public static func fail(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
}

/// Les outils du serveur : `ask_gemini`, `gemini_result`, `gemini_status`, `reset_gemini_session`.
public final class ToolHandler: Sendable {
    public static let maxPromptCharacters = 100_000
    /// Plafond de la réponse renvoyée à Claude (Claude Code écarte les résultats trop gros).
    public static let maxResponseCharacters = 45_000
    /// Historique rejoué (backend gemini) : taille totale et taille d'une réponse, pour rester sous ARG_MAX.
    static let maxReplayCharacters = 60_000
    static let maxReplayResponseCharacters = 8_000

    private let settings: Settings
    private let store: SessionStore
    private let workspace: URL
    private let environment: [String: String]
    private let home: String
    private let jobs = JobBoard()
    private let fetch: @Sendable (URL) async throws -> Data

    public init(settings: Settings, store: SessionStore,
                workspace: URL = Settings.workspaceURL(),
                environment: [String: String] = Locator.environment(),
                home: String = NSHomeDirectory(),
                fetch: @escaping @Sendable (URL) async throws -> Data = ToolHandler.fetchCaptions) {
        self.fetch = fetch
        self.settings = settings
        self.store = store
        self.workspace = workspace
        self.environment = environment
        self.home = home
    }

    // MARK: - Définitions

    public var definitions: [JSONValue] {
        [
            [
                "name": "ask_gemini",
                "title": "Demander à Gemini",
                "description": .string("""
                Délègue une demande à Gemini (Google) via la ligne de commande locale, puis renvoie sa réponse brute. \
                À utiliser pour ce que Gemini fait mieux : recherche web ou Google Maps en temps réel, analyse d'une chaîne \
                ou d'une vidéo YouTube, très gros volumes de texte. Gemini ne voit PAS cette conversation : la demande \
                doit être complète et autonome. Renvoie un `session_id` à repasser pour une question de suivi \
                (limite de \(settings.effectiveMaxTurns) échanges par session). Gemini peut se tromper : recouper les faits importants. \
                Une recherche peut durer plus d'une minute : si la réponse n'est pas prête après \(settings.effectiveWait) s, l'outil \
                renvoie un `job_id` (ce n'est pas une erreur) : appeler alors `gemini_result` avec ce `job_id`, autant de fois que nécessaire.
                """),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "La demande, complète et autonome."],
                        "session_id": ["type": "string", "description": "Identifiant renvoyé par un appel précédent, pour poursuivre la même conversation. Omettre pour en ouvrir une nouvelle."],
                        "files": ["type": "array", "items": ["type": "string"], "description": "Fichiers à joindre (chemins complets, 5 au plus, 20 Mo chacun) : images (png, jpg, gif, webp, heic), PDF, texte (txt, md, csv, tsv, json, log). Gemini les lit ; leur contenu est envoyé à Google. Fichiers cachés et dossiers sensibles refusés."],
                        "model": ["type": "string", "description": "Modèle (facultatif ; par défaut celui des réglages) : nom court argon, flash, opus, sonnet, gpt, ou identifiant complet de `agy models`."],
                        "effort": ["type": "string", "description": "Effort de réflexion (facultatif ; par défaut celui des réglages) : low, medium ou high. Avec un nom court de modèle, choisit la variante (flash + high = gemini-3.8-flash-high)."],
                    ],
                    "required": ["prompt"],
                ],
                "annotations": ["title": "Demander à Gemini", "readOnlyHint": true, "openWorldHint": true],
            ],
            [
                "name": "youtube_transcript",
                "title": "Transcription d'une vidéo YouTube",
                "description": """
                Récupère les sous-titres d'une vidéo YouTube (adresse https youtube.com ou youtu.be) avec yt-dlp et les renvoie en texte, \
                avec titre, chaîne, durée et repères de temps. Ce sont les sous-titres publiés ou, à défaut, les sous-titres automatiques de YouTube : \
                pas une transcription audio. Aucune vidéo n'est téléchargée. Pour résumer ou analyser la vidéo, donner ensuite ce texte à `ask_gemini` \
                (ou le résumer soi-même). `save_to` enregistre aussi le texte complet dans un fichier .txt du dossier personnel.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Adresse de la vidéo YouTube."],
                        "language": ["type": "string", "description": "Langue des sous-titres (code : en, fr…). Par défaut, la langue d'origine de la vidéo."],
                        "timestamps": ["type": "boolean", "description": "Repères [mm:ss] toutes les 30 s (défaut : oui)."],
                        "save_to": ["type": "string", "description": "Chemin complet d'un nouveau fichier .txt à créer, dans le dossier personnel (rien n'est écrasé)."],
                    ],
                    "required": ["url"],
                ],
                "annotations": ["title": "Transcription d'une vidéo YouTube", "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true],
            ],
            [
                "name": "gemini_result",
                "title": "Récupérer la réponse de Gemini",
                "description": .string("""
                Récupère la réponse d'une demande lancée par `ask_gemini` qui n'était pas terminée (message « en cours » avec un `job_id`). \
                Attend jusqu'à \(settings.effectiveWait) s ; si Gemini travaille encore, rappeler cet outil avec le même `job_id`.
                """),
                "inputSchema": [
                    "type": "object",
                    "properties": ["job_id": ["type": "string", "description": "Le `job_id` renvoyé par `ask_gemini` (facultatif : par défaut, la demande la plus récente)."]],
                ],
                "annotations": ["title": "Récupérer la réponse de Gemini", "readOnlyHint": true, "openWorldHint": true],
            ],
            [
                "name": "gemini_status",
                "title": "État du pont Gemini",
                "description": "Indique quel programme (agy ou gemini) est utilisé, où il se trouve, sa version et les réglages. Avec test = true, envoie une toute petite demande pour vérifier la connexion Google.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["test": ["type": "boolean", "description": "Vérifier aussi la connexion par un appel réel."]],
                ],
                "annotations": ["title": "État du pont Gemini", "readOnlyHint": true, "openWorldHint": true],
            ],
            [
                "name": "reset_gemini_session",
                "title": "Oublier une session Gemini",
                "description": "Efface la mémoire d'une session Gemini (à utiliser quand l'utilisateur change de sujet).",
                "inputSchema": [
                    "type": "object",
                    "properties": ["session_id": ["type": "string", "description": "La session à oublier."]],
                    "required": ["session_id"],
                ],
                "annotations": ["title": "Oublier une session Gemini", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
            ],
        ]
    }

    // MARK: - Appel

    public func call(name: String, arguments: [String: JSONValue]) async -> ToolResult {
        switch name {
        case "ask_gemini": return await askGemini(arguments)
        case "gemini_result": return await geminiResult(arguments)
        case "youtube_transcript": return await youtubeTranscript(arguments)
        case "gemini_status": return await status(test: arguments["test"]?.bool ?? false)
        case "reset_gemini_session": return await reset(arguments)
        default: return .fail("Outil inconnu : \(name)")
        }
    }

    /// Lance la demande en arrière-plan et attend un peu moins que la limite de 60 s de Claude Desktop :
    /// si Gemini n'a pas fini, on rend un `job_id` que Claude réclame avec `gemini_result`.
    private func askGemini(_ arguments: [String: JSONValue]) async -> ToolResult {
        guard let id = jobs.start({ [self] in await runAsk(arguments) }) else {
            return .fail("Déjà \(JobBoard.maxRunning) demandes à Gemini en cours : attendre leur fin (gemini_result) avant d'en lancer une autre.")
        }
        return render(await jobs.wait(id: id, seconds: TimeInterval(settings.effectiveWait)), id: id)
    }

    private func geminiResult(_ arguments: [String: JSONValue]) async -> ToolResult {
        guard let id = arguments["job_id"]?.string.flatMap({ $0.isEmpty ? nil : $0 }) ?? jobs.latestID else {
            return .fail("Aucune demande à Gemini en cours ni à récupérer.")
        }
        return render(await jobs.wait(id: id, seconds: TimeInterval(settings.effectiveWait)), id: id)
    }

    private func render(_ outcome: JobBoard.Outcome, id: String) -> ToolResult {
        switch outcome {
        case .finished(let result):
            return result
        case .running(let elapsed):
            return .ok("⏳ Gemini travaille encore (\(elapsed) s écoulées). Ce n'est pas une erreur : appelle `gemini_result` avec job_id = \"\(id)\" pour récupérer la réponse (il attend jusqu'à \(settings.effectiveWait) s de plus).")
        case .unknown:
            return .fail("Aucune demande en cours avec le job_id « \(id) » (déjà récupérée, ou oubliée après 30 minutes). Relancer ask_gemini.")
        }
    }

    private func runAsk(_ arguments: [String: JSONValue]) async -> ToolResult {
        guard let prompt = arguments["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            return .fail("Le paramètre « prompt » est obligatoire (texte non vide).")
        }
        guard prompt.count <= Self.maxPromptCharacters else {
            return .fail("La demande dépasse \(Self.maxPromptCharacters) caractères : la raccourcir.")
        }
        let kind = settings.backend
        guard let executable = Locator.executable(for: kind, override: settings.executable, home: home) else {
            return .fail(Self.missingMessage(kind, override: settings.executable))
        }
        let requestedEffort = arguments["effort"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let requestedEffort, !ModelCatalog.isEffort(requestedEffort) {
            return .fail("Effort « \(requestedEffort) » inconnu : \(ModelCatalog.efforts.joined(separator: ", ")).")
        }
        let askedModel = arguments["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let (model, effort) = ModelCatalog.resolve(
            model: askedModel ?? settings.model,
            effort: requestedEffort ?? settings.effort)

        // Les fichiers joints sont vérifiés avant d'ouvrir l'échange : un refus ne consomme rien.
        var attached: Attachments.Prepared?
        if let files = arguments["files"] {
            guard let list = files.array, list.allSatisfy({ $0.string != nil }) else {
                return .fail("Le paramètre « files » doit être une liste de chemins.")
            }
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                Attachments.purgeStale(workspace: workspace)
                let prepared = try Attachments.prepare(paths: list.compactMap(\.string), workspace: workspace, home: home,
                                                       id: String(UUID().uuidString.prefix(8)).lowercased())
                if !prepared.relativePaths.isEmpty { attached = prepared }
            } catch {
                return .fail(error.localizedDescription)
            }
        }
        defer { if let attached { Attachments.remove(attached) } }

        let session: SessionSnapshot
        do {
            session = try await store.begin(sessionId: arguments["session_id"]?.string)
        } catch {
            return .fail(error.localizedDescription)
        }

        let fullPrompt = composePrompt(prompt, session: session) + Attachments.promptNote(attached?.relativePaths ?? [])
        let reply: BridgeReply
        do {
            reply = try await execute(kind: kind, executable: executable, prompt: fullPrompt, model: model, effort: effort,
                                      conversationId: session.conversationId)
        } catch is CancellationError {
            await store.abort(id: session.id)
            return .fail("Appel annulé.")
        } catch {
            await store.abort(id: session.id)
            return .fail(error.localizedDescription)
        }

        if let error = reply.error {
            await store.abort(id: session.id)
            var text = "Gemini n'a pas pu répondre : \(error)."
            if !reply.response.isEmpty { text += "\n\nRéponse partielle :\n\(reply.response)" }
            text += "\n\n[session_id: \(session.id) — cet échec ne compte pas dans la limite]"
            return .fail(text)
        }

        await store.finish(id: session.id, prompt: prompt, response: reply.response, conversationId: reply.conversationId)
        var footer = "[session_id: \(session.id) — échange \(session.turn)/\(session.maxTurns)"
        footer += session.turn >= session.maxTurns
            ? " — limite atteinte : rédige maintenant la réponse finale]"
            : "]"
        var answer = reply.response.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.count > Self.maxResponseCharacters {
            answer = String(answer.prefix(Self.maxResponseCharacters))
                + "\n\n[réponse tronquée à \(Self.maxResponseCharacters) caractères ; redemander une partie précise dans la même session]"
        }
        return .ok("\(answer)\n\n\(footer)")
    }

    /// Première demande : consigne puis question. Suite sans identifiant de conversation côté programme
    /// (gemini-cli, ou agy qui n'en a pas renvoyé) : on rejoue l'historique gardé en mémoire.
    private func composePrompt(_ prompt: String, session: SessionSnapshot) -> String {
        let preamble = settings.preamble.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.history.isEmpty {
            return preamble.isEmpty ? prompt : "\(preamble)\n\n\(prompt)"
        }
        if session.conversationId != nil { return prompt }
        var parts: [String] = []
        if !preamble.isEmpty { parts.append(preamble) }
        parts.append("Échanges précédents de cette conversation :")
        // Du plus récent au plus ancien tant que la taille le permet, puis remis dans l'ordre.
        var kept: [String] = []
        var budget = Self.maxReplayCharacters
        for (index, exchange) in session.history.enumerated().reversed() {
            let response = exchange.response.count > Self.maxReplayResponseCharacters
                ? String(exchange.response.prefix(Self.maxReplayResponseCharacters)) + " […]" : exchange.response
            let prompt = exchange.prompt.count > Self.maxReplayResponseCharacters
                ? String(exchange.prompt.prefix(Self.maxReplayResponseCharacters)) + " […]" : exchange.prompt
            let block = "— Demande \(index + 1) : \(prompt)\n— Ta réponse \(index + 1) : \(response)"
            if block.count > budget { break }
            budget -= block.count
            kept.append(block)
        }
        parts.append(contentsOf: kept.reversed())
        parts.append("Nouvelle demande : \(prompt)")
        return parts.joined(separator: "\n\n")
    }

    private func execute(kind: BackendKind, executable: String, prompt: String, model: String?,
                         effort: String?, conversationId: String?) async throws -> BridgeReply {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let timeout = settings.effectiveTimeout
        let arguments = Backend.arguments(kind: kind, prompt: prompt, model: model, mode: settings.mode, effort: effort,
                                          conversationId: conversationId, timeoutSeconds: timeout)
        let result = try await ProcessRunner.run(
            executable: executable, arguments: arguments, environment: environment, workingDirectory: workspace,
            // Marge sur le délai propre du programme (--print-timeout) pour recevoir sa réponse partielle.
            timeout: TimeInterval(timeout + 15), abortMarkers: Backend.authMarkers)
        return Backend.parse(kind: kind, result: result, timeoutSeconds: timeout)
    }

    // MARK: - État et remise à zéro

    private func status(test: Bool) async -> ToolResult {
        var lines = ["Programme utilisé : \(settings.backend.rawValue)"]
        for kind in BackendKind.allCases {
            let override = kind == settings.backend ? settings.executable : nil
            guard let path = Locator.executable(for: kind, override: override, home: home) else {
                lines.append("- \(kind.rawValue) : introuvable")
                continue
            }
            var version = "version inconnue"
            if let result = try? await ProcessRunner.run(executable: path, arguments: ["--version"], environment: environment,
                                                         workingDirectory: FileManager.default.temporaryDirectory, timeout: 15) {
                let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { version = String(text.prefix(80)) }
            }
            lines.append("- \(kind.rawValue) : \(path) (\(version))")
        }
        lines.append("Modèle : \(settings.model ?? "celui du programme") · mode : \(settings.mode ?? "par défaut") · délai : \(settings.effectiveTimeout) s")
        lines.append("Garde-fous : \(settings.effectiveMaxTurns) échanges par session, \(settings.effectiveMaxCalls) appels par 10 minutes")
        lines.append("Sessions en mémoire : \(await store.count)")
        guard test else { return .ok(lines.joined(separator: "\n")) }

        guard let executable = Locator.executable(for: settings.backend, override: settings.executable, home: home) else {
            lines.append("Test : impossible, programme introuvable.")
            return .fail(lines.joined(separator: "\n"))
        }
        do {
            try await store.noteCall()
            let reply = try await execute(kind: settings.backend, executable: executable,
                                          prompt: "Réponds uniquement par le mot : ok", model: settings.model, effort: settings.effort, conversationId: nil)
            if let error = reply.error {
                lines.append("Test : échec — \(error)")
                return .fail(lines.joined(separator: "\n"))
            }
            lines.append("Test : réussi (réponse : \(reply.response.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)))")
            return .ok(lines.joined(separator: "\n"))
        } catch {
            lines.append("Test : échec — \(error.localizedDescription)")
            return .fail(lines.joined(separator: "\n"))
        }
    }

    private func reset(_ arguments: [String: JSONValue]) async -> ToolResult {
        guard let id = arguments["session_id"]?.string, !id.isEmpty else {
            return .fail("Le paramètre « session_id » est obligatoire.")
        }
        return await store.reset(id: id) ? .ok("Session \(id) effacée.") : .fail(SessionError.unknown(id: id).localizedDescription)
    }

    // MARK: - Transcription YouTube

    private func youtubeTranscript(_ arguments: [String: JSONValue]) async -> ToolResult {
        guard let raw = arguments["url"]?.string, let url = YouTubeTranscript.validate(raw) else {
            return .fail("« url » doit être une adresse https de vidéo YouTube (youtube.com ou youtu.be).")
        }
        let language = arguments["language"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let timestamps = arguments["timestamps"]?.bool ?? true
        var savePath: URL?
        if let target = arguments["save_to"]?.string, !target.isEmpty {
            do { savePath = try YouTubeTranscript.validateSavePath(target, home: home) } catch { return .fail(error.localizedDescription) }
        }
        guard let ytDlp = Locator.tool(named: "yt-dlp", override: settings.ytDlp, home: home) else {
            return .fail("yt-dlp est introuvable. L'installer : brew install yt-dlp (ou indiquer son chemin dans le réglage « ytDlp »).")
        }

        let info: ProcessResult
        do {
            info = try await ProcessRunner.run(
                executable: ytDlp,
                arguments: ["--skip-download", "--dump-single-json", "--no-warnings", "--no-playlist", "--", url],
                environment: environment, workingDirectory: FileManager.default.temporaryDirectory, timeout: 45)
        } catch is CancellationError {
            return .fail("Appel annulé.")
        } catch {
            return .fail(error.localizedDescription)
        }
        if info.timedOut { return .fail("yt-dlp a dépassé 45 s : réessayer (YouTube est peut-être lent ou bloque la requête).") }
        guard info.exitCode == 0, let json = Backend.extractJSON(info.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let detail = info.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail("yt-dlp n'a pas pu lire la vidéo (privée, supprimée, restreinte ou adresse erronée ?)" + (detail.isEmpty ? "" : " : \(String(detail.suffix(300)))"))
        }

        let title = json["title"]?.string ?? "(sans titre)"
        let channel = json["channel"]?.string ?? json["uploader"]?.string ?? "(inconnue)"
        let duration = YouTubeTranscript.durationText(json["duration"]?.double) ?? "inconnue"
        guard let track = YouTubeTranscript.pickTrack(json: json, language: language) else {
            let available = ((json["subtitles"]?.object ?? [:]).keys.sorted() + (json["automatic_captions"]?.object ?? [:]).keys.sorted().prefix(8)).joined(separator: ", ")
            return .fail("Aucun sous-titre\(language.map { " « \($0) »" } ?? "") pour la vidéo « \(title) » (\(channel)). Pistes vues : \(available.isEmpty ? "aucune" : available).")
        }
        guard let trackURL = URL(string: track.url) else { return .fail("Adresse de sous-titres invalide.") }

        let vtt: String
        do {
            vtt = String(decoding: try await fetch(trackURL), as: UTF8.self)
        } catch is CancellationError {
            return .fail("Appel annulé.")
        } catch {
            return .fail("Téléchargement des sous-titres impossible : \(error.localizedDescription)")
        }
        let body = YouTubeTranscript.format(YouTubeTranscript.parseVTT(vtt, deduplicate: track.isAutomatic), timestamps: timestamps)
        guard !body.isEmpty else { return .fail("Les sous-titres de la vidéo « \(title) » sont vides.") }

        let kind = track.isAutomatic ? "sous-titres automatiques de YouTube, non relus" : "sous-titres publiés"
        let header = "Titre : \(title)\nChaîne : \(channel)\nDurée : \(duration)\nSource : \(url)\nLangue : \(track.language) (\(kind))\n\n"
        var saved = ""
        if let savePath {
            do {
                // Contrôle refait au moment d'écrire (le dossier ou le fichier ont pu changer pendant l'attente),
                // puis création exclusive : jamais d'écrasement, jamais de lien symbolique suivi.
                let target = try YouTubeTranscript.validateSavePath(savePath.path, home: home)
                try YouTubeTranscript.writeExclusively((header + body + "\n").data(using: .utf8) ?? Data(), to: target)
                saved = "\n\n[Enregistré dans \(target.path)]"
            } catch {
                saved = "\n\n[Enregistrement impossible : \(error.localizedDescription)]"
            }
        }
        var text = header + body
        if text.count > Self.maxResponseCharacters {
            text = String(text.prefix(Self.maxResponseCharacters))
                + "\n\n[texte tronqué à \(Self.maxResponseCharacters) caractères" + (savePath == nil ? " ; utiliser save_to pour garder la transcription complète" : "") + "]"
        }
        return .ok(text + saved)
    }

    /// Téléchargement d'une piste de sous-titres : https, domaine YouTube seulement, 5 Mo au plus.
    @Sendable public static func fetchCaptions(_ url: URL) async throws -> Data {
        guard url.scheme == "https", let host = url.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            throw BridgeError.invalid("adresse de sous-titres hors YouTube refusée")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BridgeError.invalid("réponse HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count <= 5 * 1024 * 1024 else { throw BridgeError.invalid("sous-titres trop volumineux") }
        return data
    }

    static func missingMessage(_ kind: BackendKind, override: String?) -> String {
        if let override, !override.isEmpty {
            return "Le programme indiqué dans les réglages est introuvable ou non exécutable : \(override)"
        }
        switch kind {
        case .agy: return "Antigravity CLI (`agy`) est introuvable. L'installer : brew install --cask antigravity-cli, puis lancer `agy` une fois pour se connecter."
        case .gemini: return "gemini-cli (`gemini`) est introuvable. L'installer : brew install gemini-cli."
        }
    }
}
