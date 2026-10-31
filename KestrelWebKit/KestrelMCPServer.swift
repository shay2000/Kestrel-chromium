#if canImport(SwiftUI) && canImport(CefSwiftUI) && canImport(Network) && canImport(Security)

import Foundation
import Network
import Security
import SwiftUI

struct KestrelMCPToolCall: Sendable {
    let name: String
    let action: String?
    let url: String?
    let query: String?
    let maxCharacters: Int?
    var requestID: String? = nil
}

struct KestrelMCPToolReply: Sendable {
    let text: String
    var isError = false
}

/// A small, opt-in Streamable HTTP MCP endpoint for local coding agents.
/// It binds only to loopback, authenticates with a Keychain-backed path token,
/// and exposes no page-mutating action that bypasses the in-app approval UI.
@MainActor
final class KestrelMCPServer: ObservableObject {
    nonisolated static let portValue: UInt16 = 52768
    nonisolated static let configurationName = "kestrel"
    nonisolated static let tokenService = "com.shayprasad.Kestrel.mcp"
    nonisolated static let tokenAccount = "loopback-access-token"
    private static let supportedProtocolVersions = ["2025-11-25", "2025-03-26", "2024-11-05"]

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Off"
    @Published private(set) var endpointURL: String?

    private let requestedPort: UInt16
    private let credentialService: String
    private let credentialAccount: String
    private let tokenLookup: (Bool) -> KeychainSecretStore.LookupOutcome
    private let tokenWriter: (String) -> Bool
    private var listener: NWListener?
    private var activeEndpointPath = ""
    private var boundPort: UInt16?
    private var toolHandler: @MainActor (KestrelMCPToolCall) async -> KestrelMCPToolReply = { _ in
        KestrelMCPToolReply(text: "Kestrel is not connected to a browser.", isError: true)
    }
    private var settingsProvider: @MainActor () -> AgentMCPSettings = { .default }

    init(
        requestedPort: UInt16 = KestrelMCPServer.portValue,
        credentialService: String = KestrelMCPServer.tokenService,
        credentialAccount: String = KestrelMCPServer.tokenAccount,
        tokenLookup: ((Bool) -> KeychainSecretStore.LookupOutcome)? = nil,
        tokenWriter: ((String) -> Bool)? = nil
    ) {
        self.requestedPort = requestedPort
        self.credentialService = credentialService
        self.credentialAccount = credentialAccount
        self.tokenLookup = tokenLookup ?? { allowInteraction in
            KeychainSecretStore.lookupOutcome(account: credentialAccount, service: credentialService, allowInteraction: allowInteraction)
        }
        self.tokenWriter = tokenWriter ?? { token in
            KeychainSecretStore.setSecret(token, account: credentialAccount, service: credentialService)
        }
    }

    var displayEndpoint: String {
        "http://127.0.0.1:\(boundPort ?? requestedPort)/mcp/[Keychain token]/mcp"
    }

    func configure(
        settingsProvider: @escaping @MainActor () -> AgentMCPSettings,
        toolHandler: @escaping @MainActor (KestrelMCPToolCall) async -> KestrelMCPToolReply
    ) {
        self.settingsProvider = settingsProvider
        self.toolHandler = toolHandler
    }

    func start(allowKeychainInteraction: Bool = true) {
        guard listener == nil else { return }
        // Keychain ACL password dialogues are not reliably suppressed by
        // kSecUseAuthenticationUIFail on every macOS build. Passive startup
        // must not touch the token at all; only an explicit connection may.
        guard allowKeychainInteraction else {
            statusMessage = "Local MCP is paused. Use Connect Codex in Settings → Connections to unlock its Keychain token. In-app Codex browsing uses the separate helper."
            return
        }
        guard let token = loadOrCreateToken(allowInteraction: allowKeychainInteraction) else { return }

        let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port
        )

        do {
            // requiredLocalEndpoint already supplies the loopback address and
            // port. Supplying a second non-zero port produces EINVAL.
            let listener = try NWListener(using: parameters)
            activeEndpointPath = "/mcp/\(token)/mcp"
            if requestedPort != 0 {
                endpointURL = "http://127.0.0.1:\(requestedPort)\(activeEndpointPath)"
            }
            statusMessage = "Starting local MCP server…"
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handle(listenerState: state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                let session = KestrelMCPHTTPSession(connection: connection)
                session.start { [weak self, session] request, respond in
                    Task { @MainActor in
                        guard let self else {
                            respond(.unavailable)
                            return
                        }
                        respond(await self.process(request))
                        _ = session
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            statusMessage = "Could not start the MCP server: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        endpointURL = nil
        activeEndpointPath = ""
        boundPort = nil
        statusMessage = "Off"
    }

    static func codexSetupCommand(endpointURL: String) -> String {
        "codex mcp add \(configurationName) --url '\(endpointURL)'"
    }

    /// Exercises the same local Streamable HTTP handshake a client uses. This
    /// verifies Kestrel's listener and current tool list without editing an
    /// agent's configuration or exposing the endpoint URL/token to logs.
    func testConnection() async throws -> Int {
        guard isRunning, let endpointURL, let url = URL(string: endpointURL) else {
            throw KestrelMCPConnectionProbeError.serverNotRunning
        }

        let initialize = try await postProbeRequest(
            to: url,
            identifier: 1,
            method: "initialize",
            parameters: [
                "protocolVersion": Self.supportedProtocolVersions[0],
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Kestrel local check", "version": "1"]
            ]
        )
        guard let initializeResult = initialize["result"] as? [String: Any],
              (initializeResult["serverInfo"] as? [String: Any])?["name"] as? String == "Kestrel" else {
            throw KestrelMCPConnectionProbeError.invalidHandshake
        }

        try await postProbeNotification(to: url, method: "notifications/initialized")

        let listing = try await postProbeRequest(
            to: url,
            identifier: 2,
            method: "tools/list",
            parameters: [:]
        )
        guard let result = listing["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]],
              !tools.isEmpty else {
            throw KestrelMCPConnectionProbeError.invalidToolList
        }
        return tools.count
    }

    private func postProbeRequest(
        to url: URL,
        identifier: Int,
        method: String,
        parameters: [String: Any]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": identifier,
            "method": method,
            "params": parameters
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw KestrelMCPConnectionProbeError.unreachable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0",
              object["id"] as? Int == identifier,
              object["error"] == nil else {
            throw KestrelMCPConnectionProbeError.invalidResponse
        }
        return object
    }

    private func postProbeNotification(to url: URL, method: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": method
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 202 else {
                throw KestrelMCPConnectionProbeError.invalidResponse
            }
        } catch let error as KestrelMCPConnectionProbeError {
            throw error
        } catch {
            throw KestrelMCPConnectionProbeError.unreachable
        }
    }

    private func loadOrCreateToken(allowInteraction: Bool) -> String? {
        switch tokenLookup(allowInteraction) {
        case .found(let token): return token
        case .inaccessible:
            // Never rotate a token just because a rebuilt app cannot release
            // it. Passive launch must not show a Keychain password dialogue.
            statusMessage = "Local MCP is waiting for Keychain access. Use Connect Codex in Settings → Connections when you want to unlock it."
            return nil
        case .notFound:
            guard allowInteraction else {
                statusMessage = "Use Connect Codex in Settings → Connections to create the local MCP token."
                return nil
            }
            let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            guard tokenWriter(token) else {
                statusMessage = "Could not create the local MCP Keychain token."
                return nil
            }
            return token
        }
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            boundPort = listener?.port?.rawValue ?? requestedPort
            if let boundPort {
                endpointURL = "http://127.0.0.1:\(boundPort)\(activeEndpointPath)"
            }
            isRunning = true
            statusMessage = "Running locally on this Mac."
        case .failed(let error):
            isRunning = false
            statusMessage = "The local MCP server stopped: \(error.localizedDescription)"
            listener?.cancel()
            listener = nil
        case .cancelled:
            isRunning = false
        case .setup, .waiting:
            break
        @unknown default:
            statusMessage = "The MCP server state is unavailable."
        }
    }

    private func process(_ request: KestrelMCPHTTPRequest) async -> KestrelMCPHTTPResponse {
        let requestPort = boundPort ?? requestedPort
        let expectedHost = "127.0.0.1:\(requestPort)"
        let host = request.headers["host"]?.lowercased()
        guard host == expectedHost || host == "localhost:\(requestPort)" else {
            return .forbidden
        }

        if let origin = request.headers["origin"] {
            let allowedOrigins = ["http://127.0.0.1:\(requestPort)", "http://localhost:\(requestPort)"]
            guard allowedOrigins.contains(origin.lowercased()) else { return .forbidden }
        }

        guard request.path == activeEndpointPath else { return .notFound }
        guard request.method == "POST" else { return .methodNotAllowed }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .unsupportedMediaType
        }
        let accept = request.headers["accept"]?.lowercased() ?? ""
        guard accept.contains("application/json"), accept.contains("text/event-stream") else {
            return .notAcceptable
        }

        let message: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return .badRequest
            }
            message = decoded
        } catch {
            return .badRequest
        }

        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return rpcError(id: message["id"], code: -32600, message: "Invalid JSON-RPC request.")
        }
        let identifier = message["id"]
        let parameters = message["params"] as? [String: Any] ?? [:]

        if method == "notifications/initialized" || method.hasPrefix("notifications/") {
            return .accepted
        }

        switch method {
        case "initialize":
            let requestedVersion = parameters["protocolVersion"] as? String
            let version = Self.supportedProtocolVersions.contains(requestedVersion ?? "")
                ? requestedVersion!
                : Self.supportedProtocolVersions[0]
            return rpcResult(id: identifier, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "Kestrel", "version": "1.0"]
            ])

        case "ping":
            return rpcResult(id: identifier, result: [String: String]())

        case "tools/list":
            return rpcResult(id: identifier, result: ["tools": toolDefinitions()])

        case "tools/call":
            guard let name = parameters["name"] as? String else {
                return rpcError(id: identifier, code: -32602, message: "The tool name is required.")
            }
            let arguments = parameters["arguments"] as? [String: Any] ?? [:]
            let call = KestrelMCPToolCall(
                name: name,
                action: arguments["action"] as? String,
                url: arguments["url"] as? String,
                query: arguments["query"] as? String,
                maxCharacters: arguments["maxCharacters"] as? Int,
                requestID: arguments["requestID"] as? String
            )
            let reply = await toolHandler(call)
            return rpcResult(id: identifier, result: [
                "content": [["type": "text", "text": reply.text]],
                "isError": reply.isError
            ])

        default:
            return rpcError(id: identifier, code: -32601, message: "Method not found.")
        }
    }

    private func toolDefinitions() -> [[String: Any]] {
        let access = settingsProvider()
        var tools: [[String: Any]] = [[
            "name": "kestrel_get_action_status",
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
            "description": "Check the outcome of a queued Kestrel action by requestID. Returns waiting_for_approval, running, succeeded, failed, declined, skipped or cancelled, without page text. Waiting is not success: pause for the user; do not queue duplicates or poll repeatedly. After success, use permitted page reads to verify the task outcome.",
            "inputSchema": ["type": "object", "properties": ["requestID": ["type": "string", "format": "uuid"]], "required": ["requestID"], "additionalProperties": false]
        ], [
            "name": "kestrel_request_browser_action",
            "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true],
            "description": "Queue one allow-listed browser action. Kestrel waits for user approval. The returned requestID is not completion: check kestrel_get_action_status after the user resolves approval. Never repeat a pending action. No arbitrary JavaScript, selectors, shell commands, or form submission are supported.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["open_url", "go_back", "go_forward", "reload", "stop", "find_text", "click_text"]],
                    "url": ["type": "string", "description": "HTTP or HTTPS address; required for open_url."],
                    "query": ["type": "string", "maxLength": BrowserActionDecoder.maximumQueryLength, "description": "Exact visible control label or find text; required for click_text and find_text."]
                ],
                "required": ["action"],
                "additionalProperties": false
            ]
        ]]

        if access.sharesActiveTabMetadata {
            tools.append([
                "name": "kestrel_get_active_tab",
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
                "description": "Return the active tab title and address only. Requires the user's separate active-tab metadata permission; this does not include page contents.",
                "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]
            ])
        }
        if access.allowsPageReads {
            tools.append([
                "name": "kestrel_read_active_page",
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
                "description": "Read bounded, visible page text after Kestrel's best-effort redaction. This tool appears only when the user separately enables page-text sharing in Kestrel Settings.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["maxCharacters": ["type": "integer", "minimum": 200, "maximum": PageContextBuilder.maximumCharacterLimit]],
                    "additionalProperties": false
                ]
            ])
        }
        return tools
    }

    private func rpcResult(id: Any?, result: [String: Any]) -> KestrelMCPHTTPResponse {
        guard let id else { return .accepted }
        return jsonResponse(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func rpcError(id: Any?, code: Int, message: String) -> KestrelMCPHTTPResponse {
        var response: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { response["id"] = id }
        else { response["id"] = NSNull() }
        return jsonResponse(response)
    }

    private func jsonResponse(_ object: [String: Any]) -> KestrelMCPHTTPResponse {
        guard JSONSerialization.isValidJSONObject(object), let body = try? JSONSerialization.data(withJSONObject: object) else {
            return .internalError
        }
        return KestrelMCPHTTPResponse(status: 200, contentType: "application/json", body: body)
    }
}

private enum KestrelMCPConnectionProbeError: LocalizedError {
    case serverNotRunning
    case unreachable
    case invalidHandshake
    case invalidResponse
    case invalidToolList

    var errorDescription: String? {
        switch self {
        case .serverNotRunning: "Start the local MCP server before testing it."
        case .unreachable: "Kestrel could not reach its local MCP endpoint. Check that the server is still running."
        case .invalidHandshake, .invalidResponse: "The local MCP endpoint returned an invalid response."
        case .invalidToolList: "The endpoint connected, but did not return any available tools."
        }
    }
}

private struct KestrelMCPHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct KestrelMCPHTTPResponse {
    let status: Int
    let contentType: String?
    let body: Data

    init(status: Int, contentType: String? = nil, body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    static let accepted = KestrelMCPHTTPResponse(status: 202)
    static let badRequest = KestrelMCPHTTPResponse(status: 400)
    static let forbidden = KestrelMCPHTTPResponse(status: 403)
    static let notFound = KestrelMCPHTTPResponse(status: 404)
    static let methodNotAllowed = KestrelMCPHTTPResponse(status: 405)
    static let notAcceptable = KestrelMCPHTTPResponse(status: 406)
    static let unsupportedMediaType = KestrelMCPHTTPResponse(status: 415)
    static let tooLarge = KestrelMCPHTTPResponse(status: 413)
    static let internalError = KestrelMCPHTTPResponse(status: 500)
    static let unavailable = KestrelMCPHTTPResponse(status: 503)

    var data: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 406: reason = "Not Acceptable"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        case 500: reason = "Internal Server Error"
        default: reason = "Service Unavailable"
        }
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]
        if let contentType { headers.append("Content-Type: \(contentType)") }
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }
}

private final class KestrelMCPHTTPSession {
    private static let maximumRequestSize = 256 * 1024
    private let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(onRequest: @escaping (KestrelMCPHTTPRequest, @escaping (KestrelMCPHTTPResponse) -> Void) -> Void) {
        connection.start(queue: .main)
        receiveNext(onRequest: onRequest)
    }

    private func receiveNext(onRequest: @escaping (KestrelMCPHTTPRequest, @escaping (KestrelMCPHTTPResponse) -> Void) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            guard buffer.count <= Self.maximumRequestSize else {
                respond(.tooLarge)
                return
            }
            switch Self.parse(buffer) {
            case .request(let request):
                onRequest(request) { [self] response in respond(response) }
            case .invalid:
                respond(.badRequest)
            case .incomplete:
                if isComplete || error != nil {
                    respond(.badRequest)
                } else {
                    receiveNext(onRequest: onRequest)
                }
            }
        }
    }

    private func respond(_ response: KestrelMCPHTTPResponse) {
        connection.send(content: response.data, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private enum ParseResult {
        case request(KestrelMCPHTTPRequest)
        case incomplete
        case invalid
    }

    private static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return .incomplete }
        guard let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0, contentLength <= maximumRequestSize else { return .invalid }
        let bodyStart = range.upperBound
        guard data.count - bodyStart >= contentLength else { return .incomplete }
        let bodyRange = bodyStart..<(bodyStart + contentLength)
        return .request(KestrelMCPHTTPRequest(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]),
            headers: headers,
            body: data.subdata(in: bodyRange)
        ))
    }
}

#endif
