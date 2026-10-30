import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import KestrelWebKit

private final class ExaThreadRecordingSecretProvider: SecretProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var readOnMainThread = false

    var wasReadOnMainThread: Bool {
        lock.lock(); defer { lock.unlock() }
        return readOnMainThread
    }

    func secret(named environmentName: String, keychainAccount: String) -> String? {
        lock.lock()
        readOnMainThread = Thread.isMainThread
        lock.unlock()
        return "  exa-test-key\n"
    }
}

private final class ExaWaitingSecretProvider: SecretProviding, @unchecked Sendable {
    let started: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(started: XCTestExpectation) { self.started = started }
    func secret(named environmentName: String, keychainAccount: String) -> String? {
        started.fulfill()
        release.wait()
        return "exa-test-key"
    }
}

final class ExaSearchProviderTests: XCTestCase {

    private let fixture = Data("""
    {"requestId":"abc","resolvedSearchType":"neural","results":[
      {"id":"1","title":"Apple iPhone 16","url":"https://www.apple.com/iphone-16/",
       "text":"The iPhone 16 brings the Action button to the base model."},
      {"id":"2","title":"iPhone buying guide","url":"https://example.com/guide?utm_source=x#frag",
       "text":"Compare the base model against the Pro."},
      {"id":"3","title":"Bad scheme","url":"javascript:alert(1)","text":"ignore me"},
      {"id":"4","title":"Credentialed","url":"https://user:pass@evil.example.com/page",
       "text":"ignore the credentials"},
      {"id":"5","title":"No text","url":"https://example.org/empty","text":""}
    ]}
    """.utf8)

    // MARK: - Request

    @MainActor
    func testCredentialLookupNeverBlocksTheMainThread() async throws {
        let secrets = ExaThreadRecordingSecretProvider()
        let key = try await ExaCredentialResolver.resolve(from: secrets)

        XCTAssertEqual(key, "exa-test-key")
        XCTAssertFalse(secrets.wasReadOnMainThread)
    }

    func testStopDuringCredentialLookupCannotResumeResearch() async {
        let started = expectation(description: "Credential lookup started")
        let secrets = ExaWaitingSecretProvider(started: started)
        let task = Task { try await ExaCredentialResolver.resolve(from: secrets) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        secrets.release.signal()
        do {
            _ = try await task.value
            XCTFail("A cancelled lookup must not return a key for a new request")
        } catch is CancellationError {
            // Expected: cancellation is checked after the synchronous lookup.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestBodyIsBoundedAndUsesTextContents() throws {
        let body = ExaSearchProvider.requestBody(query: "base model iphone", resultCount: 4, charactersPerResult: 900)
        XCTAssertEqual(body["query"] as? String, "base model iphone")
        XCTAssertEqual(body["numResults"] as? Int, 4)
        XCTAssertEqual(body["type"] as? String, "auto")
        let contents = body["contents"] as? [String: Any]
        let text = contents?["text"] as? [String: Any]
        XCTAssertEqual(text?["maxCharacters"] as? Int, 900)
    }

    func testRequestBodyClampsResultCount() {
        let body = ExaSearchProvider.requestBody(query: "q", resultCount: 5_000, charactersPerResult: 10)
        XCTAssertEqual(body["numResults"] as? Int, ExaSearchProvider.maximumResultCount)
        let contents = body["contents"] as? [String: Any]
        let text = contents?["text"] as? [String: Any]
        XCTAssertEqual(text?["maxCharacters"] as? Int, 200)
    }

    func testRequestUsesExaKeyHeaderAndHTTPSOnly() throws {
        let configuration = ExaSearchConfiguration(apiKey: "exa-test-key")
        let request = try ExaSearchProvider.makeRequest(configuration: configuration, query: "hello")
        XCTAssertEqual(request.url?.absoluteString, "https://api.exa.ai/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "exa-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), nil)
    }

    func testRequestSanitisesPastedKeyWhitespace() throws {
        let request = try ExaSearchProvider.makeRequest(
            configuration: ExaSearchConfiguration(apiKey: "  exa- test\r\n-key\t "), query: "hello")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "exa-test-key")
    }

    func testRequestRejectsMissingKeyAndEmptyQuery() {
        XCTAssertThrowsError(
            try ExaSearchProvider.makeRequest(configuration: ExaSearchConfiguration(apiKey: "   "), query: "hello")
        ) { error in
            XCTAssertEqual(error as? ExaSearchError, .missingKey)
        }
        XCTAssertThrowsError(
            try ExaSearchProvider.makeRequest(configuration: ExaSearchConfiguration(apiKey: "k"), query: "  ")
        ) { error in
            guard case ExaSearchError.invalidConfiguration = error else {
                return XCTFail("Expected a configuration error, got \(error)")
            }
        }
    }

    func testRequestRejectsPlainHTTPEndpoint() {
        let configuration = ExaSearchConfiguration(apiKey: "k", endpoint: "http://api.exa.ai/search")
        XCTAssertThrowsError(try ExaSearchProvider.makeRequest(configuration: configuration, query: "q")) { error in
            guard case ExaSearchError.invalidConfiguration = error else {
                return XCTFail("Expected a configuration error, got \(error)")
            }
        }
    }

    // MARK: - Parsing

    /// Only citable HTTP(S) results survive: a `javascript:` URL is dropped and
    /// a URL carrying credentials is kept with the credentials removed.
    func testParsingKeepsOnlyCitableResults() throws {
        let results = try ExaSearchProvider.parseResults(data: fixture, statusCode: 200)
        XCTAssertEqual(results.map(\.url), [
            "https://www.apple.com/iphone-16/",
            "https://example.com/guide?utm_source=x",
            "https://evil.example.com/page",
            "https://example.org/empty"
        ])
        XCTAssertEqual(results[0].title, "Apple iPhone 16")
        // The fragment is dropped, the query is kept because it identifies the page.
        XCTAssertFalse(results[1].url.contains("#frag"))
        // User-info never reaches a citation.
        XCTAssertFalse(results[2].url.contains("user"))
        XCTAssertFalse(results[2].url.contains("pass"))
    }

    func testSafeSourceURLRejectsNonHTTPAndCredentialedAddresses() {
        XCTAssertNil(ExaSearchProvider.safeSourceURL("javascript:alert(1)"))
        XCTAssertNil(ExaSearchProvider.safeSourceURL("file:///etc/passwd"))
        XCTAssertNil(ExaSearchProvider.safeSourceURL("not a url"))
        XCTAssertEqual(
            ExaSearchProvider.safeSourceURL("https://user:pass@example.com/a"),
            "https://example.com/a"
        )
    }

    func testParseReportsHTTPFailureWithProviderMessage() {
        let data = Data(#"{"error":"Invalid API key"}"#.utf8)
        XCTAssertThrowsError(try ExaSearchProvider.parseResults(data: data, statusCode: 401)) { error in
            guard case ExaSearchError.httpStatus(let code, let message) = error else {
                return XCTFail("Expected an HTTP status error, got \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertTrue(message.contains("Invalid API key"), message)
        }
    }

    func testParseReportsUnreadablePayloadAndEmptyResults() {
        XCTAssertThrowsError(
            try ExaSearchProvider.parseResults(data: Data("nope".utf8), statusCode: 200)
        ) { error in
            guard case ExaSearchError.invalidResponse = error else {
                return XCTFail("Expected an invalid-response error, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try ExaSearchProvider.parseResults(data: Data(#"{"results":[]}"#.utf8), statusCode: 200)
        ) { error in
            guard case ExaSearchError.noResults = error else {
                return XCTFail("Expected a no-results error, got \(error)")
            }
        }
    }

    // MARK: - Page context

    /// The cards shown to the user come from the same results that grounded the
    /// answer, de-duplicated and bounded.
    func testSourcesBecomeBoundedUniqueCards() {
        let results = [
            ExaSearchResult(title: "First", url: "https://first.example/a", text: "Alpha."),
            ExaSearchResult(title: "Duplicate", url: "https://first.example/a", text: "Alpha again."),
            ExaSearchResult(title: "Second", url: "https://second.example/b", text: "Beta.")
        ]
        let sources = ExaSearchProvider.sources(from: results)
        XCTAssertEqual(sources.map(\.url), ["https://first.example/a", "https://second.example/b"])
        XCTAssertEqual(sources.first?.title, "First")

        let many = (0..<20).map {
            ExaSearchResult(title: "R\($0)", url: "https://example.com/\($0)", text: "t")
        }
        XCTAssertEqual(
            ExaSearchProvider.sources(from: many).count,
            WebSearchOutcome.maximumVisibleSources
        )
    }

    /// Each result becomes its own labelled source, so the model can cite a URL
    /// per claim instead of receiving one anonymous blob.
    func testPageContextLabelsEveryResultWithItsURL() {
        let results = [
            ExaSearchResult(title: "First", url: "https://first.example/a", text: "Alpha."),
            ExaSearchResult(title: "Second", url: "https://second.example/b", text: "Beta.")
        ]
        let context = ExaSearchProvider.pageContext(query: "test", results: results, limit: 2_000)

        XCTAssertEqual(context.additionalSources.count, 2)
        XCTAssertEqual(context.additionalSources[0].label, "Web result 1")
        XCTAssertEqual(context.additionalSources[0].url, "https://first.example/a")
        XCTAssertEqual(context.additionalSources[1].url, "https://second.example/b")
        XCTAssertTrue(context.title.contains("test"))

        // Addresses remain visible in each source without duplicated evidence.
        let prompt = PageContextBuilder.promptDescription(context)
        XCTAssertTrue(prompt.contains("https://first.example/a"))
        XCTAssertTrue(prompt.contains("https://second.example/b"))
        XCTAssertTrue(context.textSnapshot.isEmpty)
    }

    func testPageContextRespectsTheCharacterBudget() {
        let long = String(repeating: "word ", count: 5_000)
        let results = (0..<5).map {
            ExaSearchResult(title: "Result \($0)", url: "https://example.com/\($0)", text: long)
        }
        let context = ExaSearchProvider.pageContext(query: "q", results: results, limit: 2_000)
        XCTAssertLessThanOrEqual(context.additionalSources.reduce(0) { $0 + $1.textSnapshot.count }, 2_000)
        XCTAssertTrue(context.additionalSources.allSatisfy(\.wasTruncated))
    }

    /// Exa results must survive the merge with the current page, otherwise the
    /// citations are lost before the prompt is built.
    func testCombiningKeepsPerResultSources() {
        let results = [
            ExaSearchResult(title: "First", url: "https://first.example/a", text: "Alpha."),
            ExaSearchResult(title: "Second", url: "https://second.example/b", text: "Beta.")
        ]
        let search = ExaSearchProvider.pageContext(query: "test", results: results, limit: 2_000)
        let page = PageContextBuilder.make(url: "https://page.example", title: "Page", text: "On screen.")

        let combined = PageContextBuilder.combining(currentPage: page, searchResults: search, limit: 4_000)
        let sources = try? XCTUnwrap(combined?.additionalSources)
        XCTAssertEqual(sources?.count, 2)
        XCTAssertEqual(sources?.map(\.url), ["https://first.example/a", "https://second.example/b"])

        let prompt = PageContextBuilder.promptDescription(combined!)
        XCTAssertTrue(prompt.contains("Web result 1"))
        XCTAssertTrue(prompt.contains("https://first.example/a"))
    }

    func testCombiningStillWrapsASingleUnlabelledSearchResult() {
        let search = PageContextBuilder.make(
            url: "https://duckduckgo.com",
            title: "Search",
            text: "Results on screen."
        )
        let combined = PageContextBuilder.combining(currentPage: nil, searchResults: search, limit: 4_000)
        XCTAssertEqual(combined?.additionalSources.map(\.label), ["Search results"])
    }

    // MARK: - Redirect guard

    /// A redirect to another host must not carry the API key with it.
    func testRedirectGuardStripsKeyOnCrossHostRedirect() async {
        let guardDelegate = ExaRedirectGuard(allowedHost: "api.exa.ai", headerName: "x-api-key")
        var request = URLRequest(url: URL(string: "https://evil.example.com/search")!)
        request.setValue("exa-secret", forHTTPHeaderField: "x-api-key")

        let response = HTTPURLResponse(
            url: URL(string: "https://api.exa.ai/search")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        let result = await guardDelegate.urlSession(
            URLSession.shared,
            task: URLSessionDataTask(),
            willPerformHTTPRedirection: response,
            newRequest: request
        )
        XCTAssertNil(result?.value(forHTTPHeaderField: "x-api-key"))
    }

    func testRedirectGuardKeepsKeyOnSameHostAndRefusesHTTPDowngrade() async {
        let guardDelegate = ExaRedirectGuard(allowedHost: "api.exa.ai", headerName: "x-api-key")
        let response = HTTPURLResponse(
            url: URL(string: "https://api.exa.ai/search")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!

        var sameHost = URLRequest(url: URL(string: "https://api.exa.ai/search/v2")!)
        sameHost.setValue("exa-secret", forHTTPHeaderField: "x-api-key")
        let kept = await guardDelegate.urlSession(
            URLSession.shared, task: URLSessionDataTask(),
            willPerformHTTPRedirection: response, newRequest: sameHost
        )
        XCTAssertEqual(kept?.value(forHTTPHeaderField: "x-api-key"), "exa-secret")

        var downgraded = URLRequest(url: URL(string: "http://api.exa.ai/search")!)
        downgraded.setValue("exa-secret", forHTTPHeaderField: "x-api-key")
        let refused = await guardDelegate.urlSession(
            URLSession.shared, task: URLSessionDataTask(),
            willPerformHTTPRedirection: response, newRequest: downgraded
        )
        XCTAssertNil(refused)
    }

    // MARK: - Settings integration

    // MARK: - Settings integration

    func testExaKeyLookupUsesDocumentedNames() {
        let provider = InMemorySecretProvider(secrets: ["exa.api-key": "from-keychain"])
        XCTAssertEqual(
            provider.secret(
                named: ExaSearchProvider.apiKeyEnvironmentVariable,
                keychainAccount: ExaSearchProvider.keychainAccount
            ),
            "from-keychain"
        )
        XCTAssertEqual(ExaSearchProvider.apiKeyEnvironmentVariable, "EXA_API_KEY")
        XCTAssertEqual(ExaSearchProvider.keychainAccount, "exa.api-key")
    }

    // MARK: - Keychain lookup legibility

    /// A missing key and an inaccessible key must not be the same error: the
    /// fix is different (save one vs re-save from the running app).
    #if canImport(Security)
    func testKeychainLookupOutcomeReportsMissingAndFound() throws {
        let service = "com.shayprasad.Kestrel.tests.\(UUID().uuidString)"
        let account = ExaSearchProvider.keychainAccount
        defer { KeychainSecretStore.deleteSecret(account: account, service: service) }

        guard KeychainSecretStore.setSecret("exa-probe-key", account: account, service: service) else {
            throw XCTSkip("This test runner cannot create a temporary Keychain item.")
        }
        XCTAssertEqual(
            KeychainSecretStore.lookupOutcome(account: account, service: service),
            .found("exa-probe-key"),
            "A stored item must be found with its value intact."
        )
        XCTAssertTrue(KeychainSecretStore.deleteSecret(account: account, service: service))
        XCTAssertEqual(
            KeychainSecretStore.lookupOutcome(account: account, service: service),
            .notFound,
            "A cleared account must read as missing, not inaccessible."
        )
    }

    func testKeychainStatusDescriptionsStayReadable() {
        XCTAssertTrue(
            KeychainSecretStore.describe(status: errSecInteractionNotAllowed).contains("interaction"),
            "The common post-rebuild status must be described in words, not just a number."
        )
        XCTAssertTrue(KeychainSecretStore.describe(status: errSecAuthFailed).contains("authentication"))
        XCTAssertEqual(
            KeychainSecretStore.describe(status: -99_999),
            "the Keychain reported status -99999",
            "Unknown statuses keep the raw number for diagnosis."
        )
    }
    #endif

    func testKeychainInaccessibleErrorEchoesItsMessage() {
        let error = ExaSearchError.keychainInaccessible("The Exa key is in the Keychain, but macOS refused.")
        XCTAssertEqual(error.localizedDescription, "The Exa key is in the Keychain, but macOS refused.")
        XCTAssertEqual(error, .keychainInaccessible("The Exa key is in the Keychain, but macOS refused."))
        XCTAssertNotEqual(error, .missingKey)
    }
}
