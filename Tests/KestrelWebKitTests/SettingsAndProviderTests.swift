import XCTest
#if os(macOS) && canImport(FoundationModels)
import FoundationModels
#endif

@testable import KestrelWebKit

#if canImport(SwiftUI) && canImport(WebKit)
private actor AIRequestRecorder {
    private var value: AIRequest?

    func record(_ request: AIRequest) {
        value = request
    }

    func request() -> AIRequest? {
        value
    }
}

private struct AIRecordingProvider: AIProvider {
    let recorder: AIRequestRecorder
    var kind: AIProviderKind { .codexCLI }

    func respond(to request: AIRequest) async throws -> AIResponse {
        await recorder.record(request)
        return AIResponse(text: "Captured")
    }
}

private actor AISequencedProvider: AIProvider {
    let kind: AIProviderKind = .appleLocalModel
    private var replies: [String]
    private var capturedRequests: [AIRequest] = []

    init(replies: [String]) {
        self.replies = replies
    }

    func respond(to request: AIRequest) async throws -> AIResponse {
        capturedRequests.append(request)
        guard !replies.isEmpty else { return AIResponse(text: "No scripted response.") }
        return AIResponse(text: replies.removeFirst())
    }

    func requests() -> [AIRequest] { capturedRequests }
}
#endif

final class SettingsAndProviderTests: XCTestCase {
    func testDefaultsAreHonestAndConfigurable() {
        let settings = AISettings.default
        XCTAssertEqual(settings.selectedProvider, .codexCLI)
        XCTAssertEqual(settings.codex.executablePath, AIDefaults.codexExecutable)
        XCTAssertEqual(settings.openRouter.baseURL, AIDefaults.openRouterBaseURL)
        XCTAssertEqual(settings.openRouter.apiKeyEnvironmentVariable, AIDefaults.openRouterAPIKeyEnvironment)
        XCTAssertFalse(settings.openRouter.apiKeyEnvironmentVariable.isEmpty)
        XCTAssertTrue(settings.allowsAutomaticPageReads)
        XCTAssertEqual(settings.automaticPageContextCharacterLimit, 16_000)
    }

    func testAutomaticPageBudgetTracksSelectedProviderAndIgnoresLegacyPreferences() throws {
        var settings = AISettings.default
        settings.selectedProvider = .openRouter
        var openRouter = settings.openRouter
        openRouter.model = "vendor/custom-8k"
        settings.update(openRouter)
        XCTAssertEqual(settings.automaticPageContextCharacterLimit, 6_000)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacyObject["allowsAutomaticPageReads"] = false
        legacyObject["pageContextCharacterLimit"] = 200
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let restored = try JSONDecoder().decode(AISettings.self, from: legacyData)

        XCTAssertTrue(restored.allowsAutomaticPageReads)
        XCTAssertEqual(restored.automaticPageContextCharacterLimit, 6_000)
    }

    #if canImport(SwiftUI)
    @MainActor
    func testPersonalProfilePersistsSeparatelyAndClearsWithoutEnteringAISettings() throws {
        let suite = "KestrelProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.personalProfile, PersonalProfile())
        var profile = PersonalProfile()
        profile.name = "  Example Person  "
        profile.email = "person@example.invalid"
        profile.addressLine1 = "1 Example Road"
        profile.postcode = "EX1 1EX"
        profile.preferences = "Private preference note"
        settings.personalProfile = profile
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.personalProfile.name, "Example Person")
        XCTAssertTrue(restored.personalProfile.deliveryText.contains("person@example.invalid"))
        XCTAssertFalse(restored.personalProfile.deliveryText.contains("Private preference note"))
        let encodedAI = String(decoding: try JSONEncoder().encode(settings.ai), as: UTF8.self)
        XCTAssertFalse(encodedAI.contains("person@example.invalid"))
        XCTAssertFalse(encodedAI.contains("Example Person"))
        settings.personalProfile = .init()
        XCTAssertEqual(AppSettings(defaults: defaults).personalProfile, .init())
        XCTAssertTrue(AppSettings(defaults: defaults).personalProfile.deliveryText.isEmpty)
        profile.name = String(repeating: "x", count: 1_000)
        profile.preferences = String(repeating: "x", count: 3_000)
        XCTAssertEqual(profile.normalised.name.count, 512)
        XCTAssertEqual(profile.normalised.preferences.count, 2_000)
    }

    @MainActor
    func testAgentConnectionAndAssistantShortcutAreSafeDefaultsAndPersist() {
        let suiteName = "KestrelSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.searchEngine, .google)
        XCTAssertEqual(settings.appearanceMode, .system)
        XCTAssertTrue(settings.translucentChromeEnabled, "Translucent browser chrome should be enabled by default.")
        XCTAssertEqual(settings.newTabAssistantDestination, .assistantPage)
        XCTAssertFalse(settings.agentMCP.isEnabled)
        XCTAssertFalse(settings.agentMCP.sharesActiveTabMetadata)
        XCTAssertFalse(settings.agentMCP.allowsPageReads)
        XCTAssertTrue(settings.autoApproveSafeBrowsing)
        XCTAssertTrue(settings.assistantWebSearchEnabled, "Assistant web search should be enabled by default.")
        XCTAssertEqual(settings.assistantSidebarShortcut, .default)
        XCTAssertEqual(settings.assistantSidebarShortcut.displayName, "⌘ E")

        let chosenShortcut = AssistantSidebarShortcut(key: "j", modifiers: ["command", "shift"])
        let conversation = AssistantConversation(
            title: "Falcon Heavy research",
            messages: [
                AIMessage(role: .user, text: "Tell me about Falcon Heavy"),
                AIMessage(role: .assistant, text: "It is SpaceX's heavy-lift launch vehicle.")
            ],
            updatedAt: Date(timeIntervalSince1970: 1_759_000_000)
        )
        settings.assistantSidebarShortcut = chosenShortcut
        settings.appearanceMode = .dark
        settings.translucentChromeEnabled = false
        settings.newTabAssistantDestination = .assistantSidebar
        settings.autoApproveSafeBrowsing = false
        settings.assistantWebSearchEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).autoApproveSafeBrowsing, "A deliberate strict-approval preference must persist.")
        XCTAssertFalse(AppSettings(defaults: defaults).assistantWebSearchEnabled, "The user's choice to disable default web search must persist.")
        settings.autoApproveSafeBrowsing = true
        settings.assistantWebSearchEnabled = true
        settings.searchEngine = .duckDuckGo
        settings.assistantConversations = [conversation]
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.searchEngine, .duckDuckGo)
        XCTAssertEqual(restored.appearanceMode, .dark)
        XCTAssertFalse(restored.translucentChromeEnabled, "The translucent-chrome choice should persist.")
        XCTAssertEqual(restored.newTabAssistantDestination, .assistantSidebar)
        XCTAssertEqual(restored.assistantSidebarShortcut, chosenShortcut)
        XCTAssertTrue(restored.autoApproveSafeBrowsing)
        XCTAssertTrue(restored.assistantWebSearchEnabled)
        XCTAssertEqual(restored.assistantConversations, [conversation])
    }

    func testAppearanceModesMapToSystemLightAndDarkSchemes() {
        XCTAssertNil(KestrelAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(KestrelAppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(KestrelAppearanceMode.dark.preferredColorScheme, .dark)
    }

    func testAssistantShortcutRejectsBareAndInvalidKeys() {
        XCTAssertFalse(AssistantSidebarShortcut(key: "e", modifiers: []).isValid)
        XCTAssertFalse(AssistantSidebarShortcut(key: "escape", modifiers: ["command"]).isValid)
        XCTAssertFalse(AssistantSidebarShortcut(key: "e", modifiers: ["function"]).isValid)
        XCTAssertTrue(AssistantSidebarShortcut(key: "e", modifiers: ["command"]).isValid)
    }
    #endif

    #if canImport(Network) && canImport(Security) && canImport(SwiftUI) && canImport(WebKit)
    @MainActor
    func testMCPSetupCommandTargetsCodexStreamableHTTP() {
        let endpoint = "http://127.0.0.1:52768/mcp/test-token/mcp"
        XCTAssertEqual(
            KestrelMCPServer.codexSetupCommand(endpointURL: endpoint),
            "codex mcp add kestrel --url '\(endpoint)'"
        )
    }

    @MainActor
    func testLiveCodexReadsThroughTheActualMCPBridge() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_LIVE_CODEX_TESTS"] == "1" else {
            throw XCTSkip("Opt-in authenticated Codex MCP acceptance")
        }
        let service = "com.shayprasad.Kestrel.tests.\(UUID().uuidString)"
        let server = KestrelMCPServer(requestedPort: 0, credentialService: service, credentialAccount: "bridge")
        let marker = "Bridge evidence " + UUID().uuidString
        var reads = 0
        server.configure(settingsProvider: { .init(isEnabled: true, sharesActiveTabMetadata: false, allowsPageReads: true) }, toolHandler: { call in
            guard call.name == "kestrel_read_active_page" else { return .init(text: "Unexpected tool", isError: true) }
            reads += 1
            return .init(text: marker)
        })
        server.start()
        defer { server.stop(); KeychainSecretStore.deleteSecret(account: "bridge", service: service) }
        for _ in 0..<100 where !server.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let endpoint = try XCTUnwrap(server.endpointURL)
        XCTAssertTrue(server.isRunning, server.statusMessage)
        let executable = ProcessInfo.processInfo.environment["KESTREL_LIVE_CODEX_EXECUTABLE"] ?? "codex"
        let provider = CLIProvider(configuration: .init(kind: .codexCLI, executablePath: executable,
            argumentTemplate: ["exec", "--ignore-user-config", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "--json",
                "-c", "mcp_servers.kestrel_qa.url=\"\(endpoint)\"",
                "-c", "mcp_servers.kestrel_qa.enabled_tools=[\"kestrel_read_active_page\"]", "{prompt}"],
            model: "", outputFormat: .codexJSON))
        let response = try await provider.respond(to: .init(messages: [.init(role: .user,
            text: "Use the kestrel_qa kestrel_read_active_page MCP tool once, then repeat its text exactly. Do not use shell or other tools. This is a local synthetic public-page test.")], model: ""))
        let diagnostic = Redaction.redacted(response.text.replacingOccurrences(of: endpoint, with: "[loopback endpoint]"))
        XCTAssertEqual(reads, 1, diagnostic)
        XCTAssertTrue(response.text.contains(marker), diagnostic)
        if reads == 1 { print("LIVE_CODEX_MCP: authenticated CLI read server-only fixture evidence") }
    }

    @MainActor
    func testMCPServerCompletesHandshakeOnAnExplicitNonzeroPort() async throws {
        let service = "com.shayprasad.Kestrel.tests.\(UUID().uuidString)"
        let port = UInt16.random(in: 53000...63000)
        let server = KestrelMCPServer(requestedPort: port, credentialService: service, credentialAccount: "fixed-port")
        server.configure(settingsProvider: { .default }, toolHandler: { .init(text: $0.name) })
        server.start()
        defer { server.stop(); KeychainSecretStore.deleteSecret(account: "fixed-port", service: service) }
        for _ in 0..<100 where !server.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(server.isRunning, server.statusMessage)
        guard server.isRunning else { return }
        XCTAssertTrue(server.displayEndpoint.contains("127.0.0.1:\(port)/"))
        let count = try await server.testConnection()
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testMCPServerCompletesLocalInitializeAndToolListHandshake() async throws {
        let service = "com.shayprasad.Kestrel.tests.\(UUID().uuidString)"
        let account = "mcp-probe"
        let server = KestrelMCPServer(
            requestedPort: 0,
            credentialService: service,
            credentialAccount: account
        )
        server.configure(
            settingsProvider: {
                AgentMCPSettings(
                    isEnabled: true,
                    sharesActiveTabMetadata: false,
                    allowsPageReads: false
                )
            },
            toolHandler: { call in KestrelMCPToolReply(text: call.name) }
        )
        server.start()
        defer {
            server.stop()
            KeychainSecretStore.deleteSecret(account: account, service: service)
        }

        for _ in 0..<100 where !server.isRunning {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard server.isRunning else {
            if server.statusMessage == "Could not create the local MCP Keychain token." {
                throw XCTSkip("This test runner cannot create a temporary Keychain item; the live MCP handshake is not available in this sandbox.")
            }
            XCTFail(server.statusMessage)
            return
        }
        let toolCount = try await server.testConnection()
        XCTAssertEqual(toolCount, 2)
    }
    #endif

    func testAssistantCopyMakesAutomaticPageContextAndRedactionClear() {
        XCTAssertTrue(AIMode.ask.explanation.contains("current page's visible text"))
        XCTAssertTrue(AIMode.ask.explanation.contains("best-effort"))
        XCTAssertTrue(AIMode.operatorMode.explanation.contains("page clicks and changes still require approval"))
    }

    #if canImport(SwiftUI) && canImport(WebKit)
    @MainActor
    func testSearchRequestIncludesCurrentPageAndSearchResultsAutomatically() async throws {
        let recorder = AIRequestRecorder()
        let chat = AIChatStore()
        chat.localIntentClassifier = { _ in .answer }
        var settings = AISettings.default
        settings.selectedProvider = .openRouter
        var openRouter = settings.openRouter
        openRouter.model = "vendor/custom-16k"
        settings.update(openRouter)
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (settings, secrets) }
        chat.providerFactory = { _, _ in AIRecordingProvider(recorder: recorder) }

        let pageText = "Current page's visible text"
        let resultsText = "Visible search results text"
        var pageLimit: Int?
        var resultsLimit: Int?
        chat.currentBrowserContextProvider = {
            BrowserActionContext(tabID: UUID(), pageURL: "https://example.com/current")
        }
        chat.pageContextProvider = { _, _, limit, question in
            pageLimit = limit
            return PageContextBuilder.make(
                url: "https://example.com/current",
                title: "Current page",
                text: pageText,
                limit: limit
            )
        }
        chat.webSearchContextProvider = { query, mode, limit in
            XCTAssertEqual(query, "Find current information")
            XCTAssertEqual(mode, .web)
            resultsLimit = limit
            return WebSearchOutcome(context: PageContextBuilder.make(
                url: "https://duckduckgo.com/",
                title: "Search results",
                text: resultsText,
                limit: limit
            ))
        }

        chat.input = "Find current information"
        chat.send()

        var request: AIRequest?
        for _ in 0..<200 {
            request = await recorder.request()
            if request != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let capturedRequest = try XCTUnwrap(request)
        let systemMessage = try XCTUnwrap(capturedRequest.messages.first { $0.role == .system })

        XCTAssertEqual(pageLimit, 6_000)
        XCTAssertEqual(resultsLimit, 12_000 - pageText.count)
        XCTAssertTrue(systemMessage.text.contains(pageText))
        XCTAssertTrue(systemMessage.text.contains(resultsText))
        XCTAssertTrue(systemMessage.text.contains("redacted on a best-effort basis"))
        XCTAssertTrue(systemMessage.text.contains("Kestrel has already performed a web search"))
        XCTAssertEqual(chat.lastPageContext?.additionalSources.first?.label, "Search results")
        chat.clearConversation()
    }

    @MainActor
    func testAssistantChatsAreSavedReopenedAndUsedAsFollowUpHistory() async throws {
        let recorder = AIRequestRecorder()
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        var persistedConversations: [AssistantConversation] = []
        chat.savedConversationsProvider = { persistedConversations }
        chat.savedConversationsWriter = { persistedConversations = $0 }
        chat.loadSavedConversations()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in AIRecordingProvider(recorder: recorder) }
        chat.localIntentClassifier = { _ in .answer }
        chat.pageContextProvider = { _, _, limit, question in
            PageContextBuilder.make(
                url: "https://example.com/falcon-heavy",
                title: "Falcon Heavy",
                text: "Page snapshot should not be stored in chat history.",
                limit: limit
            )
        }

        chat.send(prompt: "Tell me about Falcon Heavy")
        for _ in 0..<300 {
            let answered = chat.items.contains { item in
                guard case .message(let message) = item else { return false }
                return message.role == .assistant && message.text == "Captured"
            }
            if answered && !chat.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let saved = try XCTUnwrap(chat.savedConversations.first)
        XCTAssertEqual(saved.title, "Tell me about Falcon Heavy")
        XCTAssertEqual(saved.messages.map(\.role), [.user, .assistant])
        XCTAssertFalse(saved.messages.contains { $0.text.contains("Page snapshot should not be stored") })
        XCTAssertEqual(persistedConversations, chat.savedConversations)

        chat.clearConversation()
        XCTAssertTrue(chat.items.isEmpty)
        chat.openConversation(saved.id)
        XCTAssertEqual(chat.items.count, 2)
        XCTAssertEqual(chat.items.compactMap { item -> String? in
            guard case .message(let message) = item else { return nil }
            return message.text
        }, ["Tell me about Falcon Heavy", "Captured"])

        chat.send(prompt: "Can you expand on that?")
        var followUpRequest: AIRequest?
        for _ in 0..<300 {
            let request = await recorder.request()
            if request?.messages.last?.text == "Can you expand on that?" {
                followUpRequest = request
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let messages = try XCTUnwrap(followUpRequest?.messages)
        XCTAssertTrue(messages.contains { $0.role == .user && $0.text == "Tell me about Falcon Heavy" })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.text == "Captured" })
        XCTAssertEqual(messages.last?.text, "Can you expand on that?")

        chat.deleteSavedConversation(saved.id)
        XCTAssertFalse(chat.savedConversations.contains { $0.id == saved.id })
        XCTAssertTrue(chat.items.isEmpty, "Deleting the active chat also clears its visible transcript.")
    }

    @MainActor
    func testAssistantImageSearchUsesTheExtractedQueryAndPreservesComposerDraft() async throws {
        let recorder = AIRequestRecorder()
        let chat = AIChatStore()
        chat.localIntentClassifier = { _ in .answer }
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in AIRecordingProvider(recorder: recorder) }
        chat.currentBrowserContextProvider = { nil }
        chat.pageContextProvider = { _, _, _, question in nil }
        chat.searchEngineProvider = { .bing }

        var observedQuery: String?
        var observedMode: WebSearchMode?
        chat.webSearchContextProvider = { query, mode, _ in
            observedQuery = query
            observedMode = mode
            return WebSearchOutcome(context: PageContextBuilder.make(
                url: "https://www.bing.com/images/search?q=Falcon%20Heavy",
                title: "Bing Images",
                text: "Image results for Falcon Heavy",
                limit: 1_000
            ))
        }

        chat.input = "Keep this draft"
        chat.send(prompt: "Search the web for images of Falcon Heavy")
        var assistantReply: AIMessage?
        for _ in 0..<200 {
            assistantReply = chat.items.compactMap { item in
                guard case .message(let message) = item, message.role == .assistant else { return nil }
                return message
            }.last
            if assistantReply != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let capturedRequest = await recorder.request()
        XCTAssertNil(capturedRequest, "Image search should not ask the small model to claim it cannot browse or inspect image pixels.")
        XCTAssertEqual(
            assistantReply?.text,
            "Opened Bing Images for “Falcon Heavy” in a new tab. Browse the images and their source links there."
        )
        XCTAssertEqual(observedQuery, "Falcon Heavy")
        XCTAssertEqual(observedMode, .images)
        XCTAssertEqual(chat.input, "Keep this draft")
        XCTAssertFalse(chat.isSearchingWeb)
        XCTAssertNil(chat.activityMessage)
        XCTAssertFalse(chat.items.contains { item in
            if case .notice(_, let text) = item { return text.hasPrefix("Searching ") }
            return false
        }, "Transient search progress must not remain in the completed conversation.")
        chat.clearConversation()
    }

    @MainActor
    func testSafeBrowsingAutoApprovesSearchButKeepsClicksAndMCPActionsGated() async throws {
        let scriptedProvider = AISequencedProvider(replies: [
            #"I'll open Apple's store page. {"action":"open_url","url":"https://www.apple.com/shop","rationale":"Open the store"}"#,
            #"{"action":"search_page","query":"iPhone","rationale":"Search the current store page"}"#,
            #"{"action":"click_text","query":"Add to bag","rationale":"Select the requested product"}"#
        ])
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in scriptedProvider }
        chat.localIntentClassifier = { _ in .cursor }
        chat.autoApproveSafeBrowsingProvider = { true }

        let tabID = UUID()
        let context = BrowserActionContext(tabID: tabID, pageURL: "https://www.apple.com/shop")
        chat.currentBrowserContextProvider = { context }
        chat.pageContextProvider = { context, _, limit, question in
            PageContextBuilder.make(
                url: context?.pageURL ?? "https://www.apple.com/shop",
                title: "Apple Store",
                text: "Search the store for iPhone. Add to bag.",
                limit: limit
            )
        }

        var executedActions: [BrowserAction] = []
        chat.actionExecutor = { action, actionContext in
            XCTAssertEqual(actionContext?.tabID, tabID)
            executedActions.append(action)
            return ActionResult(kind: action.kind, status: .succeeded, summary: action.summary, detail: "Updated page.")
        }

        chat.send(prompt: "Can you find and add an iPhone to my basket on Apple's website?")
        for _ in 0..<200 where chat.pendingCursorPrompt == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(chat.pendingCursorPrompt)
        chat.chooseCursorAssistance(true)

        for _ in 0..<300 {
            if chat.pendingProposal?.action == .clickText("Add to bag") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(executedActions, [.openURL("https://www.apple.com/shop"), .searchPage("iPhone")])
        XCTAssertEqual(chat.pendingProposal?.action, .clickText("Add to bag"))
        XCTAssertTrue(chat.items.contains { item in
            guard case .notice(_, let text) = item else { return false }
            return text.contains("Auto-approved safe browsing action") && text.contains("Search this site")
        })
        XCTAssertFalse(chat.items.contains { item in
            guard case .message(let message) = item else { return false }
            return message.role == .assistant && message.text.contains("\"action\"")
        }, "Operator action JSON should be represented by the action/proposal UI, not exposed as chat prose.")
        XCTAssertTrue(chat.items.contains { item in
            guard case .message(let message) = item else { return false }
            return message.role == .assistant && message.text == "I'll open Apple's store page."
        })

        chat.clearConversation()
        let externalProposal = chat.requestExternalAction(.searchPage("tracked query"), context: context)
        XCTAssertNotNil(externalProposal)
        XCTAssertEqual(chat.pendingProposal?.action, .searchPage("tracked query"), "The preference must not bypass MCP approvals.")
        chat.clearConversation()
    }

    /// Arming page control is the explicit opt-in for the next message. It
    /// writes nothing to the transcript and adds no invented "control this
    /// page" instruction; the user's own words are what the operator receives.
    @MainActor
    func testArmedPageControlMakesTheNextMessageOperateWithoutASecondPrompt() async throws {
        let scriptedProvider = AISequencedProvider(replies: ["I looked at the page and there is nothing to do yet."])
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in scriptedProvider }
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.com/pricing")
        chat.currentBrowserContextProvider = { context }
        chat.pageContextProvider = { context, _, limit, question in
            PageContextBuilder.make(
                url: context?.pageURL ?? "",
                title: "Pricing",
                text: "Choose a plan.",
                limit: limit
            )
        }

        XCTAssertFalse(chat.isPageControlArmed, "Page control is off until the user asks for it")
        XCTAssertTrue(chat.canArmPageControl)
        chat.togglePageControl()
        XCTAssertTrue(chat.isPageControlArmed)
        XCTAssertTrue(chat.items.isEmpty, "Arming must not write anything to the transcript")

        chat.input = "Open the pricing page"
        chat.send()

        XCTAssertNil(chat.pendingCursorPrompt, "Arming is the opt-in; there is no second question")
        XCTAssertTrue(chat.isPageControlArmed, "Agent mode persists for the same chat and tab")
        for _ in 0..<200 where chat.isBusy || !chat.items.contains(where: {
            if case .message(let message) = $0 { return message.role == .assistant }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(chat.items.contains { item in
            guard case .message(let message) = item else { return false }
            return message.role == .user && message.text == "Open the pricing page"
        }, "The typed task is the instruction; nothing is invented")
        XCTAssertFalse(chat.items.contains { item in
            guard case .message(let message) = item else { return false }
            return message.role == .user && message.text.contains("Start navigating this page")
        })
        chat.clearConversation()
    }

    /// With no page to operate, page control cannot be armed.
    @MainActor
    func testPageControlCannotBeArmedWithoutAPage() {
        let chat = AIChatStore()
        chat.currentBrowserContextProvider = { nil }
        XCTAssertFalse(chat.canArmPageControl)
        chat.togglePageControl()
        XCTAssertFalse(chat.isPageControlArmed)
        XCTAssertTrue(chat.items.isEmpty)
    }

    /// A message sent after the arm was spent routes normally again.
    @MainActor
    func testPageControlPersistsUntilTabChangeOrNewChat() async throws {
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in AISequencedProvider(replies: ["Fine."]) }
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.com/")
        chat.currentBrowserContextProvider = { context }
        chat.pageContextProvider = { context, _, limit, question in
            PageContextBuilder.make(url: context?.pageURL ?? "", title: "Example", text: "Body", limit: limit)
        }

        chat.togglePageControl()
        XCTAssertTrue(chat.isPageControlArmed)
        chat.input = "First request"
        chat.send()
        XCTAssertTrue(chat.isPageControlArmed)
        chat.browserTabChanged(to: UUID())
        XCTAssertTrue(chat.isPageControlArmed, "An active task continues on its initiating tab")
        for _ in 0..<100 where chat.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        chat.browserTabChanged(to: UUID())
        XCTAssertFalse(chat.isPageControlArmed)
        chat.enableAutomaticAgentMode()
        XCTAssertTrue(chat.isAutomaticAgentMode)
        chat.clearConversation()
        XCTAssertFalse(chat.isPageControlArmed)
        XCTAssertFalse(chat.isAutomaticAgentMode)
        chat.clearConversation()
    }

    @MainActor
    func testLocalRouterHandoffRunsApprovedActionsAgainstFreshPageContext() async throws {
        let scriptedProvider = AISequencedProvider(replies: [
            #"{"action":"open_url","url":"https://www.apple.com/shop/buy-iphone/","rationale":"Open Apple's iPhone store"}"#,
            #"{"action":"search_page","query":"iPhone","rationale":"Find the iPhone options on Apple's store page"}"#,
            "I found the iPhone options. Which model, colour and storage would you like? I will not continue through checkout."
        ])
        let chat = AIChatStore()
        var settings = AISettings.default
        settings.selectedProvider = .appleLocalModel
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (settings, secrets) }
        chat.providerFactory = { _, _ in scriptedProvider }
        chat.localIntentClassifier = { _ in .answer }

        let tabID = UUID()
        var pageURL = "https://www.apple.com/"
        var pageText = "Apple homepage"
        chat.currentBrowserContextProvider = {
            BrowserActionContext(tabID: tabID, pageURL: pageURL)
        }
        chat.pageContextProvider = { context, _, limit, question in
            PageContextBuilder.make(
                url: context?.pageURL ?? pageURL,
                title: "Apple Store",
                text: pageText,
                limit: limit
            )
        }
        chat.actionExecutor = { action, context in
            XCTAssertEqual(context?.tabID, tabID, "Every follow-up action must stay on the approved tab.")
            switch action {
            case .openURL(let url):
                pageURL = url
                pageText = "Apple Store. Choose an iPhone model."
            case .searchPage(let query):
                XCTAssertEqual(query, "iPhone")
                pageText = "Search results. Choose a model, colour and storage."
            default:
                XCTFail("Unexpected scripted action: \(action)")
            }
            return ActionResult(kind: action.kind, status: .succeeded, summary: action.summary, detail: "Page updated.")
        }

        chat.send(prompt: "Can you find and add an iPhone to my basket on Apple's website?")
        for _ in 0..<200 where chat.pendingCursorPrompt == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(chat.pendingCursorPrompt)
        let requestsBeforeOptIn = await scriptedProvider.requests()
        XCTAssertTrue(requestsBeforeOptIn.isEmpty, "The operator model must not run until the user opts in.")

        chat.chooseCursorAssistance(true)
        for _ in 0..<200 where chat.pendingProposal == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(chat.pendingProposal?.action, .openURL("https://www.apple.com/shop/buy-iphone/"))
        chat.approvePendingProposal()

        for _ in 0..<300 {
            if let proposal = chat.pendingProposal, case .searchPage = proposal.action { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let proposal = chat.pendingProposal, case .searchPage("iPhone") = proposal.action else {
            return XCTFail("Expected the operator to use the Apple page's search field.")
        }

        let afterNavigation = await scriptedProvider.requests()
        XCTAssertEqual(afterNavigation.count, 2)
        XCTAssertEqual(afterNavigation[0].generationPurpose, .browserOperator)
        XCTAssertEqual(afterNavigation[1].generationPurpose, .browserOperator)
        XCTAssertTrue(afterNavigation[1].localContext?.contains("Choose an iPhone model") == true)
        XCTAssertTrue(afterNavigation[1].localContext?.contains("Earlier approved browser action results") == true)
        XCTAssertTrue(afterNavigation[1].localInstructions?.contains("continuation") == true)
        chat.approvePendingProposal()

        for _ in 0..<300 {
            let requests = await scriptedProvider.requests()
            if requests.count == 3, !chat.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalRequests = await scriptedProvider.requests()
        XCTAssertEqual(finalRequests.count, 3)
        XCTAssertEqual(finalRequests[2].generationPurpose, .browserOperator)
        XCTAssertTrue(finalRequests[2].localContext?.contains("Choose a model, colour and storage") == true)
        XCTAssertTrue(chat.items.contains { item in
            guard case .message(let message) = item, message.role == .assistant else { return false }
            return message.text.contains("Which model, colour and storage")
        })
        XCTAssertNil(chat.pendingProposal)
        XCTAssertFalse(chat.isBusy)
        chat.clearConversation()
    }

    @MainActor
    func testRepeatedRefreshOnUnchangedPageStopsWithoutAskingForApprovalAgain() async throws {
        let scriptedProvider = AISequencedProvider(replies: [
            #"{"action":"reload","rationale":"Refresh the page"}"#,
            #"{"action":"reload","rationale":"Try refreshing again"}"#
        ])
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in scriptedProvider }
        chat.localIntentClassifier = { _ in .cursor }

        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.com/article")
        chat.currentBrowserContextProvider = { context }
        chat.pageContextProvider = { _, _, limit, question in
            PageContextBuilder.make(
                url: context.pageURL,
                title: "Example article",
                text: "The article has not changed.",
                limit: limit
            )
        }

        var executedActions: [BrowserAction] = []
        chat.actionExecutor = { action, _ in
            executedActions.append(action)
            return ActionResult(kind: action.kind, status: .succeeded, summary: action.summary, detail: "Page reloaded.")
        }

        chat.send(prompt: "Move to the next section of this page")
        for _ in 0..<200 where chat.pendingCursorPrompt == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(chat.pendingCursorPrompt)
        chat.chooseCursorAssistance(true)

        for _ in 0..<300 where chat.pendingProposal?.action != .reload {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(chat.pendingProposal?.action, .reload)
        chat.approvePendingProposal()

        var stoppedNotice: String?
        for _ in 0..<400 {
            stoppedNotice = chat.items.compactMap { item in
                guard case .notice(_, let text) = item,
                      text.contains("proposed the same browser action again") else { return nil }
                return text
            }.first
            if stoppedNotice != nil, !chat.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNotNil(stoppedNotice)
        XCTAssertNil(chat.pendingProposal, "The repeated refresh must not create another approval prompt.")
        XCTAssertEqual(executedActions, [.reload], "Only the first, explicitly approved reload should run.")
        let requests = await scriptedProvider.requests()
        XCTAssertEqual(requests.count, 3, "A stopped loop still gets one summary-only request")
        let archived = try XCTUnwrap(chat.savedConversations.first)
        XCTAssertFalse(archived.messages.contains { $0.text.contains("\"action\":\"reload\"") })
        XCTAssertFalse(chat.isBusy)
        chat.clearConversation()
    }
    #endif

    func testAssistantIntentFallbackKeepsConversationSearchAndCursorDistinct() {
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification("Explain this in simple terms"), .answer)
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification("Find current reviews of this laptop"), .search)
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification("Click the download button on this page"), .cursor)
    }

    func testCachedIntentRulesKeepConcurrentRequestsIndependent() async {
        let cases: [(String, AssistantIntent)] = [
            ("Explain 👩🏽‍💻 café and 東京", .answer),
            ("What is the weather in 東京?", .search),
            ("Click the café button", .cursor),
            ("Find photos of 東京, please", .imageSearch)
        ]
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<100 {
                let (prompt, expected) = cases[index % cases.count]
                group.addTask {
                    AssistantIntentRouter.resolve(prompt, modelDecision: nil) == expected
                        && AssistantIntentRouter.imageSearchQuery(from: "Find photos of 東京, please") == "東京"
                        && AssistantIntentRouter.strippingSearchInstruction("look up 👩🏽‍💻 café") == "👩🏽‍💻 café"
                }
            }
            for await matches in group { XCTAssertTrue(matches) }
        }
    }

    /// A topic word is not a search request.
    ///
    /// The fallback used to search whenever a prompt merely contained "latest",
    /// "current", "recent", "news", "price", "compare", "sources" or "reviews",
    /// which sent ordinary questions to a results page.
    func testATopicWordAloneDoesNotTurnAQuestionIntoASearch() {
        let questions = [
            "Compare these two Swift functions",
            "Explain how the current flows through a diode",
            "What are your sources for that claim?",
            "Summarise the recent changes in this file",
            "Write a weather app for macOS",
            "How do I compare two dates in Swift?",
            "Describe the price elasticity of demand",
            "Give me an example of a review comment"
        ]
        for question in questions {
            XCTAssertEqual(
                AssistantIntentRouter.fallbackClassification(question),
                .answer,
                question
            )
        }
    }

    /// An explicit request to search is still honoured.
    func testExplicitSearchRequestsAreStillRoutedToTheWeb() {
        let requests = [
            "Search the web for reusable rockets",
            "Look up the Falcon Heavy specs",
            "Google the best time to visit Iceland",
            "Can you research the history of the kestrel?",
            "Find online where to buy a mechanical keyboard",
            "Find me the latest rocket launch dates"
        ]
        for request in requests {
            XCTAssertEqual(
                AssistantIntentRouter.fallbackClassification(request),
                .search,
                request
            )
        }
    }

    /// With no classifier available, only wording that means nothing without
    /// live data should reach the web.
    func testLiveInformationWordingRoutesToSearchButAuthoringDoesNot() {
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification("What is the weather in London?"), .search)
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification("Any coffee shops near me?"), .search)
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification("What happened with the launch?"), .search)

        // The same wording inside a request to build or explain something is
        // answered instead.
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification("Write a script that fetches the weather"), .answer)
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification("Explain how weather forecasting works"), .answer)
    }

    /// The classifier decides everything that is not explicit, so a small
    /// model's answer label must survive `resolve`.
    func testModelAnswerLabelSurvivesResolveForAPlainQuestion() {
        XCTAssertEqual(
            AssistantIntentRouter.resolve("Tell me about reusable rockets", modelDecision: .answer),
            .answer
        )
        XCTAssertEqual(
            AssistantIntentRouter.resolve("Tell me about reusable rockets", modelDecision: nil),
            .answer
        )
        XCTAssertEqual(
            AssistantIntentRouter.resolve("Tell me about reusable rockets", modelDecision: .search),
            .search
        )
    }

    func testExplicitWebsiteOperationOverridesLocalAnswerButInstructionalQuestionDoesNot() {
        let operation = "Can you find and add an iPhone to my basket on Apple's website?"
        XCTAssertEqual(AssistantIntentRouter.resolve(operation, modelDecision: .answer), .cursor)
        XCTAssertEqual(AssistantIntentRouter.resolve("I need an iPhone selected in my cart.", modelDecision: .answer), .cursor)
        XCTAssertEqual(AssistantIntentRouter.resolve("I want an iPhone in my basket.", modelDecision: .answer), .cursor)
        XCTAssertEqual(AssistantIntentRouter.resolve("How do I add an iPhone to my basket?", modelDecision: .answer), .answer)
        XCTAssertEqual(AssistantIntentRouter.resolve("Can you tell me if an iPhone is already in my cart?", modelDecision: .answer), .answer)
        XCTAssertEqual(
            AssistantIntentRouter.resolve("Can you find me images of Falcon Heavy?", modelDecision: .cursor),
            .imageSearch
        )
    }

    func testImageSearchIntentExtractsTheSubjectInsteadOfSearchingTheInstruction() {
        let prompt = "Search the web for images of Falcon Heavy"
        XCTAssertEqual(AssistantIntentRouter.fallbackClassification(prompt), .imageSearch)
        XCTAssertEqual(AssistantIntentRouter.imageSearchQuery(from: prompt), "Falcon Heavy")
        XCTAssertEqual(
            AssistantIntentRouter.imageSearchQuery(from: "Can you search the web for pictures of falcon heavy"),
            "falcon heavy"
        )
        XCTAssertEqual(
            AssistantIntentRouter.imageSearchQuery(from: "Can you find me images of Falcon Heavy?"),
            "Falcon Heavy"
        )
        XCTAssertEqual(
            AssistantIntentRouter.imageSearchQuery(from: "Could you show me some photos of the aurora, please?"),
            "the aurora"
        )
        XCTAssertEqual(AssistantIntentRouter.imageSearchQuery(from: "Find falcon heavy images"), "falcon heavy")
        XCTAssertEqual(AssistantIntentRouter.imageSearchQuery(from: "Find me photos of the aurora?"), "the aurora")
        XCTAssertNil(AssistantIntentRouter.imageSearchQuery(from: "Explain Falcon Heavy"))
    }

#if canImport(SwiftUI)
    @MainActor
    func testRecentSearchesPersistDeduplicateAndExcludeNavigations() throws {
        let suiteName = "KestrelRecentSearchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.recordSearch("Falcon Heavy")
        settings.recordSearch("falcon heavy")
        settings.recordSearch("swift concurrency")
        settings.recordSearch("site:example.com Falcon Heavy")
        settings.recordSearch("https://example.com")
        settings.recordSearch("example.com")

        XCTAssertEqual(settings.recentSearches.count, 3)
        XCTAssertEqual(settings.recentSearches.first, "site:example.com Falcon Heavy")
        XCTAssertEqual(settings.recentSearches[1], "swift concurrency")
        XCTAssertEqual(settings.recentSearches.last?.localizedLowercase, "falcon heavy")
        XCTAssertEqual(AppSettings(defaults: defaults).recentSearches, settings.recentSearches)

        for index in 0..<55 {
            settings.recordSearch("search \(index)")
        }
        XCTAssertEqual(settings.recentSearches.count, 50)
        XCTAssertEqual(settings.recentSearches.first, "search 54")
        XCTAssertFalse(settings.recentSearches.contains("search 0"))

        settings.clearSearchHistory()
        XCTAssertTrue(settings.recentSearches.isEmpty)
        XCTAssertTrue(AppSettings(defaults: defaults).recentSearches.isEmpty)
    }

    /// History is for the words the user searched for. The bang is how they
    /// asked for them, and keeping it makes the list read as command syntax and
    /// makes re-running an entry repeat a mode they did not choose.
    @MainActor
    func testRecentSearchesDropALeadingShortcutBang() throws {
        let suiteName = "KestrelBangHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.recordSearch("!maps eiffel tower")
        settings.recordSearch("!images aurora borealis")
        settings.recordSearch("!w Rosetta Stone")
        settings.recordSearch("!youtube lo-fi beats")
        settings.recordSearch("!a mechanical keyboard")

        XCTAssertEqual(settings.recentSearches, [
            "mechanical keyboard",
            "lo-fi beats",
            "Rosetta Stone",
            "aurora borealis",
            "eiffel tower"
        ])
        XCTAssertFalse(settings.recentSearches.contains { $0.hasPrefix("!") })
    }

    /// A bare trigger word is an ordinary search term, and an unknown bang is
    /// not a shortcut Kestrel understands. Neither should be rewritten.
    @MainActor
    func testRecentSearchesKeepTextThatOnlyLooksLikeAShortcut() throws {
        let suiteName = "KestrelBangHistoryEdgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.recordSearch("maps of Iceland")
        settings.recordSearch("!notashortcut something")
        settings.recordSearch("weather !maps")

        XCTAssertEqual(settings.recentSearches, [
            "weather !maps",
            "!notashortcut something",
            "maps of Iceland"
        ])
    }

    /// A bang on its own carries no query, so there is nothing worth recording.
    @MainActor
    func testRecentSearchesIgnoreABangWithNoQuery() throws {
        let suiteName = "KestrelBangHistoryEmptyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.recordSearch("!maps")
        settings.recordSearch("!maps   ")

        XCTAssertTrue(settings.recentSearches.isEmpty)
    }

    @MainActor
    func testBrowserBookmarksPersistAndRejectUnsafeOrCredentialURLs() throws {
        let suiteName = "KestrelBookmarkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.toggleBookmark(
            title: "Example",
            address: "https://EXAMPLE.com:443/path#fragment",
            faviconURL: "https://example.com/favicon.ico"
        ))
        XCTAssertTrue(settings.isBookmarked("https://example.com/path"))
        XCTAssertFalse(settings.toggleBookmark(title: "Duplicate", address: "https://example.com/path", faviconURL: nil))
        XCTAssertEqual(settings.bookmarks.count, 0)
        XCTAssertFalse(settings.toggleBookmark(title: "Unsafe", address: "javascript:alert(1)", faviconURL: nil))
        XCTAssertFalse(settings.toggleBookmark(title: "Credential", address: "https://user:pass@example.com", faviconURL: nil))

        XCTAssertTrue(settings.toggleBookmark(title: "Kestrel", address: "https://kestrel.example/", faviconURL: nil))
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.bookmarks.map(\.displayTitle), ["Kestrel"])
    }
#endif

    func testCodexConfigAddsAnIdempotentManagedEntryWithoutChangingOtherSettings() throws {
        let endpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "a", count: 64))/mcp"
        let original = "model = \"gpt-test\"\n[mcp_servers.other]\nurl = \"http://127.0.0.1:9000\"\n"
        let first = try CodexMCPConfigManager.updatedContents(original, endpointURL: endpoint)

        XCTAssertEqual(first.update, .added)
        XCTAssertTrue(first.contents.hasPrefix(original))
        XCTAssertTrue(first.contents.contains(CodexMCPConfigManager.beginMarker))
        XCTAssertTrue(first.contents.contains("[mcp_servers.kestrel]\nurl = \"\(endpoint)\""))

        let second = try CodexMCPConfigManager.updatedContents(first.contents, endpointURL: endpoint)
        XCTAssertEqual(second.update, .unchanged)
        XCTAssertEqual(second.contents, first.contents)
    }

    func testCodexConfigUpdatesAndRemovesOnlyItsOwnManagedBlock() throws {
        let firstEndpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "a", count: 64))/mcp"
        let nextEndpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "b", count: 64))/mcp"
        let source = "# User comment\nmodel = \"local\"\n"
        let added = try CodexMCPConfigManager.updatedContents(source, endpointURL: firstEndpoint).contents
        let updated = try CodexMCPConfigManager.updatedContents(added, endpointURL: nextEndpoint)
        XCTAssertEqual(updated.update, .updated)
        XCTAssertTrue(updated.contents.contains(nextEndpoint))
        XCTAssertFalse(updated.contents.contains(firstEndpoint))

        let disconnected = try XCTUnwrap(CodexMCPConfigManager.contentsRemovingManagedEntry(updated.contents))
        XCTAssertEqual(disconnected, source)
        XCTAssertNil(try CodexMCPConfigManager.contentsRemovingManagedEntry(disconnected))
    }

    func testCodexConfigPreservesCRLFAndRefusesUnmanagedConflicts() throws {
        let endpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "c", count: 64))/mcp"
        let source = "model = \"test\"\r\n"
        let result = try CodexMCPConfigManager.updatedContents(source, endpointURL: endpoint)
        XCTAssertTrue(result.contents.contains("\r\n"))

        let conflict = "[mcp_servers.kestrel]\nurl = \"https://example.invalid\"\n"
        XCTAssertThrowsError(try CodexMCPConfigManager.updatedContents(conflict, endpointURL: endpoint)) { error in
            XCTAssertEqual(error as? CodexMCPConfigManager.ConfigError, .existingEntry)
        }
    }

    func testCodexConfigDetectsQuotedKeysInlineTablesAndArrayTables() throws {
        let endpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "c", count: 64))/mcp"
        let conflicts = [
            "[\"mcp_servers\".kestrel]\nurl = \"https://example.invalid\"\n",
            "[[mcp_servers.kestrel]]\nurl = \"https://example.invalid\"\n",
            "\"mcp_servers\".kestrel.url = \"https://example.invalid\"\n",
            "[mcp_servers]\n\"kestrel\" = { url = \"https://example.invalid\" }\n",
            "mcp_servers = { kestrel = { url = \"https://example.invalid\" } }\n"
        ]

        for source in conflicts {
            XCTAssertThrowsError(
                try CodexMCPConfigManager.updatedContents(source, endpointURL: endpoint),
                "Expected conflict for TOML: \(source)"
            ) { error in
                XCTAssertEqual(error as? CodexMCPConfigManager.ConfigError, .existingEntry)
            }
        }
    }

    func testCodexConfigDoesNotRewriteOrRemoveAnEditedManagedBlock() throws {
        let endpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "f", count: 64))/mcp"
        let managed = try CodexMCPConfigManager.updatedContents("model = \"fixture\"\n", endpointURL: endpoint).contents
        let edited = managed.replacingOccurrences(
            of: "[mcp_servers.kestrel]\n",
            with: "unrelated = true\n[mcp_servers.kestrel]\n"
        )

        XCTAssertThrowsError(try CodexMCPConfigManager.updatedContents(edited, endpointURL: endpoint)) { error in
            XCTAssertEqual(error as? CodexMCPConfigManager.ConfigError, .malformedManagedEntry)
        }
        XCTAssertThrowsError(try CodexMCPConfigManager.contentsRemovingManagedEntry(edited)) { error in
            XCTAssertEqual(error as? CodexMCPConfigManager.ConfigError, .malformedManagedEntry)
        }
    }

    func testCodexConfigRejectsEndpointsOutsideTheAuthenticatedLoopbackShape() {
        let token = String(repeating: "d", count: 64)
        let endpoints = [
            "https://127.0.0.1:52768/mcp/\(token)/mcp",
            "http://example.com:52768/mcp/\(token)/mcp",
            "http://127.0.0.1:52768/mcp/short/mcp",
            "http://127.0.0.1:52768/mcp/\(token)/mcp?token=extra"
        ]
        for endpoint in endpoints {
            XCTAssertThrowsError(try CodexMCPConfigManager.updatedContents("", endpointURL: endpoint))
        }
    }

    func testCodexConfigFileRoundTripUsesOnlyTheSuppliedTemporaryFixture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-codex-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.toml")
        try Data("model = \"fixture\"\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let endpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "e", count: 64))/mcp"

        XCTAssertEqual(try CodexMCPConfigManager.connect(endpointURL: endpoint, configurationURL: url), .added)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(endpoint))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o640
        )
        XCTAssertTrue(try CodexMCPConfigManager.disconnect(configurationURL: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "model = \"fixture\"\n")
    }

    func testCodexConfigDisconnectRestoresOriginalFileWithoutFinalNewline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-codex-eof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.toml")
        let original = "model = \"fixture\""
        try Data(original.utf8).write(to: url)
        let endpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "e", count: 64))/mcp"

        XCTAssertEqual(try CodexMCPConfigManager.connect(endpointURL: endpoint, configurationURL: url), .added)
        XCTAssertTrue(try CodexMCPConfigManager.disconnect(configurationURL: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testCodexConfigRefusesSymbolicLinkWithoutChangingItsTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-codex-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.toml")
        let link = directory.appendingPathComponent("config.toml")
        let original = "model = \"fixture\"\n"
        try Data(original.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let endpoint = "http://127.0.0.1:52768/mcp/\(String(repeating: "e", count: 64))/mcp"

        XCTAssertThrowsError(try CodexMCPConfigManager.connect(endpointURL: endpoint, configurationURL: link)) { error in
            XCTAssertEqual(error as? CodexMCPConfigManager.ConfigError, .symbolicLinkNotAllowed)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), original)
    }

    func testAppleLocalModelProviderIsKeylessAndAvailabilityIsReportedHonestly() throws {
        var settings = AISettings.default
        settings.selectedProvider = .appleLocalModel
        XCTAssertEqual(AIProviderKind.appleLocalModel.displayName, "Apple On-Device")

        if let issue = AppleLocalModelProvider.availabilityIssue {
            XCTAssertFalse(issue.isEmpty)
            XCTAssertThrowsError(try AIProviderFactory.makeProvider(for: settings, secretProvider: InMemorySecretProvider()))
        } else {
            let provider = try AIProviderFactory.makeProvider(for: settings, secretProvider: InMemorySecretProvider())
            XCTAssertEqual(provider.kind, .appleLocalModel)
        }
    }

    func testUpdateReplacesOnlyTheMatchingProvider() {
        var settings = AISettings.default
        var mistral = settings.mistral
        mistral.model = "custom-model"
        settings.update(mistral)
        XCTAssertEqual(settings.mistral.model, "custom-model")
        XCTAssertEqual(settings.openRouter.model, AIDefaults.openRouterModel)
    }

    func testHTTPProviderReportsMissingSecret() {
        var settings = AISettings.default
        settings.selectedProvider = .openRouter
        let issue = settings.configurationIssue(secretProvider: InMemorySecretProvider())
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.contains(AIDefaults.openRouterAPIKeyEnvironment) == true)
    }

    func testChatPageReadinessDoesNotRequireCredentialLookup() {
        var settings = AISettings.default
        settings.selectedProvider = .googleGemini
        XCTAssertNil(settings.displayConfigurationIssueWithoutReadingSecrets())
    }

    func testHTTPProviderWithSecretHasNoIssue() {
        var settings = AISettings.default
        settings.selectedProvider = .openRouter
        let secrets = InMemorySecretProvider(secrets: [AIDefaults.openRouterAPIKeyEnvironment: "test-key"])
        XCTAssertNil(settings.configurationIssue(secretProvider: secrets))
    }

    func testHTTPProviderRejectsWhitespaceOnlySecret() {
        var settings = AISettings.default
        settings.selectedProvider = .openRouter
        let secrets = InMemorySecretProvider(secrets: [AIDefaults.openRouterAPIKeyEnvironment: "   "])

        XCTAssertNotNil(settings.configurationIssue(secretProvider: secrets))
        XCTAssertThrowsError(try AIProviderFactory.makeProvider(for: settings, secretProvider: secrets))
    }

    func testHTTPProviderRequiresHTTPSBaseURL() {
        var settings = AISettings.default
        settings.selectedProvider = .mistral
        var mistral = settings.mistral
        mistral.baseURL = "http://api.mistral.ai/v1"
        settings.update(mistral)
        let secrets = InMemorySecretProvider(secrets: [AIDefaults.mistralAPIKeyEnvironment: "test-key"])

        XCTAssertTrue(settings.configurationIssue(secretProvider: secrets)?.contains("HTTPS") == true)
        XCTAssertThrowsError(try AIProviderFactory.makeProvider(for: settings, secretProvider: secrets))
    }

    func testFactoryBuildsHTTPProvider() throws {
        var settings = AISettings.default
        settings.selectedProvider = .mistral
        let secrets = InMemorySecretProvider(secrets: [AIDefaults.mistralAPIKeyEnvironment: "test-key"])
        let provider = try AIProviderFactory.makeProvider(for: settings, secretProvider: secrets)
        XCTAssertTrue(provider is HTTPChatProvider)
        XCTAssertEqual(provider.kind, .mistral)
    }

    func testFactoryBuildsCLIProvider() throws {
        var settings = AISettings.default
        settings.selectedProvider = .codexCLI
        let provider = try AIProviderFactory.makeProvider(for: settings, secretProvider: InMemorySecretProvider())
        XCTAssertTrue(provider is CLIProvider)
        XCTAssertEqual(provider.kind, .codexCLI)
    }

    func testFactoryRejectsMissingSecret() {
        var settings = AISettings.default
        settings.selectedProvider = .openRouter
        XCTAssertThrowsError(try AIProviderFactory.makeProvider(for: settings, secretProvider: InMemorySecretProvider())) { error in
            XCTAssertEqual(error as? AIProviderError, .missingSecret(
                "No API key found for OpenRouter. Add one in Settings, or set \(AIDefaults.openRouterAPIKeyEnvironment) for local development."
            ))
        }
    }

    func testFactoryRejectsEmptyExecutable() {
        var settings = AISettings.default
        settings.selectedProvider = .kiloCLI
        var kilo = settings.kilo
        kilo.executablePath = "   "
        settings.update(kilo)
        XCTAssertThrowsError(try AIProviderFactory.makeProvider(for: settings, secretProvider: InMemorySecretProvider()))
    }

    func testFactoryCanBuildASpecificKind() throws {
        var settings = AISettings.default
        settings.selectedProvider = .codexCLI
        let secrets = InMemorySecretProvider(secrets: [AIDefaults.openRouterAPIKeyEnvironment: "test-key"])
        let provider = try AIProviderFactory.makeProvider(kind: .openRouter, settings: settings, secretProvider: secrets)
        XCTAssertEqual(provider.kind, .openRouter)
    }

    /// Every added keyed provider must build through the shared HTTP adapter
    /// from its own defaults and its own secret.
    func testFactoryBuildsEachAdditionalHTTPProvider() throws {
        let cases: [(AIProviderKind, String)] = [
            (.googleGemini, AIDefaults.geminiAPIKeyEnvironment),
            (.groq, AIDefaults.groqAPIKeyEnvironment),
            (.deepSeek, AIDefaults.deepSeekAPIKeyEnvironment),
            (.xAI, AIDefaults.xAIAPIKeyEnvironment),
            (.customOpenAI, AIDefaults.customOpenAIAPIKeyEnvironment)
        ]
        for (kind, environment) in cases {
            var settings = AISettings.default
            settings.selectedProvider = kind
            let secrets = InMemorySecretProvider(secrets: [environment: "test-key"])
            let provider = try AIProviderFactory.makeProvider(for: settings, secretProvider: secrets)
            XCTAssertTrue(provider is HTTPChatProvider, "\(kind)")
            XCTAssertEqual(provider.kind, kind)
            XCTAssertNil(settings.configurationIssue(secretProvider: secrets), "\(kind)")
        }
    }

    /// Adding providers must not throw away a configuration saved before they
    /// existed: a stored blob without the new keys decodes with defaults filled.
    func testDecodingSettingsWithoutNewProviderBlocksKeepsExistingValues() throws {
        var original = AISettings.default
        original.selectedProvider = .deepSeek
        original.openRouter.model = "custom/model"
        let encoded = try JSONEncoder().encode(original)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return XCTFail("Expected a JSON object")
        }
        for key in ["googleGemini", "groq", "deepSeek", "xAI", "customOpenAI"] {
            object.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AISettings.self, from: stripped)
        XCTAssertEqual(decoded.selectedProvider, .deepSeek)
        XCTAssertEqual(decoded.openRouter.model, "custom/model")
        XCTAssertEqual(decoded.googleGemini.model, AIDefaults.geminiModel)
        XCTAssertEqual(decoded.groq.baseURL, AIDefaults.groqBaseURL)
        XCTAssertEqual(decoded.xAI.model, AIDefaults.xAIModel)
        XCTAssertEqual(decoded.customOpenAI.baseURL, AIDefaults.customOpenAIBaseURL)
    }

    func testEnvironmentSecretProviderReadsByName() {
        let provider = EnvironmentSecretProvider(environment: ["MY_KEY": "value"])
        XCTAssertEqual(provider.secret(named: "MY_KEY", keychainAccount: ""), "value")
        XCTAssertNil(provider.secret(named: "OTHER_KEY", keychainAccount: ""))
    }

    func testCompositePrefersEarlierProvider() {
        let composite = CompositeSecretProvider([
            InMemorySecretProvider(secrets: ["acct": "first"]),
            InMemorySecretProvider(secrets: ["acct": "second"])
        ])
        XCTAssertEqual(composite.secret(named: "ENV", keychainAccount: "acct"), "first")
    }

    func testPromptBuilderIncludesPageContext() {
        let context = PageContextBuilder.make(url: "https://example.com", title: "Example", text: "Hello body", limit: 100)
        let prompt = AIPromptBuilder.systemPrompt(mode: .ask, pageContext: context, settings: .default)
        XCTAssertTrue(prompt.contains("https://example.com"))
        XCTAssertTrue(prompt.contains("Example"))
        XCTAssertTrue(prompt.contains("Hello body"))
        XCTAssertTrue(prompt.contains("untrusted data"))
        XCTAssertTrue(prompt.contains("Current-page visible text is included automatically"))
        XCTAssertTrue(prompt.contains("redacted on a best-effort basis"))
        XCTAssertTrue(prompt.contains("visible sensitive text may still be included"))
    }

    func testAssistantInstructionsDoNotForceOverlyBriefAnswers() {
        let instructions = AIPromptBuilder.localInstructions(mode: .ask)
        XCTAssertTrue(instructions.contains("complete, useful answers"))
        XCTAssertTrue(instructions.contains("few short paragraphs"))
        XCTAssertTrue(instructions.contains("real bullet or numbered lists"))
        XCTAssertTrue(instructions.contains("Never run a heading into the next sentence"))
        XCTAssertTrue(instructions.contains("Keep simple factual requests brief"))
        XCTAssertTrue(instructions.contains("Do not trade accuracy for detail"))
    }

    /// A generated title is trimmed into shape: a trailing full stop, quotes
    /// and stray whitespace are removed, an empty line is refused, a question
    /// is a reply rather than a name, and a single topic word is accepted so
    /// the on-device model always names the chat instead of falling back.
    func testGeneratedConversationTitlesAreCleanedAndValidated() {
        XCTAssertEqual(AppleLocalModelProvider.sanitisedConversationTitle("Rockets"), "Rockets")
        XCTAssertEqual(AppleLocalModelProvider.sanitisedConversationTitle("Rockets."), "Rockets")
        XCTAssertEqual(
            AppleLocalModelProvider.sanitisedConversationTitle("\"Reusable rockets.\""),
            "Reusable rockets"
        )
        XCTAssertEqual(
            AppleLocalModelProvider.sanitisedConversationTitle("  Capital of France!  "),
            "Capital of France"
        )

        XCTAssertTrue(AppleLocalModelProvider.isUsableConversationTitle("Paris"))
        XCTAssertFalse(AppleLocalModelProvider.isUsableConversationTitle(
            "What is the capital of France?"
        ))
        XCTAssertFalse(AppleLocalModelProvider.isUsableConversationTitle(""))
        XCTAssertFalse(AppleLocalModelProvider.isUsableConversationTitle("   "))
        XCTAssertFalse(AppleLocalModelProvider.isUsableConversationTitle("..."))
    }

    func testGeneratedConversationTitlesAreBoundedToATitleLength() {
        XCTAssertFalse(AppleLocalModelProvider.isUsableConversationTitle(
            "one two three four five six seven eight nine"
        ))
        XCTAssertTrue(AppleLocalModelProvider.isUsableConversationTitle(
            "one two three four five six seven eight"
        ))
    }

    /// A substantive answer is worth several draft passes; a trivial one is not.
    func testAppleAnswerCouncilOnlyRunsForSubstantivePrompts() {
        XCTAssertFalse(AppleLocalAnswerStrategy.deservesCouncil("hi"))
        XCTAssertFalse(AppleLocalAnswerStrategy.deservesCouncil("2+2"))
        XCTAssertFalse(AppleLocalAnswerStrategy.deservesCouncil("what is 2+2"))
        XCTAssertTrue(AppleLocalAnswerStrategy.deservesCouncil("what is the cost of a new iPhone"))
        XCTAssertTrue(AppleLocalAnswerStrategy.deservesCouncil("explain how HTTPS certificates are validated"))

        XCTAssertEqual(AppleLocalAnswerStrategy.draftTemperatures.count, 3)
        XCTAssertEqual(Set(AppleLocalAnswerStrategy.draftTemperatures).count, 3, "Each draft must differ")
        XCTAssertGreaterThan(
            AppleLocalAnswerStrategy.synthesisTokenBudget,
            AppleLocalAnswerStrategy.draftTokenBudget
        )
    }

    // MARK: - Region context

    /// Only a coarse, locale-derived region is described, and a bare language
    /// has no region at all.
    func testAssistantUserContextIsCoarseAndLocaleDerived() {
        XCTAssertEqual(AssistantUserContext.regionCode(Locale(identifier: "en_GB")), "GB")
        XCTAssertEqual(AssistantUserContext.regionCode(Locale(identifier: "zh_Hans_CN")), "CN")
        XCTAssertNil(AssistantUserContext.regionCode(Locale(identifier: "en")))

        let description = AssistantUserContext.description(
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "Europe/London")!
        )
        XCTAssertTrue(description?.contains("GB") == true)
        XCTAssertTrue(description?.contains("Europe/London") == true)
        XCTAssertNil(AssistantUserContext.description(locale: Locale(identifier: "en"), timeZone: .current))
    }

    /// The region line is present only when a region string is supplied, so the
    /// setting can remove it completely.
    func testLocalInstructionsIncludeRegionOnlyWhenSupplied() {
        let plain = AIPromptBuilder.localInstructions(mode: .ask)
        XCTAssertFalse(plain.contains("approximate region"))
        XCTAssertTrue(plain.contains("British English"), "Every answer is British English by default")

        let withRegion = AIPromptBuilder.localInstructions(
            mode: .ask,
            userContext: "region United Kingdom (GB), time zone Europe/London"
        )
        XCTAssertTrue(withRegion.contains("region United Kingdom (GB), time zone Europe/London"))
        XCTAssertTrue(withRegion.contains("never claim to know exactly where the user is"))
    }

    /// A search about a price or a shop is qualified with the user's country
    /// before it runs; a general knowledge question is not.
    func testLocalisedSearchQueryQualifiesCommerceQueriesOnly() {
        XCTAssertEqual(
            AssistantIntentRouter.localisedSearchQuery("latest iPhone price", regionName: "United Kingdom"),
            "latest iPhone price United Kingdom"
        )
        XCTAssertEqual(
            AssistantIntentRouter.localisedSearchQuery("how much is a new iPad", regionName: "United Kingdom"),
            "how much is a new iPad United Kingdom"
        )
        XCTAssertEqual(
            AssistantIntentRouter.localisedSearchQuery("what is quantum computing", regionName: "United Kingdom"),
            "what is quantum computing"
        )
        XCTAssertEqual(
            AssistantIntentRouter.localisedSearchQuery("latest iPhone price", regionName: nil),
            "latest iPhone price"
        )
        XCTAssertEqual(
            AssistantIntentRouter.localisedSearchQuery("iPhone price in United Kingdom", regionName: "United Kingdom"),
            "iPhone price in United Kingdom",
            "The country is not added twice"
        )

        XCTAssertTrue(AssistantIntentRouter.isLocalCommerceQuery("is it in stock near me"))
        XCTAssertFalse(AssistantIntentRouter.isLocalCommerceQuery("explain Swift closures"))
    }

    /// A follow-up keeps the conversation's research behaviour, but an
    /// explanation request or a bare acknowledgement does not.
    func testFollowUpKeepsSearchingOnlyInASearchedConversation() {
        XCTAssertTrue(AssistantIntentRouter.followUpContinuesSearch("and the Pro model", conversationSearched: true))
        XCTAssertTrue(AssistantIntentRouter.followUpContinuesSearch("why?", conversationSearched: true))
        XCTAssertFalse(AssistantIntentRouter.followUpContinuesSearch("and the Pro model", conversationSearched: false))
        XCTAssertFalse(AssistantIntentRouter.followUpContinuesSearch("explain that again", conversationSearched: true))
        XCTAssertFalse(AssistantIntentRouter.followUpContinuesSearch("thanks", conversationSearched: true))
    }

    /// Once a chat has searched, its follow-up searches too, so an answer that
    /// needs current data is not given from memory.
    #if canImport(SwiftUI) && canImport(WebKit)
    @MainActor
    func testFollowUpInASearchedConversationSearchesToo() async throws {
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in AISequencedProvider(replies: ["First answer.", "Second answer."]) }
        chat.localIntentClassifier = { _ in .answer }
        chat.currentBrowserContextProvider = { nil }
        chat.pageContextProvider = { _, _, _, question in nil }
        chat.regionNameProvider = { nil }
        var queries: [String] = []
        chat.webSearchContextProvider = { query, _, _ in
            queries.append(query)
            return .empty
        }

        chat.send(prompt: "Search the web for the latest iPhone price", allowsWebSearch: true)
        for _ in 0..<200 where queries.isEmpty || chat.isBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(queries.count, 1)

        chat.send(prompt: "and the Pro model", allowsWebSearch: true)
        for _ in 0..<200 where queries.count < 2 || chat.isBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(queries.count, 2, "A follow-up in a searched chat searches too")
        XCTAssertEqual(
            queries.last,
            "the latest iPhone price and the Pro model",
            "The follow-up query carries the earlier subject, not a dangling pronoun"
        )
        chat.clearConversation()
    }
    #endif

    /// A follow-up search carries the earlier subject, so it does not search a
    /// dangling pronoun and come back with nothing.
    func testFollowUpSearchQueryCarriesTheEarlierSubject() {
        XCTAssertEqual(
            AssistantIntentRouter.followUpSearchQuery(
                previousUserPrompt: "Search the web for the latest iPhone price",
                currentPrompt: "and the Pro model"
            ),
            "the latest iPhone price and the Pro model"
        )
        XCTAssertEqual(
            AssistantIntentRouter.strippingSearchInstruction("look up iPhone 17 reviews"),
            "iPhone 17 reviews"
        )
        XCTAssertEqual(
            AssistantIntentRouter.followUpSearchQuery(previousUserPrompt: nil, currentPrompt: "and the Pro model"),
            "and the Pro model"
        )
    }

    /// Sources are archived with the answer they followed, so switching to
    /// another chat and back does not lose them.
    #if canImport(SwiftUI) && canImport(WebKit)
    @MainActor
    func testSourcesSurviveSwitchingAwayAndBack() async throws {
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in AISequencedProvider(replies: ["Answer one.", "Answer two."]) }
        chat.localIntentClassifier = { _ in nil }
        chat.currentBrowserContextProvider = { nil }
        chat.pageContextProvider = { _, _, _, question in nil }
        chat.regionNameProvider = { nil }
        chat.webSearchContextProvider = { _, _, _ in
            WebSearchOutcome(
                context: PageContextBuilder.make(
                    url: "https://results.example/",
                    title: "Results",
                    text: "Result text",
                    limit: 1_000
                ),
                sources: [AssistantSource(title: "One", url: "https://one.example/a")]
            )
        }

        chat.send(prompt: "Search the web for the latest iPhone price", allowsWebSearch: true)
        for _ in 0..<200 where !chat.items.contains(where: {
            if case .sources = $0 { return true }
            return false
        }) || chat.isBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let conversationID = try XCTUnwrap(chat.savedConversations.first?.id)
        XCTAssertTrue(chat.items.contains { if case .sources = $0 { return true }; return false })

        chat.clearConversation()
        XCTAssertFalse(chat.items.contains { if case .sources = $0 { return true }; return false })

        chat.openConversation(conversationID)
        XCTAssertTrue(
            chat.items.contains { if case .sources = $0 { return true }; return false },
            "Reopening a chat restores its source lists"
        )
        chat.clearConversation()
    }
    #endif

    /// A question that only live data can answer routes to search even when the
    /// fast classifier would answer it. Arithmetic and explanatory questions
    /// are not dragged to the web.
    func testPriceQuestionsRouteToSearchButArithmeticDoesNot() {
        XCTAssertEqual(
            AssistantIntentRouter.resolve("what is the price of the latest iPhone", modelDecision: .answer),
            .search
        )
        XCTAssertEqual(
            AssistantIntentRouter.resolve("how much is a new iPad", modelDecision: .answer),
            .search
        )
        XCTAssertEqual(
            AssistantIntentRouter.resolve("is the PS5 in stock", modelDecision: .answer),
            .search
        )
        XCTAssertTrue(AssistantIntentRouter.needsLiveInformation("what does an iPhone cost"))

        XCTAssertEqual(
            AssistantIntentRouter.resolve("how much is 2+2", modelDecision: .answer),
            .answer,
            "Arithmetic is not a live price"
        )
        XCTAssertEqual(
            AssistantIntentRouter.resolve("explain the cost of living", modelDecision: .answer),
            .answer,
            "An explanatory request keeps the model's answer"
        )
        XCTAssertEqual(
            AssistantIntentRouter.resolve("what is the time cost of quicksort", modelDecision: .answer),
            .answer,
            "Algorithmic cost is not a shop price"
        )
        XCTAssertEqual(
            AssistantIntentRouter.resolve("tell me about reusable rockets", modelDecision: .answer),
            .answer
        )
    }

    /// The country reaches the search provider before the search runs, so the
    /// result set is local rather than defaulting to another market.
    #if canImport(SwiftUI) && canImport(WebKit)
    @MainActor
    func testSearchQueryGetsTheUsersCountryBeforeItRuns() async throws {
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in AISequencedProvider(replies: ["Prices vary by retailer."]) }
        chat.localIntentClassifier = { _ in .search }
        chat.currentBrowserContextProvider = { nil }
        chat.pageContextProvider = { _, _, _, question in nil }
        chat.regionNameProvider = { "United Kingdom" }
        var observedQuery: String?
        chat.webSearchContextProvider = { query, _, _ in
            observedQuery = query
            return .empty
        }

        chat.send(prompt: "latest iPhone price", allowsWebSearch: true)
        for _ in 0..<200 where observedQuery == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(observedQuery, "latest iPhone price United Kingdom")
        chat.clearConversation()
    }
    #endif

    /// A source card's icon comes from the result's own origin, with no
    /// credentials, port, query or path carried into the request.
    func testAssistantSourceDerivesFaviconFromItsOwnOrigin() {
        let source = AssistantSource(
            title: "Example",
            url: "https://user:pass@www.example.com:8443/product?x=1#frag"
        )
        XCTAssertEqual(source.faviconURL?.absoluteString, "https://www.example.com/favicon.ico")
        XCTAssertNil(AssistantSource(title: "Bad", url: "not a url").faviconURL)
    }

    /// Assistant prose shows a link's text without a second clickable surface:
    /// the source cards are the place to click.
    #if canImport(SwiftUI) && canImport(WebKit)
    func testAssistantMarkdownFlattensLinks() throws {
        let attributed = try AttributedString(markdown: "See [the source](https://example.com/a) now.")
        let flattened = AssistantMarkdownLinks.plainText(attributed)
        XCTAssertEqual(String(flattened.characters), "See the source now.")
        XCTAssertTrue(flattened.runs.allSatisfy { $0.link == nil })
    }
    #endif

    /// Search results become clickable cards under the answer, de-duplicated and
    /// bounded, so a citation cannot point somewhere the request never carried.
    #if canImport(SwiftUI) && canImport(WebKit)
    @MainActor
    func testSearchResultsBecomeSourceCardsUnderTheAnswer() async throws {
        let chat = AIChatStore()
        let secrets = InMemorySecretProvider()
        chat.settingsProvider = { (.default, secrets) }
        chat.providerFactory = { _, _ in AISequencedProvider(replies: ["Here is what I found."]) }
        chat.localIntentClassifier = { _ in nil }
        chat.currentBrowserContextProvider = { nil }
        chat.pageContextProvider = { _, _, _, question in nil }
        chat.webSearchContextProvider = { _, _, _ in
            WebSearchOutcome(
                context: PageContextBuilder.make(
                    url: "https://results.example/",
                    title: "Results",
                    text: "Some result text",
                    limit: 1_000
                ),
                sources: [
                    AssistantSource(title: "First", url: "https://first.example/a"),
                    AssistantSource(title: "Duplicate", url: "https://first.example/a"),
                    AssistantSource(title: "Second", url: "https://second.example/b")
                ]
            )
        }

        chat.send(prompt: "Search the web for something useful", allowsWebSearch: true)
        for _ in 0..<400 where !chat.items.contains(where: {
            if case .sources = $0 { return true }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .sources(_, let sources)? = chat.items.last(where: {
            if case .sources = $0 { return true }
            return false
        }) else { return XCTFail("Expected source cards") }
        XCTAssertEqual(sources.map(\.url), ["https://first.example/a", "https://second.example/b"])
        chat.clearConversation()
    }
    #endif

    #if canImport(SwiftUI) && canImport(WebKit)
    func testAssistantMarkdownParserSeparatesHeadingsAndListItems() {
        let blocks = AssistantMarkdownParser.parse(
            "## Summary\n\nA **clear** introduction.\n\n- First point\n- Second point\n2. Next step"
        )

        XCTAssertEqual(blocks.map(\.content), [
            .heading(level: 2, text: "Summary"),
            .paragraph("A **clear** introduction."),
            .bullet(depth: 0, text: "First point"),
            .bullet(depth: 0, text: "Second point"),
            .numbered(depth: 0, number: 2, text: "Next step")
        ])
    }

    func testAssistantMarkdownParserRepairsJoinedSummaryAndSentenceSpacing() {
        let blocks = AssistantMarkdownParser.parse("**Summary**On 18 September. It ended.The response.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("**Summary**"),
            .paragraph("On 18 September. It ended. The response.")
        ])
    }
    #endif

    #if os(macOS) && canImport(FoundationModels)
    @available(macOS 26.0, *)
    func testAppleModelUsesConstrainedRoutingAndRouteSpecificResponseSettings() {
        XCTAssertEqual(AppleLocalModelProvider.classifierGenerationOptions.sampling, .greedy)
        XCTAssertEqual(AppleLocalModelProvider.classifierGenerationOptions.maximumResponseTokens, 12)

        let answer = AppleLocalModelProvider.generationOptions(for: .answer)
        XCTAssertEqual(answer.temperature, 0.7)
        XCTAssertEqual(answer.maximumResponseTokens, 1_200)

        let summary = AppleLocalModelProvider.generationOptions(for: .webSearchSummary)
        XCTAssertEqual(summary.temperature, 0.35)
        XCTAssertEqual(summary.maximumResponseTokens, 900)

        let operatorOptions = AppleLocalModelProvider.generationOptions(for: .browserOperator)
        XCTAssertEqual(operatorOptions.sampling, .greedy)
        XCTAssertEqual(operatorOptions.maximumResponseTokens, 450)
    }
    #endif

    func testOperatorPromptListsAllowListedActions() {
        let prompt = AIPromptBuilder.systemPrompt(mode: .operatorMode, pageContext: nil, settings: .default)
        XCTAssertTrue(prompt.contains("open_url"))
        XCTAssertTrue(prompt.contains("read_page_text"))
        XCTAssertTrue(prompt.contains("click_text"))
        XCTAssertTrue(prompt.contains("search_page"))
        XCTAssertTrue(prompt.contains("same-origin GET form"))
        XCTAssertTrue(prompt.contains("approval"))
        XCTAssertTrue(prompt.contains("untrusted data"))
        XCTAssertTrue(prompt.contains("Never use reload to move around within a page"))
        XCTAssertTrue(prompt.contains("If the same action leaves the page unchanged, do not repeat it"))
    }

    func testFlattenedPromptOmitsSystemDuplicate() {
        let request = AIRequest(
            messages: [AIMessage(role: .user, text: "Hi")],
            systemPrompt: "SYS",
            model: "m"
        )
        let flattened = request.flattenedPrompt()
        XCTAssertTrue(flattened.contains("System:\nSYS"))
        XCTAssertTrue(flattened.contains("User:\nHi"))
    }
}
