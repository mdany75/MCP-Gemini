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
/// secondes ne bloque ni `ping` ni les autres requêtes. Prend en charge `notifications/cancelled`
/// et envoie des `notifications/progress` pendant les appels longs quand le client en demande.
public final class MCPServer: @unchecked Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public let name: String
    public let version: String
    public let instructions: String
    private let tools: ToolHandler
    /// Intervalle entre deux notifications de progression.
    private let progressInterval: TimeInterval

    private let lock = NSLock()
    private var inFlight: [String: Task<Void, Never>] = [:]

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
        // Le verrou est tenu pendant l'inscription : la tâche ne peut pas se « désinscrire » avant.
        lock.lock()
        let task = Task { [self] in
            if let response = await handle(message: message, send: send) { send(response) }
            if let key { forget(key) }
        }
        if let key { inFlight[key] = task }
        lock.unlock()
    }

    /// Annule tout (fin de l'entrée) : les programmes lancés sont arrêtés.
    public func cancelAll() {
        lock.lock()
        let tasks = Array(inFlight.values)
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private func forget(_ key: String) {
        lock.lock()
        inFlight.removeValue(forKey: key)
        lock.unlock()
    }

    private func cancel(requestID: JSONValue) {
        lock.lock()
        let task = inFlight[JSONCoding.line(requestID)]
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
            let ticker = progressTicker(token: params["_meta"]?["progressToken"], toolName: toolName, send: send)
            defer { ticker?.cancel() }
            let result = await tools.call(name: toolName, arguments: arguments)
            return [
                "content": [["type": "text", "text": .string(result.text)]],
                "isError": .bool(result.isError),
            ]
        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "Méthode inconnue : \(method)")
        }
    }

    /// Un signe de vie régulier pendant un appel long, seulement si le client a donné un `progressToken`.
    private func progressTicker(token: JSONValue?, toolName: String,
                                send: @escaping @Sendable (JSONValue) -> Void) -> Task<Void, Never>? {
        guard let token, !token.isNull else { return nil }
        let interval = progressInterval
        return Task {
            var elapsed = 0.0
            var step = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                elapsed += interval
                step += 1
                send([
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": [
                        "progressToken": token,
                        "progress": .number(step),
                        "message": .string("\(toolName) : en attente de Gemini (\(Int(elapsed)) s)"),
                    ],
                ])
            }
        }
    }

    private static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
