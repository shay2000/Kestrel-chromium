import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configuration for an OpenAI-compatible chat endpoint. OpenRouter and
/// Mistral both speak this shape, so they share one adapter with different
/// defaults and headers.
struct HTTPChatProviderConfiguration: Equatable, Sendable {
    let kind: AIProviderKind
    let baseURL: String
    let model: String
    let apiKey: String
    let additionalHeaders: [String: String]
    let timeout: TimeInterval

    init(
        kind: AIProviderKind,
        baseURL: String,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
        timeout: TimeInterval = 90
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
        self.timeout = timeout
    }
}

/// A native `URLSession` chat client. No third-party networking is involved.
struct HTTPChatProvider: AIProvider {
    let kind: AIProviderKind
    let configuration: HTTPChatProviderConfiguration

    init(configuration: HTTPChatProviderConfiguration) {
        self.kind = configuration.kind
        self.configuration = configuration
    }

    func respond(to request: AIRequest) async throws -> AIResponse {
        let urlRequest = try Self.makeURLRequest(configuration: configuration, request: request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch {
            throw AIProviderError.transport(Redaction.redacted(error.localizedDescription))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse("The server did not return an HTTP response.")
        }

        return try Self.parseResponse(
            data: data,
            statusCode: httpResponse.statusCode,
            kind: kind,
            fallbackModel: configuration.model
        )
    }

    static func makeURLRequest(
        configuration: HTTPChatProviderConfiguration,
        request: AIRequest
    ) throws -> URLRequest {
        let base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URLNormalisation.isHTTPSURL(base),
              var components = URLComponents(string: base),
              components.host != nil else {
            throw AIProviderError.invalidConfiguration("The \(configuration.kind.displayName) base URL must be a valid HTTPS URL.")
        }
        let path = components.path.hasSuffix("/") ? "\(components.path)chat/completions" : "\(components.path)/chat/completions"
        components.path = path
        guard let url = components.url else {
            throw AIProviderError.invalidConfiguration("The \(configuration.kind.displayName) endpoint could not be built.")
        }

        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidConfiguration("No model is configured for \(configuration.kind.displayName).")
        }
        guard let apiKey = APIKeyHygiene.bearerValue(configuration.apiKey) else {
            throw AIProviderError.missingSecret("No API key is available for \(configuration.kind.displayName).")
        }

        var payload: [String: Any] = [
            "model": configuration.model,
            "messages": try messagesPayload(request, kind: configuration.kind)
        ]
        payload["stream"] = false

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in configuration.additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        return urlRequest
    }

    private static func messagesPayload(_ request: AIRequest, kind: AIProviderKind) throws -> [[String: Any]] {
        var payload: [[String: Any]] = []
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            payload.append(["role": "system", "content": systemPrompt])
        }

        // Attachments belong to this turn, not the transcript. Their extracted
        // text is included as bounded provider context and binary files ride as
        // content parts on the final user message.
        let lastUserIndex = request.messages.lastIndex { $0.role == .user }

        for (index, message) in request.messages.enumerated() {
            if index == lastUserIndex, !request.attachments.isEmpty {
                payload.append([
                    "role": message.role.rawValue,
                    "content": try contentParts(text: message.text, attachments: request.attachments, kind: kind)
                ])
            } else {
                payload.append(["role": message.role.rawValue, "content": message.text])
            }
        }
        guard !payload.isEmpty else {
            throw AIProviderError.invalidConfiguration("There is nothing to send to the provider.")
        }
        return payload
    }

    /// OpenAI-compatible multimodal content.
    ///
    /// Images use an `image_url` data URL. Other files — in practice PDFs — use
    /// the `file` part with base64 `file_data`, which is the shape OpenRouter
    /// documents. Mistral's chat endpoint has no equivalent, so a non-image
    /// attachment is refused there rather than sent as something it will reject
    /// with an unhelpful error.
    private static func contentParts(
        text: String,
        attachments: [AIRequestAttachment],
        kind: AIProviderKind
    ) throws -> [[String: Any]] {
        let requestText = [text, AIRequest(
            messages: [],
            model: "",
            attachments: attachments
        ).attachmentContext]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        var parts: [[String: Any]] = [["type": "text", "text": requestText]]
        for attachment in attachments {
            guard case .binary(let data, let mimeType) = attachment.content else { continue }
            let encoded = data.base64EncodedString()
            if mimeType.hasPrefix("image/") {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mimeType);base64,\(encoded)"]
                ])
                continue
            }
            guard kind == .openRouter else {
                throw AIProviderError.invalidConfiguration(
                    "“\(attachment.origin)” is a \(mimeType) file, and \(kind.displayName) cannot read that in a chat request. Choose OpenRouter, or attach an image or a text file instead."
                )
            }
            parts.append([
                "type": "file",
                "file": [
                    "filename": attachment.origin,
                    "file_data": "data:\(mimeType);base64,\(encoded)"
                ]
            ])
        }
        return parts
    }

    static func parseResponse(
        data: Data,
        statusCode: Int,
        kind: AIProviderKind,
        fallbackModel: String? = nil
    ) throws -> AIResponse {
        let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]

        guard (200..<300).contains(statusCode) else {
            let message = Self.errorMessage(from: object) ?? String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.httpStatus(code: statusCode, message: Redaction.redacted(bound(message)))
        }

        guard let object else {
            throw AIProviderError.invalidResponse("The reply was not JSON.")
        }

        if let errorObject = object["error"] as? [String: Any],
           let message = errorObject["message"] as? String {
            throw AIProviderError.invalidResponse(Redaction.redacted(bound(message)))
        }

        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw AIProviderError.invalidResponse("The reply contained no choices.")
        }

        let message = first["message"] as? [String: Any]
        let text = Self.visibleAssistantText(message?["content"])
            ?? Self.visibleAssistantText(first["text"])
            ?? Self.nonEmptyText(message?["refusal"] as? String)
        guard let text else {
            throw AIProviderError.invalidResponse(Self.emptyReplyReason(choice: first, message: message))
        }

        let model = object["model"] as? String ?? fallbackModel
        return AIResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines), model: model)
    }

    /// OpenRouter usually returns a string, but some compatible routes return
    /// text blocks or a single typed text object. Deliberately ignore reasoning
    /// fields: hidden reasoning is not user-facing assistant content.
    private static func visibleAssistantText(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return nonEmptyText(string) }
        if let object = value as? [String: Any] {
            let type = object["type"] as? String
            guard type == nil || type == "text" || type == "output_text" else { return nil }
            return nonEmptyText(object["text"] as? String)
        }
        if let parts = value as? [Any] {
            let strings = parts.compactMap { part -> String? in
                if let string = part as? String { return nonEmptyText(string) }
                guard let object = part as? [String: Any] else { return nil }
                let type = object["type"] as? String
                guard type == nil || type == "text" || type == "output_text" else { return nil }
                return nonEmptyText(object["text"] as? String)
            }
            return strings.isEmpty ? nil : strings.joined()
        }
        return nil
    }

    private static func nonEmptyText(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func emptyReplyReason(choice: [String: Any], message: [String: Any]?) -> String {
        if let calls = message?["tool_calls"] as? [Any], !calls.isEmpty {
            return "The model returned a tool call instead of a text reply. Kestrel's OpenRouter connection expects text-based browser actions; try a model that returns assistant text."
        }

        switch choice["finish_reason"] as? String {
        case "length":
            return "OpenRouter stopped generation at the output limit before returning visible text (finish reason: length). Try a shorter request or a model with a larger output limit."
        case "content_filter":
            return "The model response was blocked by a content filter and contained no visible text."
        case "stop":
            return "The model finished without returning visible text. Try another model or resend the request."
        default:
            return "The reply contained no visible text. Try another model or resend the request."
        }
    }

    private static func errorMessage(from object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String
        }
        if let message = object["message"] as? String {
            return message
        }
        return nil
    }

    private static func bound(_ text: String, limit: Int = 600) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[text.startIndex..<end]) + "…"
    }
}
