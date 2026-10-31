#if canImport(SwiftUI) && canImport(CefSwiftUI)

import CefSwiftUI
import SwiftUI

@main
struct KestrelChromiumApp: CefSwiftApp {
    @StateObject private var settings: AppSettings
    @StateObject private var tabs: TabStore
    @StateObject private var chat: AIChatStore
    @StateObject private var mcpServer: KestrelMCPServer
    @StateObject private var branding: KestrelBranding
    @StateObject private var updater: KestrelUpdater

    static var cefConfiguration: CefConfiguration {
        var configuration = CefConfiguration()
        configuration.noSandbox = false
        configuration.windowlessRenderingEnabled = false
        configuration.defaultRuntimeStyle = .chrome
        // Retain the pinned Chromium engine identity and matching client hints.
        configuration.extraCommandLineSwitches.merge(BrowserExtensionHost.commandLineSwitches()) { _, new in new }
        return configuration
    }

    @MainActor
    init() {
        CefScriptRunner.shared.installBridge()
        CefPasskeyHandoff.shared.installBridge()
        let settings = AppSettings()
        settings.seedDefaultBookmarksIfNeeded()
        let tabs = TabStore(
            searchEngine: settings.searchEngine,
            pinnedTabsDefaults: .standard
        )
        let chat = AIChatStore()
        let mcpServer = KestrelMCPServer()
        let updater = KestrelUpdater()

        chat.settingsProvider = { [weak settings] in
            (settings?.ai ?? .default, settings?.secrets ?? Secrets.defaultProvider())
        }
        chat.savedConversationsProvider = { [weak settings] in
            settings?.assistantConversations ?? []
        }
        chat.savedConversationsWriter = { [weak settings] conversations in
            settings?.assistantConversations = conversations
        }
        chat.loadSavedConversations()
        chat.localTitleGenerator = { prompt, answer in
            await AppleLocalModelProvider.generateConversationTitle(prompt: prompt, answer: answer)
        }
        chat.autoApproveSafeBrowsingProvider = { [weak settings] in
            settings?.autoApproveSafeBrowsing ?? false
        }
        tabs.personalProfileProvider = { [weak settings] in settings?.personalProfile ?? PersonalProfile() }
        chat.profileFieldAvailabilityProvider = { [weak settings] in Array(settings?.personalProfile.formValues.keys ?? Dictionary<String,String>().keys).sorted() }
        chat.profileFillPreviewProvider = { [weak tabs] context in await tabs?.prepareProfileFill(context) }
        chat.backgroundTaskBinding = { [weak tabs] id in
            tabs?.backgroundAgentTabID = id
            if id == nil { tabs?.clearProfileFill() }
        }
        chat.currentBrowserContextProvider = { [weak tabs, weak chat] in
            if let id = chat?.backgroundTaskTabID { return tabs?.actionContext(for: id) }
            return tabs?.currentActionContext
        }
        chat.checkoutHandoffProvider = { [weak tabs] context in
            return await tabs?.requiresCheckoutHandoff(context) ?? true
        }
        chat.pageContextProvider = { [weak tabs] context, mode, limit, question in
            guard let tabs else {
                return nil
            }
            guard let context else { return nil }
            return await tabs.capturePageContext(for: context, limit: limit, includeControls: mode == .operatorMode, query: question)
        }
        chat.pageImageProvider = { [weak tabs] context in
            await tabs?.captureAgentPageImage(for: context)
        }
        chat.searchEngineProvider = { [weak tabs] in
            tabs?.searchEngine ?? .default
        }
        let exaSearch: @MainActor (String, Int) async throws -> WebSearchOutcome? = { [weak settings] query, limit in
            guard let settings, settings.exaSearchEnabled else { return nil }
            let key = try await ExaCredentialResolver.resolve(from: settings.secrets)
            return try await ExaSearchProvider(apiKey: key).search(query: query, limit: limit)
        }
        chat.agenticWebSearchContextProvider = exaSearch
        chat.webSearchContextProvider = { [weak tabs] query, mode, limit in
            // Exa is opt-in and replaces the browser search only for ordinary
            // web research. Image search is still a browser task. A missing key
            // or a failed request is reported as itself; Kestrel never silently
            // falls back to another search service.
            if mode == .web, let outcome = try await exaSearch(query, limit) {
                return outcome
            }
            guard let tabs else { return .empty }
            // A browser-scraped results page has no structured result list, so
            // it grounds the answer without producing clickable cards.
            return WebSearchOutcome(context: await tabs.searchAndCapture(query: query, mode: mode, limit: limit))
        }
        chat.openExternalURL = { [weak tabs] url in
            guard let tabs else { return }
            // A citation loads in a background tab: the page is ready to read
            // from the tab rail, but clicking a source does not switch the
            // window away from the chat or drag the browser chrome over it.
            _ = tabs.newTab(urlString: url.absoluteString, select: false)
        }
        chat.userContextProvider = { [weak settings] in
            guard let settings, settings.shareRegionWithAssistant else { return nil }
            return AssistantUserContext.description()
        }
        chat.regionNameProvider = { [weak settings] in
            guard let settings, settings.shareRegionWithAssistant else { return nil }
            return AssistantUserContext.regionName()
        }
        chat.actionExecutor = { [weak tabs, weak chat] action, context in
            guard let tabs, let chat else {
                return ActionResult(kind: action.kind, status: .failed, summary: action.summary, detail: "No browser is attached.")
            }
            return await tabs.perform(action, for: context, requiresProductOptionGroup: chat.requiresVerifiedProductOptionGroup)
        }

        mcpServer.configure(
            settingsProvider: { [weak settings] in settings?.agentMCP ?? .default },
            toolHandler: { [weak settings, weak tabs, weak chat] call in
                guard let settings, let tabs, let chat else {
                    return KestrelMCPToolReply(text: "Kestrel is not ready to handle this request.", isError: true)
                }

                switch call.name {
                case "kestrel_get_active_tab":
                    guard settings.agentMCP.sharesActiveTabMetadata else {
                        return KestrelMCPToolReply(text: "Active-tab metadata sharing is disabled in Kestrel Settings.", isError: true)
                    }
                    guard let context = tabs.currentActionContext else {
                        return KestrelMCPToolReply(text: "There is no active browser tab.", isError: true)
                    }
                    let title = Redaction.redacted(tabs.selectedBrowser.pageTitle)
                    let url = PageContextBuilder.safeURLString(URL(string: context.pageURL))
                    return KestrelMCPToolReply(text: "Title: \(title)\nURL: \(url)")

                case "kestrel_read_active_page":
                    guard settings.agentMCP.allowsPageReads else {
                        return KestrelMCPToolReply(text: "Page-text sharing is disabled in Kestrel Settings.", isError: true)
                    }
                    guard let context = tabs.currentActionContext,
                          let page = await tabs.capturePageContext(
                            for: context,
                            limit: call.maxCharacters ?? PageContextBuilder.defaultCharacterLimit
                          ) else {
                        return KestrelMCPToolReply(text: "The active page changed or could not be read. Try again on the current page.", isError: true)
                    }
                    let payload: [String: Any] = [
                        "title": page.title,
                        "url": page.url,
                        "text": page.textSnapshot,
                        "truncated": page.wasTruncated
                    ]
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let text = String(data: data, encoding: .utf8) else {
                        return KestrelMCPToolReply(text: "The page result could not be encoded.", isError: true)
                    }
                    return KestrelMCPToolReply(text: text)

                case "kestrel_get_action_status":
                    guard let rawID = call.requestID, let id = UUID(uuidString: rawID),
                          let status = chat.externalActionStatus(id) else {
                        return KestrelMCPToolReply(text: "Unknown or expired action requestID. Only the last 16 requests in this app session are retained.", isError: true)
                    }
                    return KestrelMCPToolReply(text: "Action \(id.uuidString): \(status). This status contains no page evidence.")

                case "kestrel_request_browser_action":
                    guard let rawAction = call.action else {
                        return KestrelMCPToolReply(text: "An allow-listed action name is required.", isError: true)
                    }
                    var value: [String: Any] = ["action": rawAction]
                    if let url = call.url { value["url"] = url }
                    if let query = call.query { value["query"] = query }
                    do {
                        let action = try BrowserActionDecoder.decode(jsonObject: value)
                        guard !action.isReadOnly else {
                            return KestrelMCPToolReply(text: "Page reads use the separate permission-gated read tool.", isError: true)
                        }
                        guard let context = tabs.currentActionContext else {
                            return KestrelMCPToolReply(text: "There is no active browser tab.", isError: true)
                        }
                        guard let proposalID = chat.requestExternalAction(action, context: context) else {
                            return KestrelMCPToolReply(text: "Another action is already waiting for approval in Kestrel.", isError: true)
                        }
                        return KestrelMCPToolReply(text: "requestID: \(proposalID.uuidString)\nStatus: waiting_for_approval. Nothing will run until the user approves it in Kestrel. Pause for the user, then check kestrel_get_action_status; do not repeat this request or claim success yet.")
                    } catch let error as BrowserActionDecoder.DecodingError {
                        return KestrelMCPToolReply(text: error.reason, isError: true)
                    } catch {
                        return KestrelMCPToolReply(text: "The requested browser action was not valid.", isError: true)
                    }

                default:
                    return KestrelMCPToolReply(text: "That Kestrel MCP tool is not available.", isError: true)
                }
            }
        )

        if settings.agentMCP.isEnabled { mcpServer.start(allowKeychainInteraction: false) }

        _settings = StateObject(wrappedValue: settings)
        _tabs = StateObject(wrappedValue: tabs)
        _chat = StateObject(wrappedValue: chat)
        _mcpServer = StateObject(wrappedValue: mcpServer)
        _branding = StateObject(wrappedValue: KestrelBranding(settings: settings))
        _updater = StateObject(wrappedValue: updater)
    }

    var body: some Scene {
        WindowGroup("Kestrel") {
            ContentView(tabs: tabs, chat: chat, settings: settings)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .frame(minWidth: 700, minHeight: 520)
                .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
                .animation(.easeInOut(duration: 0.22), value: settings.appearanceMode)
                .onOpenURL { url in
                    tabs.open(url: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_200, height: 800)
        .commands {
            KestrelCommands(tabs: tabs, chat: chat, settings: settings, updater: updater)
        }

        Settings {
            SettingsView(settings: settings, mcpServer: mcpServer)
                .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
        }
    }
}

#else

import Foundation

@main
struct KestrelChromiumUnavailable {
    static func main() {
        print("Kestrel Chromium requires macOS and its bundled Chromium runtime.")
    }
}

#endif
