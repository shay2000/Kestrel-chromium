import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One web result returned by Exa.
struct ExaSearchResult: Equatable, Sendable {
    let title: String
    let url: String
    let text: String
}

enum ExaSearchError: Error, Equatable, LocalizedError, Sendable {
    case missingKey
    case keychainInaccessible(String)
    case invalidConfiguration(String)
    case transport(String)
    case httpStatus(code: Int, message: String)
    case invalidResponse(String)
    case noResults(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Exa API key found. Add one in Settings, or set EXA_API_KEY for local development."
        case .keychainInaccessible(let message):
            return message
        case .invalidConfiguration(let message),
             .invalidResponse(let message),
             .noResults(let message):
            return message
        case .transport(let message):
            return "The Exa request could not be completed: \(message)"
        case .httpStatus(let code, let message):
            return "Exa replied with HTTP \(code)\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}

/// Reads the opt-in Exa credential away from the main actor. A Keychain item
/// may need user interaction after an app rebuild; `SecItemCopyMatching` is a
/// synchronous call, so performing it on the UI thread would freeze Kestrel
/// and make the operator's Stop control unavailable while macOS decides.
enum ExaCredentialResolver {
    static func resolve(from secrets: SecretProviding) async throws -> String {
        try Task.checkCancellation()
        let key = try await Task.detached(priority: .userInitiated) {
            let rawKey = secrets.secret(
                named: ExaSearchProvider.apiKeyEnvironmentVariable,
                keychainAccount: ExaSearchProvider.keychainAccount
            )
            let key = rawKey.map(APIKeyHygiene.sanitise)
            guard let key, !key.isEmpty else {
                // The composite chain found nothing. Before saying "no key",
                // ask the same provider chain what the Keychain reported. This
                // stays on the worker because the diagnostic is another
                // synchronous Security.framework lookup.
                #if canImport(Security)
                if let outcome = (secrets as? KeychainLookupDiagnosing)?.keychainLookupOutcome(
                    account: ExaSearchProvider.keychainAccount
                ), case .inaccessible(let status) = outcome {
                    throw ExaSearchError.keychainInaccessible(
                        "The Exa key is in the Keychain, but \(KeychainSecretStore.describe(status: status)). "
                            + "Open Settings → Exa web search and save the key again from this copy of Kestrel, then try the search once more."
                    )
                }
                #endif
                throw ExaSearchError.missingKey
            }
            return key
        }.value
        // Security.framework cannot interrupt its synchronous lookup. If Stop
        // was pressed while it waited, never start the network request after
        // the credential eventually becomes available.
        try Task.checkCancellation()
        return key
    }
}

struct ExaSearchConfiguration: Equatable, Sendable {
    let apiKey: String
    let endpoint: String
    let timeout: TimeInterval
    let resultCount: Int
    let charactersPerResult: Int

    /// Exa's documented search endpoint.
    static let defaultEndpoint = "https://api.exa.ai/search"

    init(
        apiKey: String,
        endpoint: String = ExaSearchConfiguration.defaultEndpoint,
        timeout: TimeInterval = 45,
        resultCount: Int = 5,
        charactersPerResult: Int = 1_200
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.timeout = timeout
        self.resultCount = resultCount
        self.charactersPerResult = charactersPerResult
    }
}

/// A connector for Exa's search API.
///
/// This exists so a model can be given real web results instead of Kestrel
/// opening a search tab and scraping the rendered page. Only the redacted query
/// leaves the app: no page text, no cookies, no conversation history. The
/// response is bounded before it becomes page context, and the API key is sent
/// only to the configured origin — a redirect to another host loses it.
struct ExaSearchProvider: Sendable {
    static let apiKeyEnvironmentVariable = "EXA_API_KEY"
    static let keychainAccount = "exa.api-key"
    static let apiKeyHeader = "x-api-key"

    /// Ceiling on the response body held in memory.
    static let maximumResponseBytes = 2_000_000
    static let maximumResultCount = 20

    let configuration: ExaSearchConfiguration

    init(configuration: ExaSearchConfiguration) {
        self.configuration = configuration
    }

    init(apiKey: String) {
        self.configuration = ExaSearchConfiguration(apiKey: apiKey)
    }

    // MARK: - Request

    /// The documented request body. Kept as a pure function so the exact shape
    /// sent to Exa can be asserted in a test without a live key.
    static func requestBody(query: String, resultCount: Int, charactersPerResult: Int) -> [String: Any] {
        [
            "query": query,
            "numResults": min(max(resultCount, 1), maximumResultCount),
            "type": "auto",
            "contents": [
                "text": ["maxCharacters": max(charactersPerResult, 200)]
            ]
        ]
    }

    static func makeRequest(configuration: ExaSearchConfiguration, query: String) throws -> URLRequest {
        guard let trimmedKey = APIKeyHygiene.bearerValue(configuration.apiKey) else {
            throw ExaSearchError.missingKey
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw ExaSearchError.invalidConfiguration("There is no search query to send to Exa.")
        }
        let endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URLNormalisation.isHTTPSURL(endpoint), let url = URL(string: endpoint) else {
            throw ExaSearchError.invalidConfiguration("The Exa endpoint must be a valid HTTPS URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(trimmedKey, forHTTPHeaderField: apiKeyHeader)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(
                query: trimmedQuery,
                resultCount: configuration.resultCount,
                charactersPerResult: configuration.charactersPerResult
            ),
            options: []
        )
        return request
    }

    // MARK: - Parsing

    /// Reads the `{"results":[…]}` envelope. Only HTTP(S) results with a usable
    /// URL are kept: a result Kestrel cannot cite is not worth passing on.
    static func parseResults(data: Data, statusCode: Int) throws -> [ExaSearchResult] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(statusCode) else {
            let message = (object?["error"] as? String)
                ?? (object?["message"] as? String)
                ?? String(decoding: data.prefix(400), as: UTF8.self)
            throw ExaSearchError.httpStatus(code: statusCode, message: Redaction.redacted(bound(message, limit: 300)))
        }

        guard let object else {
            throw ExaSearchError.invalidResponse("Exa's reply was not readable JSON.")
        }
        if let error = object["error"] as? String, !error.isEmpty {
            throw ExaSearchError.invalidResponse(Redaction.redacted(bound(error, limit: 300)))
        }
        guard let rows = object["results"] as? [[String: Any]] else {
            throw ExaSearchError.invalidResponse("Exa's reply contained no results array.")
        }

        let results = rows.compactMap { row -> ExaSearchResult? in
            guard let rawURL = (row["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let safeURL = safeSourceURL(rawURL) else { return nil }
            let title = ((row["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = ((row["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !title.isEmpty else { return nil }
            return ExaSearchResult(
                title: title.isEmpty ? safeURL : Redaction.redacted(title),
                url: safeURL,
                text: Redaction.redacted(text)
            )
        }

        guard !results.isEmpty else {
            throw ExaSearchError.noResults("Exa returned no readable web results for that query.")
        }
        return results
    }

    /// Accepts only a plain HTTP(S) address, and drops any user-info component
    /// so a result cannot smuggle credentials into a citation.
    static func safeSourceURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.string
    }

    /// Turns results into bounded page context. Each result becomes its own
    /// labelled source so the model can cite a URL per claim. Do not also put
    /// a merged copy in the primary excerpt: promptDescription sends both.
    static func pageContext(query: String, results: [ExaSearchResult], limit: Int) -> PageContext {
        let budget = PageContextBuilder.clampLimit(limit)
        var sources: [PageContextSource] = []
        for (index, result) in results.enumerated() {
            var source = PageContext.empty
            source.url = result.url
            source.title = result.title
            source.textSnapshot = result.text
            sources.append(
                PageContextSource(label: "Web result \(index + 1)", context: source)
            )
        }
        var context = PageContext(
            url: "",
            title: "Exa web results for “\(Redaction.redacted(query))”",
            textSnapshot: "",
            wasTruncated: false
        )
        context.additionalSources = sources
        return PageContextBuilder.boundedContext(context, limit: budget)
    }

    // MARK: - Search

    func search(query: String, limit: Int) async throws -> WebSearchOutcome {
        let request = try Self.makeRequest(configuration: configuration, query: query)

        let host = request.url?.host
        let delegate = ExaRedirectGuard(allowedHost: host, headerName: Self.apiKeyHeader)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch {
            throw ExaSearchError.transport(Redaction.redacted(Self.bound(error.localizedDescription, limit: 300)))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExaSearchError.invalidResponse("Exa did not return an HTTP response.")
        }

        let results = try Self.parseResults(
            data: data.prefix(Self.maximumResponseBytes),
            statusCode: httpResponse.statusCode
        )
        // The same results that ground the answer become the user's clickable
        // cards, so a card can never point somewhere the model never saw.
        return WebSearchOutcome(
            context: Self.pageContext(query: query, results: results, limit: limit),
            sources: Self.sources(from: results)
        )
    }

    /// The bounded, de-duplicated card list for a set of results.
    static func sources(from results: [ExaSearchResult]) -> [AssistantSource] {
        WebSearchOutcome.visibleSources(
            from: results.map { AssistantSource(title: $0.title, url: $0.url) }
        )
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

/// Keeps the API key on the origin it was meant for.
///
/// If a redirect leaves that host the credential header is removed, and a
/// redirect that drops out of HTTPS is refused outright. A search API should
/// never be the reason a key ends up somewhere it was not sent.
final class ExaRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let allowedHost: String?
    private let headerName: String

    init(allowedHost: String?, headerName: String) {
        self.allowedHost = allowedHost?.lowercased()
        self.headerName = headerName
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, url.scheme?.lowercased() == "https" else {
            return nil
        }
        guard let allowedHost, url.host?.lowercased() == allowedHost else {
            var stripped = request
            stripped.setValue(nil, forHTTPHeaderField: headerName)
            return stripped
        }
        return request
    }
}
