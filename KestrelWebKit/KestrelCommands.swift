#if canImport(SwiftUI) && canImport(CefSwiftUI)

import SwiftUI

/// The app's menu contributions. The Extensions menu is only built when the
/// setting is on: Kestrel never reaches into the global menu bar, it simply
/// chooses whether to contribute a command menu.
struct KestrelCommands: Commands {
    @ObservedObject var tabs: TabStore
    @ObservedObject var chat: AIChatStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: KestrelUpdater
    @ObservedObject private var extensionCatalogue = ChromiumInstalledExtensions.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Kestrel") { KestrelBranding.showAboutPanel() }
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(after: .newItem) {
            Button("New Tab") {
                withAnimation(.snappy(duration: 0.20)) { tabs.newTabCommand() }
            }
            .help("Open the New Tab dashboard for a website, search or AI question")
            .kestrelShortcut(.newTab, settings: settings)
            Button("Close Tab") {
                withAnimation(.snappy(duration: 0.20)) { tabs.closeSelectedTab() }
            }
            .help("Close the selected tab")
            .kestrelShortcut(.closeTab, settings: settings)
            Button("Reopen Closed Tab") {
                withAnimation(.snappy(duration: 0.20)) { tabs.reopenClosedTab() }
            }
            .help("Restore the most recently closed tab")
            .kestrelShortcut(.reopenTab, settings: settings)
            .disabled(tabs.recentlyClosedTabs.isEmpty)
        }

        CommandMenu("Tabs") {
            Button("Next Tab") { tabs.selectNext() }
                .help("Select the next tab")
                .kestrelShortcut(.nextTab, settings: settings)
            Button("Previous Tab") { tabs.selectPrevious() }
                .help("Select the previous tab")
                .kestrelShortcut(.previousTab, settings: settings)
            ForEach(1...9, id: \.self) { index in
                Button(index == 9 ? "Last Tab" : "Select Tab \(index)") {
                    if index == 9 {
                        tabs.selectLastTab()
                    } else {
                        tabs.selectTab(atOneBasedIndex: index)
                    }
                }
                .help(index == 9 ? "Select the last tab" : "Select tab \(index)")
                .kestrelShortcut(BrowserCommand(rawValue: "tab\(index)")!, settings: settings)
                .disabled(tabs.tabs.count < (index == 9 ? 1 : index))
            }
            Divider()
            Button(tabs.isSidebarVisible ? "Hide Tab Sidebar" : "Show Tab Sidebar") {
                withAnimation(.snappy(duration: 0.22)) { tabs.isSidebarVisible.toggle() }
            }
            .help(tabs.isSidebarVisible ? "Hide the tab list" : "Show the tab list")
            // ⌘S belongs to the browser's Save Page action. Keep the
            // Kestrel-only sidebar toggle on a chord Chrome does not use.
            .kestrelShortcut(.toggleSidebar, settings: settings)
            Button("Move Tab to Left Split") { splitAction(on: .left) }
                .help("Place the selected tab in the left side of a split view")
                .kestrelShortcut(.splitLeft, settings: settings)
            Button("Move Tab to Right Split") { splitAction(on: .right) }
                .help("Place the selected tab in the right side of a split view")
                .kestrelShortcut(.splitRight, settings: settings)
            Button("Separate Split View") {
                tabs.separateSplit(containing: tabs.selectedID)
            }
            .help("Turn the selected pane back into a regular tab")
            .kestrelShortcut(.separateSplit, settings: settings)
            .disabled(tabs.split == nil)
            Button("Equal Split Widths") { tabs.resizeSplit(to: 0.5) }
                .help("Give both split-view panes equal width")
                .kestrelShortcut(.equalSplit, settings: settings)
                .disabled(tabs.split == nil)
        }

        CommandMenu("Navigate") {
            Button("Focus Address Bar") { tabs.requestAddressFieldFocus() }
                .help("Move the keyboard focus to the address and search field")
                .kestrelShortcut(.focusAddress, settings: settings)
            Button("Find on Page") { tabs.requestFindInPage() }
                .help("Find text in the current web page")
                .kestrelShortcut(.find, settings: settings)
                .disabled(tabs.isAssistantTab(tabs.selectedID) || tabs.selectedTabHasNoPage)
            Button("Reload Page") { tabs.selectedBrowser.reload() }
                .help("Reload the current web page")
                .kestrelShortcut(.reload, settings: settings)
                .disabled(tabs.isAssistantTab(tabs.selectedID) || tabs.selectedTabHasNoPage)
            Button("Go Back") { tabs.selectedBrowser.goBack() }
                .kestrelShortcut(.back, settings: settings)
                .help("Return to the previous page in this tab")
                .disabled(!tabs.selectedBrowser.canGoBack)
            Button("Go Forward") { tabs.selectedBrowser.goForward() }
                .kestrelShortcut(.forward, settings: settings)
                .help("Move to the next page in this tab")
                .disabled(!tabs.selectedBrowser.canGoForward)
            Divider()
            Button("Zoom In") { tabs.selectedBrowser.changePageZoom(by: 0.1) }
                .help("Make the current web page larger")
                .kestrelShortcut(.zoomIn, settings: settings)
            Button("Zoom Out") { tabs.selectedBrowser.changePageZoom(by: -0.1) }
                .help("Make the current web page smaller")
                .kestrelShortcut(.zoomOut, settings: settings)
            Button("Actual Size") { tabs.selectedBrowser.resetPageZoom() }
                .help("Reset the current web page to its default size")
                .kestrelShortcut(.actualSize, settings: settings)
        }

        CommandGroup(after: .newItem) {
            // Explicitly opens the current page outside Kestrel. Chromium
            // handles WebAuthn in-app; the command remains available as a
            // user-controlled fallback for sites or authenticators that fail.
            Button("Open Page in Default Browser") {
                _ = tabs.openSelectedPageInDefaultBrowser()
            }
            .kestrelShortcut(.openDefaultBrowser, settings: settings)
            .disabled(tabs.pageURL(for: tabs.selectedID) == nil)
            .help("Open this page in your default browser, where macOS Passwords and passkeys are available.")
        }

        CommandMenu("Assistant") {
            Button(chat.isSidebarVisible ? "Hide Assistant" : "Show Assistant") {
                withAnimation(.snappy(duration: 0.22)) { AssistantChatLauncher.toggle(tabs: tabs, chat: chat) }
            }
            .help(chat.isSidebarVisible ? "Hide the Assistant sidebar beside the current page" : "Show the Assistant sidebar beside the current page")
            .kestrelShortcut(.assistant, settings: settings)

            Button("Open Assistant Page") {
                withAnimation(.snappy(duration: 0.22)) {
                    AssistantChatLauncher.showCurrent(tabs: tabs, chat: chat)
                }
            }
            .help("Open the Assistant as a full page")
            .kestrelShortcut(.assistantPage, settings: settings)

            Button("Clear Conversation") { chat.clearConversation() }
                .help("Remove the messages from the current conversation")
                .kestrelShortcut(.clearConversation, settings: settings)
                .disabled(chat.items.isEmpty)
        }

        // Chats live in their own menu rather than inside Assistant. Larger
        // archives are grouped into small recency submenus so the menu remains
        // quick to scan without hiding any saved conversation.
        CommandMenu("Chats") {
            AssistantChatMenuItems(chat: chat) { conversationID in
                withAnimation(.snappy(duration: 0.22)) {
                    AssistantChatLauncher.open(conversationID, tabs: tabs, chat: chat)
                }
            }
        }

        CommandMenu("Chromium") {
            Button("Site Permissions & Browser Settings…") {
                _ = tabs.openChromiumPage("chrome://settings/content")
            }
            Button("Browsing History…") {
                _ = tabs.openChromiumPage("chrome://history")
            }
            Button("Downloads…") {
                _ = tabs.openChromiumPage("chrome://downloads")
            }
        }

        if settings.extensions.menuBarVisible {
            CommandMenu("Extensions") {
                ForEach(extensionCatalogue.actions) { item in
                    Button(item.name) { tabs.showExtensionAction(item.id) }
                        .disabled(!tabs.canShowExtensionActions(for: tabs.selectedID))
                }
                if !extensionCatalogue.actions.isEmpty { Divider() }
                Button("Show Extensions") { tabs.showExtensionMenu(for: tabs.selectedID) }
                    .disabled(!tabs.canShowExtensionActions(for: tabs.selectedID))
                Button("Manage Extensions…") { tabs.openChromiumExtensions() }
                Button("Get Extensions…") { _ = tabs.newTab(urlString: "https://chromewebstore.google.com/category/extensions") }
                    .help("Open Chromium's extension manager")
                Text("Import packages in Kestrel Settings → Extensions")
            }
        }
    }

    private func splitAction(on side: BrowserSplitSide) {
        withAnimation(.snappy(duration: 0.24)) {
            let query = tabs.newTabSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if tabs.isNewTabSearchPresented, !query.isEmpty {
                settings.recordSearch(query)
                _ = tabs.openSearchInSplit(query, on: side)
            } else {
                tabs.placeSelectedTab(on: side)
            }
        }
    }
}

#endif
