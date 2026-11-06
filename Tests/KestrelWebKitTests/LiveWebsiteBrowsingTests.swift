#if canImport(WebKit) && canImport(AppKit) && !canImport(CefSwiftUI)
import AppKit
import WebKit
import XCTest
@testable import KestrelWebKit

/// Opt-in public-site acceptance. No credentials, saved cookies or private pages.
@MainActor
final class LiveWebsiteBrowsingTests: XCTestCase {
    func testExaEvidenceUsesTheRealLocalSummaryPath() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_LIVE_LOCAL_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Opt-in local model research-summary acceptance")
        }
        guard AppleLocalModelProvider.availabilityIssue == nil else { throw XCTSkip("Apple Intelligence unavailable") }
        let chat = AIChatStore()
        var settings = AISettings.default
        settings.selectedProvider = .appleLocalModel
        chat.settingsProvider = { (settings, InMemorySecretProvider()) }
        chat.providerFactory = { _, _ in AppleLocalModelProvider() }
        let context = BrowserActionContext(tabID: UUID(), pageURL: "https://example.invalid/")
        chat.currentBrowserContextProvider = { context }
        chat.pageContextProvider = { _, _, _, _ in
            PageContextBuilder.make(url: context.pageURL, title: "Unrelated page", text: "Documentation example domain.")
        }
        chat.agenticWebSearchContextProvider = { _, limit in
            WebSearchOutcome(
                context: ExaSearchProvider.pageContext(query: "Juno launch", results: [
                    ExaSearchResult(title: "Juno mission", url: "https://science.nasa.gov/mission/juno/",
                        text: "Juno launched on 5 August 2011 and arrived at Jupiter on 4 July 2016.")
                ], limit: limit),
                sources: [AssistantSource(title: "Juno mission", url: "https://science.nasa.gov/mission/juno/")]
            )
        }
        var actions = 0
        chat.actionExecutor = { action, _ in
            actions += 1
            return .skipped(action, reason: "Research summary must not operate the page")
        }
        chat.togglePageControl()
        chat.send(prompt: "Search the web for when Juno launched and arrived at Jupiter")
        for _ in 0..<600 {
            if !chat.isBusy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(chat.isBusy)
        XCTAssertNil(chat.errorMessage)
        XCTAssertEqual(actions, 0)
        let answer = chat.savedConversations.first?.messages.last?.text ?? ""
        XCTAssertTrue(answer.contains("2011") && answer.contains("2016"), answer)
        XCTAssertTrue(chat.items.contains { if case .sources = $0 { return true }; return false })
        print("LIVE_EXA_SUMMARY_FIXTURE actions=\(actions): \(answer)")
    }

    func testPublicWebsiteResearch() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_LIVE_WEBSITE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in live public website acceptance")
        }
        guard AppleLocalModelProvider.availabilityIssue == nil else { throw XCTSkip("Apple Intelligence unavailable") }
        try await checkPublicWebsiteResearch(usingCodex: false)
    }

    func testCodexPublicWebsiteResearchThroughChatStore() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_LIVE_CODEX_TESTS"] == "1" else {
            throw XCTSkip("Opt-in authenticated Codex browsing acceptance")
        }
        try await checkPublicWebsiteResearch(usingCodex: true)
    }

    private func checkPublicWebsiteResearch(usingCodex: Bool) async throws {
        let cases = [
            ("wikipedia", "https://en.wikipedia.org/wiki/Juno_(spacecraft)", "Using this page, when was Juno launched and when did it enter orbit around Jupiter?"),
            ("nasa", "https://science.nasa.gov/mission/juno/", "Using this page, when did Juno launch and when did it arrive at Jupiter?"),
            ("python", "https://docs.python.org/3/tutorial/datastructures.html", "Using this page, what is the difference between list.append and list.extend?")
        ]
        for (name, address, question) in cases {
            if usingCodex && name != "nasa" { continue }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
            let store = BrowserStore()
            store.attach(to: view)
            let loaded = await store.loadAndWait(for: URL(string: address)!)
            XCTAssertTrue(loaded, "\(name) did not load")
            guard loaded else { continue }
            let browser = BrowserOperator(webView: view)
            let tabID = UUID()
            let chat = AIChatStore()
            var settings = AISettings.default
            settings.selectedProvider = usingCodex ? .codexCLI : .appleLocalModel
            if usingCodex { settings.codex.model = "gpt-6-luna" }
            chat.settingsProvider = { (settings, InMemorySecretProvider()) }
            chat.providerFactory = { _, _ in
                if usingCodex {
                    var defaults = AIProviderSettings.defaultSettings(for: .codexCLI)
                    defaults.argumentTemplate.insert("--ignore-user-config", at: 1)
                    return CLIProvider(configuration: .init(kind: .codexCLI,
                        executablePath: ProcessInfo.processInfo.environment["KESTREL_LIVE_CODEX_EXECUTABLE"] ?? "codex",
                        argumentTemplate: defaults.argumentTemplate, model: "gpt-6-luna", outputFormat: .codexJSON))
                }
                return AppleLocalModelProvider()
            }
            chat.currentBrowserContextProvider = { BrowserActionContext(tabID: tabID, pageURL: view.url?.absoluteString ?? address) }
            chat.pageContextProvider = { _, mode, limit, question in
                let page = await browser.capturePageContext(limit: limit, includeControls: mode == .operatorMode, query: question)
                print("LIVE_WEBSITE_CONTEXT \(name): \(page?.textSnapshot ?? "nil")")
                return page
            }
            chat.autoApproveSafeBrowsingProvider = { true }
            var actions: [BrowserAction] = []
            var actionResults: [ActionResult] = []
            chat.actionExecutor = { action, _ in
                actions.append(action)
                // This acceptance case reads the requested document only.
                switch action {
                case .findText, .readPageText, .readSelectedText:
                    let result = await browser.perform(action)
                    actionResults.append(result)
                    return result
                default: return .skipped(action, reason: "Acceptance case is limited to reading this public page")
                }
            }
            if usingCodex {
                chat.togglePageControl()
                chat.send(prompt: "Find Juno on this page")
                for _ in 0..<600 {
                    if !chat.isBusy { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                XCTAssertFalse(chat.isBusy)
                XCTAssertNil(chat.errorMessage)
                XCTAssertTrue(actions.contains(.findText("Juno")), "Expected a real WebKit find action: \(actions)")
                XCTAssertTrue(actionResults.contains { $0.kind == BrowserAction.findText("Juno").kind && $0.status == .succeeded }, "Find must succeed in the real WebKit page")
                XCTAssertTrue(chat.isPageControlArmed, "Agent mode persists in the same chat and tab")
                print("LIVE_CODEX_AGENT_FIND model=gpt-6-luna reasoning=medium actions=\(actions.map(\.summary))")
                actions.removeAll()
            }
            chat.togglePageControl()
            chat.send(prompt: question)
            for _ in 0..<600 {
                if !chat.isBusy { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertFalse(chat.isBusy, name)
            XCTAssertNil(chat.errorMessage, name)
            XCTAssertNil(chat.pendingProposal, name)
            let answer = chat.items.compactMap { item -> String? in
                if case .message(let message) = item, message.role == .assistant { return message.text }
                return nil
            }.last ?? ""
            print("LIVE_WEBSITE_RESULT \(usingCodex ? "codex" : "apple") \(name) actions=\(actions.map(\.summary)): \(answer)")
            let lower = answer.lowercased()
            if name == "python" {
                XCTAssertTrue(lower.contains("list.append") && lower.contains("list.extend") && lower.contains("iterable"), answer)
            } else {
                XCTAssertTrue(lower.contains("2011") && lower.contains("2016"), answer)
                XCTAssertTrue(lower.contains("august") || lower.contains("aug."), answer)
                XCTAssertTrue(lower.contains("july") || lower.contains("jul."), answer)
                XCTAssertFalse(lower.contains("21 july") || lower.contains("july 21"), answer)
            }
            chat.cancel()
            store.stopLoading()
        }
    }
}
#endif
