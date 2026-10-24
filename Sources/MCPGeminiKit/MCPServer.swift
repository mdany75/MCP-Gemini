import Foundation

/// Erreur JSON-RPC 2.0.
public struct JSONRPCError: Error, Equatable {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// Serveur MCP minimal (`initialize`, `ping`, `tools/list`, `tools/call`) sur des messages JSON-RPC
/// d'une ligne. Les appels d'outils tournent en parallèle : un appel à Gemini de plusieurs dizaines de
/// secondes ne bloque ni `ping` ni les autres requêtes. Prend en charge `notifications/cancelled` (la
/// requête annulée ne reçoit plus de réponse) et envoie des `notifications/progress` pendant les appels
/// longs quand le client en demande : ce que fait Gemini dès que ça change, et un signe de vie régulier.
public final class MCPServer: @unchecked Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public let name: String
    public let version: String
    public let instructions: String
    private let tools: ToolHandler
    /// Intervalle entre deux signes de vie quand rien ne change.
    private let progressInterval: TimeInterval

    private let lock = NSLock()
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Requêtes annulées par le client : leur réponse n'est pas envoyée.
    private var cancelled = Set<String>()
    /// Plus aucun envoi (fin de l'entrée : le client est parti).
    private var closed = false

    public init(name: String, version: String, instructions: String, tools: ToolHandler,
                progressInterval: TimeInterval = 10) {
        self.progressInterval = progressInterval
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    // MARK: - Transport

    /// Traite une ligne reçue. Les réponses (et notifications de progression) sont remises à `send`,
    /// éventuellement plus tard et depuis un autre fil.
    public func receive(line: String, send: @escaping @Sendable (JSONValue) -> Void) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message: JSONValue
        do {
            message = try JSONCoding.parse(trimmed)
        } catch {
            send(Self.errorResponse(id: .null, code: JSONRPCError.parseError, message: "JSON illisible"))
            return
        }

        if message["method"]?.string == "notifications/cancelled" {
            if let requestID = message["params"]?["requestId"] { cancel(requestID: requestID) }
            return
        }

        let key = message["id"].flatMap { $0.isNull ? nil : JSONCoding.line($0) }
        let gated: @Sendable (JSONValue) -> Void = { [weak self] value in
            guard let self, self.isOpen else { return }
            send(value)
        }
        // Le verrou est tenu pendant l'inscription : la tâche ne peut pas se « désinscrire » avant.
        lock.lock()
        let task = Task { [self] in
            let response = await handle(message: message, send: gated)
            // Une requête annulée par le client ne reçoit pas de réponse (spécification MCP).
            if let response, !(key.map(wasCancelled) ?? false) { gated(response) }
            if let key { forget(key) }
        }
        if let key { inFlight[key] = task }
        lock.unlock()
    }

    /// Fin de l'entrée : les attentes en cours s'arrêtent et plus rien n'est envoyé (le client est parti).
    /// Les demandes à Gemini, détachées, sont arrêtées par l'arrêt du serveur.
    public func cancelAll() {
        lock.lock()
        closed = true
        let tasks = Array(inFlight.values)
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    private func wasCancelled(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(key)
    }

    private func forget(_ key: String) {
        lock.lock()
        inFlight.removeValue(forKey: key)
        cancelled.remove(key)
        lock.unlock()
    }

    private func cancel(requestID: JSONValue) {
        let key = JSONCoding.line(requestID)
        lock.lock()
        let task = inFlight[key]
        // Seulement une requête en cours : un identifiant réutilisé plus tard ne doit pas être réduit au silence.
        if task != nil { cancelled.insert(key) }
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Messages

    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message: JSONValue
        do {
            message = try JSONCoding.parse(trimmed)
        } catch {
            return JSONCoding.line(Self.errorResponse(id: .null, code: JSONRPCError.parseError, message: "JSON illisible"))
        }
        return await handle(message: message, send: { _ in }).map(JSONCoding.line)
    }

    public func handle(message: JSONValue, send: @escaping @Sendable (JSONValue) -> Void) async -> JSONValue? {
        guard case .object = message, let method = message["method"]?.string else {
            return Self.errorResponse(id: message["id"] ?? .null, code: JSONRPCError.invalidRequest,
                                      message: "Requête JSON-RPC invalide")
        }
        let params = message["params"] ?? .object([:])

        if method.hasPrefix("notifications/") { return nil }
        guard let requestID = message["id"], !requestID.isNull else { return nil }

        do {
            let result = try await dispatch(method: method, params: params, send: send)
            return ["jsonrpc": "2.0", "id": requestID, "result": result]
        } catch let error as JSONRPCError {
            return Self.errorResponse(id: requestID, code: error.code, message: error.message)
        } catch {
            return Self.errorResponse(id: requestID, code: JSONRPCError.internalError, message: error.localizedDescription)
        }
    }

    private func dispatch(method: String, params: JSONValue, send: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue {
        switch method {
        case "initialize":
            // Claude Code (« claude-code ») n'a pas la coupure de 60 s de Claude Desktop : ask_gemini l'attend jusqu'au bout.
            tools.setClient(name: params["clientInfo"]?["name"]?.string)
            let requested = params["protocolVersion"]?.string ?? ""
            let negotiated = Self.supportedProtocolVersions.contains(requested)
                ? requested : Self.supportedProtocolVersions[0]
            return [
                "protocolVersion": .string(negotiated),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(version)],
                "instructions": .string(instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(tools.definitions)]
        case "tools/call":
            guard let toolName = params["name"]?.string else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Paramètre « name » manquant")
            }
            let arguments = params["arguments"]?.object ?? [:]
            let token = params["_meta"]?["progressToken"]
            let progress = token.flatMap { $0.isNull ? nil : CallProgress() }
            let ticker = progressTicker(token: token, toolName: toolName, progress: progress, send: send)
            let result = await tools.call(name: toolName, arguments: arguments, progress: progress)
            // Le signe de vie est arrêté (et attendu) avant la réponse : aucune progression ne la suit.
            ticker?.cancel()
            await ticker?.value
            var content: [JSONValue] = [["type": "text", "text": .string(result.text)]]
            content += result.images.map { ["type": "image", "data": .string($0.data), "mimeType": .string($0.mimeType)] }
            return ["content": .array(content), "isError": .bool(result.isError)]
        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "Méthode inconnue : \(method)")
        }
    }

    /// Progression pendant un appel long, seulement si le client a donné un `progressToken` : ce que fait
    /// l'outil dès que ça change (au plus une fois par seconde), sinon un signe de vie tous les `progressInterval`.
    /// `progress` est un compteur strictement croissant, sans total (durée inconnue).
    private func progressTicker(token: JSONValue?, toolName: String, progress: CallProgress?,
                                send: @escaping @Sendable (JSONValue) -> Void) -> Task<Void, Never>? {
        guard let token, !token.isNull else { return nil }
        let interval = progressInterval
        let tick = min(1.0, interval)
        return Task {
            let start = Date()
            var lastSent = Date()
            var lastText: String?
            var step = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                if Task.isCancelled { break }
                let note = progress?.note
                let changed = note != nil && note?.text != lastText
                guard changed || Date().timeIntervalSince(lastSent) >= interval else { continue }
                step += 1
                lastSent = Date()
                lastText = note?.text
                let seconds = note?.elapsed ?? Int(Date().timeIntervalSince(start))
                let message = "\(note?.text ?? "\(toolName) : en cours") — \(seconds) s"
                send([
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": [
                        "progressToken": token,
                        "progress": .number(step),
                        "message": .string(message),
                    ],
                ])
            }
        }
    }

    private static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
