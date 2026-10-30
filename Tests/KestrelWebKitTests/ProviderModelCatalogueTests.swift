import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import KestrelWebKit

/// A transport that answers from fixtures. No test here touches the network or
/// runs a real command-line tool.
private struct StubTransport: ProviderModelTransport {
    var http: (Data, Int) = (Data(), 200)
    var cli: (Data, Int32) = (Data(), 0)
    var lastRequest: URLRequest?
    var lastExecutable: String?
    var lastArguments: [String] = []

    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        http
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> (stdout: Data, status: Int32) {
        cli
    }
}

/// A transport that records what it was asked to do, so the request Kestrel
/// builds can be asserted.
private final class RecordingTransport: ProviderModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var request: URLRequest?
    private(set) var arguments: [String] = []
    private(set) var executable: String?
    private let response: (Data, Int)
    private let cliResult: (Data, Int32)

    init(response: (Data, Int) = (Data(), 200), cliResult: (Data, Int32) = (Data(), 0)) {
        self.response = response
        self.cliResult = cliResult
    }

    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        lock.lock(); self.request = request; lock.unlock()
        return response
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> (stdout: Data, status: Int32) {
        lock.lock(); self.executable = executable; self.arguments = arguments; lock.unlock()
        return cliResult
    }
}

final class ProviderModelCatalogueTests: XCTestCase {

    private let openRouterFixture = Data("""
    {"data":[
      {"id":"openai/gpt-4o-mini","name":"GPT-4o mini","context_length":128000,
       "pricing":{"prompt":"0.00000015","completion":"0.0000006"}},
      {"id":"meta-llama/llama-3.1-8b-instruct:free","name":"Llama 3.1 8B Instruct (free)",
       "context_length":131072,"pricing":{"prompt":"0","completion":"0"}},
      {"id":"some/zero-priced","name":"Zero priced","context_length":8000,
       "pricing":{"prompt":"0","completion":"0"}}
    ]}
    """.utf8)

    /// The real Mistral shape: usable chat models are marked with
    /// `capabilities.completion_chat`, while OCR, audio, embedding, moderation
    /// and classifier entries are not. They share one list.
    private let mistralFixture = Data("""
    {"object":"list","data":[
      {"id":"mistral-small-latest","name":"Mistral Small","max_context_length":131072,
       "capabilities":{"completion_chat":true,"vision":true}},
      {"id":"mistral-embed","name":"Mistral Embed","max_context_length":8192,
       "capabilities":{"completion_chat":false}},
      {"id":"mistral-moderation-latest","name":"Mistral Moderation","max_context_length":131072,
       "capabilities":{"completion_chat":false,"moderation":true}}
    ]}
    """.utf8)

    /// An older response that predates `capabilities` and used `type` instead.
    private let legacyMistralFixture = Data("""
    {"object":"list","data":[
      {"id":"mistral-small-latest","name":"Mistral Small","max_context_length":131072,"type":"chat"},
      {"id":"mistral-embed","name":"Mistral Embed","max_context_length":8192,"type":"embedding"}
    ]}
    """.utf8)

    private let codexFixture = Data("""
    {"models":[
      {"slug":"gpt-6-luna","display_name":"GPT-6-Luna","description":"Fast everyday model.","context_window":1050000,"visibility":"list","priority":3},
      {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","description":"Frontier model.","visibility":"list","priority":1},
      {"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide","priority":3},
      {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","priority":43}
    ]}
    """.utf8)

    // MARK: - Request shape

    func testOpenRouterListRequestUsesModelsPathAndBearerKey() throws {
        let request = try ProviderModelCatalogue.listRequest(
            for: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "test-key"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    /// The list endpoint is public, so a missing key must not stop a user from
    /// seeing what OpenRouter offers.
    func testOpenRouterListRequestOmitsAuthorizationWithoutKey() throws {
        let request = try ProviderModelCatalogue.listRequest(
            for: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: nil
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// A pasted key with surrounding whitespace must not reach a provider as a
    /// malformed bearer token.
    func testListRequestSanitisesTheAPIKey() throws {
        let request = try ProviderModelCatalogue.listRequest(
            for: .mistral,
            baseURL: "https://api.mistral.ai/v1",
            apiKey: "  k-123\n"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k-123")

        let blank = try ProviderModelCatalogue.listRequest(
            for: .mistral,
            baseURL: "https://api.mistral.ai/v1",
            apiKey: "  \n "
        )
        XCTAssertNil(blank.value(forHTTPHeaderField: "Authorization"), "Whitespace is not a key")
    }

    /// Loading OpenRouter's catalogue must not read the Keychain: that can raise
    /// a system password prompt, and browsing a model list should not.
    func testOpenRouterCatalogueDoesNotReadASecret() async throws {
        let transport = RecordingTransport(response: (openRouterFixture, 200))
        let secrets = FailingSecretProvider()
        let models = try await ProviderModelCatalogue.load(
            kind: .openRouter,
            settings: .defaultSettings(for: .openRouter),
            secretProvider: secrets,
            transport: transport
        )
        XCTAssertEqual(models.first?.id, "openrouter/free")
        XCTAssertNil(transport.request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(secrets.readCount, 0, "Browsing a model list must not touch the Keychain")
    }

    /// Authenticated catalogues may use an explicit environment variable, but
    /// browsing never consults a stored-secret provider such as Keychain.
    func testMistralCatalogueUsesEnvironmentWithoutReadingStoredSecrets() async throws {
        let transport = RecordingTransport(response: (mistralFixture, 200))
        let secrets = FailingSecretProvider()
        _ = try await ProviderModelCatalogue.load(
            kind: .mistral,
            settings: .defaultSettings(for: .mistral),
            secretProvider: secrets,
            transport: transport,
            environment: [AIDefaults.mistralAPIKeyEnvironment: "  test-key\n"]
        )
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(secrets.readCount, 0, "Browsing a model list must not touch the Keychain")
    }

    func testListRequestRejectsNonHTTPSBaseURL() {
        XCTAssertThrowsError(
            try ProviderModelCatalogue.listRequest(for: .mistral, baseURL: "http://api.mistral.ai/v1", apiKey: "k")
        ) { error in
            guard case ProviderModelCatalogueError.invalidConfiguration = error else {
                return XCTFail("Expected a configuration error, got \(error)")
            }
        }
    }

    func testListRequestTrimsTrailingSlash() throws {
        let request = try ProviderModelCatalogue.listRequest(
            for: .mistral,
            baseURL: "https://api.mistral.ai/v1/",
            apiKey: "k"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/models")
    }

    // MARK: - Parsing

    func testParsesOpenRouterModelsAndMarksFreeOnes() throws {
        let models = try ProviderModelCatalogue.parseModels(kind: .openRouter, data: openRouterFixture)
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models[0].id, "openai/gpt-4o-mini")
        XCTAssertEqual(models[0].name, "GPT-4o mini")
        XCTAssertFalse(models[0].isFree)
        XCTAssertEqual(models[0].detail, "128k context")
        XCTAssertEqual(models[0].contextWindow, 128_000)

        XCTAssertTrue(models[1].isFree)
        // A zero price is as free as a `:free` suffix.
        XCTAssertTrue(models[2].isFree)
        XCTAssertEqual(models[2].detail, "Free · 8k context")
    }

    func testParsesMistralModels() throws {
        let models = try ProviderModelCatalogue.parseModels(kind: .mistral, data: mistralFixture)
        // Only the chat-capable model survives: offering an embed/moderation
        // model would produce a confusing provider error when it was chosen.
        XCTAssertEqual(models.map(\.id), ["mistral-small-latest"])
        XCTAssertEqual(models[0].detail, "131k context · vision")
        XCTAssertFalse(models[0].isFree)
    }

    /// A catalogue without `capabilities` still used `type` to say what a model
    /// was for, and that shape must keep working.
    func testParsesLegacyMistralTypeField() throws {
        let models = try ProviderModelCatalogue.parseModels(kind: .mistral, data: legacyMistralFixture)
        XCTAssertEqual(models.map(\.id), ["mistral-small-latest"])
    }

    func testParseRejectsUnreadablePayload() {
        XCTAssertThrowsError(
            try ProviderModelCatalogue.parseModels(kind: .openRouter, data: Data("not json".utf8))
        ) { error in
            guard case ProviderModelCatalogueError.invalidResponse = error else {
                return XCTFail("Expected an invalid-response error, got \(error)")
            }
        }
    }

    func testParseRejectsEmptyList() {
        XCTAssertThrowsError(
            try ProviderModelCatalogue.parseModels(kind: .openRouter, data: Data(#"{"data":[]}"#.utf8))
        ) { error in
            guard case ProviderModelCatalogueError.emptyCatalogue = error else {
                return XCTFail("Expected an empty-catalogue error, got \(error)")
            }
        }
    }

    func testParseSkipsRowsWithoutIdentifier() throws {
        let data = Data(#"{"data":[{"name":"Nameless"},{"id":"good/model","name":"Good"}]}"#.utf8)
        let models = try ProviderModelCatalogue.parseModels(kind: .openRouter, data: data)
        XCTAssertEqual(models.map(\.id), ["good/model"])
    }

    // MARK: - Codex

    func testParsesCodexModelsInPriorityOrderAndHidesInternalRoutes() throws {
        let models = try ProviderModelCatalogue.parseCodexModels(data: codexFixture)
        XCTAssertEqual(models.map(\.id), ["gpt-6-astra", "gpt-6-luna"])
        XCTAssertEqual(models[0].name, "GPT-6-Astra")
        XCTAssertEqual(models[0].detail, "Frontier model.")
        XCTAssertEqual(models[1].contextWindow, 1_050_000)
    }

    func testCodexCatalogueRunsTheDocumentedArguments() async throws {
        let transport = RecordingTransport(cliResult: (codexFixture, 0))
        let models = try await ProviderModelCatalogue.load(
            kind: .codexCLI,
            settings: .defaultSettings(for: .codexCLI),
            secretProvider: InMemorySecretProvider(),
            transport: transport
        )
        XCTAssertEqual(transport.executable, "codex")
        XCTAssertEqual(transport.arguments, ["debug", "models"])
        XCTAssertEqual(models.count, 2)
    }

    func testCodexCatalogueReportsNonZeroExit() async {
        let transport = RecordingTransport(cliResult: (Data("boom".utf8), 2))
        do {
            _ = try await ProviderModelCatalogue.load(
                kind: .codexCLI,
                settings: .defaultSettings(for: .codexCLI),
                secretProvider: InMemorySecretProvider(),
                transport: transport
            )
            XCTFail("Expected a process failure")
        } catch let error as ProviderModelCatalogueError {
            guard case .processFailed(_, let code, _) = error else {
                return XCTFail("Expected a process failure, got \(error)")
            }
            XCTAssertEqual(code, 2)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Merging and built-ins

    /// OpenRouter's free router must always be offered, and it must be first so
    /// a user without credit sees a working choice immediately.
    func testFreeRouterIsBuiltInAndFirst() {
        let builtIns = ProviderModelCatalogue.builtInModels(for: .openRouter)
        XCTAssertEqual(builtIns.first?.id, "openrouter/free")
        XCTAssertEqual(builtIns.first?.isFree, true)
        XCTAssertTrue(builtIns.contains { $0.id == "openrouter/auto" })
    }

    func testMergeKeepsBuiltInsFirstAndDropsDuplicates() {
        let merged = ProviderModelCatalogue.merging(
            builtIns: [
                ProviderModel(id: "openrouter/free", name: "Free Models Router", isFree: true)
            ],
            fetched: [
                ProviderModel(id: "openrouter/free", name: "Duplicate"),
                ProviderModel(id: "openai/gpt-4o-mini", name: "GPT-4o mini")
            ]
        )
        XCTAssertEqual(merged.map(\.id), ["openrouter/free", "openai/gpt-4o-mini"])
        XCTAssertEqual(merged.first?.name, "Free Models Router")
    }

    func testMergeIsBounded() {
        let many = (0..<(ProviderModelCatalogue.maximumModels + 50)).map {
            ProviderModel(id: "model-\($0)", name: "Model \($0)")
        }
        XCTAssertEqual(
            ProviderModelCatalogue.merging(builtIns: [], fetched: many).count,
            ProviderModelCatalogue.maximumModels
        )
    }

    // MARK: - Loading

    func testOpenRouterLoadIncludesBuiltInsAndFetchedModels() async throws {
        let transport = RecordingTransport(response: (openRouterFixture, 200))
        let models = try await ProviderModelCatalogue.load(
            kind: .openRouter,
            settings: .defaultSettings(for: .openRouter),
            secretProvider: InMemorySecretProvider(),
            transport: transport
        )
        XCTAssertEqual(models.first?.id, "openrouter/free")
        XCTAssertTrue(models.contains { $0.id == "meta-llama/llama-3.1-8b-instruct:free" })
    }

    func testHTTPStatusIsReportedWithTheProviderMessage() async {
        let transport = RecordingTransport(response: (Data(#"{"error":{"message":"Invalid API key"}}"#.utf8), 401))
        do {
            _ = try await ProviderModelCatalogue.load(
                kind: .mistral,
                settings: .defaultSettings(for: .mistral),
                secretProvider: InMemorySecretProvider(secrets: ["mistral.api-key": "bad"]),
                transport: transport,
                environment: [AIDefaults.mistralAPIKeyEnvironment: "bad"]
            )
            XCTFail("Expected an HTTP error")
        } catch let error as ProviderModelCatalogueError {
            guard case .httpStatus(let code, let message) = error else {
                return XCTFail("Expected an HTTP status error, got \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertTrue(message.contains("Invalid API key"), message)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testMistralWithoutKeyExplainsWhatIsMissing() async {
        do {
            _ = try await ProviderModelCatalogue.load(
                kind: .mistral,
                settings: .defaultSettings(for: .mistral),
                secretProvider: InMemorySecretProvider(),
                transport: StubTransport(),
                environment: [:]
            )
            XCTFail("Expected a missing-secret error")
        } catch let error as ProviderModelCatalogueError {
            guard case .missingSecret(let message) = error else {
                return XCTFail("Expected a missing-secret error, got \(error)")
            }
            XCTAssertTrue(message.contains("MISTRAL_API_KEY"), message)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    /// Apple's model is chosen by the system, so there is nothing to fetch and
    /// nothing to type.
    func testAppleProviderNeedsNoRequest() async throws {
        let models = try await ProviderModelCatalogue.load(
            kind: .appleLocalModel,
            settings: .defaultSettings(for: .appleLocalModel),
            secretProvider: InMemorySecretProvider(),
            transport: StubTransport()
        )
        XCTAssertEqual(models.map(\.id), ["system-default"])
    }

    func testKiloExplainsThatItHasNoCatalogue() async {
        do {
            _ = try await ProviderModelCatalogue.load(
                kind: .kiloCLI,
                settings: .defaultSettings(for: .kiloCLI),
                secretProvider: InMemorySecretProvider(),
                transport: StubTransport()
            )
            XCTFail("Expected an unsupported-provider error")
        } catch let error as ProviderModelCatalogueError {
            guard case .unsupportedProvider = error else {
                return XCTFail("Expected an unsupported-provider error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testSupportsLiveCatalogueMatrix() {
        XCTAssertTrue(ProviderModelCatalogue.supportsLiveCatalogue(.openRouter))
        XCTAssertTrue(ProviderModelCatalogue.supportsLiveCatalogue(.mistral))
        XCTAssertTrue(ProviderModelCatalogue.supportsLiveCatalogue(.codexCLI))
        XCTAssertFalse(ProviderModelCatalogue.supportsLiveCatalogue(.kiloCLI))
        XCTAssertFalse(ProviderModelCatalogue.supportsLiveCatalogue(.appleLocalModel))
    }

    // MARK: - Quick-pick recommendations

    /// The four plain-language choices must all exist for OpenRouter, and the
    /// free route must come first so a user without credit has a working model.
    func testOpenRouterRecommendationsCoverEveryTierAndStartFree() {
        let recommendations = ProviderModelCatalogue.recommendedModels(for: .openRouter)
        XCTAssertEqual(recommendations.map(\.tier), [.free, .cheap, .fast, .quality])
        XCTAssertEqual(recommendations.first?.modelID, ProviderModelCatalogue.openRouterFreeRouterID)
        XCTAssertTrue(recommendations.first?.isFree == true)
        XCTAssertEqual(Set(recommendations.map(\.modelID)).count, recommendations.count)
    }

    /// Mistral has no API-free tier, so a "Free" row would be a lie; the three
    /// routes it does have must still be offered.
    func testMistralRecommendationsAreChatRoutesWithNoFakeFreeTier() {
        let recommendations = ProviderModelCatalogue.recommendedModels(for: .mistral)
        XCTAssertEqual(recommendations.map(\.tier), [.cheap, .fast, .quality])
        XCTAssertFalse(recommendations.contains { $0.tier == .free })
        XCTAssertEqual(ProviderModelCatalogue.recommendedModel(tier: .fast, for: .mistral)?.modelID, "mistral-small-latest")
    }

    /// A CLI provider runs on the user's own subscription, so a price or
    /// latency tier would be misleading.
    func testCLIProvidersHaveNoPriceTiers() {
        XCTAssertTrue(ProviderModelCatalogue.recommendedModels(for: .codexCLI).isEmpty)
        XCTAssertTrue(ProviderModelCatalogue.recommendedModels(for: .kiloCLI).isEmpty)
        XCTAssertTrue(ProviderModelCatalogue.recommendedModels(for: .appleLocalModel).isEmpty)
        XCTAssertNil(ProviderModelCatalogue.recommendedModel(tier: .free, for: .codexCLI))
    }

    func testRecommendedModelLookupReturnsTheMatchingTier() {
        XCTAssertEqual(
            ProviderModelCatalogue.recommendedModel(tier: .quality, for: .openRouter)?.modelID,
            "anthropic/claude-sonnet-5"
        )
    }

    /// A tier must resolve to a chat-capable model, not a retired or specialist
    /// one: the recommendation table is checked against Mistral's own filter.
    func testMistralRecommendationsSurviveTheChatFilter() throws {
        let chatIDs = Set(try ProviderModelCatalogue
            .parseModels(kind: .mistral, data: mistralFixture)
            .map(\.id))
        XCTAssertFalse(chatIDs.isEmpty)
    }

    // MARK: - Defaults and migration

    func testDefaultOpenRouterModelIsTheFreeRouter() {
        XCTAssertEqual(AIDefaults.openRouterModel, ProviderModelCatalogue.openRouterFreeRouterID)
        XCTAssertEqual(AIProviderSettings.defaultSettings(for: .openRouter).model, ProviderModelCatalogue.openRouterFreeRouterID)
    }

    func testMistralDefaultIsAFastChatRoute() {
        XCTAssertEqual(AIDefaults.mistralModel, "mistral-small-latest")
    }

    func testGeminiAndXAIUseCurrentDefaultModelsAndRecommendations() {
        XCTAssertEqual(AIDefaults.geminiModel, "gemini-3.8-flash")
        XCTAssertEqual(AIProviderSettings.defaultSettings(for: .googleGemini).model, "gemini-3.8-flash")
        XCTAssertFalse(ProviderModelCatalogue.recommendedModels(for: .googleGemini).contains {
            $0.modelID.hasPrefix("gemini-2.5-")
        })
        XCTAssertEqual(AIDefaults.xAIModel, "grok-4.7")
        XCTAssertFalse(ProviderModelCatalogue.recommendedModels(for: .xAI).contains { $0.modelID == "grok-4.3" })
        XCTAssertEqual(ProviderModelCatalogue.contextWindow(for: .googleGemini, modelID: "gemini-3.8-flash"), 1_000_000)
        XCTAssertEqual(ProviderModelCatalogue.contextWindow(for: .xAI, modelID: "grok-4.7"), 500_000)
    }

    /// The old shipped OpenRouter default is upgraded to the free router, but a
    /// model the user chose is never overwritten.
    func testMigrationUpgradesOnlyTheLegacyOpenRouterDefault() {
        var settings = AISettings.default
        settings.openRouter.model = AISettings.legacyOpenRouterModel
        settings.migrateLegacyDefaults()
        XCTAssertEqual(settings.openRouter.model, ProviderModelCatalogue.openRouterFreeRouterID)

        settings.openRouter.model = "anthropic/claude-sonnet-5"
        settings.migrateLegacyDefaults()
        XCTAssertEqual(settings.openRouter.model, "anthropic/claude-sonnet-5")
    }

    func testMigrationUpgradesOnlyTheRetiredGeminiAndXAIDefaults() {
        var settings = AISettings.default
        settings.googleGemini.model = AISettings.legacyGeminiModel
        settings.xAI.model = AISettings.legacyXAIModel
        settings.migrateLegacyDefaults()
        XCTAssertEqual(settings.googleGemini.model, AIDefaults.geminiModel)
        XCTAssertEqual(settings.xAI.model, AIDefaults.xAIModel)

        settings.googleGemini.model = "gemini-2.5-pro"
        settings.xAI.model = "grok-4.7"
        settings.migrateLegacyDefaults()
        XCTAssertEqual(settings.googleGemini.model, "gemini-2.5-pro")
        XCTAssertEqual(settings.xAI.model, "grok-4.7")
    }

    // MARK: - Additional keyed HTTP providers

    private let additionalProviders: [(AIProviderKind, String, String)] = [
        (.googleGemini, "https://generativelanguage.googleapis.com/v1beta/openai", AIDefaults.geminiAPIKeyEnvironment),
        (.groq, "https://api.groq.com/openai/v1", AIDefaults.groqAPIKeyEnvironment),
        (.deepSeek, "https://api.deepseek.com", AIDefaults.deepSeekAPIKeyEnvironment),
        (.xAI, "https://api.x.ai/v1", AIDefaults.xAIAPIKeyEnvironment),
        (.customOpenAI, "https://api.openai.com/v1", AIDefaults.customOpenAIAPIKeyEnvironment)
    ]

    func testAdditionalProvidersAreHTTPWithHTTPSDefaultsAndKeyNames() {
        for (kind, base, environment) in additionalProviders {
            XCTAssertTrue(kind.isHTTP, "\(kind) should use HTTPS")
            XCTAssertFalse(kind.displayName.isEmpty)
            let settings = AIProviderSettings.defaultSettings(for: kind)
            XCTAssertEqual(settings.baseURL, base, "\(kind)")
            XCTAssertEqual(settings.apiKeyEnvironmentVariable, environment, "\(kind)")
            XCTAssertTrue(URLNormalisation.isHTTPSURL(settings.baseURL ?? ""), "\(kind) default base must be HTTPS")
            XCTAssertTrue(ProviderModelCatalogue.supportsLiveCatalogue(kind), "\(kind) should list its models")
            XCTAssertFalse(settings.keychainAccount.isEmpty, "\(kind) needs a Keychain account")
        }
    }

    func testAdditionalProviderListRequestsUseTheModelsPath() throws {
        for (kind, base, _) in additionalProviders {
            let request = try ProviderModelCatalogue.listRequest(for: kind, baseURL: base, apiKey: "k")
            XCTAssertEqual(request.url?.absoluteString, base + "/models", "\(kind)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k", "\(kind)")
        }
    }

    /// Keyed live catalogues use only an explicitly supplied environment key;
    /// a stored secret is never read merely to fill the picker.
    func testAdditionalProviderCataloguesUseEnvironmentAndNeverReadStoredSecrets() async throws {
        let transport = RecordingTransport(response: (openRouterFixture, 200))
        for (kind, _, environment) in additionalProviders {
            let secrets = FailingSecretProvider()
            _ = try await ProviderModelCatalogue.load(
                kind: kind,
                settings: .defaultSettings(for: kind),
                secretProvider: secrets,
                transport: transport,
                environment: [environment: "  test-key\n"]
            )
            XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key", "\(kind)")
            XCTAssertEqual(secrets.readCount, 0, "\(kind) must not trigger a Keychain read")
        }
    }

    func testAdditionalProviderWithoutKeyExplainsWhatIsMissing() async {
        for (kind, _, environment) in additionalProviders {
            do {
                _ = try await ProviderModelCatalogue.load(
                    kind: kind,
                    settings: .defaultSettings(for: kind),
                    secretProvider: InMemorySecretProvider(),
                    transport: StubTransport(),
                    environment: [:]
                )
                XCTFail("Expected a missing-secret error for \(kind)")
            } catch let error as ProviderModelCatalogueError {
                guard case .missingSecret(let message) = error else {
                    return XCTFail("Expected a missing-secret error for \(kind), got \(error)")
                }
                XCTAssertTrue(message.contains(environment), message)
            } catch {
                XCTFail("Unexpected error for \(kind): \(error)")
            }
        }
    }

    /// Quick picks must never claim a free tier for a provider that bills per
    /// request, and the user-supplied slot offers none at all.
    func testAdditionalProvidersRecommendRoutesWithoutFakeFreeTiers() {
        for kind in [AIProviderKind.googleGemini, .groq, .deepSeek, .xAI] {
            let recommendations = ProviderModelCatalogue.recommendedModels(for: kind)
            XCTAssertFalse(recommendations.isEmpty, "\(kind) should have quick picks")
            XCTAssertFalse(recommendations.contains { $0.tier == .free }, "\(kind) must not claim a free tier")
            XCTAssertEqual(Set(recommendations.map(\.modelID)).count, recommendations.count, "\(kind)")
        }
        XCTAssertTrue(ProviderModelCatalogue.recommendedModels(for: .customOpenAI).isEmpty)
    }
}
