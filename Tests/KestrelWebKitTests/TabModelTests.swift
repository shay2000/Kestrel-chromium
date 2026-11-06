import XCTest
#if canImport(AppKit)
import AppKit
#endif

@testable import KestrelWebKit

final class TabModelTests: XCTestCase {
    func testSplitRailCombinesMembersInVisualPaneOrderWithoutDuplicateRows() {
        let left = BrowserTab(title: "Left")
        let other = BrowserTab(title: "Other")
        let right = BrowserTab(title: "Right")
        let split = BrowserSplit(leftTabID: left.id, rightTabID: right.id)
        XCTAssertEqual(BrowserTabRailItem.items(tabs: [right, other, left], splits: [split]),
                       [.split(split), .tab(other)])
    }

    func testSplitRailKeepsPinnedPairReachableWithoutAddingUnpairedPins() {
        let left = BrowserTab(title: "Pinned left", isPinned: true)
        let right = BrowserTab(title: "Pinned right", isPinned: true)
        let unrelated = BrowserTab(title: "Pin", isPinned: true)
        let split = BrowserSplit(leftTabID: left.id, rightTabID: right.id)
        XCTAssertEqual(BrowserTabRailItem.items(tabs: [left, unrelated, right], splits: [split]), [.split(split)])
    }

    func testSplitResizeBoundsBothPanesAndHandlesNarrowWindows() {
        var split = BrowserSplit(leftTabID: UUID(), rightTabID: UUID())
        split.resize(to: 0.7)
        XCTAssertEqual(split.leadingWidth(availableWidth: 1_000), 700)
        XCTAssertEqual(split.leadingWidth(availableWidth: 600), 320)
        XCTAssertEqual(split.leadingWidth(availableWidth: 400), 200)
        split.resize(to: .infinity)
        XCTAssertEqual(split.leadingFraction, 0.7)
        split.resize(to: 10)
        XCTAssertEqual(split.leadingFraction, 0.8)
        split.resize(to: -10)
        XCTAssertEqual(split.leadingFraction, 0.2)
        XCTAssertEqual(split.leadingWidth(availableWidth: -1), 0)
    }

    func testEmptyCollectionHasNoSelection() {
        let collection = TabCollection()
        XCTAssertTrue(collection.isEmpty)
        XCTAssertNil(collection.selectedID)
    }

    func testFirstAddedTabIsSelected() {
        var collection = TabCollection()
        let tab = collection.addTab(BrowserTab(title: "One"))
        XCTAssertEqual(collection.selectedID, tab.id)
        XCTAssertEqual(collection.tabs.count, 1)
    }

    func testClosingSelectedTabSelectsNeighbour() {
        var collection = TabCollection()
        let first = collection.addTab(BrowserTab(title: "One"))
        let second = collection.addTab(BrowserTab(title: "Two"))
        let third = collection.addTab(BrowserTab(title: "Three"))

        collection.select(id: second.id)
        collection.close(id: second.id)
        XCTAssertEqual(collection.selectedID, third.id)
        XCTAssertEqual(collection.tabs.count, 2)
        XCTAssertFalse(collection.tabs.contains { $0.id == second.id })
        XCTAssertNotEqual(first.id, second.id)
    }

    func testClosingLastTabLeavesEmptyCollection() {
        var collection = TabCollection()
        let tab = collection.addTab(BrowserTab(title: "Only"))
        collection.close(id: tab.id)
        XCTAssertTrue(collection.isEmpty)
        XCTAssertNil(collection.selectedID)
    }

    func testPinnedTabsSortToTheFront() {
        var collection = TabCollection()
        let first = collection.addTab(BrowserTab(title: "One"))
        let second = collection.addTab(BrowserTab(title: "Two"))
        collection.setPinned(true, for: second.id)
        XCTAssertEqual(collection.tabs.first?.id, second.id)
        XCTAssertEqual(collection.pinnedTabs.count, 1)
        XCTAssertEqual(collection.unpinnedTabs.first?.id, first.id)
    }

    func testSelectNextWraps() {
        var collection = TabCollection()
        let first = collection.addTab(BrowserTab(title: "One"))
        let second = collection.addTab(BrowserTab(title: "Two"))
        collection.select(id: second.id)
        collection.selectNext()
        XCTAssertEqual(collection.selectedID, first.id)
    }

    func testUpdateChangesTitleAndURL() {
        var collection = TabCollection()
        let tab = collection.addTab(BrowserTab())
        collection.update(
            id: tab.id,
            title: "Loaded",
            urlString: "https://example.com",
            faviconURL: "https://example.com/favicon.ico"
        )
        XCTAssertEqual(collection.tabs.first?.title, "Loaded")
        XCTAssertEqual(collection.tabs.first?.urlString, "https://example.com")
        XCTAssertEqual(collection.tabs.first?.faviconURL, "https://example.com/favicon.ico")
    }

    func testNavigationCanClearStaleFavicon() {
        var collection = TabCollection()
        let tab = collection.addTab(BrowserTab(faviconURL: "https://example.com/favicon.ico"))

        collection.update(id: tab.id, title: "New page", urlString: "https://other.example", faviconURL: nil)

        XCTAssertNil(collection.tabs.first?.faviconURL)
    }

    func testDisplayTitleFallsBackForBlanks() {
        XCTAssertEqual(BrowserTab(title: "   ").displayTitle, "New Tab")
        XCTAssertEqual(BrowserTab(title: "").displayTitle, "New Tab")
    }

    /// An assistant tab has no host, so the rail's second line has to say what
    /// the row is rather than going blank under the title.
    func testAssistantTabNamesItselfInTheRail() {
        let assistant = BrowserTab(title: "Falcon Heavy", isAssistant: true)
        XCTAssertEqual(assistant.detailLabel, "Assistant")
        XCTAssertEqual(assistant.hostLabel, "")
        XCTAssertEqual(
            BrowserTab(title: "Example", urlString: "https://example.com/x").detailLabel,
            "example.com"
        )
    }

    /// Turning the empty new tab into the assistant page keeps the row where it
    /// is. Adding a tab instead would leave a blank one behind beside every chat
    /// started from the new tab page.
    func testMakingATabAssistantKeepsItsPlaceAndClearsItsPage() {
        var collection = TabCollection()
        let first = collection.addTab(BrowserTab(title: "One", urlString: "https://one.example"))
        let second = collection.addTab(BrowserTab(
            title: "Two",
            urlString: "https://two.example",
            faviconURL: "https://two.example/favicon.ico"
        ))

        collection.makeAssistant(id: second.id)

        XCTAssertEqual(collection.tabs.map(\.id), [first.id, second.id])
        XCTAssertEqual(collection.selectedID, second.id)
        XCTAssertEqual(collection.tabs.last?.title, "Assistant")
        XCTAssertEqual(collection.tabs.last?.urlString, "")
        XCTAssertNil(collection.tabs.last?.faviconURL)
        XCTAssertTrue(collection.tabs.last?.isAssistant ?? false)
        XCTAssertFalse(collection.tabs.first?.isAssistant ?? true)
    }

    func testMakingAnUnknownTabAssistantChangesNothing() {
        var collection = TabCollection()
        collection.addTab(BrowserTab(title: "One", urlString: "https://one.example"))

        collection.makeAssistant(id: UUID())

        XCTAssertEqual(collection.tabs.count, 1)
        XCTAssertFalse(collection.tabs[0].isAssistant)
    }

    /// macOS truncates a menu item wherever the row runs out, which can be past
    /// the words that tell two chats apart. The cut is made deliberately so the
    /// distinguishing part stays visible and the ellipsis is not preceded by the
    /// space it landed on.
    func testChatMenuTitlesAreCutDeliberately() {
        XCTAssertEqual(AssistantConversation.menuTitle(for: "   "), "Untitled chat")
        XCTAssertEqual(AssistantConversation.menuTitle(for: "Falcon Heavy"), "Falcon Heavy")

        let long = String(repeating: "a", count: 60)
        let cut = AssistantConversation.menuTitle(for: long)
        XCTAssertEqual(cut.count, 49)
        XCTAssertTrue(cut.hasSuffix("…"))

        XCTAssertEqual(
            AssistantConversation.menuTitle(for: "alpha beta gamma delta", maximumLength: 11),
            "alpha beta…"
        )
    }

    func testSavedChatsAreGroupedIntoBoundedMenuSections() {
        XCTAssertEqual(AssistantChatMenuLayout.groups(for: 0), [])
        XCTAssertEqual(AssistantChatMenuLayout.groups(for: 5), [0..<5])
        XCTAssertEqual(AssistantChatMenuLayout.groups(for: 6), [0..<5, 5..<6])
        XCTAssertEqual(AssistantChatMenuLayout.groups(for: 30), [0..<5, 5..<10, 10..<15, 15..<20, 20..<25, 25..<30])
        XCTAssertTrue(AssistantChatMenuLayout.groups(for: 30).allSatisfy { $0.count <= 5 })
        XCTAssertEqual(AssistantChatMenuLayout.title(forGroup: 0, range: 0..<5), "Recent Chats")
        XCTAssertEqual(AssistantChatMenuLayout.title(forGroup: 1, range: 5..<10), "Earlier Chats")
        XCTAssertEqual(AssistantChatMenuLayout.title(forGroup: 2, range: 10..<15), "Chats 11–15")
    }

    func testSplitPlacesAnUnshownTabInTargetPane() {
        let left = UUID()
        let right = UUID()
        let incoming = UUID()
        var split = BrowserSplit(leftTabID: left, rightTabID: right)

        split.place(incoming, on: .left)

        XCTAssertEqual(split.leftTabID, incoming)
        XCTAssertEqual(split.rightTabID, right)
        XCTAssertEqual(split.side(containing: incoming), .left)
    }

    func testSplitSwapsInsteadOfDuplicatingTheOppositePaneTab() {
        let left = UUID()
        let right = UUID()
        var split = BrowserSplit(leftTabID: left, rightTabID: right)

        split.place(right, on: .left)

        XCTAssertEqual(split.leftTabID, right)
        XCTAssertEqual(split.rightTabID, left)
        XCTAssertNotEqual(split.leftTabID, split.rightTabID)
    }

    func testBookmarkWithoutStoredFaviconUsesItsOwnOriginAndHidesWWW() throws {
        let bookmark = BrowserBookmark(title: "  ", urlString: "https://www.example.com/article")
        XCTAssertEqual(bookmark.displayTitle, "example.com")
        XCTAssertEqual(try XCTUnwrap(bookmark.faviconSourceURL).absoluteString, "https://www.example.com/favicon.ico")
    }

    func testBookmarkFaviconRejectsUnsafeURLAndFallsBackToBookmarkOrigin() throws {
        let bookmark = BrowserBookmark(
            title: "Example",
            urlString: "https://example.com/article",
            faviconURL: "javascript:alert(1)"
        )
        XCTAssertEqual(try XCTUnwrap(bookmark.faviconSourceURL).absoluteString, "https://example.com/favicon.ico")
    }

    func testImportsChromeBookmarksJSONAndSkipsUnsafeOrDuplicateURLs() throws {
        let json = #"{"roots":{"bookmark_bar":{"children":[{"type":"url","name":"Search","url":"https://example.com/"},{"type":"folder","children":[{"type":"url","name":"Duplicate","url":"https://EXAMPLE.com/#top"},{"type":"url","name":"Unsafe","url":"javascript:alert(1)"}] }]},"other":{"children":[{"type":"url","name":"Kestrel","url":"https://kestrel.example/"}]}}}"#
        let bookmarks = try BrowserBookmarkImporter.parse(data: Data(json.utf8), filename: "Bookmarks")

        XCTAssertEqual(bookmarks.map(\.displayTitle), ["Search", "Kestrel"])
        XCTAssertEqual(bookmarks.first?.urlString, "https://example.com/")
    }

    func testImportsSafariBookmarkPropertyList() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [[
                "WebBookmarkType": "WebBookmarkTypeLeaf",
                "Title": "Apple",
                "URLString": "https://www.apple.com/"
            ]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let bookmarks = try BrowserBookmarkImporter.parse(data: data, filename: "Bookmarks.plist")

        XCTAssertEqual(bookmarks.map(\.displayTitle), ["Apple"])
        XCTAssertEqual(bookmarks.first?.urlString, "https://www.apple.com/")
    }

    func testImportsNetscapeBookmarkHTMLAndDecodesEntities() throws {
        let html = #"<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF="https://example.com/?a=1&amp;b=2">A &amp; B</A></DL>"#
        let bookmarks = try BrowserBookmarkImporter.parse(data: Data(html.utf8), filename: "bookmarks.html")

        XCTAssertEqual(bookmarks.map(\.displayTitle), ["A & B"])
        XCTAssertEqual(bookmarks.first?.urlString, "https://example.com/?a=1&b=2")
    }

    func testRejectsOversizedBrowserBookmarkFiles() {
        let data = Data(repeating: 0, count: BrowserBookmarkImporter.maximumFileBytes + 1)
        XCTAssertThrowsError(try BrowserBookmarkImporter.parse(data: data, filename: "Bookmarks"))
    }

#if canImport(SwiftUI) && canImport(WebKit) && !canImport(CefSwiftUI)
    @MainActor
    func testNewTabShortcutCanToggleItsOverlayClosed() {
        let tabs = TabStore(initialAddress: "https://example.com")
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        tabs.toggleNewTabSearch()
        XCTAssertTrue(tabs.isNewTabSearchPresented)
        tabs.toggleNewTabSearch()
        XCTAssertFalse(tabs.isNewTabSearchPresented)
    }

    @MainActor
    func testTabWithNoPageIsReportedAsHavingNoPage() {
        XCTAssertTrue(TabStore(initialAddress: "").selectedTabHasNoPage)
        XCTAssertTrue(TabStore(initialAddress: "   ").selectedTabHasNoPage)
        XCTAssertFalse(TabStore(initialAddress: "https://example.com").selectedTabHasNoPage)
    }

    @MainActor
    func testBlankLaunchAlwaysShowsTheNewTabDashboard() {
        let tabs = TabStore()
        XCTAssertFalse(tabs.isAssistantTab(tabs.selectedID))
        XCTAssertTrue(tabs.selectedTabHasNoPage)
        XCTAssertTrue(tabs.isNewTabSearchPresented)
    }

    @MainActor
    func testIncomingURLDismissesDashboardBeforeSplitting() throws {
        let tabs = TabStore()
        tabs.newTabSearchQuery = "unfinished search"
        tabs.open(url: try XCTUnwrap(URL(string: "https://example.com")))
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        XCTAssertFalse(tabs.selectedTabHasNoPage)
        XCTAssertEqual(tabs.newTabSearchQuery, "")

        tabs.placeSelectedTab(on: .left)
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        tabs.focusSplitPane(.right)
        XCTAssertTrue(tabs.selectedTabHasNoPage)
        tabs.open(url: try XCTUnwrap(URL(string: "https://example.org")))
        tabs.focusSplitPane(.left)
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        tabs.focusSplitPane(.right)
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        XCTAssertFalse(tabs.selectedTabHasNoPage)
    }

    @MainActor
    func testFloatingSearchDoesNotFollowSplitFocusOrTabSelection() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        let left = tabs.selectedID
        let right = tabs.newTab(urlString: "about:blank", select: false)
        tabs.pairTabs(left: left, right: right)
        tabs.presentNewTabSearch()
        tabs.newTabSearchQuery = "left draft"
        tabs.focusSplitPane(.right)
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        XCTAssertEqual(tabs.newTabSearchQuery, "")

        tabs.presentNewTabSearch()
        tabs.selectPrevious()
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        tabs.presentNewTabSearch()
        tabs.selectNext()
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        tabs.presentNewTabSearch()
        tabs.select(id: left)
        XCTAssertFalse(tabs.isNewTabSearchPresented)
    }

    @MainActor
    func testFloatingSearchSurvivesMetadataAndBackgroundTabChanges() {
        let tabs = TabStore(initialAddress: "about:blank")
        tabs.presentNewTabSearch()
        tabs.newTabSearchQuery = "keep this draft"
        tabs.setTitle("Updated title", for: tabs.selectedID)
        _ = tabs.newTab(urlString: "about:blank", select: false)
        tabs.select(id: tabs.selectedID)
        XCTAssertTrue(tabs.isNewTabSearchPresented)
        XCTAssertEqual(tabs.newTabSearchQuery, "keep this draft")
    }

    /// The bug this covers: ⌘T used to toggle unconditionally, so pressing it on
    /// the new tab page dismissed the only thing on screen and left an empty
    /// pane. On a tab with no page the command must only ever present.
    @MainActor
    func testNewTabCommandNeverLeavesAPagelessTabEmpty() {
        let tabs = TabStore(initialAddress: "")
        XCTAssertTrue(tabs.selectedTabHasNoPage)

        for _ in 0..<4 {
            tabs.newTabCommand()
            XCTAssertTrue(tabs.isNewTabSearchPresented)
        }
    }

    /// It still clears the field, so a second ⌘T on the new tab page gives the
    /// user a fresh search rather than repeating the last one.
    @MainActor
    func testNewTabCommandClearsTheQueryOnAPagelessTab() {
        let tabs = TabStore(initialAddress: "")
        tabs.newTabSearchQuery = "leftover"
        tabs.newTabCommand()
        XCTAssertEqual(tabs.newTabSearchQuery, "")
        XCTAssertTrue(tabs.isNewTabSearchPresented)
    }

    /// Over a real page the shortcut keeps its long-standing toggle, because
    /// dismissing reveals the page underneath.
    @MainActor
    func testNewTabCommandStillTogglesOverARealPage() {
        let tabs = TabStore(initialAddress: "https://example.com")
        tabs.newTabCommand()
        XCTAssertTrue(tabs.isNewTabSearchPresented)
        tabs.newTabCommand()
        XCTAssertFalse(tabs.isNewTabSearchPresented)
    }

    @MainActor
    func testRailNewTabActionCreatesAndSelectsDashboard() {
        let tabs = TabStore(initialAddress: "https://example.com")
        let originalID = tabs.selectedID

        let dashboardID = tabs.openNewTabDashboard()

        XCTAssertNotEqual(dashboardID, originalID)
        XCTAssertEqual(tabs.selectedID, dashboardID)
        XCTAssertTrue(tabs.selectedTabHasNoPage)
        XCTAssertTrue(tabs.isNewTabSearchPresented)
        XCTAssertEqual(tabs.tabs.count, 2)
    }

    /// A new tab created by any route — the "+" button, a link, a bookmark —
    /// has no page, so the field is shown without anything having to remember
    /// to set a flag.
    @MainActor
    func testFreshlyCreatedTabHasNoPage() {
        let tabs = TabStore(initialAddress: "https://example.com")
        tabs.dismissNewTabSearch()
        let id = tabs.newTab()
        XCTAssertEqual(tabs.selectedID, id)
        XCTAssertTrue(tabs.selectedTabHasNoPage)
    }

    @MainActor
    func testFirstSplitKeepsCurrentTabOnRequestedSideAndCreatesOtherPane() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        let currentID = tabs.selectedID

        tabs.placeSelectedTab(on: .left)

        let split = try XCTUnwrap(tabs.split)
        XCTAssertEqual(split.leftTabID, currentID)
        XCTAssertNotEqual(split.rightTabID, currentID)
        XCTAssertEqual(tabs.selectedID, currentID)
        XCTAssertEqual(tabs.tabs.count, 2)
    }

    @MainActor
    func testSearchFromNewTabFieldOpensQueryInRequestedPaneAndKeepsCurrentPageOpposite() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        let currentID = tabs.selectedID
        let query = "Falcon Heavy"
        tabs.presentNewTabSearch()
        tabs.newTabSearchQuery = query

        let searchID = try XCTUnwrap(tabs.openSearchInSplit(query, on: .left))
        var split = try XCTUnwrap(tabs.split)
        XCTAssertEqual(split.leftTabID, searchID)
        XCTAssertEqual(split.rightTabID, currentID)
        XCTAssertEqual(tabs.selectedID, searchID)
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        XCTAssertEqual(
            tabs.browser(for: searchID).addressText,
            try XCTUnwrap(SearchEngine.google.searchURL(for: query)).absoluteString
        )

        let replacementQuery = "Falcon Heavy launch"
        tabs.presentNewTabSearch()
        tabs.newTabSearchQuery = replacementQuery
        let replacementID = try XCTUnwrap(tabs.openSearchInSplit(replacementQuery, on: .left))
        split = try XCTUnwrap(tabs.split)
        XCTAssertEqual(split.leftTabID, replacementID)
        XCTAssertEqual(split.rightTabID, currentID)
        XCTAssertEqual(tabs.selectedID, replacementID)
        XCTAssertEqual(
            tabs.browser(for: replacementID).addressText,
            try XCTUnwrap(SearchEngine.google.searchURL(for: replacementQuery)).absoluteString
        )
    }

    @MainActor
    func testFocusingSplitPaneUpdatesTheActiveTabAndClosingItExitsSplit() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        let leftID = tabs.selectedID
        tabs.placeSelectedTab(on: .left)
        let rightID = try XCTUnwrap(tabs.split?.rightTabID)

        tabs.focusSplitPane(.right)
        XCTAssertEqual(tabs.selectedID, rightID)

        tabs.closeTab(id: rightID)
        XCTAssertNil(tabs.split)
        XCTAssertEqual(tabs.selectedID, leftID)
    }

    @MainActor
    func testSplitSurvivesTabSwitchingWithItsWidthAndLivePages() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        let left = tabs.selectedID
        let leftView = tabs.selectedWebView
        tabs.placeSelectedTab(on: .left)
        let right = try XCTUnwrap(tabs.split?.rightTabID)
        let rightView = tabs.webView(for: right)
        tabs.resizeSplit(to: 0.65)
        let pair = try XCTUnwrap(tabs.split)
        let other = tabs.newTab(urlString: "about:blank")
        XCTAssertNil(tabs.split)
        XCTAssertEqual(tabs.splits, [pair])
        tabs.select(id: right)
        XCTAssertEqual(tabs.split, pair)
        XCTAssertTrue(tabs.webView(for: left) === leftView)
        XCTAssertTrue(tabs.selectedWebView === rightView)
        tabs.select(id: other)
        tabs.selectPrevious()
        XCTAssertEqual(tabs.split, pair)
    }

    @MainActor
    func testSeparatingSplitRetainsBothPagesAndSelection() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        let left = tabs.selectedID
        tabs.placeSelectedTab(on: .left)
        let right = try XCTUnwrap(tabs.split?.rightTabID)
        tabs.select(id: right)
        tabs.separateSplit(containing: left)
        XCTAssertNil(tabs.split)
        XCTAssertTrue(tabs.splits.isEmpty)
        XCTAssertEqual(tabs.selectedID, right)
        XCTAssertEqual(Set(tabs.tabs.map(\.id)), Set([left, right]))
    }

    @MainActor
    func testClosingBackgroundSplitMemberDoesNotSelectItsSibling() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        let left = tabs.selectedID
        tabs.placeSelectedTab(on: .left)
        let right = try XCTUnwrap(tabs.split?.rightTabID)
        let other = tabs.newTab(urlString: "about:blank")
        tabs.closeTab(id: left)
        XCTAssertEqual(tabs.selectedID, other)
        XCTAssertTrue(tabs.splits.isEmpty)
        XCTAssertTrue(tabs.tabs.contains { $0.id == right })
    }

    @MainActor
    func testPairingExistingTabsRemovesConflictingGroups() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        let first = tabs.selectedID
        tabs.placeSelectedTab(on: .left)
        let displaced = try XCTUnwrap(tabs.split?.rightTabID)
        let second = tabs.newTab(urlString: "about:blank")
        tabs.placeSelectedTab(on: .left)
        XCTAssertEqual(tabs.splits.count, 2)
        tabs.pairTabs(left: first, right: second)
        XCTAssertEqual(tabs.splits.count, 1)
        XCTAssertEqual(tabs.split?.leftTabID, first)
        XCTAssertEqual(tabs.split?.rightTabID, second)
        XCTAssertTrue(tabs.tabs.contains { $0.id == displaced })
        tabs.pairTabs(left: first, right: first)
        XCTAssertNotNil(tabs.split)
    }

    @MainActor
    func testSubmittingBlankSplitPaneFillsItWithoutBreakingPair() throws {
        let tabs = TabStore(initialAddress: "about:blank")
        tabs.placeSelectedTab(on: .left)
        let pair = try XCTUnwrap(tabs.split)
        tabs.focusSplitPane(.right)
        XCTAssertTrue(tabs.selectedTabHasNoPage)
        XCTAssertEqual(tabs.openNewTabSearch("https://example.com"), pair.rightTabID)
        XCTAssertEqual(tabs.split, pair)
        XCTAssertEqual(tabs.tabs.count, 2)
        XCTAssertEqual(tabs.selectedBrowser.addressText, "https://example.com")
    }

    @MainActor
    func testClosingTabRequestsMediaPauseBeforeReleasingItsWebView() {
        var didRequestMediaPause = false
        let tabs = TabStore(initialAddress: "about:blank", pauseMediaPlayback: { _ in
            didRequestMediaPause = true
        })
        let closingTabID = tabs.selectedID
        _ = tabs.selectedWebView

        tabs.closeTab(id: closingTabID)

        XCTAssertTrue(didRequestMediaPause)
        XCTAssertFalse(tabs.tabs.contains { $0.id == closingTabID })
    }

    @MainActor
    func testAssistantControlKeepsWebPageAndDraftWhenTogglingSidebar() {
        let tabs = TabStore(initialAddress: "https://example.com")
        let chat = AIChatStore()
        chat.input = "Explain this section"
        let pageID = tabs.selectedID
        tabs.presentNewTabSearch()

        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
        XCTAssertEqual(tabs.selectedID, pageID)
        XCTAssertNil(tabs.assistantTabID)
        XCTAssertTrue(chat.isSidebarVisible)
        XCTAssertFalse(tabs.isNewTabSearchPresented)
        XCTAssertEqual(chat.input, "Explain this section")

        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
        XCTAssertFalse(chat.isSidebarVisible)
        XCTAssertEqual(chat.input, "Explain this section")
    }

    @MainActor
    func testAssistantControlOnEmptyTabKeepsConversationDraftAndReusesTab() {
        let tabs = TabStore(initialAddress: "")
        let chat = AIChatStore()
        chat.input = "Unsent question"
        chat.isSidebarVisible = true
        let originalID = tabs.selectedID

        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
        XCTAssertTrue(tabs.isAssistantTab(originalID))
        XCTAssertEqual(tabs.tabs.count, 1)
        XCTAssertFalse(chat.isSidebarVisible)
        XCTAssertEqual(chat.input, "Unsent question")
        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
        XCTAssertEqual(tabs.tabs.count, 1)
        XCTAssertEqual(chat.input, "Unsent question")
    }

    @MainActor
    func testNewChatDismissesRetainedSearchOverlayAndSidebar() {
        let tabs = TabStore(initialAddress: "")
        let chat = AIChatStore()
        chat.input = "Old draft"
        chat.isSidebarVisible = true
        tabs.presentNewTabSearch()
        tabs.newTabSearchQuery = "Old search question"

        AssistantChatLauncher.open(nil, tabs: tabs, chat: chat)

        XCTAssertFalse(tabs.isNewTabSearchPresented)
        XCTAssertTrue(tabs.newTabSearchQuery.isEmpty)
        XCTAssertFalse(chat.isSidebarVisible)
        XCTAssertTrue(tabs.isAssistantTab(tabs.selectedID))
        XCTAssertTrue(chat.input.isEmpty)
        XCTAssertTrue(chat.items.isEmpty)
    }

    @MainActor
    func testAttachedDraftSurvivesSidebarAndPageTransitionsUntilNewChat() {
        let tabs = TabStore(initialAddress: "https://example.com")
        let chat = AIChatStore()
        let file = NewTabAttachment(kind: .file, label: "notes.txt", origin: "notes.txt", text: "Draft context")
        chat.input = "Explain these notes"
        chat.draftAttachments = [file]
        let pageID = tabs.selectedID

        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
        XCTAssertEqual(chat.draftAttachments, [file])
        AssistantChatLauncher.showCurrent(tabs: tabs, chat: chat)
        XCTAssertTrue(tabs.isAssistantTab(tabs.selectedID))
        XCTAssertEqual(chat.draftAttachments, [file])
        XCTAssertEqual(chat.input, "Explain these notes")
        tabs.select(id: pageID)
        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
        XCTAssertEqual(chat.draftAttachments, [file])

        chat.draftAttachmentError = "A previous file could not be read"
        AssistantChatLauncher.open(nil, tabs: tabs, chat: chat)
        XCTAssertTrue(chat.draftAttachments.isEmpty)
        XCTAssertTrue(chat.input.isEmpty)
        XCTAssertNil(chat.draftAttachmentError)
    }

    @MainActor
    func testOpeningSavedChatClearsUnsentAttachmentDraftWithoutArchivingIt() throws {
        let chat = AIChatStore()
        let saved = AssistantConversation(title: "Saved chat", messages: [AIMessage(role: .user, text: "Saved question")])
        var written: [AssistantConversation] = [saved]
        chat.savedConversationsProvider = { written }
        chat.savedConversationsWriter = { written = $0 }
        chat.loadSavedConversations()
        chat.input = "Unsent question"
        chat.draftAttachments = [NewTabAttachment(kind: .file, label: "notes.txt", origin: "notes.txt", text: "Unsent file contents")]
        chat.draftAttachmentError = "Draft error"

        chat.openConversation(saved.id)

        XCTAssertTrue(chat.input.isEmpty)
        XCTAssertTrue(chat.draftAttachments.isEmpty)
        XCTAssertNil(chat.draftAttachmentError)
        let archive = String(decoding: try JSONEncoder().encode(written), as: UTF8.self)
        XCTAssertFalse(archive.contains("Unsent file contents"))
        XCTAssertFalse(archive.contains("Unsent question"))
        XCTAssertEqual(chat.conversationTitle, "Saved chat")
    }

    // MARK: - The assistant page

    @MainActor
    func testHiddenScrollbarsRetainTheFullContentWidth() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 900))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.tile()
        let reservedWidth = scroll.contentView.bounds.width
        let host = NSView(frame: scroll.frame)
        host.addSubview(scroll)

        BrowserScrollbars.apply(to: host)
        scroll.tile()

        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertTrue(scroll.verticalScroller == nil || scroll.verticalScroller!.isHidden)
        XCTAssertTrue(scroll.horizontalScroller == nil || scroll.horizontalScroller!.isHidden)
        XCTAssertGreaterThan(scroll.contentView.bounds.width, reservedWidth)
        XCTAssertEqual(scroll.contentView.bounds.width, 240, accuracy: 1)
        XCTAssertEqual(scroll.documentView?.frame.height, 900)
    }

    /// On the new tab page there is nothing to keep, so the chat takes that tab
    /// over rather than adding a second one beside it.
    @MainActor
    func testOpeningTheAssistantPageOnAnEmptyTabReusesIt() {
        let tabs = TabStore(initialAddress: "")
        let originalID = tabs.selectedID

        let assistantID = tabs.openAssistantTab()

        XCTAssertEqual(assistantID, originalID)
        XCTAssertEqual(tabs.tabs.count, 1)
        XCTAssertTrue(tabs.isAssistantTab(originalID))
        XCTAssertEqual(tabs.selectedID, originalID)
    }

    /// Over a real page the chat needs its own tab, because the page is still
    /// there and still wants to be read.
    @MainActor
    func testOpeningTheAssistantPageOverAPageGetsItsOwnTab() {
        let tabs = TabStore(initialAddress: "https://example.com")
        let pageID = tabs.selectedID

        let assistantID = tabs.openAssistantTab()

        XCTAssertNotEqual(assistantID, pageID)
        XCTAssertEqual(tabs.tabs.count, 2)
        XCTAssertFalse(tabs.isAssistantTab(pageID))
        XCTAssertEqual(tabs.selectedID, assistantID)
        XCTAssertEqual(tabs.browser(for: pageID).addressText, "https://example.com")
    }

    /// The chat store holds one live transcript, so a second assistant tab would
    /// be a second view of the same conversation.
    @MainActor
    func testAskingForTheAssistantPageAgainBringsTheSameTabForward() {
        let tabs = TabStore(initialAddress: "https://example.com")
        let first = tabs.openAssistantTab()
        let second = tabs.openAssistantTab()

        XCTAssertEqual(first, second)
        XCTAssertEqual(tabs.tabs.filter(\.isAssistant).count, 1)
    }

    /// The assistant page has no address, but it is not a new tab page: the chat
    /// is what is on screen there. Reporting it otherwise drops the search field
    /// on top of the conversation.
    @MainActor
    func testAssistantPageIsNotReportedAsAPagelessTab() {
        let tabs = TabStore(initialAddress: "")
        tabs.openAssistantTab()

        XCTAssertFalse(tabs.selectedTabHasNoPage)
    }

    /// ⌘T on the assistant page has to produce a page. Toggling the overlay there
    /// would put a search field over the conversation, and the conversation has
    /// no address to search from.
    @MainActor
    func testNewTabCommandOnTheAssistantPageOpensARealTab() {
        let tabs = TabStore(initialAddress: "")
        tabs.openAssistantTab()

        tabs.newTabCommand()

        XCTAssertFalse(tabs.isAssistantTab(tabs.selectedID))
        XCTAssertTrue(tabs.selectedTabHasNoPage)
        XCTAssertTrue(tabs.isNewTabSearchPresented)
    }

    /// The assistant page is its own thing: it must not answer about, or search
    /// from, the site the user was last on. The sidebar beside a webpage still
    /// reads that page, because there the selected tab is the page itself.
    @MainActor
    func testAssistantPageDoesNotBorrowTheLastPage() {
        let tabs = TabStore(initialAddress: "https://example.com")
        let pageID = tabs.selectedID

        tabs.openAssistantTab()

        XCTAssertEqual(tabs.contextTabID, tabs.selectedID)
        XCTAssertNotEqual(tabs.contextTabID, pageID)
        XCTAssertNil(tabs.currentActionContext, "A chat page has no page of its own to read or search from")

        // Selecting a real page again restores that page as the context, which
        // is what keeps "ask about this page" working from the sidebar.
        tabs.select(id: pageID)
        XCTAssertEqual(tabs.currentActionContext?.pageURL, "https://example.com")
    }

    @MainActor
    func testAssistantPageWithNoPreviousPageHasNoContext() {
        let tabs = TabStore(initialAddress: "")
        tabs.openAssistantTab()

        XCTAssertEqual(tabs.contextTabID, tabs.selectedID)
        XCTAssertNil(tabs.currentActionContext)
    }

    /// Visiting a page and returning to the chat keeps the chat independent
    /// rather than silently attaching the site the user just left.
    @MainActor
    func testAssistantPageStaysIndependentAfterVisitingAnotherPage() {
        let tabs = TabStore(initialAddress: "https://first.example")
        tabs.openAssistantTab()
        _ = tabs.newTab(urlString: "https://second.example")

        tabs.select(id: tabs.assistantTabID ?? tabs.selectedID)

        XCTAssertNil(tabs.currentActionContext)
    }

    @MainActor
    func testClosingTheAssistantPageFallsBackToThePage() {
        let tabs = TabStore(initialAddress: "https://example.com")
        let pageID = tabs.selectedID
        let assistantID = tabs.openAssistantTab()

        tabs.closeTab(id: assistantID)

        XCTAssertEqual(tabs.selectedID, pageID)
        XCTAssertNil(tabs.assistantTabID)
        XCTAssertFalse(tabs.isAssistantTab(pageID))
    }

    /// The rail's own background reads the selected tab's page edges, which asks
    /// for a browser store. That store must not write back and relabel the chat's
    /// row "New Tab".
    @MainActor
    func testAssistantTabTitleSurvivesAStoreBeingBuiltForIt() {
        let tabs = TabStore(initialAddress: "")
        let id = tabs.openAssistantTab()
        tabs.setTitle("Falcon Heavy", for: id)

        _ = tabs.browser(for: id)

        XCTAssertEqual(tabs.tabs.first { $0.id == id }?.title, "Falcon Heavy")
        XCTAssertEqual(tabs.tabs.first { $0.id == id }?.urlString, "")
    }

    /// A tab that never had a page must not be handed a web view: it is a WebKit
    /// process drawing into nothing.
    @MainActor
    func testAssistantTabDoesNotGetAWebViewOnSelection() {
        let tabs = TabStore(initialAddress: "")
        let id = tabs.openAssistantTab()

        tabs.select(id: id)

        XCTAssertFalse(tabs.hasLiveWebView(for: id))
    }
#endif
}

final class TabOrganisationTests: XCTestCase {
    func testPinningBackgroundTabPreservesSelectionAndRepeatedPinPreservesOrder() {
        var collection = TabCollection()
        let first = collection.addTab(BrowserTab(title: "First", urlString: "https://one.example"))
        let second = collection.addTab(BrowserTab(title: "Second", urlString: "https://two.example"))
        let selected = collection.addTab(BrowserTab(title: "Reading"))
        collection.setPinned(true, for: first.id)
        collection.setPinned(true, for: second.id)
        collection.setPinned(true, for: first.id)
        XCTAssertEqual(collection.selectedID, selected.id)
        XCTAssertEqual(collection.pinnedTabs.map(\.id), [first.id, second.id])
        collection.setPinned(false, for: first.id)
        XCTAssertEqual(collection.selectedID, selected.id)
        XCTAssertNil(collection.tabs.last?.pinnedPage)
    }

    func testReorderWorksBothDirectionsWithoutChangingSelectionOrGroups() {
        let pin = BrowserTab(title: "Pinned", urlString: "https://pin.example", isPinned: true)
        let first = BrowserTab(title: "First")
        let second = BrowserTab(title: "Second")
        let third = BrowserTab(title: "Third")
        var collection = TabCollection(tabs: [pin, first, second, third], selectedID: second.id)
        XCTAssertTrue(collection.move(id: first.id, to: third.id))
        XCTAssertEqual(collection.tabs.map(\.id), [pin.id, second.id, third.id, first.id])
        XCTAssertTrue(collection.move(id: first.id, to: second.id))
        XCTAssertEqual(collection.tabs.map(\.id), [pin.id, first.id, second.id, third.id])
        XCTAssertFalse(collection.move(id: first.id, to: pin.id))
        XCTAssertFalse(collection.move(id: UUID(), to: first.id))
        XCTAssertFalse(collection.move(id: first.id, to: first.id))
        XCTAssertEqual(collection.selectedID, second.id)
    }

    func testCustomNameSurvivesNavigationAndCanBeReset() {
        let tab = BrowserTab(title: "Original", urlString: "https://example.com")
        var collection = TabCollection(tabs: [tab])
        collection.rename(id: tab.id, to: "  Work  ")
        collection.update(id: tab.id, title: "New page title", urlString: "https://example.com/next", faviconURL: nil)
        XCTAssertEqual(collection.selectedTab?.displayTitle, "Work")
        collection.rename(id: tab.id, to: "\n ")
        XCTAssertEqual(collection.selectedTab?.displayTitle, "New page title")
        collection.rename(id: tab.id, to: String(repeating: "x", count: 200))
        XCTAssertEqual(collection.selectedTab?.displayTitle.count, 120)
    }

    func testPinRemembersOriginalDestinationAndIconWhileNavigating() {
        let tab = BrowserTab(title: "Home", urlString: "https://example.com/home", faviconURL: "https://example.com/icon.png")
        var collection = TabCollection(tabs: [tab])
        collection.setPinned(true, for: tab.id)
        collection.update(id: tab.id, title: "Elsewhere", urlString: "https://elsewhere.example", faviconURL: nil)
        XCTAssertEqual(collection.selectedTab?.displayTitle, "Home")
        XCTAssertEqual(collection.selectedTab?.faviconSourceURL?.absoluteString, "https://example.com/icon.png")
        collection.resetPinnedPage(id: tab.id)
        XCTAssertEqual(collection.selectedTab?.urlString, "https://example.com/home")
    }

    func testPinArchiveRestoresOrderNamesAndOnlySavedDestinations() throws {
        let first = BrowserTab(title: "Home", urlString: "https://example.com/home", isPinned: true)
        let second = BrowserTab(title: "Second", urlString: "https://two.example", isPinned: true)
        var collection = TabCollection(tabs: [first, second])
        collection.rename(id: first.id, to: "Work")
        collection.update(id: first.id, title: "Private browsing destination", urlString: "https://example.com/temporary", faviconURL: nil)
        collection.move(id: first.id, to: second.id)
        let data = try XCTUnwrap(PinnedTabArchive.encode(collection.tabs))
        let restored = PinnedTabArchive.decode(data)
        XCTAssertEqual(restored.map(\.id), [second.id, first.id])
        XCTAssertEqual(restored.last?.displayTitle, "Work")
        XCTAssertEqual(restored.last?.urlString, "https://example.com/home")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("temporary"))
    }

    func testPinArchiveRejectsUnsafeURLsDuplicateIdentitiesAndOversizedInput() {
        let safe = BrowserTab(title: "Safe", urlString: "https://example.com", isPinned: true)
        let unsafe = ["file:///tmp/private", "javascript:alert(1)", "https://user:password@example.com"]
            .map { BrowserTab(title: "Unsafe", urlString: $0, isPinned: true) }
        let data = PinnedTabArchive.encode([safe, safe] + unsafe)
        XCTAssertEqual(PinnedTabArchive.decode(data).map(\.id), [safe.id])
        XCTAssertTrue(PinnedTabArchive.decode(Data(repeating: 0, count: PinnedTabArchive.maximumBytes + 1)).isEmpty)
        XCTAssertTrue(PinnedTabArchive.decode(Data("invalid".utf8)).isEmpty)
    }

    func testFaviconFallsBackToSameOriginAndRejectsCredentialURL() {
        let tab = BrowserTab(urlString: "https://example.com/path", faviconURL: "https://user:password@other.example/icon.png")
        XCTAssertEqual(tab.faviconSourceURL?.absoluteString, "https://example.com/favicon.ico")
    }
}

#if canImport(SwiftUI) && canImport(WebKit) && !canImport(CefSwiftUI)
@MainActor
final class TabOrganisationStoreTests: XCTestCase {
    func testClosingPinnedPageKeepsShortcutAndReleasesWebView() {
        let store = TabStore(initialAddress: "https://example.com/home")
        let pinID = store.selectedID
        _ = store.webView(for: pinID)
        store.setPinned(true, for: pinID)
        store.renameTab(id: pinID, to: "Work")
        store.closeSelectedTab()
        XCTAssertTrue(store.tabs.contains { $0.id == pinID && $0.isPinned && $0.displayTitle == "Work" })
        XCTAssertFalse(store.hasLiveWebView(for: pinID))
        XCTAssertNotEqual(store.selectedID, pinID)
        XCTAssertTrue(store.selectedTabHasNoPage)
        XCTAssertTrue(store.recentlyClosedTabs.isEmpty)
    }

    func testPinPersistenceIsLazyAndUnpinRemovesArchiveEntry() throws {
        let suite = "Kestrel.PinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TabStore(initialAddress: "https://example.com", pinnedTabsDefaults: defaults)
        let id = store.selectedID
        store.setPinned(true, for: id)
        store.renameTab(id: id, to: "Home")
        let restored = TabStore(pinnedTabsDefaults: defaults)
        XCTAssertEqual(restored.tabs.first?.displayTitle, "Home")
        XCTAssertFalse(restored.hasLiveWebView(for: id))
        XCTAssertTrue(restored.selectedTabHasNoPage)
        restored.setPinned(false, for: id)
        XCTAssertTrue(PinnedTabArchive.decode(defaults.data(forKey: PinnedTabArchive.key)).isEmpty)
    }

    func testRenameDuplicateCloseReopenPreservesNameAndAddress() throws {
        let store = TabStore(initialAddress: "https://example.com")
        let originalID = store.selectedID
        store.renameTab(id: originalID, to: "Research")
        store.duplicateTab(id: originalID)
        let duplicateID = store.selectedID
        XCTAssertNotEqual(duplicateID, originalID)
        XCTAssertEqual(store.selectedTab?.displayTitle, "Research")
        XCTAssertFalse(try XCTUnwrap(store.selectedTab).isPinned)
        store.closeSelectedTab()
        XCTAssertEqual(store.recentlyClosedTabs.count, 1)
        store.reopenClosedTab()
        XCTAssertEqual(store.selectedID, duplicateID)
        XCTAssertEqual(store.selectedTab?.displayTitle, "Research")
        XCTAssertEqual(store.selectedTab?.urlString, "https://example.com")
        XCTAssertTrue(store.recentlyClosedTabs.isEmpty)
    }

    func testClosePinnedSplitPaneKeepsOtherPaneSelected() {
        let store = TabStore(initialAddress: "https://example.com")
        let pinnedID = store.selectedID
        store.setPinned(true, for: pinnedID)
        store.placeSelectedTab(on: .left)
        let otherID = store.split!.rightTabID
        store.closeTab(id: pinnedID)
        XCTAssertNil(store.split)
        XCTAssertEqual(store.selectedID, otherID)
        XCTAssertTrue(store.tabs.contains { $0.id == pinnedID && $0.isPinned })
    }
}
#endif

final class InlineAddressCompletionTests: XCTestCase {
    func testRecentSearchWinsAndKeepsTypedCase() {
        XCTAssertEqual(InlineAddressCompletion.complete("Fal", recentSearches: ["falcon heavy launch"],
            bookmarks: [], openTabs: [], suggestions: ["falafel"]), "Falcon heavy launch")
    }

    func testKnownSiteCompletesWithoutSchemeOrWWW() {
        let bookmark = BrowserBookmark(title: "YouTube", urlString: "https://www.youtube.com/")
        XCTAssertEqual(InlineAddressCompletion.complete("you", recentSearches: [], bookmarks: [bookmark], openTabs: []), "youtube.com/")
        XCTAssertEqual(InlineAddressCompletion.complete("https://www.you", recentSearches: [], bookmarks: [bookmark], openTabs: []), "https://www.youtube.com/")
    }

    func testPrefixOnlyAndSafeURLs() {
        XCTAssertNil(InlineAddressCompletion.complete("cat", recentSearches: ["my cat"], bookmarks: [], openTabs: []))
        XCTAssertNil(InlineAddressCompletion.complete("exa", recentSearches: [],
            bookmarks: [BrowserBookmark(title: "Private", urlString: "https://user:password@example.com")], openTabs: []))
        XCTAssertNil(InlineAddressCompletion.complete("!ma", recentSearches: ["!maps London"], bookmarks: [], openTabs: []))
        XCTAssertNil(InlineAddressCompletion.complete("cat ", recentSearches: ["cat videos"], bookmarks: [], openTabs: []))
    }

    func testRemoteFallbackAndUnicodeSuffix() {
        XCTAssertEqual(InlineAddressCompletion.complete("café", recentSearches: ["cafe reviews"], bookmarks: [], openTabs: []), "café reviews")
        XCTAssertEqual(InlineAddressCompletion.complete("weather", recentSearches: [], bookmarks: [], openTabs: [], suggestions: ["weather London"]), "weather London")
    }
}
