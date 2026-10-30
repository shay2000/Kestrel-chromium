#if canImport(SwiftUI) && canImport(WebKit)
import XCTest
@testable import KestrelWebKit

@MainActor
final class AssistantRoutingRegressionTests: XCTestCase {
    private func makeChat() -> AIChatStore {
        let chat = AIChatStore()
        chat.localIntentClassifier = { _ in .answer }
        chat.providerFactory = { _, _ in RoutingTestProvider() }
        chat.settingsProvider = { (.default, InMemorySecretProvider()) }
        return chat
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Assistant did not reach the expected state")
    }

    private func waitUntilStarted(_ provider: ProgressRoutingTestProvider) async throws {
        for _ in 0..<200 {
            if await provider.hasStarted() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Provider did not start within the fixture deadline")
        throw NSError(domain: "AssistantRegressionTimeout", code: 1)
    }

    func testWebDefaultDoesNotSearchWebsiteActionOrSkipInitialApproval() async throws {
        for prompt in [
            "Can you add a base model iPhone to my basket on Apple's website?",
            "Can you find and open the ExampleProject repo on GitHub?",
            "Please click the reviews link on this page"
        ] {
            let chat = makeChat()
            var searches = 0
            var actions = 0
            chat.webSearchContextProvider = { _, _, _ in searches += 1; return .empty }
            chat.actionExecutor = { action, _ in
                actions += 1
                return ActionResult(kind: action.kind, status: .succeeded, summary: "Done", detail: "")
            }
            chat.send(prompt: prompt, allowsWebSearch: true)
            try await waitUntil { chat.pendingCursorPrompt != nil }
            XCTAssertEqual(searches, 0, prompt)
            XCTAssertEqual(actions, 0, prompt)
            chat.chooseCursorAssistance(false)
            try await waitUntil { searches == 1 && !chat.isBusy }
            XCTAssertNil(chat.pendingCursorPrompt, "Declining must not loop back to cursor approval")
        }
    }

    /// The composer's Web switch is permission, not a command.
    ///
    /// It used to force a search whenever it was on — and it ships on — so the
    /// Assistant never answered anything: every question opened a results page
    /// in its own tab. A plain question must be answered either way, and only
    /// an explicit request to search should reach the web.
    func testWebSwitchGatesSearchInsteadOfForcingIt() async throws {
        for allowed in [true, false] {
            let chat = makeChat()
            var searches = 0
            chat.webSearchContextProvider = { _, _, _ in searches += 1; return .empty }
            chat.send(prompt: "Tell me about reusable rockets", allowsWebSearch: allowed)
            try await waitUntil { chat.items.count > 1 && !chat.isBusy }
            XCTAssertEqual(searches, 0, "A question must not become a search (allowed=\(allowed))")
        }

        let searching = makeChat()
        var searches = 0
        searching.webSearchContextProvider = { _, _, _ in searches += 1; return .empty }
        searching.send(prompt: "Search the web for reusable rocket launches", allowsWebSearch: true)
        try await waitUntil { searching.items.count > 1 && !searching.isBusy }
        XCTAssertEqual(searches, 1)

        let heldBack = makeChat()
        var heldBackSearches = 0
        heldBack.webSearchContextProvider = { _, _, _ in heldBackSearches += 1; return .empty }
        heldBack.send(prompt: "Search the web for reusable rocket launches", allowsWebSearch: false)
        try await waitUntil { heldBack.items.count > 1 && !heldBack.isBusy }
        XCTAssertEqual(heldBackSearches, 0, "The switch must be able to hold a search back")
        XCTAssertTrue(
            heldBack.items.contains { item in
                if case .notice(_, let text) = item { return text.contains("Web search is off") }
                return false
            },
            "Suppressing a search should say so rather than answer silently"
        )
    }


    func testProgressLabelsCoverPageReadingWebSearchAndAnswerGeneration() async throws {
        let chat = makeChat()
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.com")
        let provider = ProgressRoutingTestProvider()
        var pageContinuation: CheckedContinuation<PageContext?, Never>?
        var searchContinuation: CheckedContinuation<WebSearchOutcome, Never>?

        chat.currentBrowserContextProvider = { context }
        chat.localIntentClassifier = { _ in .search }
        chat.pageContextProvider = { _, _, _, question in
            await withCheckedContinuation { pageContinuation = $0 }
        }
        chat.webSearchContextProvider = { _, _, _ in
            await withCheckedContinuation { searchContinuation = $0 }
        }
        chat.providerFactory = { _, _ in provider }

        chat.send(prompt: "Search the web for the latest rocket launch")
        try await waitUntil { chat.activityMessage == "Reading the page…" }
        XCTAssertTrue(chat.isBusy)
        XCTAssertNotNil(pageContinuation)

        pageContinuation?.resume(returning: nil)
        try await waitUntil { chat.activityMessage == "Searching the web…" }
        XCTAssertTrue(chat.isSearchingWeb)
        XCTAssertFalse(chat.activityMessage?.contains("latest rocket launch") ?? true)
        XCTAssertNotNil(searchContinuation)

        searchContinuation?.resume(returning: .empty)
        try await waitUntil {
            chat.activityMessage == "Preparing the answer…" && chat.isSending && !chat.isSearchingWeb
        }
        let providerStarted = await provider.hasStarted()
        XCTAssertTrue(providerStarted)

        await provider.finish(with: "A useful answer")
        try await waitUntil { !chat.isBusy }
        XCTAssertNil(chat.activityMessage)
        XCTAssertTrue(chat.activityEntries.contains("Reading the page…"))
        XCTAssertTrue(chat.activityEntries.contains("Searching the web…"))
        XCTAssertTrue(chat.activityEntries.contains("Preparing the answer…"))
        chat.clearConversation()
        XCTAssertTrue(chat.activityEntries.isEmpty)
    }

    func testLocalTitleIsGeneratedOnceSavedAndRestoredWithRemoteProvider() async throws {
        let chat = makeChat()
        var settings = AISettings.default
        settings.selectedProvider = .openRouter
        chat.settingsProvider = { (settings, InMemorySecretProvider()) }
        var calls = 0
        chat.localTitleGenerator = { prompt, answer in
            calls += 1
            XCTAssertEqual(prompt, "Tell me about reusable rockets")
            XCTAssertEqual(answer, "A useful answer")
            return "Reusable rockets"
        }
        chat.send(prompt: "Tell me about reusable rockets")
        try await waitUntil { chat.conversationTitle != nil && !chat.isBusy }
        let id = try XCTUnwrap(chat.savedConversations.first?.id)
        XCTAssertEqual(chat.conversationTitle, "Reusable rockets")
        chat.send(prompt: "How do they land?")
        try await waitUntil { chat.items.count >= 4 && !chat.isBusy }
        XCTAssertEqual(calls, 1)
        chat.clearConversation()
        XCTAssertNil(chat.conversationTitle)
        chat.openConversation(id)
        XCTAssertEqual(chat.conversationTitle, "Reusable rockets")
    }

    /// The name is chosen after the first answer, from both the question and
    /// what the answer actually said, so it describes the conversation's real
    /// topic rather than a guess made before the model replied.
    func testTitleIsGeneratedFromTheQuestionAndTheFirstAnswer() async throws {
        let chat = makeChat()
        var observed: (String, String)?
        chat.localTitleGenerator = { prompt, answer in
            observed = (prompt, answer)
            return "Reusable rockets"
        }
        chat.send(prompt: "Tell me about reusable rockets")
        try await waitUntil { chat.conversationTitle != nil && !chat.isBusy }

        XCTAssertEqual(observed?.0, "Tell me about reusable rockets")
        XCTAssertEqual(observed?.1, "A useful answer")
        XCTAssertEqual(chat.conversationTitle, "Reusable rockets")
        chat.clearConversation()
    }

    func testFailedSearchConnectorStopsWithoutInventingAnAnswer() async throws {
        let chat = makeChat()
        chat.webSearchContextProvider = { _, _, _ in
            throw AIProviderError.notConfigured("Add an Exa API key in Connections.")
        }
        chat.send(prompt: "Search the web for the latest rocket launch dates", allowsWebSearch: true)
        try await waitUntil { chat.errorMessage != nil && !chat.isBusy }
        XCTAssertTrue(chat.errorMessage?.contains("Exa") == true)
        XCTAssertFalse(chat.isSearchingWeb)
        XCTAssertFalse(chat.items.contains { item in
            if case .message(let message) = item { return message.role == .assistant }
            return false
        })
    }

    func testLateAnswerAfterNewChatCannotReplaceOrStopReplacementTurn() async throws {
        let chat = makeChat()
        let oldProvider = ProgressRoutingTestProvider()
        let newProvider = ProgressRoutingTestProvider()
        var requests = 0
        chat.providerFactory = { _, _ in
            requests += 1
            return requests == 1 ? oldProvider : newProvider
        }
        chat.send(prompt: "Old question")
        try await waitUntilStarted(oldProvider)
        let oldID = chat.currentConversationID
        chat.clearConversation()
        XCTAssertNotEqual(chat.currentConversationID, oldID)
        chat.send(prompt: "New question")
        try await waitUntilStarted(newProvider)
        await oldProvider.finish(with: "Old answer")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(chat.isBusy, "Old task cleanup must not stop the replacement request")
        XCTAssertNil(chat.errorMessage)
        await newProvider.finish(with: "New answer")
        try await waitUntil { !chat.isBusy }
        let texts = chat.items.compactMap { item -> String? in
            if case .message(let message) = item { return message.text }
            return nil
        }
        XCTAssertEqual(texts, ["New question", "New answer"])
        XCTAssertFalse(chat.savedConversations.flatMap(\.messages).contains { $0.text == "Old answer" })
    }

    func testLateAgenticResearchCannotMakeNewChatContinueOldSearch() async throws {
        let chat = makeChat()
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.com")
        chat.currentBrowserContextProvider = { context }
        chat.pageContextProvider = { _, _, _, _ in PageContext(url: "https://example.com", title: "Example", textSnapshot: "A public research page", wasTruncated: false) }
        var continuation: CheckedContinuation<WebSearchOutcome?, Never>?
        var searches: [String] = []
        chat.agenticWebSearchContextProvider = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        chat.webSearchContextProvider = { query, _, _ in
            searches.append(query)
            return .empty
        }
        chat.togglePageControl()
        chat.send(prompt: "Search the web for recent lunar missions")
        try await waitUntil { continuation != nil }
        chat.clearConversation()
        continuation?.resume(returning: .empty)
        // Let the cancelled connector finish before starting the replacement.
        for _ in 0..<10 { await Task.yield() }
        chat.send(prompt: "Explain how rockets work")
        try await waitUntil { !chat.isBusy }
        chat.send(prompt: "and satellites?")
        try await waitUntil { !chat.isBusy }
        XCTAssertTrue(searches.isEmpty, "A late connector must not make the new chat inherit the old research subject")
        XCTAssertFalse(chat.items.contains { item in
            if case .message(let message) = item { return message.text.contains("recent lunar missions") }
            return false
        })
    }

    func testLateLocalTitleCannotResurrectDeletedConversation() async throws {
        let chat = makeChat()
        var continuation: CheckedContinuation<String?, Never>?
        chat.localTitleGenerator = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        chat.send(prompt: "Help me understand rockets")
        try await waitUntil { continuation != nil }
        chat.deleteAllSavedConversations()
        continuation?.resume(returning: "Old chat")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(chat.conversationTitle)
        XCTAssertTrue(chat.savedConversations.isEmpty)
        XCTAssertTrue(chat.items.isEmpty)
    }
}

private struct RoutingTestProvider: AIProvider {
    let kind: AIProviderKind = .openRouter
    func respond(to request: AIRequest) async throws -> AIResponse {
        AIResponse(text: "A useful answer", model: "fixture")
    }
}

private actor ProgressRoutingTestProvider: AIProvider {
    nonisolated let kind: AIProviderKind = .openRouter
    private var continuation: CheckedContinuation<AIResponse, Error>?
    private var started = false

    func respond(to request: AIRequest) async throws -> AIResponse {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func hasStarted() -> Bool { started }

    func finish(with text: String) {
        continuation?.resume(returning: AIResponse(text: text, model: "fixture"))
        continuation = nil
    }
}
#endif
