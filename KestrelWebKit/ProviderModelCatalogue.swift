import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One model a provider offers, or one Kestrel ships as a starting point.
struct ProviderModel: Identifiable, Equatable, Sendable {
    /// The identifier sent to the provider. Also the picker's identity, because
    /// a model is chosen by its identifier and never by its display name.
    let id: String
    let name: String
    /// A short, non-secret hint: context size, price class, and so on.
    let detail: String?
    /// Context window reported by the provider, in tokens, when available.
    let contextWindow: Int?
    /// Free models are surfaced first so a user without credit still has a
    /// working choice.
    let isFree: Bool

    init(
        id: String,
        name: String,
        detail: String? = nil,
        isFree: Bool = false,
        contextWindow: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isFree = isFree
        self.contextWindow = contextWindow
    }
}

/// A quick, plain-language way to choose a model without knowing a provider's
/// identifiers. Each tier resolves to one concrete model per provider.
enum ModelChoiceTier: String, CaseIterable, Identifiable, Sendable {
    case free
    case cheap
    case fast
    case quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .cheap: return "Cheap"
        case .fast: return "Fast"
        case .quality: return "Quality"
        }
    }

    var symbol: String {
        switch self {
        case .free: return "gift"
        case .cheap: return "creditcard"
        case .fast: return "bolt"
        case .quality: return "star"
        }
    }

    /// Answers "what am I choosing?" in one line, without model jargon.
    var blurb: String {
        switch self {
        case .free: return "No cost"
        case .cheap: return "Lowest price"
        case .fast: return "Lowest delay"
        case .quality: return "Best answers"
        }
    }
}

/// One tier's concrete model for one provider, ready to be shown as a row.
struct RecommendedModel: Identifiable, Equatable, Sendable {
    let tier: ModelChoiceTier
    let modelID: String
    let name: String
    let detail: String
    let isFree: Bool
    let contextWindow: Int?

    init(
        tier: ModelChoiceTier,
        modelID: String,
        name: String,
        detail: String,
        isFree: Bool,
        contextWindow: Int? = nil
    ) {
        self.tier = tier
        self.modelID = modelID
        self.name = name
        self.detail = detail
        self.isFree = isFree
        self.contextWindow = contextWindow
    }

    var id: String { "\(tier.rawValue)|\(modelID)" }
}

enum ProviderModelCatalogueError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProvider(String)
    case missingSecret(String)
    case invalidConfiguration(String)
    case transport(String)
    case httpStatus(code: Int, message: String)
    case invalidResponse(String)
    case processFailed(executable: String, exitCode: Int32, message: String)
    case emptyCatalogue(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let message),
             .missingSecret(let message),
             .invalidConfiguration(let message),
             .invalidResponse(let message),
             .emptyCatalogue(let message):
            return message
        case .transport(let message):
            return "The model list could not be fetched: \(message)"
        case .httpStatus(let code, let message):
            return "The provider replied with HTTP \(code)\(message.isEmpty ? "" : ": \(message)")"
        case .processFailed(let executable, let exitCode, let message):
            return "\(executable) exited with code \(exitCode)\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}

/// A small seam so the catalogue can be exercised without a network connection
/// or a real command-line tool. Implementations must never log a request or its
/// headers.
protocol ProviderModelTransport: Sendable {
    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int)
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> (stdout: Data, status: Int32)
}

/// Builds and reads model lists. All of the interesting behaviour is a pure
/// function so it can be tested against fixtures: nothing here decides policy.
enum ProviderModelCatalogue {
    /// A hard ceiling so a provider with hundreds of models cannot flood the
    /// picker or the settings pane.
    static let maximumModels = 800
    /// Response bodies are read into memory, so they are bounded too.
    static let maximumResponseBytes = 4_000_000
    static let cliTimeout: TimeInterval = 30
    static let codexModelsArguments = ["debug", "models"]

    /// OpenRouter's documented free router: it selects from the free models
    /// only, and its advertised price is zero for both prompt and completion.
    static let openRouterFreeRouterID = "openrouter/free"
    /// OpenRouter's paid auto router, offered as the convenience default.
    static let openRouterAutoRouterID = "openrouter/auto"

    /// Models that do not need to be fetched, either because they are special
    /// routes or because there is nothing to ask.
    static func builtInModels(for kind: AIProviderKind) -> [ProviderModel] {
        switch kind {
        case .openRouter:
            return [
                ProviderModel(
                    id: openRouterFreeRouterID,
                    name: "Free Models Router",
                    detail: "Free models only · OpenRouter chooses per request",
                    isFree: true
                ),
                ProviderModel(
                    id: openRouterAutoRouterID,
                    name: "Auto Router",
                    detail: "OpenRouter chooses a paid model per request"
                )
            ]
        case .workBuddyCLI:
            return [ProviderModel(id: "deepseek-v4.1-flash", name: "DeepSeek v4.1 Flash", detail: "WorkBuddy CLI · adjustable thinking")]
        case .appleLocalModel:
            return [
                ProviderModel(
                    id: "system-default",
                    name: "Automatic",
                    detail: "Apple chooses the on-device model · 4k context",
                    contextWindow: 4_096
                )
            ]
        case .codexCLI, .kiloCLI, .mistral, .googleGemini, .groq, .deepSeek, .xAI, .customOpenAI:
            return []
        }
    }

    /// True when the provider can be asked for its model list at runtime.
    static func supportsLiveCatalogue(_ kind: AIProviderKind) -> Bool {
        kind.isHTTP || kind == .codexCLI
    }

    /// The models Kestrel recommends for a provider, one per tier.
    ///
    /// These are a starting point, not a whitelist: advanced picking still lists
    /// every model the provider publishes. The free route is deliberately the
    /// first OpenRouter choice so a user without credit has something that
    /// works. Providers that charge per request are never offered a fake
    /// "free" tier; when a tier does not apply it is simply absent.
    ///
    /// The table is static on purpose, so a quick pick stays usable even when
    /// the live catalogue cannot be read (no key yet, or a provider outage). If
    /// a provider later retires one of these identifiers it returns its own
    /// clear error, and the full list remains available to choose from.
    static func recommendedModels(for kind: AIProviderKind) -> [RecommendedModel] {
        switch kind {
        case .openRouter:
            return [
                RecommendedModel(
                    tier: .free,
                    modelID: openRouterFreeRouterID,
                    name: "Free Models Router",
                    detail: "Free models only · OpenRouter chooses per request",
                    isFree: true
                ),
                RecommendedModel(
                    tier: .cheap,
                    modelID: "deepseek/deepseek-v4-flash-0731",
                    name: "DeepSeek V4 Flash",
                    detail: "Very low cost · 1.3M context",
                    isFree: false,
                    contextWindow: 1_300_000
                ),
                RecommendedModel(
                    tier: .fast,
                    modelID: "google/gemini-3.8-flash",
                    name: "Gemini 3.8 Flash",
                    detail: "Low latency · 1M context",
                    isFree: false,
                    contextWindow: 1_000_000
                ),
                RecommendedModel(
                    tier: .quality,
                    modelID: "anthropic/claude-sonnet-5",
                    name: "Claude Sonnet 5",
                    detail: "Strongest general model",
                    isFree: false
                )
            ]
        case .mistral:
            // Mistral has no API-free tier, so there is no Free row: pretending
            // otherwise would bill the user. `-latest` aliases follow Mistral's
            // current generation automatically.
            return [
                RecommendedModel(
                    tier: .cheap,
                    modelID: "ministral-8b-latest",
                    name: "Ministral 8B",
                    detail: "Cheapest chat route",
                    isFree: false
                ),
                RecommendedModel(
                    tier: .fast,
                    modelID: "mistral-small-latest",
                    name: "Mistral Small",
                    detail: "Fast, balanced route",
                    isFree: false
                ),
                RecommendedModel(
                    tier: .quality,
                    modelID: "mistral-medium-latest",
                    name: "Mistral Medium",
                    detail: "Frontier agentic and coding model",
                    isFree: false
                )
            ]
        case .googleGemini:
            // Gemini has a free allowance on some plans but no permanently free
            // model, so no Free row is claimed.
            return [
                RecommendedModel(
                    tier: .cheap,
                    modelID: "gemini-3.5-flash-lite",
                    name: "Gemini 3.5 Flash Lite",
                    detail: "Lowest cost · 1M context",
                    isFree: false,
                    contextWindow: 1_048_576
                ),
                RecommendedModel(
                    tier: .fast,
                    modelID: "gemini-3.8-flash",
                    name: "Gemini 3.8 Flash",
                    detail: "Fast and balanced · 1M context",
                    isFree: false,
                    contextWindow: 1_000_000
                ),
                RecommendedModel(
                    tier: .quality,
                    modelID: "gemini-3.1-pro-preview",
                    name: "Gemini 3.1 Pro (Preview)",
                    detail: "Strongest reasoning · preview",
                    isFree: false,
                    contextWindow: 1_048_576
                )
            ]
        case .groq:
            // Groq bills per request, with no free tier to claim.
            return [
                RecommendedModel(
                    tier: .fast,
                    modelID: "openai/gpt-oss-20b",
                    name: "GPT-OSS 20B",
                    detail: "Highest throughput on Groq",
                    isFree: false,
                    contextWindow: 131_072
                ),
                RecommendedModel(
                    tier: .quality,
                    modelID: "openai/gpt-oss-120b",
                    name: "GPT-OSS 120B",
                    detail: "Larger open-weight model",
                    isFree: false,
                    contextWindow: 131_072
                )
            ]
        case .deepSeek:
            // `deepseek-flash` is DeepSeek's current cheap, fast route.
            return [
                RecommendedModel(
                    tier: .fast,
                    modelID: "deepseek-flash",
                    name: "DeepSeek Flash",
                    detail: "Lowest price and delay",
                    isFree: false,
                    contextWindow: 1_048_576
                ),
                RecommendedModel(
                    tier: .quality,
                    modelID: "deepseek-v4-pro",
                    name: "DeepSeek V4 Pro",
                    detail: "Stronger reasoning model",
                    isFree: false,
                    contextWindow: 1_048_576
                )
            ]
        case .xAI:
            // Grok bills per request and offers no free tier.
            return [
                RecommendedModel(
                    tier: .quality,
                    modelID: "grok-4.7",
                    name: "Grok 4.7",
                    detail: "Most capable Grok · 500k context",
                    isFree: false,
                    contextWindow: 500_000
                )
            ]
        case .customOpenAI:
            // The endpoint is user-supplied, so any built-in recommendation
            // could be wrong. The live list is the honest surface here.
            return []
        case .codexCLI, .workBuddyCLI, .kiloCLI, .appleLocalModel:
            // These run on the user's own subscription or machine, so a
            // price/latency tier would be misleading. Their own list is the
            // honest choice.
            return []
        }
    }

    /// The recommended model for one tier, if the provider offers that tier.
    static func recommendedModel(tier: ModelChoiceTier, for kind: AIProviderKind) -> RecommendedModel? {
        recommendedModels(for: kind).first { $0.tier == tier }
    }

    /// Context metadata from a maintained quick pick. A fetched catalogue is
    /// preferred by callers when it reports a more specific value.
    static func contextWindow(for kind: AIProviderKind, modelID: String) -> Int? {
        if kind == .appleLocalModel { return 4_096 }
        return recommendedModels(for: kind).first(where: { $0.modelID == modelID })?.contextWindow
    }

    // MARK: - Requests

    /// Builds the `GET …/models` request for an OpenAI-compatible provider.
    /// The base URL must be HTTPS, and the key is sent only to that origin.
    static func listRequest(for kind: AIProviderKind, baseURL: String, apiKey: String?) throws -> URLRequest {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URLNormalisation.isHTTPSURL(trimmed),
              var components = URLComponents(string: trimmed),
              components.host != nil else {
            throw ProviderModelCatalogueError.invalidConfiguration(
                "Set a valid HTTPS base URL for \(kind.displayName) before loading models."
            )
        }
        components.query = nil
        components.fragment = nil
        components.path = components.path.hasSuffix("/")
            ? components.path + "models"
            : components.path + "/models"
        guard let url = components.url else {
            throw ProviderModelCatalogueError.invalidConfiguration(
                "The \(kind.displayName) model list URL could not be built."
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = APIKeyHygiene.bearerValue(apiKey) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Parsing

    /// Reads an OpenAI-compatible `{"data":[…]}` model list. Both OpenRouter and
    /// Mistral use this envelope with different extra fields, so the reader is
    /// tolerant and treats an unreadable row as absent rather than fatal.
    static func parseModels(kind: AIProviderKind, data: Data) throws -> [ProviderModel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderModelCatalogueError.invalidResponse(
                "\(kind.displayName) did not return a readable model list."
            )
        }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw ProviderModelCatalogueError.invalidResponse(Redaction.redacted(bound(message, limit: 300)))
        }
        guard let rows = root["data"] as? [[String: Any]] else {
            throw ProviderModelCatalogueError.invalidResponse(
                "\(kind.displayName) returned a model list in an unexpected shape."
            )
        }

        let models = rows.compactMap { row -> ProviderModel? in
            guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return nil }
            // Mistral's single catalogue mixes chat, OCR, audio, embedding,
            // moderation and classifier models. Only `completion_chat` models
            // can answer a chat request, so listing the rest would hand the
            // user an identifier that fails the moment it is used.
            if kind == .mistral, !isMistralChatModel(row) { return nil }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = (row["max_context_length"] as? Int) ?? (row["context_length"] as? Int)
            let isFree = isFreeModel(row: row, id: id)
            return ProviderModel(
                id: id,
                name: name?.isEmpty == false ? name! : id,
                detail: detail(for: kind, row: row, contextLength: context, isFree: isFree),
                isFree: isFree,
                contextWindow: context
            )
        }

        guard !models.isEmpty else {
            throw ProviderModelCatalogueError.emptyCatalogue(
                "\(kind.displayName) reported no usable models."
            )
        }
        return models
    }

    /// Reads the catalogue printed by `codex debug models`. Hidden entries are
    /// the tool's internal routes, not choices a person should be offered.
    static func parseCodexModels(data: Data) throws -> [ProviderModel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else {
            throw ProviderModelCatalogueError.invalidResponse(
                "Codex did not return a readable model list."
            )
        }

        let visible = rows.filter { row in
            guard let visibility = row["visibility"] as? String else { return true }
            return visibility.lowercased() != "hide"
        }

        let sorted = visible.sorted { lhs, rhs in
            let left = (lhs["priority"] as? Int) ?? Int.max
            let right = (rhs["priority"] as? Int) ?? Int.max
            if left == right {
                return ((lhs["slug"] as? String) ?? "") < ((rhs["slug"] as? String) ?? "")
            }
            return left < right
        }

        let models = sorted.compactMap { row -> ProviderModel? in
            guard let slug = (row["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !slug.isEmpty else { return nil }
            let display = (row["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = (row["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let contextWindow = (row["context_window"] as? Int)
                ?? (row["context_length"] as? Int)
                ?? (row["max_context_length"] as? Int)
            return ProviderModel(
                id: slug,
                name: display?.isEmpty == false ? display! : slug,
                detail: description?.isEmpty == false ? bound(description!, limit: 90) : nil,
                contextWindow: contextWindow
            )
        }

        guard !models.isEmpty else {
            throw ProviderModelCatalogueError.emptyCatalogue("Codex reported no usable models.")
        }
        return models
    }

    /// Merges a fetched list with Kestrel's built-ins. Built-ins stay first so a
    /// zero-cost route is always reachable, and duplicates are removed by
    /// identifier so the live list is not repeated.
    static func merging(builtIns: [ProviderModel], fetched: [ProviderModel]) -> [ProviderModel] {
        var seen = Set<String>()
        var result: [ProviderModel] = []
        for model in builtIns + fetched {
            guard seen.insert(model.id).inserted else { continue }
            result.append(model)
        }
        return Array(result.prefix(maximumModels))
    }

    // MARK: - Loading

    /// Fetches the model list for a provider. Throws a readable error rather
    /// than silently returning a partial list, so the picker can say what went
    /// wrong and the user can keep whatever model is already selected.
    static func load(
        kind: AIProviderKind,
        settings: AIProviderSettings,
        secretProvider: SecretProviding,
        transport: ProviderModelTransport = LiveProviderModelTransport(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> [ProviderModel] {
        // The shared secret chain can include Keychain. Browsing a model list is
        // not a reason to trigger a macOS credential prompt, so this loader
        // deliberately never asks `secretProvider` for a stored value.
        _ = secretProvider
        let builtIns = builtInModels(for: kind)

        switch kind {
        case .appleLocalModel:
            return builtIns

        case .workBuddyCLI:
            return builtIns
        case .kiloCLI:
            throw ProviderModelCatalogueError.unsupportedProvider(
                "Kilo does not publish a model list. Type the model name, or leave it empty to use the tool's own default."
            )

        case .codexCLI:
            if CodexRuntime.executableURL != nil {
                let rpc = try await CodexRuntime.connect()
                do {
                    var models: [ProviderModel] = []
                    var cursor: String?
                    for _ in 0..<5 {
                        var params: [String: Any] = ["includeHidden": false, "limit": 100]
                        if let cursor { params["cursor"] = cursor }
                        let result = try await rpc.request("model/list", params)
                        for row in result["data"] as? [[String: Any]] ?? [] {
                            guard let id = row["model"] as? String, row["hidden"] as? Bool != true else { continue }
                            models.append(ProviderModel(id: id, name: row["displayName"] as? String ?? id,
                                detail: (row["description"] as? String).map { bound($0, limit: 90) }, contextWindow: nil))
                        }
                        let next = result["nextCursor"] as? String
                        guard let next, next != cursor else { break }
                        cursor = next
                    }
                    await rpc.close()
                    guard !models.isEmpty else { throw ProviderModelCatalogueError.emptyCatalogue("Codex reported no usable models. Sign in with ChatGPT and reload.") }
                    return models
                } catch { await rpc.close(); throw error }
            }
            let executable = settings.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !executable.isEmpty else {
                throw ProviderModelCatalogueError.invalidConfiguration(
                    "Set the Codex executable in Settings before loading models."
                )
            }
            let result: (stdout: Data, status: Int32)
            do {
                result = try await transport.run(
                    executable: executable,
                    arguments: codexModelsArguments,
                    timeout: cliTimeout
                )
            } catch let error as ProviderModelCatalogueError {
                throw error
            } catch {
                throw ProviderModelCatalogueError.processFailed(
                    executable: executable,
                    exitCode: -1,
                    message: Redaction.redacted(bound(error.localizedDescription, limit: 300))
                )
            }
            guard result.status == 0 else {
                throw ProviderModelCatalogueError.processFailed(
                    executable: executable,
                    exitCode: result.status,
                    message: Redaction.redacted(bound(String(decoding: result.stdout.prefix(400), as: UTF8.self), limit: 300))
                )
            }
            return try parseCodexModels(data: result.stdout)

        case .openRouter, .mistral, .googleGemini, .groq, .deepSeek, .xAI, .customOpenAI:
            let key: String?
            if kind == .openRouter {
                key = nil
            } else {
                let secret = EnvironmentSecretProvider(environment: environment).secret(
                    named: settings.apiKeyEnvironmentVariable,
                    keychainAccount: ""
                )
                if (secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ProviderModelCatalogueError.missingSecret(
                        "Set \(settings.apiKeyEnvironmentVariable) in the app environment to browse all \(kind.displayName) models. Quick picks still work; saved keys are not read just to open this list."
                    )
                }
                key = secret
            }
            let request = try listRequest(for: kind, baseURL: settings.baseURL ?? "", apiKey: key)

            let response: (data: Data, statusCode: Int)
            do {
                response = try await transport.data(for: request)
            } catch let error as ProviderModelCatalogueError {
                throw error
            } catch {
                throw ProviderModelCatalogueError.transport(Redaction.redacted(bound(error.localizedDescription, limit: 300)))
            }

            guard (200..<300).contains(response.statusCode) else {
                let message = String(decoding: response.data.prefix(400), as: UTF8.self)
                throw ProviderModelCatalogueError.httpStatus(
                    code: response.statusCode,
                    message: Redaction.redacted(bound(message, limit: 300))
                )
            }
            let fetched = try parseModels(kind: kind, data: response.data)
            return merging(builtIns: builtIns, fetched: fetched)
        }
    }

    // MARK: - Helpers

    private static func isFreeModel(row: [String: Any], id: String) -> Bool {
        if id.lowercased().hasSuffix(":free") { return true }
        guard let pricing = row["pricing"] as? [String: Any] else { return false }
        let prompt = numericString(pricing["prompt"])
        let completion = numericString(pricing["completion"])
        return prompt == "0" && completion == "0"
    }

    /// Mistral marks the usable chat models with `capabilities.completion_chat`.
    /// A catalogue that predates `capabilities` reported a `type` of `chat` for
    /// the same thing; the two shapes are both understood so an older response
    /// still works, while specialist rows (OCR, audio, embed, moderation) are
    /// dropped either way.
    private static func isMistralChatModel(_ row: [String: Any]) -> Bool {
        if let capabilities = row["capabilities"] as? [String: Any] {
            return (capabilities["completion_chat"] as? Bool) == true
        }
        if let type = (row["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !type.isEmpty {
            return type == "chat"
        }
        return true
    }

    private static func numericString(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func detail(
        for kind: AIProviderKind,
        row: [String: Any],
        contextLength: Int?,
        isFree: Bool
    ) -> String? {
        var parts: [String] = []
        if isFree {
            parts.append("Free")
        }
        if let contextLength, contextLength > 0 {
            parts.append("\(contextLength / 1_000)k context")
        }
        if kind == .mistral, let capabilities = row["capabilities"] as? [String: Any] {
            // Real Mistral rows describe abilities here; `type` is only the
            // base/fine-tuned discriminator and means nothing to a user.
            if capabilities["vision"] as? Bool == true { parts.append("vision") }
            if capabilities["reasoning"] as? Bool == true { parts.append("reasoning") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func bound(_ text: String, limit: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[collapsed.startIndex..<end]) + "…"
    }
}

/// The real transport: `URLSession` for HTTP providers and `Process` for the
/// Codex command line tool. Arguments are passed as an argv array, never
/// assembled into a shell string.
struct LiveProviderModelTransport: ProviderModelTransport {
    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderModelCatalogueError.invalidResponse("The server did not return an HTTP response.")
        }
        return (data.prefix(ProviderModelCatalogue.maximumResponseBytes), httpResponse.statusCode)
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> (stdout: Data, status: Int32) {
        guard let executableURL = CLIProvider.resolveExecutable(executable) else {
            throw ProviderModelCatalogueError.processFailed(
                executable: executable,
                exitCode: -1,
                message: "The executable is missing or inaccessible to Kestrel. The macOS app sandbox may prevent access to a host CLI. For external Codex browser control, use Settings → Connections → Connect Codex; selecting the Assistant provider does not connect that bridge."
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProviderModelCatalogueError.processFailed(
                executable: executable,
                exitCode: -1,
                message: Redaction.redacted(String(error.localizedDescription.prefix(300)))
            )
        }

        return try await withThrowingTaskGroup(of: (Data, Int32).self) { group in
            group.addTask {
                async let stdout = Self.readToEnd(stdoutPipe.fileHandleForReading)
                async let stderr = Self.readToEnd(stderrPipe.fileHandleForReading)
                _ = await stderr
                let status = await Self.waitForExit(process)
                return (await stdout, status)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                if process.isRunning { process.terminate() }
                return (Data(), -1)
            }

            guard let first = try await group.next() else {
                throw ProviderModelCatalogueError.processFailed(
                    executable: executable,
                    exitCode: -1,
                    message: "The command did not run."
                )
            }
            group.cancelAll()
            return (first.0.prefix(ProviderModelCatalogue.maximumResponseBytes), first.1)
        }
    }

    private static func waitForExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
