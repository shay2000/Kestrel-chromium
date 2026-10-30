#if canImport(SwiftUI) && canImport(WebKit)
import XCTest
@testable import KestrelWebKit

@MainActor
final class OperatorReliabilityTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Operator did not reach the expected state")
    }

    private func makeChat(_ provider: OperatorFixtureProvider) -> AIChatStore {
        let chat = AIChatStore()
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.invalid/catalogue")
        chat.currentBrowserContextProvider = { context }
        chat.pageContextProvider = { _, _, _, question in
            PageContextBuilder.make(url: context.pageURL, title: "Catalogue", text: "Visible catalogue evidence")
        }
        chat.settingsProvider = { (.default, InMemorySecretProvider()) }
        chat.providerFactory = { _, _ in provider }
        chat.autoApproveSafeBrowsingProvider = { true }
        return chat
    }

    func testExplicitProductNavigationWithPriceDoesNotBecomeExaAnswer() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"find_text","query":"iPhone 17"}"#, "The product page shows £899."])
        let chat = makeChat(provider)
        var searched = false
        var actions = 0
        chat.agenticWebSearchContextProvider = { _, _ in searched = true; return .empty }
        chat.actionExecutor = { action, _ in
            actions += 1
            return .init(kind: action.kind, status: .succeeded, summary: "Found product", detail: "£899")
        }
        chat.togglePageControl()
        chat.send(prompt: "Find the standard iPhone 17 here, open its cheapest-storage product page and report its price and colour choices.")
        try await waitUntil { provider.requests.count == 2 && !chat.isBusy }
        XCTAssertEqual(actions, 1)
        XCTAssertFalse(searched)
        XCTAssertEqual(provider.requests.first?.generationPurpose, .browserOperator)
    }

    func testBackgroundTaskKeepsItsOriginalTabAndCompletesWithoutApproval() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"find_text","query":"Delivery"}"#, "Delivery takes two days."])
        let chat = makeChat(provider)
        let origin = try XCTUnwrap(chat.currentBrowserContextProvider())
        var authority: UUID?
        chat.backgroundTaskBinding = { authority = $0 }
        var selected = origin
        chat.currentBrowserContextProvider = {
            chat.backgroundTaskTabID == origin.tabID ? origin : selected
        }
        var continuation: CheckedContinuation<Void, Never>?
        provider.waitBeforeReply = {
            if provider.requests.count == 1 { await withCheckedContinuation { continuation = $0 } }
        }
        var executed: [UUID] = []
        chat.actionExecutor = { action, context in
            executed.append(try! XCTUnwrap(context?.tabID))
            return .init(kind: action.kind, status: .succeeded, summary: "Found Delivery", detail: "Two days")
        }
        chat.togglePageControl()
        chat.send(prompt: "Find delivery details")
        try await waitUntil { continuation != nil }
        selected = .init(tabID: UUID(), pageURL: "https://example.invalid/other")
        chat.browserTabChanged(to: selected.tabID)
        XCTAssertEqual(chat.backgroundTaskTabID, origin.tabID)
        XCTAssertEqual(chat.tabTaskStates[origin.tabID], .running)
        continuation?.resume()
        try await waitUntil { provider.requests.count == 2 && !chat.isBusy }
        XCTAssertEqual(executed, [origin.tabID])
        XCTAssertEqual(chat.tabTaskStates[origin.tabID], .completed)
        XCTAssertNil(chat.tabTaskStates[selected.tabID])
        XCTAssertNil(chat.pendingProposal)
        XCTAssertNil(authority, "Completed tasks must release background execution authority")
        var nextPage: UUID?
        chat.pageContextProvider = { context, _, _, _ in
            nextPage = context?.tabID
            return PageContextBuilder.make(url: context?.pageURL ?? "", title: "Other", text: "Other page")
        }
        chat.localIntentClassifier = { _ in .answer }
        chat.send(prompt: "Describe this page")
        try await waitUntil { !chat.isBusy }
        XCTAssertEqual(nextPage, selected.tabID, "A new request must not resurrect the completed task's tab")
        XCTAssertFalse(chat.isPageControlArmed)
    }

    func testStopCancelsAnAgentWaitingForApproval() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"click_text","query":"Send"}"#])
        let chat = makeChat(provider)
        let id = try XCTUnwrap(chat.currentBrowserContextProvider()?.tabID)
        var authority: UUID?
        chat.backgroundTaskBinding = { authority = $0 }
        chat.togglePageControl()
        chat.send(prompt: "Use the page control")
        try await waitUntil { chat.pendingProposal != nil && !chat.isBusy }
        XCTAssertEqual(chat.tabTaskStates[id], .needsAttention)
        chat.cancel()
        XCTAssertNil(chat.pendingProposal)
        XCTAssertNil(chat.backgroundTaskTabID)
        XCTAssertNil(authority)
        XCTAssertFalse(chat.isPageControlArmed)
        XCTAssertEqual(chat.tabTaskStates[id], .needsAttention)
    }


    func testProfileFillRequiresExactLocalPreviewEvenInAutoAndStopsBeforeRecapture() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"fill_profile","rationale":"Preview details"}"#])
        let chat = makeChat(provider)
        let context = try XCTUnwrap(chat.currentBrowserContextProvider())
        let preview = ProfileFillPreview(id: UUID(), context: context, destination: "https://example.invalid/delivery",
            fields: [.init(key: "name", label: "Name", value: "Private Example Person")])
        chat.profileFieldAvailabilityProvider = { ["name"] }
        chat.profileFillPreviewProvider = { _ in preview }
        chat.checkoutHandoffProvider = { _ in true }
        var executions = 0
        chat.actionExecutor = { action, _ in
            XCTAssertEqual(action, .fillProfile(preview.id))
            executions += 1
            return .init(kind: action.kind, status: .succeeded, summary: "Filled approved fields", detail: nil)
        }
        chat.togglePageControl()
        chat.send(prompt: "Fill this form using my saved details")
        try await waitUntil { chat.pendingProposal != nil && !chat.isBusy }
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(chat.pendingProfileFillPreview, preview)
        XCTAssertEqual(chat.pendingProposal?.action, .fillProfile(preview.id))
        XCTAssertFalse(String(describing: provider.requests).contains("Private Example Person"))
        XCTAssertFalse(String(describing: chat.items).contains("Private Example Person"))
        chat.approvePendingProposal()
        try await waitUntil { executions == 1 && !chat.isBusy }
        XCTAssertEqual(provider.requests.count, 1, "Do not recapture populated fields for a follow-up model response")
        XCTAssertFalse(chat.items.contains { if case .proposal = $0 { return true }; return false },
            "Resolved approvals must not keep asking the user to review an already completed action")
        XCTAssertNil(chat.pendingProfileFillPreview)
        XCTAssertNil(chat.backgroundTaskTabID)
    }

    func testProfileFillDeclineAndMissingPreviewNeverExecute() async throws {
        for hasPreview in [true, false] {
            let provider = OperatorFixtureProvider(replies: [#"{"action":"fill_profile"}"#])
            let chat = makeChat(provider)
            let context = try XCTUnwrap(chat.currentBrowserContextProvider())
            chat.profileFieldAvailabilityProvider = { ["email"] }
            chat.profileFillPreviewProvider = { _ in hasPreview ? .init(id: UUID(), context: context,
                destination: "https://example.invalid/", fields: [.init(key: "email", label: "Email", value: "example@example.invalid")]) : nil }
            var executions = 0
            chat.actionExecutor = { action, _ in executions += 1; return .declined(action) }
            chat.togglePageControl(); chat.send(prompt: "Fill my contact details")
            try await waitUntil { !chat.isBusy }
            if hasPreview {
                XCTAssertNotNil(chat.pendingProfileFillPreview)
                chat.declinePendingProposal()
            }
            XCTAssertEqual(executions, 0)
            XCTAssertNil(chat.pendingProfileFillPreview)
            XCTAssertNil(chat.pendingProposal)
        }
    }

    func testStaleProfilePreparationCannotResurrectClearedConversation() async throws {
        let chat = makeChat(OperatorFixtureProvider(replies: [#"{"action":"fill_profile"}"#]))
        let context = try XCTUnwrap(chat.currentBrowserContextProvider())
        var resume: CheckedContinuation<Void, Never>?
        chat.profileFillPreviewProvider = { _ in
            await withCheckedContinuation { resume = $0 }
            return .init(id: UUID(), context: context, destination: "https://example.invalid/", fields: [])
        }
        chat.togglePageControl(); chat.send(prompt: "Fill this form")
        try await waitUntil { resume != nil }
        chat.clearConversation()
        resume?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertNil(chat.pendingProfileFillPreview)
        XCTAssertNil(chat.pendingProposal)
        XCTAssertNil(chat.requestExternalAction(.fillProfile(UUID()), context: context))
    }

    func testCheckoutProfileRequestCannotExecuteOtherActions() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"click_text","query":"Continue"}"#])
        let chat = makeChat(provider)
        chat.checkoutHandoffProvider = { _ in true }
        chat.profileFieldAvailabilityProvider = { ["name"] }
        var executions = 0
        chat.actionExecutor = { action, _ in executions += 1; return .declined(action) }
        chat.togglePageControl(); chat.send(prompt: "Fill my address details")
        try await waitUntil { !chat.isBusy }
        XCTAssertEqual(executions, 0)
        XCTAssertNil(chat.pendingProposal)
    }

    func testCheckoutHandoffRunsBeforeTheProviderAndDoesNotShowCompletionTick() async throws {
        let provider = OperatorFixtureProvider(replies: ["Must not run"])
        let chat = makeChat(provider)
        let id = try XCTUnwrap(chat.currentBrowserContextProvider()?.tabID)
        chat.checkoutHandoffProvider = { _ in true }
        chat.togglePageControl()
        chat.send(prompt: "Continue shopping")
        try await waitUntil { !chat.isBusy }
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(chat.tabTaskStates[id], .needsAttention)
        XCTAssertNil(chat.pendingProposal)
    }

    func testAutomaticActionRetainsOperatingActivityUntilItCompletes() async throws {
        let chat = makeChat(OperatorFixtureProvider(replies: [#"{"action":"find_text","text":"Catalogue"}"#]))
        var resume: CheckedContinuation<Void, Never>?
        chat.actionExecutor = { action, _ in
            await withCheckedContinuation { resume = $0 }
            return .skipped(action, reason: "Fixture stopped")
        }
        chat.togglePageControl()
        chat.send(prompt: "Find Catalogue on this page")
        try await waitUntil { resume != nil }
        XCTAssertTrue(chat.isExecutingAction)
        XCTAssertEqual(chat.activityMessage, "Running: Find “Catalogue” on the page")
        chat.clearConversation()
        resume?.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertFalse(chat.isBusy)
    }

    func testMalformedActionGetsOneCorrectionAndCannotExecuteInvalidPayload() async throws {
        let provider = OperatorFixtureProvider(replies: [
            #"{"action":"find_text","query":"Storage" "broken":true}"#,
            #"{"action":"find_text","query":"Storage"}"#,
            "The storage section is visible."
        ])
        let chat = makeChat(provider)
        var actions = 0
        chat.actionExecutor = { action, _ in
            actions += 1
            return .init(kind: action.kind, status: .succeeded, summary: action.summary, detail: "Storage visible")
        }
        chat.togglePageControl()
        chat.send(prompt: "Find the storage options")
        try await waitUntil { provider.requests.count >= 3 && !chat.isBusy }
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertTrue(provider.requests[1].localInstructions?.contains("nothing executed") == true)
    }

    func testMalformedActionCorrectionStopsAfterOneRetry() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"find_text","query":"Storage" "broken":true}"#])
        let chat = makeChat(provider)
        var actions = 0
        chat.actionExecutor = { action, _ in actions += 1; return .skipped(action, reason: "Unexpected") }
        chat.togglePageControl()
        chat.send(prompt: "Find the storage options")
        try await waitUntil { provider.requests.count >= 2 && !chat.isBusy }
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(chat.activityEntries.last, "Stopped: browser action could not be verified.")
    }

    func testAutoModeCanFinishConfigurationAndVerifyBasketWithinTwelveActions() async throws {
        let provider = OperatorFixtureProvider(replies: (1...13).map {
            #"{"action":"find_text","query":"Section \#($0)"}"#
        })
        let chat = makeChat(provider)
        var actions = 0
        chat.actionExecutor = { action, _ in
            actions += 1
            return .init(kind: action.kind, status: .succeeded, summary: action.summary, detail: "Observed section")
        }
        chat.enableAutomaticAgentMode()
        chat.send(prompt: "Configure one phone and verify the bag")
        try await waitUntil { provider.requests.count >= 13 && !chat.isBusy }
        XCTAssertEqual(actions, 12)
        XCTAssertEqual(provider.requests.count, 13)
        XCTAssertEqual(provider.requests.last?.generationPurpose, .browserSummary)
    }

    func testShortFollowUpDoesNotDiscardTheSearchSubject() {
        XCTAssertEqual(AssistantIntentRouter.followUpSearchQuery(previousUserPrompt: "iPhone Pro price", currentPrompt: "price"), "iPhone Pro price")
    }

    func testExternalActionStatusTracksApprovalOutcomeWithoutPageEvidence() async throws {
        let chat = makeChat(OperatorFixtureProvider(replies: ["Unused"]))
        let context = chat.currentBrowserContextProvider()!
        chat.actionExecutor = { action, _ in
            .init(kind: action.kind, status: .succeeded, summary: "Done", detail: "Private page evidence")
        }
        let id = try XCTUnwrap(chat.requestExternalAction(.reload, context: context))
        XCTAssertEqual(chat.externalActionStatus(id), "waiting_for_approval")
        XCTAssertNil(chat.requestExternalAction(.reload, context: context))
        chat.approvePendingProposal()
        XCTAssertEqual(chat.externalActionStatus(id), "running")
        try await waitUntil { !chat.isBusy }
        XCTAssertEqual(chat.externalActionStatus(id), "succeeded")
        XCTAssertTrue(chat.savedConversations.isEmpty)
        let declined = try XCTUnwrap(chat.requestExternalAction(.reload, context: context))
        chat.declinePendingProposal()
        XCTAssertEqual(chat.externalActionStatus(declined), "declined")
        let cancelled = try XCTUnwrap(chat.requestExternalAction(.reload, context: context))
        chat.clearConversation()
        XCTAssertEqual(chat.externalActionStatus(cancelled), "cancelled")
        for _ in 0..<16 {
            _ = chat.requestExternalAction(.reload, context: context)
            chat.declinePendingProposal()
        }
        XCTAssertNil(chat.externalActionStatus(id), "Old request records must expire")
    }

    func testExternalActionCancellationCannotBeOverwrittenByLateCompletion() async throws {
        let chat = makeChat(OperatorFixtureProvider(replies: ["Unused"]))
        var resume: CheckedContinuation<Void, Never>?
        chat.actionExecutor = { action, _ in
            await withCheckedContinuation { resume = $0 }
            return .init(kind: action.kind, status: .succeeded, summary: "Late", detail: nil)
        }
        let id = try XCTUnwrap(chat.requestExternalAction(.reload, context: chat.currentBrowserContextProvider()!))
        chat.approvePendingProposal()
        try await waitUntil { resume != nil }
        chat.cancel()
        resume?.resume()
        await Task.yield()
        XCTAssertEqual(chat.externalActionStatus(id), "cancelled")
    }

    func testResearchKeepsSubjectAcrossThreeTurnsAndResetsForExplicitNewSearch() async throws {
        let provider = OperatorFixtureProvider(replies: ["A summary"])
        let chat = makeChat(provider)
        chat.localIntentClassifier = { _ in .search }
        var queries: [String] = []
        chat.webSearchContextProvider = { query, _, _ in queries.append(query); return .empty }
        for prompt in ["Search the web for the latest iPhone price", "and the Pro model", "what about its battery", "Search the web for Mars missions"] {
            chat.send(prompt: prompt)
            try await waitUntil { !chat.isBusy }
        }
        XCTAssertTrue(queries[2].contains("iPhone"))
        XCTAssertTrue(queries[2].contains("Pro model"))
        XCTAssertFalse(queries[3].contains("iPhone"))
        XCTAssertTrue(queries[3].contains("Mars missions"))
    }

    func testExplicitBrowseResearchUsesExaEvidenceAndKeepsTheBoundTabStill() async throws {
        let provider = OperatorFixtureProvider(replies: ["The researched answer is supported."])
        let chat = makeChat(provider)
        var queries: [String] = []
        var browserActions = 0
        chat.agenticWebSearchContextProvider = { query, _ in
            queries.append(query)
            return WebSearchOutcome(
                context: PageContextBuilder.make(
                    url: "https://exa.ai/",
                    title: "Exa research",
                    text: "Exa evidence unique fixture",
                    limit: 1_000
                ),
                sources: [AssistantSource(title: "Research source", url: "https://source.example/finding")]
            )
        }
        chat.actionExecutor = { action, _ in
            browserActions += 1
            return .skipped(action, reason: "No page action expected")
        }

        chat.togglePageControl()
        chat.send(prompt: "Search the web for current Juno mission findings")
        try await waitUntil { !provider.requests.isEmpty && !chat.isBusy }

        XCTAssertEqual(queries, ["current Juno mission findings"])
        XCTAssertEqual(browserActions, 0)
        XCTAssertEqual(provider.requests[0].generationPurpose, .webSearchSummary)
        XCTAssertTrue(provider.requests[0].localInstructions?.contains("Do not propose browser actions in this mode") == true)
        XCTAssertFalse(provider.requests[0].localInstructions?.contains("Propose the next allow-listed action") == true)
        XCTAssertTrue(provider.requests[0].localContext?.contains("Exa evidence unique fixture") == true)
        guard case .sources(_, let sources)? = chat.items.last(where: {
            if case .sources = $0 { return true }
            return false
        }) else { return XCTFail("Expected Exa source cards under the Browse answer") }
        XCTAssertEqual(sources.map(\.url), ["https://source.example/finding"])
    }

    func testAgenticResearchRejectsAnActionInsteadOfExecutingIt() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"find_text","query":"Juno"}"#])
        let chat = makeChat(provider)
        var browserActions = 0
        chat.agenticWebSearchContextProvider = { _, _ in
            WebSearchOutcome(
                context: PageContextBuilder.make(
                    url: "https://exa.ai/",
                    title: "Exa research",
                    text: "Current mission evidence",
                    limit: 1_000
                ),
                sources: [AssistantSource(title: "Mission source", url: "https://source.example/mission")]
            )
        }
        chat.actionExecutor = { action, _ in
            browserActions += 1
            return .skipped(action, reason: "No page action expected")
        }

        chat.togglePageControl()
        chat.send(prompt: "Search the web for current Juno mission findings")
        try await waitUntil { !provider.requests.isEmpty && !chat.isBusy }

        XCTAssertEqual(provider.requests[0].generationPurpose, .webSearchSummary)
        XCTAssertEqual(browserActions, 0)
        XCTAssertNil(chat.pendingProposal)
        XCTAssertTrue(chat.savedConversations.first?.messages.last?.text.contains("did not return a usable grounded summary") == true)
    }

    func testEarlierPageEvidenceSurvivesNavigationAndStaysOutOfArchive() async throws {
        let provider = OperatorFixtureProvider(replies: [
            #"{"action":"open_url","url":"https://example.invalid/second"}"#,
            "Both pages have been compared."
        ])
        let chat = makeChat(provider)
        var context = chat.currentBrowserContextProvider()!
        chat.currentBrowserContextProvider = { context }
        chat.pageContextProvider = { _, _, _, question in
            PageContextBuilder.make(url: context.pageURL, title: "Page",
                text: context.pageURL.hasSuffix("second") ? "Second page details" : "First page evidence unique fixture")
        }
        chat.actionExecutor = { action, _ in
            context = .init(tabID: context.tabID, pageURL: "https://example.invalid/second")
            return .init(kind: action.kind, status: .succeeded, summary: "Opened second page", detail: nil)
        }
        chat.togglePageControl()
        chat.send(prompt: "Compare these pages")
        try await waitUntil { provider.requests.count == 2 && !chat.isBusy }
        XCTAssertTrue(provider.requests[1].localContext?.contains("First page evidence unique fixture") == true)
        XCTAssertTrue(provider.requests[1].localContext?.contains("Second page details") == true)
        XCTAssertFalse(chat.savedConversations.first?.messages.contains { $0.text.contains("unique fixture") } == true)
    }

    func testAlternatingActionsStopBeforeRepeatingAnEarlierStateAndSummarise() async throws {
        let provider = OperatorFixtureProvider(replies: [
            #"{"action":"find_text","query":"Reviews"}"#,
            #"{"action":"read_page_text","maxCharacters":4000}"#,
            #"{"action":"find_text","query":" reviews "}"#,
            "The catalogue was readable, but I could not verify the review score."
        ])
        let chat = makeChat(provider)
        var actions: [BrowserAction] = []
        chat.actionExecutor = { action, _ in
            actions.append(action)
            return .init(kind: action.kind, status: .succeeded, summary: action.summary, detail: "Observed evidence")
        }
        chat.togglePageControl()
        chat.send(prompt: "Find the reviews and report the score")
        try await waitUntil { provider.requests.count >= 3 && !chat.isBusy }
        XCTAssertEqual(actions.count, 2, "Alternating actions must not evade the no-progress guard")
        XCTAssertEqual(provider.requests.count, 4, "Stopping should still produce supported findings")
        XCTAssertEqual(provider.requests.last?.generationPurpose, .browserSummary)
        XCTAssertTrue(provider.requests.last?.localInstructions?.contains("Do not propose") == true)
        XCTAssertTrue(chat.savedConversations.first?.messages.last?.text.contains("could not verify") == true)
    }

    func testChangingControlReferenceCannotRepeatBasketAddition() async throws {
        let provider = OperatorFixtureProvider(replies: [
            #"{"action":"click_text","query":"Add to cart","control":"c1_0"}"#,
            #"{"action":"click_text","query":"Add to cart","control":"c2_4"}"#,
            "The basket addition was dispatched once."
        ])
        let chat = makeChat(provider)
        var actions = 0
        chat.actionExecutor = { action, _ in
            actions += 1
            return .init(kind: action.kind, status: .succeeded, summary: action.summary, detail: "Changed status")
        }
        chat.togglePageControl()
        chat.send(prompt: "Add one phone to the basket")
        try await waitUntil { provider.requests.count == 3 && !chat.isBusy }
        XCTAssertEqual(actions, 1)
        XCTAssertNil(chat.pendingProposal)
    }

    func testBasketAdditionCannotRepeatWhenIncidentalPageTextChanges() async throws {
        let provider = OperatorFixtureProvider(replies: [
            #"{"action":"click_text","query":"Add to cart"}"#,
            #"{"action":"click_text","query":"Add to cart"}"#,
            "The add was requested once; the basket total is not yet verified."
        ])
        let chat = makeChat(provider)
        var actions = 0
        chat.pageContextProvider = { _, _, limit, _ in
            PageContextBuilder.make(url: "https://example.invalid/catalogue", title: "Shop",
                text: "Add to cart. Status update \(actions)", limit: limit)
        }
        chat.actionExecutor = { action, _ in
            actions += 1
            return .init(kind: action.kind, status: .succeeded, summary: "Clicked once", detail: "Status changed")
        }
        chat.togglePageControl()
        chat.send(prompt: "Add one phone to the basket")
        try await waitUntil { chat.pendingProposal != nil }
        chat.approvePendingProposal()
        try await waitUntil { provider.requests.count == 3 && !chat.isBusy }
        XCTAssertEqual(actions, 1)
        XCTAssertNil(chat.pendingProposal, "Incidental page changes must not invite a duplicate basket addition")
        XCTAssertEqual(provider.requests.last?.generationPurpose, .browserSummary)
    }

    func testSingleAgentModeStopsAfterTwelveActionsAndSummarises() async throws {
        let provider = OperatorFixtureProvider(replies: (1...13).map {
            #"{"action":"find_text","query":"Section \#($0)"}"#
        })
        let chat = makeChat(provider)
        var actions = 0
        chat.actionExecutor = { action, _ in
            actions += 1
            return .init(kind: action.kind, status: .succeeded, summary: "Found section \(actions)", detail: "Evidence \(actions)")
        }
        chat.togglePageControl()
        chat.send(prompt: "Inspect the twelve sections")
        try await waitUntil { actions == 12 && !chat.isBusy }
        XCTAssertEqual(provider.requests.count, 13)
        XCTAssertTrue(provider.requests.last?.localContext?.contains("Evidence 12") == true)
        XCTAssertNil(chat.pendingProposal)
        XCTAssertFalse(chat.savedConversations.first?.messages.contains { $0.text.contains("\"action\"") } == true)
    }

    func testFailureIsPassedToAReadOnlySummary() async throws {
        let provider = OperatorFixtureProvider(replies: [
            #"{"action":"search_page","query":"blue chair"}"#,
            "I could not complete the site search because no safe search form was available."
        ])
        let chat = makeChat(provider)
        chat.actionExecutor = { action, _ in .skipped(action, reason: "No safe search form") }
        chat.togglePageControl()
        chat.send(prompt: "Search this site for a blue chair")
        try await waitUntil { !provider.requests.isEmpty && !chat.isBusy }
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests.last?.localContext?.contains("No safe search form") == true)
    }

    func testTabSwitchDuringProviderResponseRejectsProposal() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"click_text","query":"Next"}"#])
        let chat = makeChat(provider)
        provider.onRequest = { _ in
            chat.currentBrowserContextProvider = { BrowserActionContext(tabID: UUID(), pageURL: "https://other.invalid/") }
        }
        chat.togglePageControl()
        chat.send(prompt: "Read the next page")
        try await waitUntil { !provider.requests.isEmpty && !chat.isBusy }
        XCTAssertNil(chat.pendingProposal)
    }

    func testCancellationDuringProviderResponseCannotExecuteAnAction() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"open_url","url":"https://example.invalid/next"}"#])
        let chat = makeChat(provider)
        var continuation: CheckedContinuation<Void, Never>?
        var actions = 0
        provider.waitBeforeReply = { await withCheckedContinuation { continuation = $0 } }
        chat.actionExecutor = { action, _ in
            actions += 1
            return .init(kind: action.kind, status: .succeeded, summary: "Opened", detail: nil)
        }
        chat.togglePageControl()
        chat.send(prompt: "Open the next page")
        try await waitUntil { continuation != nil }
        chat.cancel()
        continuation?.resume()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(actions, 0)
        XCTAssertNil(chat.pendingProposal)
    }

    func testActionProposalDoesNotRunTitleInferenceBeforeTheFindings() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"find_text","query":"Delivery"}"#, "Delivery takes seven days."])
        let chat = makeChat(provider)
        var executed = false
        var titles = 0
        chat.actionExecutor = { action, _ in
            XCTAssertEqual(titles, 0)
            executed = true
            return .init(kind: action.kind, status: .succeeded, summary: "Found Delivery", detail: "Seven days")
        }
        chat.localTitleGenerator = { _, answer in
            XCTAssertTrue(executed)
            XCTAssertEqual(answer, "Delivery takes seven days.")
            titles += 1
            return "Delivery findings"
        }
        chat.togglePageControl()
        chat.send(prompt: "Find the delivery time")
        try await waitUntil { provider.requests.count == 2 && !chat.isBusy }
        XCTAssertEqual(titles, 1)
    }

    func testPendingProviderCannotBeOverlappedByMCPOrSecondSend() async throws {
        let provider = OperatorFixtureProvider(replies: ["Done"])
        let chat = makeChat(provider)
        chat.togglePageControl()
        chat.send(prompt: "Read this page")
        chat.send(prompt: "Duplicate task")
        let proposal = chat.requestExternalAction(.reload, context: chat.currentBrowserContextProvider()!)
        XCTAssertNil(proposal)
        try await waitUntil { !provider.requests.isEmpty && !chat.isBusy }
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(chat.savedConversations.first?.messages.filter { $0.role == .user }.count, 1)
    }
    func testAgentOffCancelsLateRepliesAcrossRepeatedTurns() async throws {
        for _ in 0..<20 {
            let provider = OperatorFixtureProvider(replies: [#"{"action":"find_text","query":"Delivery"}"#])
            let chat = makeChat(provider)
            var continuation: CheckedContinuation<Void, Never>?
            var actions = 0
            provider.waitBeforeReply = { await withCheckedContinuation { continuation = $0 } }
            chat.actionExecutor = { action, _ in actions += 1; return .skipped(action, reason: "Unexpected") }
            chat.togglePageControl()
            chat.send(prompt: "Find delivery details")
            try await waitUntil { continuation != nil }
            chat.togglePageControl()
            XCTAssertFalse(chat.isPageControlArmed)
            XCTAssertFalse(chat.isBusy)
            continuation?.resume()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(actions, 0)
            XCTAssertEqual(provider.requests.count, 1)
            XCTAssertNil(chat.pendingProposal)
        }
    }

    func testCorrectionAndActionContinuationKeepRequestOnlyAttachments() async throws {
        for first in ["I will click the delivery link", #"{"action":"find_text","query":"Delivery" "broken":true}"#] {
            let provider = OperatorFixtureProvider(replies: [first, #"{"action":"find_text","query":"Delivery"}"#, "Delivery is available."])
            let chat = makeChat(provider)
            chat.actionExecutor = { action, _ in .init(kind: action.kind, status: .succeeded, summary: "Found", detail: nil) }
            chat.togglePageControl()
            chat.send(prompt: "Check the attached requirements", attachments: [
                NewTabAttachment(kind: .file, label: "requirements.txt", origin: "requirements.txt", text: "SYNTHETIC_REQUIREMENT_256GB")
            ], maximumAttachmentCharacters: 1_000, allowsWebSearch: false)
            try await waitUntil { provider.requests.count == 3 && !chat.isBusy }
            XCTAssertTrue(provider.requests.allSatisfy { $0.attachmentContext?.contains("SYNTHETIC_REQUIREMENT_256GB") == true })
            let archived = String(decoding: try JSONEncoder().encode(chat.savedConversations), as: UTF8.self)
            XCTAssertFalse(archived.contains("SYNTHETIC_REQUIREMENT_256GB"))
            chat.send(prompt: "Another question", allowsWebSearch: false)
            try await waitUntil { provider.requests.count == 4 && !chat.isBusy }
            XCTAssertTrue(provider.requests.last?.attachments.isEmpty == true)
        }
    }

    func testRandomControlReferencesDoNotDefeatRepeatedActionDetection() async throws {
        let provider = OperatorFixtureProvider(replies: [#"{"action":"find_text","query":"Delivery"}"#])
        let chat = makeChat(provider)
        var captures = 0
        var actions = 0
        chat.pageContextProvider = { _, _, _, _ in
            captures += 1
            return PageContextBuilder.make(url: "https://example.invalid/catalogue", title: "Catalogue",
                text: "Delivery. Button: Continue | control: c\(UUID().uuidString)_0 | context: Product")
        }
        chat.actionExecutor = { action, _ in actions += 1; return .init(kind: action.kind, status: .succeeded, summary: "Found", detail: nil) }
        chat.togglePageControl()
        chat.send(prompt: "Find delivery details", allowsWebSearch: false)
        try await waitUntil { !chat.isBusy && provider.requests.count >= 3 }
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertGreaterThanOrEqual(captures, 2)
    }

}

@MainActor
private final class OperatorFixtureProvider: AIProvider {
    nonisolated let kind: AIProviderKind = .openRouter
    var requests: [AIRequest] = []
    var onRequest: ((AIRequest) -> Void)?
    var waitBeforeReply: (() async -> Void)?
    private let replies: [String]
    init(replies: [String]) { self.replies = replies }
    func respond(to request: AIRequest) async throws -> AIResponse {
        requests.append(request)
        onRequest?(request)
        await waitBeforeReply?()
        return .init(text: replies[min(requests.count - 1, replies.count - 1)], model: "fixture")
    }
}
#endif
