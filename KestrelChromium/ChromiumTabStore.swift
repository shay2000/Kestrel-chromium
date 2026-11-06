#if canImport(SwiftUI) && canImport(CefSwiftUI)

import CefKit
import CefSwiftUI
import Combine
import Foundation
import Observation

#if canImport(AppKit)
import AppKit
#endif

/// Owns the tab row and, lazily, the web view behind each tab.
///
/// A tab starts as data in `TabCollection`. Its `BrowserStore` and CEF browser
/// are created only the first time the tab is shown, so restoring or opening
/// many tabs stays cheap. Once created, a web view is kept alive even when the
/// tab is not selected, which is what makes switching preserve the page, its
/// scroll position and its form state.
@MainActor
final class TabStore: ObservableObject {
    @Published private(set) var collection = TabCollection() {
        didSet {
            // The floating search belongs to the tab that opened it. Changing
            // tabs or split focus must not carry it over another live page.
            if collection.selectedID != oldValue.selectedID {
                dismissNewTabSearch()
            }
        }
    }
    @Published private(set) var splits: [BrowserSplit] = []
    /// Selecting another tab hides the pair without dissolving it.
    var split: BrowserSplit? { split(containing: selectedID) }

    func split(containing tabID: UUID) -> BrowserSplit? {
        splits.first { $0.side(containing: tabID) != nil }
    }

    private func saveSplit(_ split: BrowserSplit) {
        let index = splits.firstIndex { $0.id == split.id } ?? splits.count
        splits.removeAll {
            $0.id == split.id || $0.side(containing: split.leftTabID) != nil
                || $0.side(containing: split.rightTabID) != nil
        }
        splits.insert(split, at: min(index, splits.count))
    }

    func separateSplit(containing tabID: UUID) {
        splits.removeAll { $0.side(containing: tabID) != nil }
    }

    func resizeSplit(to fraction: Double) {
        guard var split else { return }
        split.resize(to: fraction)
        saveSplit(split)
    }

    func pairTabs(left leftID: UUID, right rightID: UUID) {
        guard leftID != rightID,
              tabs.contains(where: { $0.id == leftID }),
              tabs.contains(where: { $0.id == rightID }) else { return }
        saveSplit(BrowserSplit(leftTabID: leftID, rightTabID: rightID))
        select(id: leftID)
        dismissNewTabSearch()
    }
    @Published var isSidebarVisible = true
    @Published private(set) var isNewTabSearchPresented = false
    @Published var newTabSearchQuery = ""
    @Published private(set) var addressFieldFocusRequest = UUID()
    @Published private(set) var findInPageRequest = UUID()
    @Published var searchEngine: SearchEngine {
        didSet {
            for store in browserStores.values {
                store.searchEngine = searchEngine
            }
        }
    }

    private let pinnedTabsDefaults: UserDefaults?
    @Published private(set) var recentlyClosedTabs: [BrowserTab] = []
    @Published private var pageGenerations: [UUID: Int] = [:]

    private var browserStores: [UUID: BrowserStore] = [:]
    private var webViews: [UUID: CefWebViewModel] = [:]
    private var chromeBrowsers: [UUID: CefChromeBrowser] = [:]
    private var extensionActionRequest = UUID()
    private var pendingPageCloses: [UUID: () -> Void] = [:]
    private var browserDelegates: [UUID: CefBrowserDelegateProxy] = [:]
    private var cancellables: [UUID: AnyCancellable] = [:]

    private let pauseMediaPlayback: @MainActor (CefWebViewModel) -> Void
    private let openExternalURL: @MainActor (URL) -> Bool

    init(
        initialAddress: String = "",
        searchEngine: SearchEngine = .default,
        pinnedTabsDefaults: UserDefaults? = nil,
        pauseMediaPlayback: @escaping @MainActor (CefWebViewModel) -> Void = { model in
            model.kestrelBrowser?.isAudioMuted = true
        },
        openExternalURL: @escaping @MainActor (URL) -> Bool = { url in
            let workspace = NSWorkspace.shared
            guard let application = workspace.urlForApplication(toOpen: url),
                  application.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
                  Bundle(url: application)?.bundleIdentifier != "com.shayprasad.Kestrel",
                  Bundle(url: application)?.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            return workspace.open(url)
        }
    ) {
        self.searchEngine = searchEngine
        self.pinnedTabsDefaults = pinnedTabsDefaults
        self.pauseMediaPlayback = pauseMediaPlayback
        self.openExternalURL = openExternalURL
        if let savedPins = pinnedTabsDefaults?.data(forKey: PinnedTabArchive.key) {
            for pin in PinnedTabArchive.decode(savedPins) {
                collection.addTab(pin, select: false)
            }
        } else if let pinnedTabsDefaults,
                  pinnedTabsDefaults.object(forKey: PinnedTabArchive.key) == nil {
            // Seed the pinned app row once. An encoded empty archive means the
            // user deliberately cleared it, so it is left alone on later runs.
            for bookmark in DefaultBrowserApps.bookmarks {
                collection.addTab(BrowserTab(
                    title: bookmark.title,
                    urlString: bookmark.urlString,
                    faviconURL: bookmark.faviconURL,
                    isPinned: true
                ), select: false)
            }
            savePins()
        }
        let isBlankLaunch = initialAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        collection.addTab(BrowserTab(urlString: initialAddress))
        // A blank launch always shows the New Tab dashboard. The Assistant page
        // is opened only when the user asks the model a question.
        if isBlankLaunch {
            isNewTabSearchPresented = true
        }
    }

    var tabs: [BrowserTab] { collection.tabs }
    var selectedTab: BrowserTab? { collection.selectedTab }

    func pageGeneration(for id: UUID) -> Int { pageGenerations[id, default: 0] }

    var selectedID: UUID {
        collection.selectedID ?? ensureFallbackTab()
    }

    /// The store and view for the selected tab. Accessing these is what makes
    /// the selected tab's page exist.
    var selectedBrowser: BrowserStore { browser(for: selectedID) }
    var selectedWebView: CefWebViewModel { webView(for: selectedID) }

    // MARK: - Tab commands

    /// The tab that carries the assistant conversation, if one is open.
    var assistantTabID: UUID? {
        collection.tabs.first { $0.isAssistant }?.id
    }

    func isAssistantTab(_ id: UUID) -> Bool {
        collection.tabs.first { $0.id == id }?.isAssistant ?? false
    }

    /// Shows the assistant as a page of its own, and returns its tab.
    ///
    /// One assistant tab is reused rather than one per conversation. The chat
    /// store holds a single live transcript, so a second assistant tab would be
    /// a second view of the same conversation — two rows in the rail that always
    /// say the same thing. Asking again brings the existing page forward.
    ///
    /// On the new tab page the tab is empty, so it is turned into the assistant
    /// page rather than left behind as a blank row beside the chat. On a real
    /// page the chat needs a tab of its own, because the page is still there and
    /// still wants to be read.
    @discardableResult
    func openAssistantTab() -> UUID {
        if let existing = assistantTabID {
            select(id: existing)
            return existing
        }

        if let selected = collection.selectedID,
           !isAssistantTab(selected),
           isBlank(selected) {
            // The empty tab's page is thrown away with it: a browser left
            // behind the chat would consume memory while its page has no UI.
            requestPageClose(for: selected) { [weak self] in
                self?.discardPage(for: selected)
                self?.collection.makeAssistant(id: selected)
            }
            return selected
        }

        let tab = BrowserTab(title: "Assistant", isAssistant: true)
        collection.addTab(tab)
        return tab.id
    }

    /// A tab that has never held a page: the new tab page, or one whose address
    /// was cleared.
    private func isBlank(_ id: UUID) -> Bool {
        let address = browser(for: id).addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty else { return false }
        let stored = collection.tabs.first { $0.id == id }?.urlString
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty
    }

    /// Keep the tab, model and delegate alive while Chromium asks about unsaved work.
    private func requestPageClose(for id: UUID, completion: @escaping () -> Void) {
        guard pendingPageCloses[id] == nil else { return }
        guard let chrome = chromeBrowsers[id], chrome.isWindowAlive else { completion(); return }
        pendingPageCloses[id] = completion
        chrome.browser.onCloseCancelled = { [weak self, weak chrome] in
            guard let self, let chrome, self.chromeBrowsers[id] === chrome else { return }
            self.pendingPageCloses[id] = nil
        }
        chrome.close()
    }

    /// Releases app ownership only after confirmed native closure (or a browser-free tab).
    private func discardPage(for id: UUID) {
        if let model = webViews[id] {
            browserStores[id]?.stopLoading()
            model.kestrelDetach()
        }
        pendingPageCloses[id] = nil
        chromeBrowsers[id] = nil
        browserStores[id] = nil
        webViews[id] = nil
        browserDelegates[id] = nil
        cancellables[id] = nil
        CefPasskeyHandoff.shared.detach(tabID: id)
    }

    private func advancePageGeneration(for id: UUID) {
        pageGenerations[id, default: 0] &+= 1
    }

    /// Renames a tab without touching its address. Used to keep the rail label
    /// on the assistant tab following the conversation's own title.
    func setTitle(_ title: String, for id: UUID) {
        collection.update(id: id, title: title, urlString: nil, faviconURL: nil)
    }

    /// The tab whose page the assistant reads: whatever is selected.
    ///
    /// The assistant page has no page of its own and deliberately does **not**
    /// borrow the last real site. A chat opened as its own page is its own
    /// thing: it answers and searches from the question the user typed, not
    /// from a site they have already moved on from. Asking about a page is what
    /// the sidebar beside a webpage is for, and there the selected tab is that
    /// page.
    var contextTabID: UUID {
        selectedID
    }

    /// Touches a tab's page so selecting it is never blank.
    ///
    /// An assistant tab has no page. Building a browser for it would leave a
    /// page that the UI never displays.
    private func materialisePage(for id: UUID) {
        guard !isAssistantTab(id) else { return }
        let store = browser(for: id)
        _ = webView(for: id)
        if !store.addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = chromeBrowser(for: id)
        }
    }

    func presentNewTabSearch() {
        newTabSearchQuery = ""
        isNewTabSearchPresented = true
    }

    func toggleNewTabSearch() {
        if isNewTabSearchPresented {
            dismissNewTabSearch()
        } else {
            presentNewTabSearch()
        }
    }

    /// The rail action opens a real blank tab and shows its New Tab dashboard.
    /// ⌘T remains a separate command that reveals the floating bar over a page.
    @discardableResult
    func openNewTabDashboard() -> UUID {
        let id = newTab()
        presentNewTabSearch()
        return id
    }

    /// True while the selected tab has no page of its own, which is when the new
    /// tab page is on screen.
    ///
    /// This is the authoritative answer. `isNewTabSearchPresented` only records
    /// whether the user *asked* for the overlay on top of a real page, so it is
    /// possible to have a tab with no page and no overlay — which used to leave
    /// the user looking at an empty pane with no search field. The view derives
    /// what to show from both, so the two can never disagree visibly.
    var selectedTabHasNoPage: Bool {
        // The assistant page has no address either, but it is not a new tab
        // page: the chat *is* the page there. Reporting it as "no page" would
        // drop the search field on top of the conversation.
        guard !isAssistantTab(selectedID) else { return false }
        return browser(for: selectedID).addressText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// What the New Tab command does.
    ///
    /// On a real page it toggles the overlay, which is what ⌘T has always done
    /// and is safe because dismissing reveals the page underneath. On a tab that
    /// has no page it only ever presents: the overlay *is* the page there, so
    /// toggling it off would leave nothing on screen at all.
    ///
    /// On the assistant page it opens a real tab. The chat has no address to
    /// search from, so ⌘T there means "give me a page" rather than "put a search
    /// field over this conversation".
    func newTabCommand() {
        if isAssistantTab(selectedID) {
            _ = newTab()
            presentNewTabSearch()
        } else if selectedTabHasNoPage {
            presentNewTabSearch()
        } else {
            toggleNewTabSearch()
        }
    }

    func dismissNewTabSearch() {
        isNewTabSearchPresented = false
        newTabSearchQuery = ""
    }

    @discardableResult
    func openNewTabSearch(_ input: String) -> UUID? {
        guard let destination = URLNormalisation.destinationURL(from: input, searchEngine: searchEngine) else {
            return nil
        }
        if split != nil, selectedTabHasNoPage {
            let id = selectedID
            browser(for: id).addressText = destination.absoluteString
            browser(for: id).submitAddress()
            dismissNewTabSearch()
            return id
        }
        dismissNewTabSearch()
        return newTab(urlString: destination.absoluteString)
    }

    /// Searches in the requested split pane. With no split, the current page
    /// remains in the opposite pane; with a split, only the requested pane is
    /// replaced. The new search tab becomes the active pane.
    @discardableResult
    func openSearchInSplit(_ input: String, on side: BrowserSplitSide) -> UUID? {
        guard let destination = URLNormalisation.destinationURL(from: input, searchEngine: searchEngine),
              collection.tabs.contains(where: { $0.id == selectedID }) else { return nil }

        let currentID = selectedID
        let searchTabID = newTab(urlString: destination.absoluteString, select: false)

        if var currentSplit = split {
            currentSplit.place(searchTabID, on: side)
            saveSplit(currentSplit)
        } else {
            let leftID = side == .left ? searchTabID : currentID
            let rightID = side == .right ? searchTabID : currentID
            saveSplit(BrowserSplit(leftTabID: leftID, rightTabID: rightID))
        }

        collection.select(id: searchTabID)
        dismissNewTabSearch()
        return searchTabID
    }

    @discardableResult
    func newTab(urlString: String = "", select: Bool = true) -> UUID {
        guard CefRuntime.shared.isAcceptingBrowsers else { return selectedID }
        let tab = BrowserTab(urlString: urlString)
        collection.addTab(tab, select: select)
        // Keep a page-backed tab alive even when it opens in the background:
        // citations, popups and read-only new-tab attachments may use it before
        // the user selects it. Blank dashboard tabs remain browser-free.
        _ = webView(for: tab.id)
        if !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = chromeBrowser(for: tab.id)
        }
        return tab.id
    }

    func closeTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        requestPageClose(for: id) { [weak self] in self?.finishClosingTab(id: id) }
    }

    private func finishClosingTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.isPinned {
            // Closing a favourite releases its page; removing it is explicit Unpin.
            let wasSelected = selectedID == id
            let otherPane = split(containing: id).flatMap { split in
                split.side(containing: id).map { split.tabID(for: $0.opposite) }
            }
            separateSplit(containing: id)
            discardPage(for: id)
            advancePageGeneration(for: id)
            collection.resetPinnedPage(id: id)
            if wasSelected {
                if let nextID = otherPane ?? collection.unpinnedTabs.first?.id {
                    select(id: nextID)
                } else {
                    _ = newTab()
                }
            }
            return
        }
        if !tab.isAssistant && !tab.urlString.isEmpty {
            recentlyClosedTabs.append(tab)
            recentlyClosedTabs = Array(recentlyClosedTabs.suffix(20))
        }
        let survivingSplitTabID: UUID? = split.flatMap { currentSplit in
            guard let side = currentSplit.side(containing: id) else { return nil }
            return currentSplit.tabID(for: side.opposite)
        }
        discardPage(for: id)
        separateSplit(containing: id)
        collection.close(id: id)
        pageGenerations[id] = nil
        if let survivingSplitTabID {
            if collection.tabs.contains(where: { $0.id == survivingSplitTabID }) {
                collection.select(id: survivingSplitTabID)
            }
        }
        if collection.isEmpty {
            _ = newTab()
            presentNewTabSearch()
        }
    }

    func closeSelectedTab() {
        closeTab(id: selectedID)
    }

    func select(id: UUID) {
        guard collection.tabs.contains(where: { $0.id == id }) else { return }
        collection.select(id: id)
        // Touch the page so selection is never blank.
        materialisePage(for: id)
    }

    func selectNext() {
        collection.selectNext()
        materialisePage(for: selectedID)
    }

    func selectPrevious() {
        collection.selectPrevious()
        materialisePage(for: selectedID)
    }

    func selectTab(atOneBasedIndex index: Int) {
        guard index > 0, collection.tabs.indices.contains(index - 1) else { return }
        select(id: collection.tabs[index - 1].id)
    }

    func selectLastTab() {
        guard let last = collection.tabs.last else { return }
        select(id: last.id)
    }

    func requestAddressFieldFocus() {
        let target: AddressFieldTarget = split != nil ? .pane(selectedID) : (selectedTabHasNoPage ? .newTab : .toolbar)
        if let owner = BrowserWindowFocus.keyboardOwner, AddressTextField.focus(target, in: owner) { return }
        addressFieldFocusRequest = UUID()
    }

    func requestFindInPage() {
        guard !isAssistantTab(selectedID), !selectedTabHasNoPage else { return }
        findInPageRequest = UUID()
    }

    func findInSelectedPage(_ query: String, backwards: Bool = false) {
        guard !isAssistantTab(selectedID), !selectedTabHasNoPage else { return }
        selectedBrowser.find(query, backwards: backwards)
    }

    // MARK: - Hand-off to the system browser

    /// The live page address of a tab, when it names a real web page.
    ///
    /// Read from the live web view rather than the address bar: the address
    /// field also holds a half-typed query, which must never be handed to
    /// another application. A tab with no page, including the assistant page,
    /// has no address to hand off.
    func pageURL(for id: UUID) -> URL? {
        guard !isAssistantTab(id) else { return nil }
        let live = webViews[id]?.url?.absoluteString
        let stored = collection.tabs.first { $0.id == id }?.urlString
        guard let raw = live ?? stored else { return nil }
        return URLNormalisation.explicitHTTPURL(from: raw)
    }

    /// Hand a tab's page to the user's default browser.
    ///
    /// Local builds lack the managed browser capabilities, so a separate
    /// browser can be useful for sign-in. This is an explicit handoff. A failed launch leaves a retryable notice. Refuse to route
    /// back into Kestrel when it is itself the default browser.
    @discardableResult
    func openPageInDefaultBrowser(for id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }), !isAssistantTab(id) else { return false }
        let opened = pageURL(for: id).map(openExternalURL) ?? false
        browser(for: id).completeBrowserHandoff(opened: opened)
        return opened
    }

    @discardableResult
    func openSelectedPageInDefaultBrowser() -> Bool {
        openPageInDefaultBrowser(for: selectedID)
    }

    /// Places the selected tab in the requested pane. The first split keeps
    /// the current page on that side and creates a fresh tab in the other pane.
    /// Later placements replace a pane, or swap panes if the selected tab is
    /// already visible on the opposite side.
    func placeSelectedTab(on side: BrowserSplitSide) {
        let currentID = selectedID
        guard let currentTab = collection.tabs.first(where: { $0.id == currentID }) else { return }

        if var currentSplit = split {
            currentSplit.place(currentID, on: side)
            saveSplit(currentSplit)
        } else {
            let otherID = newTab(select: false)
            let leftID = side == .left ? currentID : otherID
            let rightID = side == .right ? currentID : otherID
            saveSplit(BrowserSplit(leftTabID: leftID, rightTabID: rightID))
            _ = webView(for: otherID)
        }

        collection.select(id: currentTab.id)
        materialisePage(for: currentID)
    }

    func focusSplitPane(_ side: BrowserSplitSide) {
        guard let split else { return }
        let id = split.tabID(for: side)
        guard selectedID != id else { return }
        collection.select(id: id)
        materialisePage(for: id)
    }

    /// Opens an incoming HTTP(S) URL in the current tab. This is used by
    /// Launch Services when Kestrel is chosen to handle a web link.
    func open(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        dismissNewTabSearch()
        let id = selectedID
        let browser = browser(for: id)
        _ = webView(for: id)
        browser.addressText = url.absoluteString
        browser.submitAddress()
    }

    func setPinned(_ pinned: Bool, for id: UUID) {
        if pinned {
            guard let tab = tabs.first(where: { $0.id == id }), tab.canPin,
                  collection.pinnedTabs.count < PinnedTabArchive.maximumCount else { return }
        }
        collection.setPinned(pinned, for: id)
        savePins()
    }

    @discardableResult
    func addPinnedTab(title: String, address: String) -> UUID? {
        guard collection.pinnedTabs.count < PinnedTabArchive.maximumCount,
              let url = URLNormalisation.explicitHTTPURL(from: address)
                ?? URLNormalisation.hostLikeURL(from: address) else { return nil }
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let tab = BrowserTab(title: name.isEmpty ? (url.host ?? "Website") : name,
                             urlString: url.absoluteString, isPinned: true)
        guard tab.canPin else { return nil }
        collection.addTab(tab, select: false)
        savePins()
        return tab.id
    }

    func renameTab(id: UUID, to title: String) {
        collection.rename(id: id, to: title)
        savePins()
    }

    @discardableResult
    func moveTab(id: UUID, to targetID: UUID) -> Bool {
        let moved = collection.move(id: id, to: targetID)
        if moved { savePins() }
        return moved
    }

    func moveTab(id: UUID, by offset: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let group = tabs.filter { $0.isPinned == tab.isPinned }
        guard let index = group.firstIndex(where: { $0.id == id }),
              group.indices.contains(index + offset) else { return }
        moveTab(id: id, to: group[index + offset].id)
    }

    func resetPinnedTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id && $0.isPinned }) else { return }
        requestPageClose(for: id) { [weak self] in
            guard let self else { return }
            self.discardPage(for: id)
            self.advancePageGeneration(for: id)
            self.collection.resetPinnedPage(id: id)
            self.select(id: id)
        }
    }

    func duplicateTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.isAssistant else { return }
        let duplicateID = newTab(urlString: tab.urlString)
        if let name = tab.customTitle { collection.rename(id: duplicateID, to: name) }
    }

    func reopenClosedTab() {
        guard let tab = recentlyClosedTabs.popLast() else { return }
        collection.addTab(tab)
        select(id: tab.id)
        dismissNewTabSearch()
    }

    private func savePins() {
        guard let data = PinnedTabArchive.encode(tabs) else { return }
        pinnedTabsDefaults?.set(data, forKey: PinnedTabArchive.key)
    }

    // MARK: - Lazily built pages

    func browser(for id: UUID) -> BrowserStore {
        if let existing = browserStores[id] {
            existing.searchEngine = searchEngine
            return existing
        }
        let store = BrowserStore()
        store.searchEngine = searchEngine
        let tab = collection.tabs.first { $0.id == id }
        store.addressText = tab?.urlString ?? ""
        browserStores[id] = store
        // An assistant tab has no page, so nothing may write back to it: the
        // observer copies a page's title and address onto the tab, and an empty
        // store would relabel the rail row "New Tab" the moment anything asked
        // for the tab's browser — which the rail's own background does.
        if !isAssistantTab(id) {
            observe(store, id: id)
        }
        return store
    }

    func webView(for id: UUID) -> CefWebViewModel {
        if let existing = webViews[id] {
            return existing
        }
        let store = browser(for: id)
        var options = CefBrowserOptions()
        options.runtimeStyle = .chrome
        options.profile = .default
        let initialURL = URLNormalisation.destinationURL(from: store.addressText, searchEngine: searchEngine)
        let view = CefWebViewModel(url: initialURL, options: options)
        view.onWindowOpen = { [weak self] request in
            guard let targetURL = request.targetURL,
                  let scheme = targetURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  targetURL.host != nil else { return .deny }
            guard let self else { return .deny }
            let address = targetURL.absoluteString
            let select = request.disposition.prefersForeground
            // Window creation comes from CEF's popup callback. Defer building
            // the Chrome-runtime window until that callback has returned.
            Task { @MainActor [weak self] in
                _ = self?.newTab(urlString: address, select: select)
            }
            return .handled
        }
        webViews[id] = view
        store.attach(to: view, tabID: id)
        return view
    }

    /// Returns the persistent Chrome-runtime browser for a tab. The SwiftUI
    /// host may disappear while the user changes tabs; this CEF-owned browser
    /// stays alive so the page, history, forms and extension state survive.
    func chromeBrowser(for id: UUID) -> CefChromeBrowser? {
        if let existing = chromeBrowsers[id], existing.isWindowAlive { return existing }
        guard CefRuntime.shared.isAcceptingBrowsers,
              collection.tabs.contains(where: { $0.id == id }), pendingPageCloses[id] == nil else { return nil }
        let model = webView(for: id)
        if CommandLine.arguments.contains("--kestrel-desktop-audit") {
            let trace = "KESTREL_DESKTOP chromeCreate begin tab=\(id) model=\(ObjectIdentifier(model)) tabs=\(tabs.count) existing=\(chromeBrowsers.count)\n"
            try? FileHandle.standardError.write(contentsOf: Data(trace.utf8))
        }
        var options = CefChromeBrowserOptions()
        options.isFrameless = true
        options.isResizable = false
        // Keep Chromium's genuine extension actions in this existing page
        // window, beneath Kestrel's native toolbar overlay.
        options.showsChromeToolbar = true
        options.chromeToolbarHeight = 40
        options.initialBounds = CGRect(x: -4096, y: -4096, width: 800, height: 600)
        let initialURL = model.url ?? URL(string: "about:blank")!
        let chrome = CefChromeBrowser.create(url: initialURL, options: options, delegate: model)
        model.kestrelAttach(chrome.browser)
        let delegate = CefBrowserDelegateProxy(model: model, store: browser(for: id), tabs: self)
        chrome.browser.delegate = delegate
        browserDelegates[id] = delegate
        chrome.hide()
        chromeBrowsers[id] = chrome
        if CommandLine.arguments.contains("--kestrel-desktop-audit") {
            let trace = "KESTREL_DESKTOP chromeCreate complete tab=\(id) browser=\(chrome.browser.id) window=\(chrome.nsWindow?.windowNumber ?? -1)\n"
            try? FileHandle.standardError.write(contentsOf: Data(trace.utf8))
        }
        chrome.onWindowDestroyed = { [weak self, weak chrome] in
            guard let self, let chrome, self.chromeBrowsers[id] === chrome else { return }
            let completion = self.pendingPageCloses.removeValue(forKey: id)
            self.chromeBrowsers[id] = nil
            if let completion { completion() }
            else if !CefRuntime.shared.isTerminationRequested { self.finishClosingTab(id: id) }
            else { self.discardPage(for: id); self.advancePageGeneration(for: id) }
        }
        return chrome
    }

    /// Chromium's post-install notification asks for a normal tabbed browser;
    /// CEF Views hosts are popup-style internally, so Chromium creates a second
    /// full Chrome window. Keep installation/profile state in the runtime, but
    /// dismiss its blank UI and show onboarding GET pages as Kestrel tabs.
    func routeChromeUIBrowser(_ browser: CefBrowser) {
        var resolved = false
        browser.onBeforeMainFrameNavigation = { [weak self, weak browser] url, method in
            guard !resolved else { return true }
            resolved = true
            let destination = ChromiumExtensionNavigation.destination(
                url, method: method, usesDefaultProfile: browser?.usesGlobalRequestContext == true
            )
            // Never destroy/create browsers while Chromium is adding a tab or
            // in OnBeforeBrowse. Cancel the original navigation first; it has
            // not loaded a form, account page or extension script to duplicate.
            DispatchQueue.main.async { [weak self, weak browser] in
                browser?.nativeView?.window?.orderOut(nil)
                if let destination, let self, CefRuntime.shared.isAcceptingBrowsers {
                    _ = self.newTab(urlString: destination.absoluteString)
                }
                browser?.close(force: false)
            }
            return true
        }
        DispatchQueue.main.async { [weak browser] in
            browser?.nativeView?.window?.orderOut(nil)
        }
    }

    /// Whether a live page exists for this tab.
    ///
    /// Exposed so the rule that an assistant tab never gets a browser can be
    /// checked directly. A stray page is invisible until it is quietly
    /// holding a Chromium browser open behind a chat.
    func hasLiveWebView(for id: UUID) -> Bool {
        webViews[id] != nil
    }

    /// An unsaved background form must be visible when it asks to stay open.
    func revealBrowser(_ browser: CefBrowser) {
        guard let entry = webViews.first(where: { $0.value.kestrelBrowser === browser }) else { return }
        select(id: entry.key)
    }

    /// Opens Chromium's built-in manager for the installed extensions.
    @discardableResult
    func openChromiumExtensions() {
        openChromiumPage("chrome://extensions")
    }

    func canShowExtensionActions(for id: UUID) -> Bool {
        guard CefRuntime.shared.isAcceptingBrowsers, collection.tabs.contains(where: { $0.id == id }),
              pendingPageCloses[id] == nil, !isAssistantTab(id), let chrome = chromeBrowsers[id], chrome.isWindowAlive,
              let page = chrome.nsWindow else { return false }
        return page.isVisible && page.parent != nil
    }

    func showExtensionMenu(for id: UUID, anchorLabel: String? = nil) {
        activateExtension(name: nil, for: id, anchorLabel: anchorLabel)
    }

    func showExtensionAction(_ id: String, for tabID: UUID? = nil, anchorLabel: String? = nil) {
        guard let action = ChromiumInstalledExtensions.shared.actions.first(where: { $0.id == id }) else { return }
        let names = ChromiumInstalledExtensions.shared.actions.filter { $0.name == action.name }
        activateExtension(name: names.count == 1 ? action.name : nil, for: tabID ?? selectedID,
                          anchorLabel: anchorLabel ?? "Open \(action.name) toolbar extension")
    }

    func pinnedExtensionActions(_ installed: [ChromiumExtensionDescriptor]) -> [String] {
        guard CefRuntime.shared.isAcceptingBrowsers, let chrome = chromeBrowsers[selectedID] else { return [] }
        return ChromiumExtensionActions.pinnedActions(in: chrome, installed: installed)
    }

    private func activateExtension(name: String?, for id: UUID, anchorLabel: String? = nil) {
        guard canShowExtensionActions(for: id), let chrome = chromeBrowsers[id] else { return }
        select(id: id)
        let request = UUID()
        extensionActionRequest = request
        let address = browser(for: id).addressText
        ChromiumExtensionActions.show(in: chrome, name: name, anchorLabel: anchorLabel) { [weak self, weak chrome] in
            guard let self, let chrome, CefRuntime.shared.isAcceptingBrowsers,
                  self.collection.tabs.contains(where: { $0.id == id }) else { return false }
            return self.extensionActionRequest == request && self.selectedID == id && self.chromeBrowsers[id] === chrome
                && self.pendingPageCloses[id] == nil && self.browser(for: id).addressText == address
                && CefRuntime.shared.isAcceptingBrowsers
        }
    }

    func openChromiumPage(_ address: String) {
        guard let url = URLNormalisation.chromiumInternalURL(from: address) else { return }
        if CommandLine.arguments.contains("--kestrel-desktop-audit") {
            let line = "KESTREL_DESKTOP internalPage received host=\(url.host ?? "nil") mode=\(RunLoop.current.currentMode?.rawValue ?? "nil") tabs=\(tabs.count)\n"
            try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        }
        // CEF creates a native top-level view for a new page. Do that after
        // AppKit finishes menu tracking, rather than inside the menu callback.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.tabs.count
                _ = self.newTab(urlString: url.absoluteString)
                if CommandLine.arguments.contains("--kestrel-desktop-audit") {
                    let line = "KESTREL_DESKTOP internalPage applied before=\(before) after=\(self.tabs.count)\n"
                    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
                }
            }
        }
    }

    @discardableResult
    func openExternalNavigation(_ url: URL) -> Bool {
        openExternalURL(url)
    }

    /// The store for the selected tab, used to wire the AI sidebar to the page
    /// that is actually on screen.
    var currentOperator: BrowserOperator {
        BrowserOperator(webView: webView(for: selectedID), tabID: selectedID)
    }

    private var preparedProfileFill: ProfileFillPreview?
    var personalProfileProvider: @MainActor () -> PersonalProfile = { PersonalProfile() }

    func clearProfileFill() { preparedProfileFill = nil }

    func prepareProfileFill(_ context: BrowserActionContext) async -> ProfileFillPreview? {
        preparedProfileFill = nil
        guard isCurrent(context) else { return nil }
        let view = webView(for: context.tabID)
        let preview = await ProfileFormAdapter.prepare(webView: view, tabID: context.tabID,
                                                       context: context, profile: personalProfileProvider())
        guard isCurrent(context), !Task.isCancelled else { return nil }
        preparedProfileFill = preview
        return preview
    }

    var backgroundAgentTabID: UUID?
    func actionContext(for id: UUID) -> BrowserActionContext? {
        guard collection.tabs.contains(where: { $0.id == id }), !isAssistantTab(id) else { return nil }
        let address = browser(for: id).addressText
        guard URLNormalisation.explicitHTTPURL(from: address) != nil else { return nil }
        return BrowserActionContext(tabID: id, pageURL: address)
    }

    func requiresCheckoutHandoff(_ context: BrowserActionContext) async -> Bool {
        guard isCurrent(context) else { return true }
        if let url = URL(string: context.pageURL), url.path.range(of: #"(?i)(?:^|[/_.-])(checkout|payment)(?:[/_.-]|$)"#, options: .regularExpression) != nil { return true }
        let script = #"return Array.from(document.querySelectorAll('input[autocomplete^="cc-"], input[name*="cardnumber" i], input[name*="card-number" i], input[name*="card_number" i]')).slice(0, 100).some(el => { const r=el.getBoundingClientRect(); const s=getComputedStyle(el); return r.width>0 && r.height>0 && s.display!=='none' && s.visibility==='visible'; });"#
        let result = await CefScriptRunner.shared.evaluateBody(script, in: webView(for: context.tabID), tabID: context.tabID) as? Bool
        return result ?? true
    }

    var currentActionContext: BrowserActionContext? {
        let id = selectedID
        // The assistant page is not a page: it has no web view and nothing to
        // read. Returning nil keeps a question asked there from being answered
        // or searched against the last site the user was on.
        guard !isAssistantTab(id) else { return nil }
        let address = browser(for: id).addressText
        guard URLNormalisation.explicitHTTPURL(from: address) != nil else { return nil }
        return BrowserActionContext(tabID: id, pageURL: address)
    }

    func capturePageContext(for context: BrowserActionContext, limit: Int, includeControls: Bool = false, query: String? = nil) async -> PageContext? {
        guard !isAssistantTab(context.tabID) else { return nil }
        guard isCurrent(context), await browser(for: context.tabID).waitUntilReady(),
              isCurrent(context), !Task.isCancelled else { return nil }
        let pageContext = await BrowserOperator(webView: webView(for: context.tabID), tabID: context.tabID)
            .capturePageContext(limit: limit, includeControls: includeControls, query: query)
        guard isCurrent(context) else { return nil }
        return pageContext
    }

    /// One temporary viewport image; no files, cookies or profile data are read.
    /// All text-entry fields are masked. Password pages are omitted entirely.
    func captureAgentPageImage(for context: BrowserActionContext) async -> Data? {
        guard isCurrent(context), !Task.isCancelled else { return nil }
        let view = webView(for: context.tabID)
        guard !view.kestrelHasChromeOverlay else { return nil }
        let script = #"""
        if (document.querySelector('input[type="password"]')) { return null; }
        const fields = Array.from(document.querySelectorAll('input:not([type="radio"]):not([type="checkbox"]):not([type="button"]):not([type="submit"]), textarea, [contenteditable="true"]'));
        if (fields.length > 500) { return null; }
        return fields.map(el => {
            const r = el.getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height};
        });
        """#
        guard let masks = await CefScriptRunner.shared.evaluateBody(script, in: view, tabID: context.tabID) as? [[String: Double]],
              isCurrent(context), !Task.isCancelled, !view.isLoading, !view.kestrelHasChromeOverlay,
              let nativeView = view.kestrelBrowser?.nativeView,
              nativeView.bounds.width > 0, nativeView.bounds.height > 0 else { return nil }
        let bounds = view.kestrelPageBounds
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let representation = nativeView.bitmapImageRepForCachingDisplay(in: bounds)
        guard let representation else { return nil }
        nativeView.cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        guard isCurrent(context), !Task.isCancelled, !view.isLoading, !view.kestrelHasChromeOverlay,
              let currentMasks = await CefScriptRunner.shared.evaluateBody(script, in: view, tabID: context.tabID) as? [[String: Double]],
              currentMasks == masks, view.kestrelPageBounds == bounds else { return nil }
        let output = NSImage(size: image.size)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSColor.windowBackgroundColor.setFill()
        let sx = image.size.width / bounds.width, sy = image.size.height / bounds.height
        for mask in masks {
            guard let x = mask["x"], let y = mask["y"], let w = mask["width"], let h = mask["height"],
                  x.isFinite, y.isFinite, w.isFinite, h.isFinite else { continue }
            NSRect(x: x * sx, y: image.size.height - (y + h) * sy, width: max(0, w * sx), height: max(0, h * sy)).fill()
        }
        output.unlockFocus()
        guard let tiff = output.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]),
              jpeg.count <= WorkBuddyInvocation.maximumImageBytes else { return nil }
        return jpeg
    }

    /// Opens an ordinary search in a fresh foreground tab, then returns only
    /// bounded visible result text. It never clicks a result or operates the
    /// searched page.
    func searchAndCapture(query: String, mode: WebSearchMode = .web, limit: Int) async -> PageContext? {
        guard let url = searchEngine.searchURL(for: query, mode: mode) else { return nil }
        let id = newTab(urlString: url.absoluteString)
        let store = browser(for: id)
        _ = chromeBrowser(for: id)

        guard await store.loadAndWait(for: url), collection.selectedID == id else { return nil }
        let context = BrowserActionContext(tabID: id, pageURL: store.addressText)
        return await capturePageContext(for: context, limit: limit)
    }

    /// Returns the title, address and bounded visible text of any open tab.
    ///
    /// `capturePageContext(for:)` deliberately refuses a tab that is not the
    /// active one, because it is the path a browser *action* takes. Connecting a
    /// tab from the new tab page is a read-only convenience and must work on
    /// background tabs, so it goes through the operator directly and never
    /// operates the page.
    func captureTabSnapshot(for id: UUID, limit: Int = NewTabAttachmentBuilder.maximumCharactersPerAttachment) async -> (title: String, url: String, text: String)? {
        guard let tab = collection.tabs.first(where: { $0.id == id }) else { return nil }
        let store = browser(for: id)
        guard URLNormalisation.explicitHTTPURL(from: store.addressText) != nil else { return nil }
        _ = chromeBrowser(for: id)
        guard await store.waitUntilReady() else { return nil }
        let context = await BrowserOperator(webView: webView(for: id), tabID: id)
            .capturePageContext(limit: limit)
        guard let context, !context.textSnapshot.isEmpty else { return nil }
        let title = tab.displayTitle
        return (
            title: title,
            url: store.addressText,
            text: context.textSnapshot
        )
    }

    func perform(_ action: BrowserAction, for context: BrowserActionContext?, requiresProductOptionGroup: Bool = false) async -> ActionResult {
        guard let context, isCurrent(context) else {
            return ActionResult(
                kind: action.kind,
                status: .skipped,
                summary: action.summary,
                detail: "The active tab or page changed before approval. Please ask again on the current page."
            )
        }

        let browser = browser(for: context.tabID)
        if case .fillProfile(let id) = action {
            let preview = preparedProfileFill
            preparedProfileFill = nil
            guard let preview, id == preview.id, preview.context == context else {
                return .skipped(action, reason: "The local form preview expired. Ask again to review current details.")
            }
            let filled = await ProfileFormAdapter.fill(webView: webView(for: context.tabID), tabID: context.tabID, preview: preview)
            return ActionResult(kind: .fillProfile, status: filled ? .succeeded : .failed,
                summary: filled ? "Filled the approved empty fields" : "Form filling stopped",
                detail: "Nothing was submitted by Kestrel. Review the form; changed controls may have left some fields unfilled.")
        }
        if case .openURL(let value) = action {
            guard let url = URLNormalisation.explicitHTTPURL(from: value)
                    ?? URLNormalisation.hostLikeURL(from: value) else {
                return ActionResult(
                    kind: action.kind,
                    status: .failed,
                    summary: action.summary,
                    detail: "The address was not a valid http or https URL."
                )
            }
            guard await browser.loadAndWait(for: url) else {
                return ActionResult(
                    kind: action.kind,
                    status: .failed,
                    summary: action.summary,
                    detail: "The page did not finish loading. You can stop the browser action at any time."
                )
            }
            return ActionResult(
                kind: action.kind,
                status: .succeeded,
                summary: "Opened \(url.absoluteString)",
                detail: nil
            )
        }

        if [.goBack, .goForward, .reload].contains(action.kind) {
            let completed = await browser.navigateAndWait(action)
            return ActionResult(kind: action.kind, status: completed ? .succeeded : .failed,
                                summary: action.summary,
                                detail: completed ? nil : "Navigation did not complete; no fresh page was confirmed.")
        }
        if case .stop = action {
            browser.stopLoading()
            return ActionResult(kind: action.kind, status: .succeeded, summary: action.summary, detail: nil)
        }
        let operatorForTab = BrowserOperator(
            webView: webView(for: context.tabID),
            tabID: context.tabID,
            requiresProductOptionGroup: requiresProductOptionGroup,
            canContinue: { [weak self] in self?.isCurrent(context) == true },
            cursorPresentation: { [weak browser] presentation in
                browser?.updateAgentCursorPresentation(presentation)
            }
        )
        let result = await operatorForTab.perform(action)
        guard !Task.isCancelled, actionContext(for: context.tabID) != nil, (contextTabID == context.tabID || backgroundAgentTabID == context.tabID) else {
            return .skipped(action, reason: "Stopped because the approved tab is no longer active.")
        }
        if result.status == .succeeded, action.kind == .clickText || action.kind == .searchPage {
            guard await browser.waitUntilReady() else {
                return ActionResult(kind: action.kind, status: .failed, summary: action.summary,
                                    detail: "The control was activated, but the destination did not finish loading.")
            }
        }
        return result
    }

    private func observe(_ store: BrowserStore, id: UUID) {
        let cancellable = store.$pageTitle
            .combineLatest(store.$addressText, store.$faviconURL)
            .removeDuplicates { previous, next in
                previous.0 == next.0 && previous.1 == next.1 && previous.2 == next.2
            }
            .sink { [weak self] title, address, faviconURL in
                self?.collection.update(
                    id: id,
                    title: title,
                    urlString: address,
                    faviconURL: faviconURL
                )
            }
        cancellables[id] = cancellable
    }

    private func ensureFallbackTab() -> UUID {
        if let existing = collection.selectedID {
            return existing
        }
        let tab = collection.addTab(BrowserTab())
        return tab.id
    }

    private func isCurrent(_ context: BrowserActionContext) -> Bool {
        // Checked against the tab the assistant is reading rather than the
        // selected one: on the assistant page those differ by design, and
        // comparing against the chat's own tab would reject every read.
        guard collection.tabs.contains(where: { $0.id == context.tabID }), contextTabID == context.tabID || backgroundAgentTabID == context.tabID else { return false }
        return URLNormalisation.explicitHTTPURL(from: context.pageURL) != nil
            && browser(for: context.tabID).addressText == context.pageURL
    }
}

#endif
