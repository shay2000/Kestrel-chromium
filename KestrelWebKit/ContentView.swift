#if canImport(SwiftUI) && canImport(CefSwiftUI)

import AppKit
import CefSwiftUI
import SwiftUI
import UniformTypeIdentifiers

private enum BrowserAddressFocus: Hashable {
    case toolbar
    case pane(UUID)
    case newTab
}

/// Keep the composer anchored while typing; the results scroll below it.
enum NewTabPageLayout {
    static func topInset(for containerHeight: CGFloat) -> CGFloat {
        guard containerHeight.isFinite, containerHeight > 0 else { return 52 }
        return min(440, max(84, containerHeight * 0.34 - 48))
    }
}

/// The steady charcoal Kestrel paints its chrome with in dark mode.
///
/// Named rather than repeated because the tab rail and the new tab page have to
/// be the *same* surface. They used to differ — the rail was solid, the page was
/// an ultra-thin material — and because the window is non-opaque that material
/// samples whatever is sitting on the desktop behind it. Over a bright wallpaper
/// a dark-mode new tab page therefore came out light while the rail beside it
/// stayed dark, so the window stopped reading as one surface.
private struct BrowserViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 900
}

private extension EnvironmentValues {
    var browserViewportHeight: CGFloat {
        get { self[BrowserViewportHeightKey.self] }
        set { self[BrowserViewportHeightKey.self] = newValue }
    }
}

enum BrowserChromeLayout {
    static let headerHeight: CGFloat = 46
    static let toolbarHeight: CGFloat = 40
    static let outerInset: CGFloat = 6
    static let splitGap: CGFloat = 6
}

private let kestrelDarkChrome = Color(red: 25.0 / 255, green: 25.0 / 255, blue: 25.0 / 255)
private let kestrelLightChrome = Color(red: 232.0 / 255, green: 233.0 / 255, blue: 236.0 / 255)
let kestrelNewTabCanvas = Color(red: 24.0 / 255, green: 24.0 / 255, blue: 27.0 / 255)

/// A Safari-inspired material with a subtle mode-aware tint. The tint stays
/// anchored to Kestrel's existing light/dark palette rather than the desktop.
struct KestrelChromeBackground: View {
    let colorScheme: ColorScheme
    let isTranslucent: Bool

    private var tint: Color {
        colorScheme == .dark ? kestrelDarkChrome : kestrelLightChrome
    }

    var body: some View {
        ZStack {
            if isTranslucent {
                KestrelNativeChromeMaterial()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle()
                .fill(isTranslucent ? Color.clear : tint)
            if isTranslucent {
                tint.opacity(colorScheme == .dark ? 0.26 : 0.16)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Native AppKit effect views provide the desktop-sampling treatment for the
/// chrome. macOS may replace them with opaque fills when Reduce Transparency is
/// enabled, so visual tests check that accessibility setting explicitly.
private struct KestrelNativeChromeMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        // CEF page content sits in a child NSWindow. When it becomes key the
        // SwiftUI host is inactive even though Kestrel is still frontmost.
        // Keep this shared chrome material active so a page click does not dim
        // or recolour the rest of the browser.
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let effect = view as? NSVisualEffectView {
            effect.material = .sidebar
            effect.blendingMode = .behindWindow
            effect.state = .active
        }
    }
}

/// The browser frame: the page stays dominant, with a quiet tab rail and an
/// assistant sidecar that can be opened without leaving the current page.
struct ContentView: View {
    @ObservedObject var tabs: TabStore
    @ObservedObject var chat: AIChatStore
    @ObservedObject var settings: AppSettings
    @AppStorage("Kestrel.sidebar.tabs.width") private var tabSidebarWidthPreference = 0.0
    @AppStorage("Kestrel.sidebar.assistant.width") private var assistantSidebarWidthPreference = 0.0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var assistantComposerHandoff
    @State private var assistantSidebarNewTabID: UUID?
    @State private var isApplicationActive = NSApp.isActive
    @State private var activeAddressField: BrowserAddressFocus?
    @FocusState private var findFieldFocused: Bool
    @State private var isFindBarPresented = false
    @State private var findQuery = ""

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 1_000
            let minimumPageWidth: CGFloat = 340
            let minimumTabRailWidth: CGFloat = 54
            let minimumAssistantWidth: CGFloat = 280
            // The resize handles straddle the seam they control, so they add no
            // layout width of their own. Without this the page sat 10 points in
            // from a sidebar but only 4 points below the toolbar.
            let visibleHandleWidth: CGFloat = 0

            let assistantMaximumWidth = min(
                560,
                max(
                    minimumAssistantWidth,
                    geometry.size.width
                        - minimumPageWidth
                        - (tabs.isSidebarVisible ? minimumTabRailWidth : 0)
                        - visibleHandleWidth
                )
            )
            let assistantDefaultWidth: CGFloat = isCompact ? 310 : 370
            let assistantPreferredWidth = assistantSidebarWidthPreference > 0
                ? CGFloat(assistantSidebarWidthPreference)
                : assistantDefaultWidth
            let assistantWidth = showsAssistantSidecar
                ? min(max(assistantPreferredWidth, minimumAssistantWidth), assistantMaximumWidth)
                : 0

            let tabMaximumWidth = min(
                360,
                max(
                    minimumTabRailWidth,
                    geometry.size.width - minimumPageWidth - assistantWidth - visibleHandleWidth
                )
            )
            let tabDefaultWidth: CGFloat = isCompact ? 90 : 190
            let tabPreferredWidth = tabSidebarWidthPreference > 0
                ? CGFloat(tabSidebarWidthPreference)
                : tabDefaultWidth
            let tabRailWidth = tabs.isSidebarVisible
                ? min(max(tabPreferredWidth, minimumTabRailWidth), tabMaximumWidth)
                : 0

            HStack(spacing: 0) {
                if tabs.isSidebarVisible {
                    TabStripView(
                        tabs: tabs,
                        chat: chat,
                        settings: settings,
                        isCompact: tabRailWidth < 150,
                        railWidth: tabRailWidth,
                        openAssistantChat: { conversationID in
                            withAnimation(.snappy(duration: 0.20)) {
                                AssistantChatLauncher.open(conversationID, tabs: tabs, chat: chat)
                            }
                        },
                        openNewTab: { openNewTabDashboard() }
                    )
                        .frame(width: tabRailWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    SidebarResizeHandle(
                        label: "Resize tab sidebar",
                        currentWidth: tabRailWidth,
                        minimumWidth: minimumTabRailWidth,
                        maximumWidth: tabMaximumWidth,
                        expansionSign: 1
                    ) { width in
                        tabSidebarWidthPreference = Double(width)
                    }
                    .padding(.horizontal, -SidebarResizeHandle.overhang)
                    .zIndex(4)
                    .transition(.opacity)
                }

                VStack(spacing: 0) {
                    // The assistant page has no address, so it does not get the
                    // browser toolbar — but it keeps the strip, because that is
                    // what carries the traffic lights and what the window is
                    // dragged by.
                    if showsAssistantHeader {
                        AssistantPageHeader(
                            chat: chat,
                            leadingInset: tabs.isSidebarVisible ? 16 : 90,
                            onNewChat: { chat.clearConversation() },
                            onClose: {
                                withAnimation(.snappy(duration: 0.20)) { tabs.closeSelectedTab() }
                            }
                        )
                        .zIndex(3)
                    } else if tabs.split == nil {
                        BrowserToolbar(
                            tabs: tabs,
                            browser: tabs.selectedBrowser,
                            chat: chat,
                            settings: settings,
                            searchEngine: settings.searchEngine,
                            activeAddressField: $activeAddressField,
                            assistantShortcut: settings.assistantSidebarShortcut,
                            tabStripIsVisible: tabs.isSidebarVisible,
                            isCompact: isCompact,
                            trafficLightsInset: max(8, 90 - tabRailWidth)
                        ) {
                            withAnimation(.snappy(duration: 0.22)) {
                                tabs.isSidebarVisible.toggle()
                            }
                        } presentNewTabSearch: {
                            spawnNewTabSearchBar()
                            DispatchQueue.main.async { activeAddressField = .newTab }
                        }
                        // The enclosing panel owns the shared clip and inset.
                        .zIndex(3)
                    }

                    ZStack(alignment: .top) {
                        if let split = tabs.split {
                            GeometryReader { geometry in
                                let available = max(0, geometry.size.width - BrowserChromeLayout.splitGap)
                                let leftWidth = split.leadingWidth(availableWidth: available)
                                HStack(spacing: 0) {
                                    splitPane(tabID: split.leftTabID, side: .left, width: leftWidth)
                                        .frame(width: leftWidth)
                                    SplitPaneDivider(
                                        fraction: leftWidth / max(1, available),
                                        availableWidth: available,
                                        resize: tabs.resizeSplit
                                    )
                                    splitPane(tabID: split.rightTabID, side: .right, width: available - leftWidth)
                                }
                            }
                            .transition(.opacity)
                        } else {
                            browserPage(tabID: tabs.selectedID, side: nil)
                                .transition(.opacity)
                        }

                        if showsNewTabSearch {
                            // Clicking anywhere on the page behind the new tab
                            // page puts it away, the way clicking outside a
                            // panel is expected to. Only when there is a page to
                            // go back to: on a tab with no page there is nothing
                            // underneath, so dismissing would show an empty pane.
                            if !isNewTabPageShowing {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.snappy(duration: 0.20)) { tabs.dismissNewTabSearch() }
                                    }
                                    .transition(.opacity)
                            }
                        }

                        if showsNewTabSearch {
                            // Sits in the upper part of the page rather than the
                            // middle: the suggestion dropdown opens downwards and
                            // needs the room below it.
                            GeometryReader { proxy in
                                let split = tabs.split
                                let available = max(0, proxy.size.width - BrowserChromeLayout.splitGap)
                                let leftWidth = split?.leadingWidth(availableWidth: available) ?? proxy.size.width
                                let isRight = split?.rightTabID == tabs.selectedID
                                let composerWidth = split == nil ? proxy.size.width : (isRight ? available - leftWidth : leftWidth)
                                FloatingNewTabSearch(
                                    query: $tabs.newTabSearchQuery,
                                    composerNamespace: tabs.split == nil ? assistantComposerHandoff : nil,
                                    settings: settings,
                                    searchEngine: settings.searchEngine,
                                    bookmarks: settings.bookmarks,
                                    recentSearches: settings.recentSearches,
                                    openTabs: tabs.tabs,
                                    activeAddressField: $activeAddressField,
                                    onEscape: {
                                        withAnimation(.snappy(duration: 0.20)) { tabs.dismissNewTabSearch() }
                                    },
                                    onSubmit: { query, attachments, capacity in
                                        guard attachments.isEmpty else {
                                            // Attached material only means something
                                            // to a model, so a question carrying it
                                            // goes to the assistant instead of
                                            // opening a results page.
                                            beginAssistantSearch(
                                                NewTabAttachmentBuilder.question(query, attachments: attachments),
                                                attachments: attachments,
                                                maximumAttachmentCharacters: capacity.maximumTextCharacters
                                            )
                                            return
                                        }
                                        withAnimation(.snappy(duration: 0.24)) {
                                            settings.recordSearch(query)
                                            _ = tabs.openNewTabSearch(query)
                                        }
                                    },
                                    onAssistantSearch: { prompt, attachments, maximumCharacters in
                                        beginAssistantSearch(
                                            prompt,
                                            attachments: attachments,
                                            maximumAttachmentCharacters: maximumCharacters
                                        )
                                    },
                                    onOpenBookmark: { bookmark in
                                        _ = tabs.openNewTabSearch(bookmark.urlString)
                                    },
                                    onSelectTab: { tab in
                                        tabs.dismissNewTabSearch()
                                        tabs.select(id: tab.id)
                                    },
                                    onRemoveBookmark: settings.removeBookmark,
                                    tabSnapshot: { tab in
                                        await tabs.captureTabSnapshot(for: tab.id)
                                    },
                                    // The "Search everything" caption belongs to
                                    // the new tab page itself. Over a real page
                                    // the field is a floating overlay, and a
                                    // heading there just adds noise.
                                    showsLabel: isNewTabPageShowing
                                )
                                .padding(.horizontal, 20)
                                .frame(width: composerWidth)
                                .padding(.top, NewTabPageLayout.topInset(for: proxy.size.height))
                                .offset(x: isRight ? leftWidth + BrowserChromeLayout.splitGap : 0)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            // A fade, not a drop. Sliding in from the top edge
                            // read as a panel being pulled down over the page;
                            // the field is the page on an empty tab, so it
                            // should simply arrive.
                            .transition(.opacity)
                        }

                        if isFindBarPresented {
                            HStack(spacing: 8) {
                                TextField("Find on page", text: $findQuery)
                                    .textFieldStyle(.plain)
                                    .font(KestrelTypography.chromeLabel)
                                    .frame(width: 220)
                                    .focused($findFieldFocused)
                                    .onSubmit { tabs.findInSelectedPage(findQuery) }
                                    .onKeyPress(.escape) {
                                        withAnimation(.easeOut(duration: 0.14)) { isFindBarPresented = false }
                                        return .handled
                                    }

                                Button {
                                    tabs.findInSelectedPage(findQuery, backwards: true)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .frame(width: 26, height: 26)
                                }
                                .buttonStyle(.plain)
                                .help("Previous match")
                                .accessibilityLabel("Previous match")

                                Button {
                                    tabs.findInSelectedPage(findQuery)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .frame(width: 26, height: 26)
                                }
                                .buttonStyle(.plain)
                                .help("Next match")
                                .accessibilityLabel("Next match")

                                Button {
                                    withAnimation(.easeOut(duration: 0.14)) { isFindBarPresented = false }
                                    findQuery = ""
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .frame(width: 26, height: 26)
                                }
                                .buttonStyle(.plain)
                                .help("Close Find")
                                .accessibilityLabel("Close Find")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                            .padding(.top, 12)
                            .padding(.trailing, 18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .transition(.opacity)
                            .zIndex(5)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if tabs.split == nil { pageSurfaceBackground }
                    }
                    // The page fills the shared panel without an independent
                    // top clip, inset, separator or shadow at the toolbar join.
                    .background(tabs.split == nil ? Color(nsColor: .windowBackgroundColor) : .clear)
                    .zIndex(1)
                }
                // Each page card owns its toolbar and outer corners. The split
                // group leaves its seam open to the continuous window backing.
                .clipShape(RoundedRectangle(cornerRadius: tabs.split == nil ? 10 : 0, style: .continuous))
                .padding(.top, BrowserChromeLayout.outerInset)
                .padding([.horizontal, .bottom], BrowserChromeLayout.outerInset)
                .zIndex(2)

                if showsAssistantSidecar {
                    SidebarResizeHandle(
                        label: "Resize assistant sidebar",
                        currentWidth: assistantWidth,
                        minimumWidth: minimumAssistantWidth,
                        maximumWidth: assistantMaximumWidth,
                        expansionSign: -1
                    ) { width in
                        assistantSidebarWidthPreference = Double(width)
                    }
                    .padding(.horizontal, -SidebarResizeHandle.overhang)
                    .zIndex(4)
                    .transition(.opacity)

                    AISidebar(
                        chat: chat,
                        settings: settings,
                        browser: tabs.selectedBrowser,
                        width: assistantWidth
                    )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // One continuous backing plate joins the rail, page surround and
            // Assistant. Separate glass views round and refract their own edges,
            // leaving notches at the top and bottom of each internal join.
            .background(KestrelChromeBackground(colorScheme: colorScheme, isTranslucent: settings.translucentChromeEnabled))
            .environment(\.browserViewportHeight, geometry.size.height)
            .ignoresSafeArea(edges: .top)
            .navigationTitle(tabs.selectedTab?.displayTitle ?? "Kestrel")
        }
        .background(Color.clear)
        .focusedSceneValue(\.isBrowserWindow, true)
        // CEF's page window can take key focus while the application remains
        // active. Keep the browser chrome in its active control appearance in
        // that case, and restore the inactive appearance when the user switches
        // to another application.
        .environment(\.controlActiveState, isApplicationActive ? .active : .inactive)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isApplicationActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isApplicationActive = false
        }
        .background(BrowserCloseShortcut(tabs: tabs, settings: settings).frame(width: 0, height: 0).allowsHitTesting(false))
        .background(WindowChromeAccessor().frame(width: 0, height: 0).allowsHitTesting(false))
        .onChange(of: tabs.selectedID) { _, id in
            chat.browserTabChanged(to: id)
        }
        .onChange(of: settings.searchEngine) { _, engine in
            tabs.searchEngine = engine
        }
        .onChange(of: chat.conversationTitle) { _, title in
            // The rail names the assistant tab after the conversation, so the
            // row says what the chat is about rather than just "Assistant".
            guard let id = tabs.assistantTabID else { return }
            tabs.setTitle(title ?? "Assistant", for: id)
        }
        .onChange(of: tabs.isNewTabSearchPresented) { _, isPresented in
            guard isPresented else {
                activeAddressField = nil
                return
            }
            DispatchQueue.main.async {
                activeAddressField = .newTab
            }
        }
        .onChange(of: tabs.addressFieldFocusRequest) { _, _ in
            if tabs.isAssistantTab(tabs.selectedID) {
                _ = tabs.newTab()
                tabs.presentNewTabSearch()
                DispatchQueue.main.async { activeAddressField = .newTab }
            } else if tabs.selectedTabHasNoPage {
                tabs.presentNewTabSearch()
                DispatchQueue.main.async { activeAddressField = .newTab }
            } else if tabs.isNewTabSearchPresented {
                DispatchQueue.main.async { activeAddressField = .newTab }
            } else if tabs.split != nil {
                DispatchQueue.main.async { activeAddressField = .pane(tabs.selectedID) }
            } else {
                DispatchQueue.main.async { activeAddressField = .toolbar }
            }
        }
        .onChange(of: tabs.findInPageRequest) { _, _ in
            isFindBarPresented = true
            DispatchQueue.main.async { findFieldFocused = true }
        }
        .onChange(of: findQuery) { _, query in
            tabs.findInSelectedPage(query)
        }
    }

    private func beginAssistantSearch(
        _ prompt: String,
        attachments: [NewTabAttachment] = [],
        maximumAttachmentCharacters: Int = NewTabAttachmentBuilder.maximumTotalCharacters
    ) {
        let animation: Animation? = reduceMotion ? nil : .snappy(duration: 0.38)
        withAnimation(animation) {
            switch settings.newTabAssistantDestination {
            case .assistantPage:
                assistantSidebarNewTabID = nil
                // Reuse the conversation and draft. New Chat is the explicit
                // action that clears a transcript.
                AssistantChatLauncher.showCurrent(tabs: tabs, chat: chat)
            case .assistantSidebar:
                assistantSidebarNewTabID = tabs.selectedTabHasNoPage ? tabs.selectedID : nil
                tabs.dismissNewTabSearch()
                chat.isSidebarVisible = true
            }
        }
        if attachments.isEmpty {
            chat.send(prompt: prompt, allowsWebSearch: settings.assistantWebSearchEnabled)
        } else {
            chat.send(
                prompt: prompt,
                attachments: attachments,
                maximumAttachmentCharacters: maximumAttachmentCharacters,
                allowsWebSearch: settings.assistantWebSearchEnabled
            )
        }
    }

    /// The rail's New Tab action creates and opens a real New Tab dashboard.
    private func openNewTabDashboard() {
        withAnimation(.snappy(duration: 0.20)) {
            _ = tabs.openNewTabDashboard()
        }
    }

    /// ⌘T and the browser toolbar's search control reveal the floating bar.
    private func spawnNewTabSearchBar() {
        withAnimation(.snappy(duration: 0.20)) { tabs.newTabCommand() }
    }

    /// Whether the assistant page's own header replaces the browser toolbar.
    ///
    /// Split panes carry their own controls instead of a shared window header.
    private var showsAssistantHeader: Bool {
        tabs.split == nil && tabs.isAssistantTab(tabs.selectedID)
    }

    /// True while the selected tab has no page of its own, which is when the new
    /// tab page is on screen.
    private var isNewTabPageShowing: Bool {
        tabs.selectedTabHasNoPage
    }

    /// Whether the search field is on screen.
    ///
    /// Either the user asked for it over a page, or the selected tab has no page
    /// and the field is the only thing there is to show. Deriving it this way is
    /// what stops the "blank pane with no search bar" case: a tab with no page
    /// always has a field, whatever the presented flag happens to say.
    ///
    /// The assistant page is the one exception: its chat already provides
    /// a composer, even when it replaced a blank tab with the same identifier.
    private var showsNewTabSearch: Bool {
        guard !tabs.isAssistantTab(tabs.selectedID) else { return false }
        return tabs.isNewTabSearchPresented || tabs.selectedTabHasNoPage
    }

    /// The surface behind the page area.
    ///
    /// A real page paints itself, so the pane only needs a solid colour. The new
    /// tab page has nothing to show, so the pane becomes a surface of its own.
    ///
    /// In dark mode that surface is solid. It used to be an ultra-thin material,
    /// which meant the new tab page was painted partly by the desktop showing
    /// through the non-opaque window: on a bright wallpaper a dark-mode page
    /// came out light while the search block on top of it — which has its own
    /// consistent tint — stayed correctly dark. The rail is solid in dark mode
    /// too, so page and rail now read as one surface instead of two.
    @ViewBuilder
    private var pageSurfaceBackground: some View {
        if showsKestrelSurface {
            emptyPageSurface.transition(.opacity)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    @ViewBuilder
    private var emptyPageSurface: some View {
        if colorScheme == .dark {
            kestrelNewTabCanvas
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay { Rectangle().fill(Color.white.opacity(0.16)) }
        }
    }
    /// The seam around the page area.
    ///
    /// Dia reads as one continuous surface: chrome and page are separated by a
    /// change of material, not by a drawn outline. A full outline at 0.8 points
    /// is what made the pane look framed, so this is a hairline in dark mode
    /// only — and nothing at all behind the new tab page, where the material
    /// already runs edge to edge. The page keeps its own inner edge, so real
    /// content is still bounded where it matters.
    @ViewBuilder
    private var browserPaneBorder: some View {
        if !showsKestrelSurface, colorScheme == .dark {
            browserPaneShape.strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.5)
        }
    }

    /// Whether the assistant sidecar is on screen.
    ///
    /// Never beside the assistant page. Both draw the same conversation, so
    /// showing them together is the same transcript twice — and the page is the
    /// one the user asked for. The preference is left alone rather than cleared,
    /// so leaving the chat page brings the sidecar back the way it was.
    private var showsAssistantSidecar: Bool {
        chat.isSidebarVisible
            && !tabs.isAssistantTab(tabs.selectedID)
            && (!tabs.selectedTabHasNoPage || assistantSidebarNewTabID == tabs.selectedID)
    }

    /// True when the pane is showing one of Kestrel's own surfaces rather than a
    /// web page.
    ///
    /// The new tab page and the assistant page both paint themselves, so neither
    /// wants the flat page colour behind it — and neither wants the hairline
    /// that separates a real page from the chrome.
    private var showsKestrelSurface: Bool {
        isNewTabPageShowing || tabs.isAssistantTab(tabs.selectedID)
    }

    @ViewBuilder
    private func browserPage(tabID: UUID, side: BrowserSplitSide?) -> some View {
        if tabs.isAssistantTab(tabID) {
            assistantPage(composerNamespace: side == nil ? assistantComposerHandoff : nil)
        } else {
            webPage(tabID: tabID, side: side)
        }
    }

    /// The toolbar and page form one card, with the focus ring around both.
    private func splitPane(tabID: UUID, side: BrowserSplitSide, width: CGFloat) -> some View {
        let isActive = tabs.selectedID == tabID
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 0) {
            if tabs.isAssistantTab(tabID) {
                AssistantPageHeader(
                    chat: chat,
                    leadingInset: side == .left && !tabs.isSidebarVisible ? 90 : 14,
                    onNewChat: { chat.clearConversation() },
                    onClose: { tabs.closeTab(id: tabID) }
                )
            } else {
                BrowserToolbar(
                    tabs: tabs,
                    browser: tabs.browser(for: tabID),
                    chat: chat,
                    settings: settings,
                    searchEngine: settings.searchEngine,
                    activeAddressField: $activeAddressField,
                    assistantShortcut: settings.assistantSidebarShortcut,
                    tabStripIsVisible: tabs.isSidebarVisible,
                    isCompact: true,
                    trafficLightsInset: side == .left && !tabs.isSidebarVisible ? 84 : 6,
                    paneID: tabID,
                    showsTabStripToggle: side == .left,
                    isNarrowPane: width < 380,
                    toggleTabStrip: {
                        withAnimation(.snappy(duration: 0.22)) { tabs.isSidebarVisible.toggle() }
                    },
                    presentNewTabSearch: {
                        tabs.focusSplitPane(side)
                        spawnNewTabSearchBar()
                    }
                )
                .zIndex(2)
            }
            browserPage(tabID: tabID, side: side)
                .zIndex(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(isActive ? 0.25 : 0.06), lineWidth: isActive ? 1 : 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
        .simultaneousGesture(TapGesture().onEnded { tabs.focusSplitPane(side) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(side == .left ? "Left split pane" : "Right split pane")
    }

    /// The assistant page.
    ///
    /// Drawn as a pane rather than as the sidecar so the conversation gets the
    /// whole width. It keeps the same inner edge as a page, because it is still
    /// a card sitting in the window rather than the window itself.
    private func assistantPage(composerNamespace: Namespace.ID?) -> some View {
        let pageShape = Rectangle()
        return AssistantChatPage(
            chat: chat,
            settings: settings,
            composerNamespace: composerNamespace
        )
            .clipShape(pageShape)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { emptyPageSurface }
    }

    @ViewBuilder
    private func webPage(tabID: UUID, side: BrowserSplitSide?) -> some View {
        let browser = tabs.browser(for: tabID)
        let isActive = tabs.selectedID == tabID
        let isDisplayed = tabs.split.map { $0.side(containing: tabID) != nil } ?? isActive
        let isSearching = chat.isSearchingWeb && isActive
        let hasInteractivePageBanner = isActive && (
            browser.navigationFailure != nil
                || browser.passkeyHandoffNeeded
                || browser.browserHandoffError != nil
        )
        // A blank page has no content to show. The persistent CEF browser is
        // parked until the tab gets an address.
        let hasNoPage = browser.addressText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let pageShape = Rectangle()
        let focusAction: (() -> Void)? = side.map { targetSide in
            { [weak tabs] in tabs?.focusSplitPane(targetSide) }
        }
        let pageOverlay = AnyView(ZStack {
            AgentCursorOverlay(browser: browser,
                isActive: chat.agentTaskTabID == tabID && chat.isPageControlArmed && (chat.isBusy || chat.pendingProposal != nil),
                stop: chat.cancel)
                .allowsHitTesting(false)

            if browser.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }

            if isActive {
                VStack(spacing: 8) {
                    BrowserNavigationFailureBanner(browser: browser)
                    BrowserHandoffBanner(browser: browser) {
                        _ = tabs.openPageInDefaultBrowser(for: tabID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
            }

            Rectangle()
                .strokeBorder(isSearching ? Color.purple.opacity(0.32) : Color.clear,
                              lineWidth: isSearching ? 1.35 : 0)
                .allowsHitTesting(false)
        })

        ZStack {
            BrowserView(browserID: tabID, browserGeneration: tabs.pageGeneration(for: tabID),
                        makeChromeBrowser: { tabs.chromeBrowser(for: tabID) },
                        pageOverlay: pageOverlay,
                        interactiveOverlayHeight: hasInteractivePageBanner ? 176 : 0,
                        onFocus: focusAction,
                        isHidden: hasNoPage, isVisible: isDisplayed)
                .clipShape(pageShape)
        }
        // The enclosing page card owns rounding and spacing in both layouts.
        // A second inset here creates a framed page inside the split card.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if hasNoPage { emptyPageSurface }
        }
        .animation(.easeInOut(duration: 0.24), value: isSearching)
    }

    private var browserPaneShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 17,
            bottomLeadingRadius: 17,
            bottomTrailingRadius: 17,
            topTrailingRadius: 17,
            style: .continuous
        )
    }
}

/// A narrow, accessible drag target at a sidebar seam. Positive horizontal
/// movement expands the sidebar on the left; negative movement expands one on
/// the right.
private struct SidebarResizeHandle: View {
    /// The width of the draggable strip itself.
    static let layoutWidth: CGFloat = 6
    /// How far the strip reaches past its own column. The strip is centred on
    /// the seam it controls, so the neighbouring page keeps the same inset on
    /// every side and the rail gains the few points back.
    static let overhang: CGFloat = layoutWidth / 2

    let label: String
    let currentWidth: CGFloat
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    let expansionSign: CGFloat
    let onResize: (CGFloat) -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(isHovering ? 0.32 : 0.12))
                    .frame(width: 1.5, height: isHovering ? 32 : 22)
                    .animation(.easeOut(duration: 0.14), value: isHovering)
            }
            .frame(width: Self.layoutWidth)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = currentWidth }
                        let start = dragStartWidth ?? currentWidth
                        let proposed = start + value.translation.width * expansionSign
                        onResize(min(max(proposed, minimumWidth), maximumWidth))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(currentWidth.rounded())) points")
            .accessibilityHint("Drag to resize, or use the VoiceOver adjustment controls.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onResize(min(currentWidth + 16, maximumWidth))
                case .decrement:
                    onResize(max(currentWidth - 16, minimumWidth))
                @unknown default:
                    break
                }
            }
    }
}

/// A restrained page-colour reflection confined to browser chrome. The page
/// itself is never overlaid or blurred; clipping contains the blur to the rail.
struct ChromeEdgeReflection: View {
    enum Edge: Equatable { case leading, trailing }

    /// The reflection is mainly a light-mode affordance. Light chrome needs a
    /// visible wash to separate the rail from the page; in dark mode the same
    /// strength reads as a smudge, so the dark appearance keeps the original,
    /// quieter value.
    static let lightModeOpacity: Double = 0.15
    static let darkModeOpacity: Double = 0.055

    let image: NSImage?
    let edge: Edge

    @Environment(\.colorScheme) private var colorScheme

    private var reflectionOpacity: Double {
        colorScheme == .dark ? Self.darkModeOpacity : Self.lightModeOpacity
    }

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 10, height: geometry.size.height)
                    .clipped()
                    .blur(radius: 4)
                    .opacity(reflectionOpacity)
                    .mask {
                        LinearGradient(
                            colors: edge == .leading ? [.white, .clear] : [.clear, .white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                    .frame(width: 10, height: geometry.size.height)
                    .clipped()
            }
        }
        .frame(width: 10)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.25), value: colorScheme)
    }
}

/// Shows where an approved assistant action is aimed inside the page. The
/// indicator is app-rendered feedback; page actions remain the fixed,
/// allow-listed browser operations in `BrowserOperator`.
private struct AgentCursorOverlay: View {
    @ObservedObject var browser: BrowserStore
    let isActive: Bool
    let stop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if isActive {
                AgentPageGlow(reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                AgentModePointer()
                    .scaleEffect(1.8)
                    .foregroundStyle(Color(red: 0.59, green: 0.35, blue: 0.85))
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                    .position(x: min(max(16, browser.agentCursorPresentation?.point.x ?? 28), max(16, geometry.size.width - 16)),
                              y: min(max(16, browser.agentCursorPresentation?.point.y ?? 34), max(16, geometry.size.height - 16)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: browser.agentCursorPresentation?.point)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                VStack {
                    HStack(spacing: 9) {
                        Label("Using page controls", systemImage: "cursorarrow")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Button(action: stop) {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.09), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Stop the assistant's page action")
                        .accessibilityLabel("Stop assistant page action")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 5)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.10), radius: 9, x: 0, y: 3)
                    .padding(12)
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: isActive) { _, active in
            if !active { browser.clearAgentCursorPresentation() }
        }
    }
}

/// A low-frequency edge shimmer, mounted only during an active page task.
private struct AgentPageGlow: View {
    let reduceMotion: Bool
    @State private var shimmering = false

    var body: some View {
        Rectangle()
            .strokeBorder(
                AngularGradient(colors: [.purple.opacity(0.38), .purple.opacity(0.8),
                    .purple.opacity(0.25), .purple.opacity(0.65), .purple.opacity(0.38)],
                    center: .center, angle: .degrees(shimmering ? 360 : 0)), lineWidth: 2)
            .shadow(color: .purple.opacity(shimmering ? 0.35 : 0.20), radius: 6)
            .padding(1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                    shimmering = true
                }
            }
    }
}

/// Lets the native traffic lights stay in place while the browser toolbar draws
/// in the title-bar region, like other modern macOS browsers.
private struct WindowChromeAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeProbe {
        WindowChromeProbe()
    }

    func updateNSView(_ view: WindowChromeProbe, context: Context) {
        view.configureWindowChrome()
    }
}

@MainActor
private final class WindowChromeProbe: NSView {
    private var windowObservers: [NSObjectProtocol] = []

    deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.configureWindowChrome() }
                })
            }
            // AppKit also lays out the native buttons after SwiftUI updates,
            // without a window resize notification. Reapply after that pass,
            // keeping the real buttons in their native host (including hover).
            let nativeViews = [window.standardWindowButton(.closeButton),
                               window.standardWindowButton(.miniaturizeButton),
                               window.standardWindowButton(.zoomButton)].compactMap { $0 }
            for view in nativeViews {
                view.postsFrameChangedNotifications = true
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.configureWindowChrome() }
                })
            }
        }
        configureWindowChrome()
        DispatchQueue.main.async { [weak self] in self?.configureWindowChrome() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configureWindowChrome() {
        guard let window, let contentView = window.contentView else { return }
        BrowserScrollbars.apply(to: contentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Keep the actual AppKit controls, centred on the same line as navigation.
        // AppKit owns their full-screen presentation; leave that mode untouched.
        if !window.styleMask.contains(.fullScreen),
           let close = window.standardWindowButton(.closeButton),
           let titlebar = close.superview,
           let container = titlebar.superview,
           let frameView = container.superview {
            // Resize the enclosing native title-bar container as well as the
            // button host. AppKit otherwise restores the short container and
            // moves the lights back up after initial window layout.
            var frame = container.frame
            frame.size.height = BrowserChromeLayout.headerHeight
            frame.origin.y = frameView.isFlipped ? 0 : frameView.bounds.height - frame.height
            if container.frame != frame { container.frame = frame }
            if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
            let centreFromTop = BrowserChromeLayout.outerInset + BrowserChromeLayout.toolbarHeight / 2
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                let origin = NSPoint(x: 18 + CGFloat(index) * 23,
                    y: titlebar.isFlipped ? centreFromTop - button.frame.height / 2
                        : titlebar.bounds.height - centreFromTop - button.frame.height / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        // A non-opaque window is what lets a behind-window blur sample the
        // desktop instead of only what is inside the window.
        //
        // This used to be conditional on `isOpaque`, on the assumption that a
        // window is opaque unless something has already changed it. SwiftUI
        // hands over a window for `.hiddenTitleBar` that is *already*
        // non-opaque, so the branch never ran and `backgroundColor` kept its
        // default. Clearing it unconditionally is what makes the blur real.
        window.isOpaque = false
        window.backgroundColor = .clear
        // Leave the SwiftUI host clear so native NSVisualEffectView backgrounds
        // in the sidebar chrome can sample the content behind this window.
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.isOpaque = false
    }
}

/// Restrained selection keeps the favicon and title as the strongest details.
private struct TabSelectionSurface: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    var restingFill: Color = .clear
    var restingBorder: Color = .clear
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(isSelected
                    ? (colorScheme == .dark ? Color(white: 0.28) : Color.white.opacity(0.9))
                    : restingFill)
                    .shadow(color: .black.opacity(isSelected ? 0.10 : 0), radius: 2, y: 1)
            }
            .overlay {
                shape.strokeBorder(isSelected ? Color.primary.opacity(0.16) : restingBorder, lineWidth: 0.5)
            }
    }
}

/// A complete tile hit target, independent of the favicon's intrinsic size.
private struct PinnedTabTile: View {
    let tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovering = false
    @State private var accentColour: Color = .secondary
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: select) {
            PageFaviconView(tab: tab, isSelected: isSelected, size: 20,
                            showsPinBadge: false, drawsTile: false,
                            onAccentColour: { accentColour = $0 })
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .modifier(TabSelectionSurface(
                    isSelected: isSelected, cornerRadius: 10,
                    restingFill: Color.primary.opacity(isHovering ? 0.14 : (colorScheme == .dark ? 0.085 : 0.055)),
                    restingBorder: Color.primary.opacity(0.07)))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(accentColour.opacity(0.09))
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(accentColour.opacity(0.85), lineWidth: 1.5)
                            .shadow(color: accentColour.opacity(0.32), radius: 2)
                            .padding(1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(tab.displayTitle + "\n" + (tab.pinnedPage?.urlString ?? tab.urlString))
        .accessibilityLabel("Pinned tab: \(tab.displayTitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A narrow, draggable seam; double-click restores equal widths.
private struct SplitPaneDivider: View {
    let fraction: Double
    let availableWidth: CGFloat
    let resize: (Double) -> Void
    @State private var dragStart: Double?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(isHovering ? 0.06 : 0.001))
            .frame(width: BrowserChromeLayout.splitGap)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if isHovering { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    guard availableWidth > 0 else { return }
                    if dragStart == nil { dragStart = fraction }
                    resize((dragStart ?? fraction) + value.translation.width / availableWidth)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { resize(0.5) }
            .help("Drag to resize panes; double-click for equal widths")
            .accessibilityLabel("Resize split panes")
            .accessibilityValue("Left pane \(Int(fraction * 100)) per cent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resize(fraction + 0.05)
                case .decrement: resize(fraction - 0.05)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Equal widths") { resize(0.5) }
    }
}

/// A small vertical tab rail with pinned shortcuts and grouped split tabs.
struct TabStripView: View {
    @ObservedObject var tabs: TabStore
    @ObservedObject var chat: AIChatStore
    @ObservedObject var settings: AppSettings
    let isCompact: Bool
    let railWidth: CGFloat
    @State private var renamingTab: BrowserTab?
    @State private var proposedName = ""
    @State private var isRenaming = false
    @State private var isAddingPin = false
    @State private var chatsRowIsHovered = false
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var draggedTabID: UUID?
    @State private var dragTargetID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Opens a chat on the assistant page. nil asks for a fresh conversation.
    let openAssistantChat: (UUID?) -> Void
    /// Opens the New Tab dashboard.
    let openNewTab: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var pinnedTabs: [BrowserTab] { tabs.tabs.filter(\.isPinned) }
    private var regularTabs: [BrowserTab] { tabs.tabs.filter { !$0.isPinned } }

    private var pinnedColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 6),
            count: max(1, min(3, Int((railWidth - 6) / 48)))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: BrowserChromeLayout.headerHeight)
                .accessibilityHidden(true)

            railBody
        }
        .coordinateSpace(name: "tab-rail")
        .onPreferenceChange(TabFramePreference.self) { tabFrames = $0 }
        .fontDesign(.default)
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: tabs.tabs.map(\.id))
        .sheet(isPresented: $isAddingPin) {
            AddPinnedWebsiteSheet { title, address in
                tabs.addPinnedTab(title: title, address: address) != nil
            }
        }
        .contextMenu {
            Button("Add Pinned Website…") { isAddingPin = true }
                .help("Add a website shortcut to the pinned section")
            Button("Reopen Closed Tab") { tabs.reopenClosedTab() }
                .help("Restore the most recently closed tab")
                .disabled(tabs.recentlyClosedTabs.isEmpty)
        }
        .alert("Rename Tab", isPresented: $isRenaming) {
            TextField("Tab name", text: $proposedName)
            Button("Cancel", role: .cancel) { renamingTab = nil }
            Button("Save") {
                if let tab = renamingTab { tabs.renameTab(id: tab.id, to: proposedName) }
                renamingTab = nil
            }
        } message: {
            Text("Leave the name empty to use the page title.")
        }
    }

    /// The rail proper: everything below the title-bar row, painted as a single
    /// surface so the pinned grid, the New Tab button and the tab list read as
    /// one pane.
    private var railBody: some View {
        VStack(spacing: 0) {
            if chat.backgroundTaskTabID != nil {
                Button { chat.cancel() } label: {
                    Label("Stop agent", systemImage: "stop.fill")
                        .font(KestrelTypography.chromeDetail)
                        .frame(maxWidth: .infinity).frame(height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(Color.purple)
                .help("Stop the agent task on its original tab")
                .accessibilityLabel("Stop background agent task")
            }
            ScrollView {
                VStack(spacing: 0) {
            if !pinnedTabs.isEmpty {
                LazyVGrid(columns: pinnedColumns, spacing: 6) {
                    ForEach(pinnedTabs) { tab in
                        PinnedTabTile(tab: tab, isSelected: tab.id == tabs.selectedID) {
                            tabs.dismissNewTabSearch()
                            tabs.select(id: tab.id)
                        }
                        .overlay { AgentTabFeedback(state: chat.tabTaskStates[tab.id]) }
                        .accessibilityValue(chat.tabTaskStates[tab.id] == .running ? "Agent working" : (chat.tabTaskStates[tab.id] == .completed ? "Agent task finished" : (chat.tabTaskStates[tab.id] == .needsAttention ? "Agent needs attention" : "")))
                        .contextMenu { tabMenu(for: tab) }
                        .modifier(tabDragTarget(for: tab))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }

            Button(action: openNewTab) {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18, height: 18)
                    if !isCompact {
                        Text("New Tab")
                            .font(KestrelTypography.chromeLabel.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .foregroundStyle(Color.primary.opacity(0.82))
                .padding(.horizontal, isCompact ? 5 : 10)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Add Pinned Website…") { isAddingPin = true }
                    .help("Add a website shortcut to the pinned section")
            }
            .help("Open a New Tab dashboard. Right-click to add a pinned website.")
            .accessibilityLabel("New tab")
            .padding(.horizontal, 6)
            .padding(.bottom, 4)

                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(BrowserTabRailItem.items(tabs: tabs.tabs, splits: tabs.splits)) { item in
                        switch item {
                        case .tab(let tab): row(for: tab)
                        case .split(let split): splitRow(split)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 10)
                }
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            chatsRow
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The rail's Chats control, at the foot of the sidebar.
    ///
    /// A menu rather than a button: there is more than one chat, so a plain
    /// button would have to guess which one the user meant. Picking "New Chat"
    /// is what opens the assistant page with nothing in it, which is why the
    /// chat icon has to be reachable from somewhere other than a page that
    /// already exists.
    private var chatsRow: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.07))
                .frame(height: 1)

            Menu {
                AssistantChatMenuItems(chat: chat, open: openAssistantChat)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left")
                        .font(KestrelTypography.chromeLabel.weight(.medium))
                        .frame(width: 20, height: 20)
                    if !isCompact {
                        Text("Chats")
                            .font(KestrelTypography.chromeLabel.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    if isCompact { Spacer(minLength: 0) }
                }
                .foregroundStyle(chatsRowIsHovered ? Color.primary : Color.secondary)
                .padding(.horizontal, isCompact ? 7 : 12)
                .frame(height: 38)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(chatsRowIsHovered ? Color.primary.opacity(0.06) : Color.clear)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, isCompact ? 6 : 11)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .onHover { chatsRowIsHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: chatsRowIsHovered)
            .help("Open a saved assistant chat or start a new one")
            .accessibilityLabel("Chats")
        }
    }

    private func row(for tab: BrowserTab) -> some View {
        TabRowView(
            tab: tab,
            isSelected: tab.id == tabs.selectedID,
            isCompact: isCompact,
            select: { tabs.dismissNewTabSearch(); tabs.select(id: tab.id) },
            close: {
                withAnimation(.snappy(duration: 0.20)) {
                    tabs.closeTab(id: tab.id)
                }
            }
        )
        .overlay { AgentTabFeedback(state: chat.tabTaskStates[tab.id]) }
        .accessibilityValue(chat.tabTaskStates[tab.id] == .running ? "Agent working" : (chat.tabTaskStates[tab.id] == .completed ? "Agent task finished" : (chat.tabTaskStates[tab.id] == .needsAttention ? "Agent needs attention" : "")))
        .contextMenu { tabMenu(for: tab) }
        .modifier(tabDragTarget(for: tab))
        .transition(.asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .scale(scale: 0.94).combined(with: .opacity)
        ))
    }

    private func splitRow(_ split: BrowserSplit) -> some View {
        let isSelected = split.side(containing: tabs.selectedID) != nil
        return HStack(spacing: 0) {
            splitMember(split.leftTabID, side: .left)
            splitMember(split.rightTabID, side: .right)
        }
        .frame(height: 34)
        .modifier(TabSelectionSurface(isSelected: isSelected, cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split view")
        .contextMenu {
            Button("Separate Split View") { tabs.separateSplit(containing: split.leftTabID) }
                .help("Turn both panes back into regular tabs")
            Button("Swap Panes") {
                tabs.select(id: split.leftTabID)
                tabs.placeSelectedTab(on: .right)
            }
            .help("Swap which page appears on the left and right")
        }
    }

    @ViewBuilder
    private func splitMember(_ id: UUID, side: BrowserSplitSide) -> some View {
        if let tab = tabs.tabs.first(where: { $0.id == id }) {
            Button {
                tabs.dismissNewTabSearch()
                tabs.select(id: id)
            } label: {
                HStack(spacing: 5) {
                    PageFaviconView(tab: tab, isSelected: false, drawsTile: false)
                    if !isCompact {
                        Text(tab.displayTitle)
                            .font(KestrelTypography.chromeLabel.weight(tab.id == tabs.selectedID ? .medium : .regular))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isCompact ? .center : .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.displayTitle)
            .accessibilityLabel("\(side == .left ? "Left" : "Right") pane: \(tab.displayTitle)")
            .accessibilityAddTraits(tab.id == tabs.selectedID ? [.isSelected] : [])
            .overlay { AgentTabFeedback(state: chat.tabTaskStates[tab.id]) }
            .accessibilityValue(chat.tabTaskStates[tab.id] == .running ? "Agent working" : (chat.tabTaskStates[tab.id] == .completed ? "Agent task finished" : (chat.tabTaskStates[tab.id] == .needsAttention ? "Agent needs attention" : "")))
            .contextMenu { tabMenu(for: tab) }
        }
    }

    @ViewBuilder
    private func tabMenu(for tab: BrowserTab) -> some View {
        Button("Add Pinned Website…") { isAddingPin = true }
            .help("Add a website shortcut to the pinned section")
        Divider()
        Button("Rename Tab…") {
            proposedName = tab.displayTitle
            renamingTab = tab
            isRenaming = true
        }
        .help("Give this tab a custom name")
        if tab.customTitle != nil {
            Button("Use Page Title") { tabs.renameTab(id: tab.id, to: "") }
                .help("Replace the custom name with the page title")
        }
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
            tabs.setPinned(!tab.isPinned, for: tab.id)
        }
        .help(tab.isPinned ? "Remove this tab from the pinned section" : "Keep this website in the pinned section")
        .disabled(!tab.isPinned && (!tab.canPin || pinnedTabs.count >= PinnedTabArchive.maximumCount))
        Button("Duplicate Tab") { tabs.duplicateTab(id: tab.id) }
            .help("Open another tab at the same address")
            .disabled(tab.isAssistant)
        Button("Open in Default Browser") {
            _ = tabs.openPageInDefaultBrowser(for: tab.id)
        }
            .disabled(tabs.pageURL(for: tab.id) == nil)
            .help("Open this page in your default browser, where macOS Passwords and passkeys are available.")
        Menu("Open in Split View With") {
            ForEach(tabs.tabs.filter { $0.id != tab.id }) { other in
                Button(other.displayTitle) { tabs.pairTabs(left: tab.id, right: other.id) }
                    .help("Open \(other.displayTitle) beside this tab")
            }
        }
        .help("Show this page beside another open tab")
        .disabled(tabs.tabs.count < 2)
        if let split = tabs.split(containing: tab.id), let side = split.side(containing: tab.id) {
            Button("Separate Split View") { tabs.separateSplit(containing: tab.id) }
                .help("Turn this pane back into a regular tab")
            Button("Swap Panes") {
                tabs.select(id: tab.id)
                tabs.placeSelectedTab(on: side.opposite)
            }
            .help("Move this page to the other side of the split")
        }
        if tab.isPinned {
            Button("Reset to Pinned Page") { tabs.resetPinnedTab(id: tab.id) }
                .help("Return this pinned tab to its saved website")
        }
        Divider()
        let group = tab.isPinned ? pinnedTabs : regularTabs
        Button("Move Earlier") { tabs.moveTab(id: tab.id, by: -1) }
            .help("Move this tab one place earlier in its section")
            .disabled(group.first?.id == tab.id)
        Button("Move Later") { tabs.moveTab(id: tab.id, by: 1) }
            .help("Move this tab one place later in its section")
            .disabled(group.last?.id == tab.id)
        Divider()
        Button {
            tabs.closeTab(id: tab.id)
        } label: {
            Text(tab.isPinned ? "Close Page (Keep Pin)" : "Close Tab")
                .font(.system(.body, weight: .regular))
        }
            .help(tab.isPinned ? "Close the page and keep its pinned shortcut" : "Close this tab")
        Button("Reopen Closed Tab") { tabs.reopenClosedTab() }
            .help("Restore the most recently closed tab")
            .disabled(tabs.recentlyClosedTabs.isEmpty)
    }

    private func tabDragTarget(for tab: BrowserTab) -> TabDragTarget {
        TabDragTarget(tab: tab, tabs: tabs, reduceMotion: reduceMotion, frames: tabFrames,
                      draggedID: $draggedTabID, targetID: $dragTargetID)
    }

}

private struct BrowserNavigationFailureBanner: View {
    @ObservedObject var browser: BrowserStore

    var body: some View {
        if let failure = browser.navigationFailure {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(failure.message).font(.callout)
                Spacer(minLength: 8)
                Button("Try Again", action: browser.reload)
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Offered after an unsuccessful passkey request with confirmed unavailable
/// platform authentication, or a failed external launch. It never redirects.
///
/// It observes the page's own store: the flag changes without touching the tab
/// list, so the surrounding content view would not otherwise redraw.
private struct BrowserHandoffBanner: View {
    @ObservedObject var browser: BrowserStore
    let open: () -> Void

    var body: some View {
        if browser.passkeyHandoffNeeded || browser.browserHandoffError != nil {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: browser.passkeyHandoffNeeded ? "key.horizontal" : "arrow.up.forward.app")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(browser.passkeyHandoffNeeded ? "Passkey sign-in did not finish" : "The other browser could not be opened")
                        .font(.callout.weight(.medium))
                    Text(browser.browserHandoffError ?? "You can try signing in with your default browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("Open in Default Browser", action: open)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button(action: { browser.dismissBrowserHandoff() }) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss browser suggestion")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.20), value: browser.passkeyHandoffNeeded || browser.browserHandoffError != nil)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct AddPinnedWebsiteSheet: View {
    let add: (String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Pinned Website").font(.headline)
            Text("Keep a favourite website in the sidebar.")
                .foregroundStyle(.secondary)
            TextField("Website address", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit(save)
            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Pin", action: save).keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { addressFocused = true }
    }

    private func save() {
        if add(name, address) { dismiss() }
        else { error = "Enter a valid HTTP or HTTPS website. You can keep up to 48 pins." }
    }
}

private struct TabFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TabDragTarget: ViewModifier {
    let tab: BrowserTab
    @ObservedObject var tabs: TabStore
    let reduceMotion: Bool
    let frames: [UUID: CGRect]
    @Binding var draggedID: UUID?
    @Binding var targetID: UUID?
    @GestureState private var translation = CGSize.zero

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: TabFramePreference.self,
                        value: [tab.id: geometry.frame(in: .named("tab-rail"))])
                }
            }
            .opacity(draggedID == tab.id ? 0.35 : 1)
            .overlay {
                if draggedID == tab.id {
                    content
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        .offset(translation)
                        .allowsHitTesting(false)
                }
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(targetID == tab.id && draggedID != tab.id ? 0.65 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .zIndex(draggedID == tab.id ? 1 : 0)
            // A local gesture keeps this reliable on macOS inside a scrolling
            // lazy grid; the system transfer drop destination can lose its
            // registration when those cells are recycled.
            .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("tab-rail"))
                .updating($translation) { value, state, _ in state = value.translation }
                .onChanged { value in
                    draggedID = tab.id
                    targetID = destination(at: value.location)
                }
                .onEnded { value in
                    if let destination = destination(at: value.location) {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.20)) {
                            _ = tabs.moveTab(id: tab.id, to: destination)
                        }
                    }
                    draggedID = nil
                    targetID = nil
                })
            .accessibilityAction(named: "Move earlier") { tabs.moveTab(id: tab.id, by: -1) }
            .accessibilityAction(named: "Move later") { tabs.moveTab(id: tab.id, by: 1) }
    }

    private func destination(at point: CGPoint) -> UUID? {
        frames.first { id, frame in
            frame.insetBy(dx: -3, dy: -3).contains(point)
                && tabs.tabs.contains { $0.id == id && $0.isPinned == tab.isPinned }
        }?.key
    }
}

private struct AgentTabFeedback: View {
    let state: AIChatStore.TabTaskState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        ZStack(alignment: .trailing) {
            if state == .running {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.purple.opacity(reduceMotion ? 0.16 : (pulse ? 0.20 : 0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.purple.opacity(0.32), lineWidth: 1))
                    .onAppear { pulse = true }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
                    .accessibilityLabel("Agent working")
            } else if state == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(Color.purple)
                    .frame(width: 16, height: 16).background(.white, in: Circle())
                    .padding(.trailing, 5).accessibilityLabel("Agent task finished")
            } else if state == .needsAttention {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.purple)
                    .padding(.trailing, 5).accessibilityLabel("Agent needs attention")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TabRowView: View {
    let tab: BrowserTab
    let isSelected: Bool
    let isCompact: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    private var titleColor: Color { .primary }
    private var detailColor: Color { .secondary }
    private var closeColor: Color { .secondary }

    var body: some View {
        HStack(spacing: isCompact ? 0 : 9) {
            if isCompact { Spacer(minLength: 0) }
            PageFaviconView(tab: tab, isSelected: isSelected, drawsTile: false)

            if !isCompact {
                Text(tab.displayTitle)
                    .font(KestrelTypography.chromeLabel.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)

            }

            if !isCompact {
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(closeColor)
                .opacity(isHovering || isSelected ? 1 : 0)
                .allowsHitTesting(isHovering || isSelected)
                .help("Close tab")
                .accessibilityLabel("Close tab \(tab.displayTitle)")
            }
            if isCompact { Spacer(minLength: 0) }
        }
        .padding(.horizontal, isCompact ? 3 : 7)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .background {
            // Hover only ever shows on an unselected row, so it cannot fight
            // with the raised tile for attention.
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
        .modifier(TabSelectionSurface(isSelected: isSelected, cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .help(tab.displayTitle)
        .onTapGesture(perform: select)
        .accessibilityAction(named: "Close tab", close)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct BrowserToolbar: View {
    @State private var addressDraft = ""
    @Environment(\.colorScheme) private var colourScheme
    @ObservedObject var tabs: TabStore
    @ObservedObject var browser: BrowserStore
    @ObservedObject var chat: AIChatStore
    @ObservedObject var settings: AppSettings
    let searchEngine: SearchEngine
    @Binding var activeAddressField: BrowserAddressFocus?
    let assistantShortcut: AssistantSidebarShortcut
    let tabStripIsVisible: Bool
    let isCompact: Bool
    let trafficLightsInset: CGFloat
    var paneID: UUID? = nil
    var showsTabStripToggle = true
    var isNarrowPane = false
    let toggleTabStrip: () -> Void
    let presentNewTabSearch: () -> Void

    /// Whether the pane in front of the user is the assistant page. Drives the
    /// Assistant chip's tint, so the control looks pressed exactly when the
    /// thing it opens is on screen.
    private var isAssistantPageShowing: Bool {
        tabs.isAssistantTab(paneID ?? tabs.selectedID) || (chat.isSidebarVisible && (paneID == nil || paneID == tabs.selectedID))
    }

    private var assistantControlLabel: String {
        browser.addressText.isEmpty ? "Open assistant chat" : (chat.isSidebarVisible ? "Hide assistant sidebar" : "Show assistant sidebar")
    }

    var body: some View {
        HStack(spacing: 4) {
            if showsTabStripToggle && !isNarrowPane {
                Button(action: toggleTabStrip) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Show or hide tabs")
                .accessibilityLabel("Show or hide tabs")
            }

            HStack(spacing: 1) {
                if !isNarrowPane {
                    Button { focusPane(); browser.goBack() } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .help("Go back")
                    .disabled(!browser.canGoBack)
                    .accessibilityLabel("Go back")

                    Button { focusPane(); browser.goForward() } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .help("Go forward")
                    .disabled(!browser.canGoForward)
                    .accessibilityLabel("Go forward")
                }

                Button {
                    focusPane()
                    if browser.isLoading {
                        browser.stopLoading()
                    } else {
                        browser.reload()
                    }
                } label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .help(browser.isLoading ? "Stop loading" : "Reload page")
                .accessibilityLabel(browser.isLoading ? "Stop loading" : "Reload page")
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 0)

            Group {
                if browser.pageTitle == "New Tab", paneID == nil {
                    Button {
                        presentNewTabSearch()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(searchEngine.displayName)
                                .font(KestrelTypography.chromeLabel)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, minHeight: 33)
                        
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Search the web or ask Kestrel a question")
                    .accessibilityLabel("Focus the new-tab search field")
                } else {
                    HStack(spacing: 0) {
                        if let paneID {
                            PageFaviconView(
                                tab: BrowserTab(id: paneID, title: browser.pageTitle,
                                                urlString: browser.addressText, faviconURL: browser.faviconURL),
                                isSelected: false, size: 14, drawsTile: false
                            )
                                .padding(.leading, 6)
                        }
                        AddressEntry(
                            text: $addressDraft,
                            onSubmit: {
                                focusPane()
                                settings.recordSearch($0)
                                browser.addressText = $0
                                browser.submitAddress()
                            },
                            onAssistantSearch: assistantSearch,
                            onEscape: { activeAddressField = nil },
                            style: .toolbar,
                            searchEngine: searchEngine,
                            bookmarks: settings.bookmarks,
                            recentSearches: settings.recentSearches,
                            openTabs: tabs.tabs,
                            onOpenBookmark: { bookmark in
                                focusPane()
                                browser.addressText = bookmark.urlString
                                browser.submitAddress()
                                activeAddressField = nil
                            },
                            onSelectTab: { tab in
                                activeAddressField = nil
                                tabs.select(id: tab.id)
                            },
                            focusOnAppear: false,
                            activeAddressField: $activeAddressField,
                            focusTarget: paneID.map(BrowserAddressFocus.pane) ?? .toolbar,
                            focusRequest: tabs.split == nil && paneID == nil ? tabs.addressFieldFocusRequest : nil
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 33)
            .zIndex(2)

            if !isNarrowPane, browser.pageTitle != "New Tab", !browser.isLoading,
               URLNormalisation.explicitHTTPURL(from: browser.addressText) != nil {
                Button {
                    settings.toggleBookmark(
                        title: browser.pageTitle,
                        address: browser.addressText,
                        faviconURL: browser.faviconURL
                    )
                } label: {
                    Image(systemName: settings.isBookmarked(browser.addressText) ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(settings.isBookmarked(browser.addressText) ? Color.accentColor : Color.secondary)
                        .frame(width: 27, height: 29)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(settings.isBookmarked(browser.addressText) ? "Remove bookmark" : "Add bookmark")
                .accessibilityLabel(settings.isBookmarked(browser.addressText) ? "Remove bookmark" : "Add bookmark")
            }

            if isNarrowPane {
                Menu {
                    Button("Go back") { focusPane(); browser.goBack() }
                        .help("Go back one page in this pane")
                        .disabled(!browser.canGoBack)
                    Button("Go forward") { focusPane(); browser.goForward() }
                        .help("Go forward one page in this pane")
                        .disabled(!browser.canGoForward)
                    Divider()
                    Button("Show or hide tabs", action: toggleTabStrip)
                        .help("Show or hide the tab sidebar")
                    Button(assistantControlLabel) {
                        focusPane()
                        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
                    }
                    .help("Open or close the Assistant for this pane")
                    if URLNormalisation.explicitHTTPURL(from: browser.addressText) != nil {
                        Button(settings.isBookmarked(browser.addressText) ? "Remove bookmark" : "Add bookmark") {
                            settings.toggleBookmark(title: browser.pageTitle, address: browser.addressText, faviconURL: browser.faviconURL)
                        }
                        .help(settings.isBookmarked(browser.addressText) ? "Remove this page from bookmarks" : "Bookmark this page")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show additional controls for this split pane")
                .accessibilityLabel("Pane controls")
            } else {
                Button {
                    focusPane()
                    activeAddressField = nil
                    withAnimation(.snappy(duration: 0.22)) {
                        AssistantChatLauncher.toggle(tabs: tabs, chat: chat)
                    }
                } label: {
                    Group {
                        if isCompact {
                            ProviderMark(provider: settings.ai.selectedProvider, size: 15)
                        } else {
                            HStack(spacing: 6) {
                                ProviderMark(provider: settings.ai.selectedProvider, size: 14)
                                Text("Assistant")
                            }
                        }
                    }
                    .font(KestrelTypography.chromeLabel.weight(.medium))
                    .padding(.horizontal, isCompact ? 8 : 9)
                    .frame(width: isCompact ? 30 : nil, height: 28)
                    .foregroundStyle(isAssistantPageShowing ? Color.accentColor : Color.primary.opacity(0.78))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .background(
                    isAssistantPageShowing ? Color.accentColor.opacity(0.085) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .help("\(assistantControlLabel) (\(assistantShortcut.displayName))")
                .accessibilityLabel(assistantControlLabel)
            }

            if let paneID {
                Button { tabs.closeTab(id: paneID) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 27, height: 30)
                        .contentShape(Rectangle())
                }
                .help("Close pane")
                .accessibilityLabel("Close pane")
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, trafficLightsInset)
        .padding(.trailing, 7)
        .frame(height: BrowserChromeLayout.toolbarHeight)
        .background(toolbarColour)
        .environment(\.colorScheme, toolbarScheme)
        .onAppear { addressDraft = browser.addressText }
        .onChange(of: browser.addressText) { _, address in
            // Navigation updates the committed address; typing stays local to
            // this toolbar and cannot rewrite the tab's URL or hide its page.
            if activeAddressField != (paneID.map(BrowserAddressFocus.pane) ?? .toolbar) {
                addressDraft = address
            }
        }
        .onChange(of: ObjectIdentifier(browser)) { _, _ in addressDraft = browser.addressText }
        .onChange(of: activeAddressField) { _, target in
            if let paneID, target == .pane(paneID) { focusPane() }
            if target != (paneID.map(BrowserAddressFocus.pane) ?? .toolbar) {
                addressDraft = browser.addressText
            }
        }
    }

    private func focusPane() {
        guard let paneID else { return }
        if tabs.selectedID != paneID { tabs.select(id: paneID) }
    }

    private var toolbarColour: Color {
        if browser.pageTitle != "New Tab", let colour = browser.pageBackgroundColor {
            return Color(nsColor: colour)
        }
        return colourScheme == .dark ? kestrelNewTabCanvas : Color(nsColor: .windowBackgroundColor)
    }

    private var toolbarScheme: ColorScheme {
        guard browser.pageTitle != "New Tab",
              let rgb = browser.pageBackgroundColor?.usingColorSpace(.sRGB) else { return colourScheme }
        return rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 < 0.5 ? .dark : .light
    }

    /// A question typed into the address bar and sent to the assistant.
    ///
    /// Keep the page in view and use it as the sidebar's current context.
    private func assistantSearch(_ prompt: String) {
        focusPane()
        activeAddressField = nil
        tabs.dismissNewTabSearch()
        withAnimation(.snappy(duration: 0.22)) {
            chat.isSidebarVisible = true
        }
        chat.send(prompt: prompt)
    }

}

private struct FloatingNewTabSearch: View {
    @Binding var query: String
    let composerNamespace: Namespace.ID?
    @ObservedObject var settings: AppSettings
    let searchEngine: SearchEngine
    let bookmarks: [BrowserBookmark]
    let recentSearches: [String]
    let openTabs: [BrowserTab]
    @Binding var activeAddressField: BrowserAddressFocus?
    let onEscape: () -> Void
    /// Carries the question *and* whatever the user attached to it. The two
    /// travel together because an attachment with no question, or a question
    /// whose material was dropped, are both meaningless.
    let onSubmit: (String, [NewTabAttachment], AttachmentCapacity) -> Void
    let onAssistantSearch: (String, [NewTabAttachment], Int) -> Void
    let onOpenBookmark: (BrowserBookmark) -> Void
    let onSelectTab: (BrowserTab) -> Void
    let onRemoveBookmark: (UUID) -> Void
    /// Reads another tab's visible text. Supplied by the frame, which owns the
    /// web views.
    let tabSnapshot: (BrowserTab) async -> (title: String, url: String, text: String)?
    /// Whether to caption the field. True on the new tab page, false when the
    /// field is floating over a real page.
    var showsLabel: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var modelCache = ProviderModelCache.shared
    @State private var attachments: [NewTabAttachment] = []
    @State private var attachmentError: String?
    @State private var isConnectingTab = false

    /// The search field is deliberately generous: this is the main control on
    /// the page, not a toolbar field, and it holds the whole composer.
    private static let fieldHeight: CGFloat = 68
    private static let actionRowHeight: CGFloat = 52

    private let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAssistantOnly: Bool { !attachments.isEmpty }

    private var attachmentCapacity: AttachmentCapacity {
        .forModel(
            provider: settings.ai.selectedProvider,
            contextWindow: modelCache.contextWindow(for: settings.ai)
        )
    }

    private var attachmentLimitWarning: String? {
        guard attachments.count > attachmentCapacity.maximumFiles else { return nil }
        let maximum = attachmentCapacity.maximumFiles == 1
            ? "1 file"
            : "\(attachmentCapacity.maximumFiles) files"
        let excess = attachments.count - attachmentCapacity.maximumFiles
        let remove = excess == 1 ? "1 file" : "\(excess) files"
        return "This model supports up to \(maximum). Remove \(remove) before sending, or choose a model with a higher limit."
    }

    /// Open tabs that actually have a page to read. An empty new tab has nothing
    /// to contribute, so offering it would only produce an error.
    private var connectableTabs: [BrowserTab] {
        openTabs.filter { !$0.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A firm, near-white lavender surface that stays visually stable over a
    /// blank New Tab or a live page. The depth comes from the edge and shadows,
    /// not from a translucent material changing with the background behind it.
    private var surfaceFill: LinearGradient {
        ComposerAccessoryPalette.composerSurface(isDark: colorScheme == .dark)
    }

    private var borderColor: Color {
        ComposerAccessoryPalette.composerSurfaceEdge(isDark: colorScheme == .dark)
    }

    var body: some View {
        VStack(spacing: 12) {
            if showsLabel {
                Text("Kestrel")
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .foregroundStyle(.primary.opacity(0.9))
                    .padding(.bottom, 10)
                    .accessibilityLabel("Kestrel")
                    .accessibilityAddTraits(.isHeader)
            }

            // One block rather than a field with loose buttons beneath it: the
            // search field and the ways of adding material to it are the same
            // control, so they share one surface.
            VStack(spacing: 0) {
                AddressEntry(
                    text: $query,
                    onSubmit: { prepared in submit(prepared) },
                    onAssistantSearch: { prompt in submitToAssistant(prompt) },
                    onEscape: onEscape,
                    style: .newTab,
                    searchEngine: searchEngine,
                    bookmarks: bookmarks,
                    recentSearches: recentSearches,
                    openTabs: openTabs,
                    onOpenBookmark: onOpenBookmark,
                    onSelectTab: onSelectTab,
                    focusOnAppear: true,
                    activeAddressField: $activeAddressField,
                    focusTarget: .newTab,
                    focusRequest: nil,
                    assistantOnly: isAssistantOnly
                )
                // Switching into or out of file context changes the legal
                // destinations for this field. Recreate its transient
                // suggestion state so a stale Google row cannot remain first.
                .id(isAssistantOnly)
                .frame(maxWidth: .infinity, minHeight: Self.fieldHeight, maxHeight: Self.fieldHeight)
                // The field's dropdown opens downwards, over the action row
                // that follows it in this stack. Without the lift, that sibling
                // draws on top of the panel and the first few rows are cut in
                // half.
                .zIndex(1)

                contextRow
            }
            .background {
                shape.fill(surfaceFill)
                    .modifier(AssistantComposerHandoffEffect(namespace: composerNamespace))
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: 1.2)
            }
            .overlay {
                shape.strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.88),
                    lineWidth: 0.8
                )
                .padding(1)
                .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.09), radius: 18, x: 0, y: 8)
            .shadow(color: ComposerAccessoryPalette.lavender.opacity(colorScheme == .dark ? 0.025 : 0.11), radius: colorScheme == .dark ? 7 : 11, x: 0, y: 4)
            .shadow(color: Color.primary.opacity(0.07), radius: 3, x: 0, y: 1)
            // The whole block has to clear the bookmark shelf below it, not
            // just the field clear its own siblings: the panel is inside this
            // subtree, and a shelf drawn afterwards would cover it.
            .zIndex(2)

            if let attachmentError = attachmentError ?? attachmentLimitWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(attachmentError)
                        .font(KestrelTypography.chromeDetail)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .transition(.opacity)
            }

            if !bookmarks.isEmpty {
                BookmarkShelf(bookmarks: bookmarks, open: onOpenBookmark, remove: onRemoveBookmark)
                    .frame(height: 36)
                    .opacity(hasQuery ? 0 : 1)
                    .scaleEffect(hasQuery ? 0.985 : 1, anchor: .top)
                    .allowsHitTesting(!hasQuery)
                    .accessibilityHidden(hasQuery)
                    // Stays under the search block so an open dropdown passes
                    // over the shelf rather than behind it.
                    .zIndex(1)
            }
        }
        .frame(maxWidth: 800)
        .animation(.easeInOut(duration: 0.18), value: hasQuery)
        .animation(.easeInOut(duration: 0.18), value: attachments.count)
        .animation(.easeInOut(duration: 0.18), value: attachmentError)
        .animation(.easeInOut(duration: 0.18), value: attachmentCapacity.maximumFiles)
    }

    // MARK: - Attached context

    /// The action row that lives inside the search block.
    private var contextRow: some View {
        FadingHorizontalScroll {
            HStack(spacing: 7) {
                attachmentMenu

                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(height: Self.actionRowHeight)
    }

    private var attachmentMenu: some View {
        Menu {
            Button(action: uploadFiles) {
                Label("Choose a file…", systemImage: "paperclip")
            }
            .disabled(attachments.count >= attachmentCapacity.maximumFiles)

            Divider()
            if connectableTabs.isEmpty {
                Button("No open tabs available") {}
                    .disabled(true)
            } else {
                Menu {
                    ForEach(connectableTabs) { tab in
                        Button {
                            connect(tab)
                        } label: {
                            Text(tab.displayTitle)
                        }
                        .help("Include visible text from \(tab.displayTitle) in the question")
                    }
                } label: {
                    Text("Open tabs")
                }
            }
        }
        label: {
            Group {
                if isConnectingTab {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ComposerAccessoryPalette.accessoryForeground(
                            isActive: false,
                            isDark: colorScheme == .dark
                        ))
                        .scaleEffect(x: -1, y: 1)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .modifier(ComposerAccessorySurface(shape: .circle))
        .help("Attach a file or choose an open tab")
        .accessibilityLabel("Attach a file or tab")
        .accessibilityValue("\(attachments.count) of \(attachmentCapacity.maximumFiles) attachments")
    }

    private func attachmentChip(_ attachment: NewTabAttachment) -> some View {
        HStack(spacing: 6) {
            NewTabAttachmentThumbnail(attachment: attachment)
            Text(attachment.label)
                .font(KestrelTypography.chromeDetail.weight(.medium))
                .lineLimit(1)
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove \(attachment.label)")
            .accessibilityLabel("Remove \(attachment.label)")
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .modifier(AttachmentChipSurface())
        .help(attachment.origin)
    }

    // MARK: - Attaching

    /// Sends the question on its way and clears the tray.
    ///
    /// `prepared` is the query as the *field* prepared it: the typed text plus
    /// any search shortcut committed with Tab. It is taken as an argument rather
    /// than re-read from `query`, because re-reading the binding threw the
    /// shortcut away — `!maps eiffel tower` arrived here as `eiffel tower`, so
    /// the bang shown in the field's badge was silently dropped and the search
    /// fell back to the default engine.
    ///
    /// Attachments are consumed here rather than by the parent so a chip cannot
    /// survive into a second question and be counted twice.
    private func submit(_ prepared: String) {
        let question = prepared.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !attachments.isEmpty else { return }
        guard attachments.count <= attachmentCapacity.maximumFiles else { return }
        // The parent is the final routing boundary: even if a stale child
        // suggestion or shortcut invokes the search callback, files can only
        // be submitted to an assistant model.
        if !attachments.isEmpty {
            submitToAssistant(question)
            return
        }
        let pending = attachments
        attachments = []
        attachmentError = nil
        onSubmit(question, pending, attachmentCapacity)
    }

    private func submitToAssistant(_ prompt: String) {
        guard attachments.count <= attachmentCapacity.maximumFiles else { return }
        let question = NewTabAttachmentBuilder.question(prompt, attachments: attachments)
        let pending = attachments
        attachments = []
        attachmentError = nil
        onAssistantSearch(question, pending, attachmentCapacity.maximumTextCharacters)
    }

    private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        // Only what Kestrel can actually read. Offering a file and then refusing
        // it is a worse experience than not offering it at all.
        panel.allowedContentTypes = NewTabAttachmentBuilder.selectableContentTypes()
        panel.allowsOtherFileTypes = false
        panel.message = "Choose images, PDFs, Office documents or text files to add to your question"
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }

        var failure: String?
        for url in panel.urls {
            guard attachments.count < attachmentCapacity.maximumFiles else {
                failure = NewTabAttachmentError
                    .tooMany(limit: attachmentCapacity.maximumFiles)
                    .errorDescription
                break
            }
            do {
                let attachment = try NewTabAttachmentBuilder.attachment(
                    forFileAt: url,
                    existingCount: attachments.count
                )
                // The same file twice adds nothing but tokens.
                if !attachments.contains(where: { $0.origin == attachment.origin }) {
                    attachments.append(attachment)
                }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "Kestrel could not read “\(url.lastPathComponent)”."
            }
        }
        attachmentError = failure
    }

    private func connect(_ tab: BrowserTab) {
        guard attachments.count < attachmentCapacity.maximumFiles else {
            attachmentError = NewTabAttachmentError
                .tooMany(limit: attachmentCapacity.maximumFiles)
                .errorDescription
            return
        }
        guard !attachments.contains(where: { $0.kind == .tab && $0.origin.contains(tab.urlString) }) else {
            return
        }
        isConnectingTab = true
        Task {
            let snapshot = await tabSnapshot(tab)
            isConnectingTab = false
            guard let snapshot else {
                attachmentError = NewTabAttachmentError
                    .noPageText(tab.displayTitle)
                    .errorDescription
                return
            }
            do {
                attachments.append(
                    try NewTabAttachmentBuilder.attachment(
                        forTabTitle: snapshot.title,
                        url: snapshot.url,
                        text: snapshot.text,
                        existingCount: attachments.count
                    )
                )
                attachmentError = nil
            } catch {
                attachmentError = (error as? LocalizedError)?.errorDescription
                    ?? "Kestrel could not read “\(tab.displayTitle)”."
            }
        }
    }
}

/// A horizontal scroller that fades an edge only when that edge is really hiding
/// something.
///
/// The bookmark shelf and the composer's action row both used to fade both ends
/// unconditionally. On a row that fits, or one still sitting at its start, that
/// only dims the first and last item for no reason — the shelf looked like it
/// had failed to render rather than like it could scroll. A fade is an
/// affordance for content that is out of view, so it now appears only where
/// content actually is.
struct FadingHorizontalScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    private struct HiddenEdges: Equatable {
        var leading = false
        var trailing = false
    }

    // Keep only the fade decisions in state. Storing the whole moving frame
    // invalidates the content (including material chips and favicons) for every
    // scroll tick, even though the mask changes only at the two ends.
    @State private var hiddenEdges = HiddenEdges()
    @State private var viewportWidth: CGFloat = 0
    @Namespace private var scrollSpace
    /// How far the soft edge reaches, in points.
    private static var fadeReach: CGFloat { 18 }

    private var maskGradient: LinearGradient {
        let width = max(viewportWidth, 1)
        let leading = hiddenEdges.leading ? min(Self.fadeReach / width, 0.45) : 0
        let trailing = hiddenEdges.trailing ? max(1 - Self.fadeReach / width, 0.55) : 1
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: leading),
                .init(color: .black, location: trailing),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        ScrollView(.horizontal) {
            content()
                .onGeometryChange(for: HiddenEdges.self) { proxy in
                    let frame = proxy.frame(in: .named(scrollSpace))
                    return HiddenEdges(
                        leading: frame.minX < -0.5,
                        trailing: frame.maxX > viewportWidth + 0.5
                    )
                } action: { edges in
                    hiddenEdges = edges
                }
        }
        .coordinateSpace(name: scrollSpace)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            viewportWidth = width
        }
        // `.never`, not `.hidden`. `.hidden` only puts the indicator away until
        // the next scroll; on a Mac using always-visible scroll bars that means a
        // permanent grey track under the shelf, which reads as a stray rule
        // across the new tab page.
        .scrollIndicators(.never)
        .mask { maskGradient }
    }
}

private struct BookmarkShelf: View {
    let bookmarks: [BrowserBookmark]
    let open: (BrowserBookmark) -> Void
    let remove: (UUID) -> Void

    var body: some View {
        FadingHorizontalScroll {
            HStack(spacing: 8) {
                ForEach(bookmarks) { bookmark in
                    Button { open(bookmark) } label: {
                        HStack(spacing: 7) {
                            favicon(for: bookmark)
                                .frame(width: 26, height: 26)
                            Text(bookmark.displayTitle)
                                .font(KestrelTypography.chromeDetail.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.leading, 5)
                        .padding(.trailing, 11)
                        .frame(height: 36)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Open \(bookmark.displayTitle)")
                    .contextMenu {
                        Button("Remove Bookmark", systemImage: "bookmark.slash") { remove(bookmark.id) }
                            .help("Remove this bookmark from the New Tab page")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func favicon(for bookmark: BrowserBookmark) -> some View {
        if let url = bookmark.faviconSourceURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(5)
                } else {
                    Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary).padding(6)
                }
            }
        } else {
            Image(systemName: "globe")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}

private struct AddressEntry: View {
    enum Style: Equatable {
        case toolbar
        case newTab

        var height: CGFloat { self == .toolbar ? 33 : 68 }
        var horizontalInset: CGFloat { self == .toolbar ? 12 : 20 }
        var cornerRadius: CGFloat { self == .toolbar ? 9 : 22 }
        // The floating composer is 120 points tall. Leave a small breathing
        // gap before the suggestion surface so the two raised cards do not
        // read as one large block when results appear.
        var suggestionOffset: CGFloat { self == .toolbar ? 39 : 134 }
        var isFloating: Bool { self == .newTab }
    }

    @Binding var text: String
    let onSubmit: (String) -> Void
    let onAssistantSearch: (String) -> Void
    let onEscape: () -> Void
    let style: Style
    let searchEngine: SearchEngine
    let bookmarks: [BrowserBookmark]
    let recentSearches: [String]
    let openTabs: [BrowserTab]
    let onOpenBookmark: (BrowserBookmark) -> Void
    let onSelectTab: (BrowserTab) -> Void
    let focusOnAppear: Bool
    @Binding var activeAddressField: BrowserAddressFocus?
    let focusTarget: BrowserAddressFocus
    let focusRequest: UUID?
    var assistantOnly = false

    @Environment(\.browserViewportHeight) private var viewportHeight
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fieldBottom: CGFloat = 0
    @State private var suggestionContentHeight: CGFloat = 200

    @State private var suggestions: [String] = []
    @State private var activeShortcut: SearchShortcut?
    @State private var isHovering = false
    @State private var isEditingAddress = false
    @State private var isHoveringSuggestions = false
    @State private var highlightedSuggestion = 0
    @State private var inlinePrefix: String?

    private var fieldIsFocused: Bool { isEditingAddress }

    private var suggestionCornerRadius: CGFloat { style.isFloating ? 22 : 14 }

    private var suggestionPanelTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var suggestionPanelAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.34, dampingFraction: 0.88)
    }

    private var completionQuery: String {
        guard fieldIsFocused else { return "" }
        return (inlinePrefix ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestionQuery: String {
        assistantOnly || SearchSuggestions.endpoint(for: completionQuery, engine: searchEngine) == nil
            ? ""
            : completionQuery
    }

    private var suggestionTaskID: String {
        "\(assistantOnly):\(searchEngine.rawValue):\(completionQuery)"
    }

    private var isSuggestionPanelVisible: Bool {
        fieldIsFocused && !completionQuery.isEmpty
    }

    private var matchingBookmarks: [BrowserBookmark] {
        guard !completionQuery.isEmpty else { return [] }
        return bookmarks.filter { bookmark in
            bookmark.displayTitle.localizedCaseInsensitiveContains(completionQuery)
                || bookmark.urlString.localizedCaseInsensitiveContains(completionQuery)
        }
    }

    private var matchingRecentSearches: [String] {
        guard !completionQuery.isEmpty else { return [] }
        return recentSearches.filter { $0.localizedCaseInsensitiveContains(completionQuery) }
    }

    private var matchingOpenTabs: [BrowserTab] {
        guard !completionQuery.isEmpty else { return [] }
        return openTabs.filter { tab in
            !tab.urlString.isEmpty
                && (tab.displayTitle.localizedCaseInsensitiveContains(completionQuery)
                    || tab.urlString.localizedCaseInsensitiveContains(completionQuery))
        }
    }

    /// The visible screen's height, used to work out how much room the panel
    /// has. Falls back to a typical laptop display so the arithmetic still
    /// lands somewhere sensible when there is no screen to ask.
    private var panelScreenHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? SuggestionPanelLayout.fallbackScreenHeight
    }

    /// How far the field sits below the top of the visible screen. The panel
    /// opens downwards from there, so this is what its budget is measured
    /// against.
    private var panelTopAllowance: CGFloat {
        style == .toolbar
            ? SuggestionPanelLayout.toolbarTopAllowance
            : SuggestionPanelLayout.newTabTopAllowance
    }

    /// How the available rows are shared between the sections.
    ///
    /// Derived rather than fixed: the panel grows and shrinks with the display,
    /// so a short screen shows fewer rows instead of pushing the last ones off
    /// the bottom, and a tall one is not left half empty.
    private var suggestionCapacity: SuggestionCapacity {
        SuggestionPanelLayout.allocate(
            capacity: SuggestionPanelLayout.rowCapacity(
                screenHeight: panelScreenHeight,
                offsetFromTop: panelTopAllowance
            ),
            bookmarkMatches: matchingBookmarks.count,
            recentMatches: matchingRecentSearches.count,
            tabMatches: matchingOpenTabs.count,
            remoteMatches: suggestions.count
        )
    }

    private var visibleBookmarks: [BrowserBookmark] {
        Array(matchingBookmarks.prefix(suggestionCapacity.bookmarks))
    }

    private var visibleRecentSearches: [String] {
        Array(matchingRecentSearches.prefix(suggestionCapacity.recentSearches))
    }

    private var visibleOpenTabs: [BrowserTab] {
        Array(matchingOpenTabs.prefix(suggestionCapacity.openTabs))
    }

    private var visibleSuggestions: [String] {
        Array(suggestions.prefix(suggestionCapacity.remote))
    }

    private var visibleLocalSuggestionCount: Int {
        visibleBookmarks.count + visibleRecentSearches.count + visibleOpenTabs.count
    }

    /// How many fixed rows sit above the local matches.
    ///
    /// The engine route is always there. The assistant route is not: once a
    /// shortcut such as `!maps` is committed, the field is pointed at a
    /// destination a model cannot answer from, so offering "Chat" only invites a
    /// question that would be sent with a maps URL attached. Tab therefore
    /// removes it, and every row below shifts up by one — which is why the
    /// offsets are derived from this rather than written as a literal 2.
    private var routeRowCount: Int { assistantOnly ? 1 : (activeShortcut == nil ? 2 : 1) }

    /// The height the overlay needs so pointer hits reach every visible row.
    private var suggestionHostHeight: CGFloat {
        style.suggestionOffset + suggestionPanelHeight
    }

    private var suggestionPanelHeight: CGFloat {
        min(suggestionContentHeight,
            max(100, viewportHeight - fieldBottom - (style.suggestionOffset - style.height) - 18))
    }

    private var placeholder: String {
        if assistantOnly { return "Ask the assistant about these files…" }
        return activeShortcut?.displayName(using: searchEngine) ?? (style.isFloating ? "Search or ask anything…" : searchEngine.displayName)
    }

    var body: some View {
        HStack(spacing: 9) {
            if style == .toolbar && !fieldIsFocused {
                Button {
                    activateAddressField()
                } label: {
                    HStack(spacing: 7) {
                        if let label = AddressBarPresentation.label(for: text) {
                            Text(label.primary)
                                .foregroundStyle(.primary)
                            if let detail = label.detail {
                                Text("/").foregroundStyle(.tertiary)
                                Text(detail).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(text.isEmpty ? "Search or enter address" : text)
                                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(KestrelTypography.chromeLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: style.height, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit the address or search the web")
                .accessibilityLabel("Address bar, \(text)")
                .accessibilityAction { activateAddressField() }
            } else {
                if style.isFloating || fieldIsFocused {
                    Image(systemName: addressSymbol)
                        .font(.system(size: style.isFloating ? 17 : 11, weight: .medium))
                        .foregroundStyle(addressTint)
                        .accessibilityHidden(true)

                    if let activeShortcut {
                        Text(activeShortcut.displayName(using: searchEngine))
                            .font(KestrelTypography.chromeDetail.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.055), in: Capsule())
                            .accessibilityHidden(true)
                    }
                }

                AddressTextField(
                    text: $text,
                    completionPrefix: $inlinePrefix,
                    isFocused: Binding(
                        get: { activeAddressField == focusTarget },
                        set: { focused in
                            if focused || !isHoveringSuggestions { isEditingAddress = focused }
                            if focused { activeAddressField = focusTarget }
                            else if activeAddressField == focusTarget { activeAddressField = nil }
                        }
                    ),
                    placeholder: placeholder,
                    fontSize: style.isFloating ? 18 : KestrelTypography.chromeLabelSize,
                    selectAllOnFocus: style == .toolbar,
                    completion: { prefix in
                        guard !assistantOnly, activeShortcut == nil else { return nil }
                        return InlineAddressCompletion.complete(prefix, recentSearches: recentSearches,
                            bookmarks: bookmarks, openTabs: openTabs, suggestions: suggestions)
                    },
                    onSubmit: {
                        if isSuggestionPanelVisible { chooseSuggestion(at: highlightedSuggestion) }
                        else { submitAddress() }
                    },
                    onAssistant: searchWithAssistant,
                    onMove: { direction in
                        guard isSuggestionPanelVisible else { return false }
                        let lastIndex = visibleLocalSuggestionCount + visibleSuggestions.count + routeRowCount - 1
                        highlightedSuggestion = min(max(highlightedSuggestion + direction, 0), lastIndex)
                        return true
                    },
                    onTab: {
                        guard let completion = SearchShortcut.tabCompletion(in: text) else { return false }
                        activeShortcut = completion.shortcut
                        inlinePrefix = nil
                        text = completion.remainingQuery
                        suggestions = []
                        return true
                    },
                    onEscape: {
                        if activeShortcut != nil { activeShortcut = nil }
                        else { onEscape() }
                    },
                    onTypedChange: { value in
                        // Deleting a query exits a search mode. Consuming its
                        // keyword with Tab also empties the editor, but must
                        // keep the newly chosen mode for the next keystroke.
                        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            activeShortcut = nil
                        }
                    },
                    onBackspaceAtStart: {
                        guard activeShortcut != nil else { return false }
                        activeShortcut = nil
                        return true
                    }
                )
                .help(assistantOnly
                      ? "Ask the assistant about the attached sources. Enter sends this only to the assistant."
                      : "Enter an address or search. Use Up and Down to choose a result, then Return to open it.")

                Button(action: submitAddress) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: style.isFloating ? 31 : 25, height: style.isFloating ? 31 : 25)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Go to address or search with \(searchEngine.displayName)")
                .accessibilityLabel("Go to address or search with \(searchEngine.displayName)")
            }
        }
        .padding(.leading, style.horizontalInset)
        .padding(.trailing, style.isFloating ? 10 : 8)
        .frame(maxWidth: .infinity, minHeight: style.height, maxHeight: style.height)
        .background {
            if !style.isFloating {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(fieldIsFocused ? 0.055 : (isHovering ? 0.045 : 0)))
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { fieldBottom = geometry.frame(in: .global).maxY }
                    .onChange(of: geometry.frame(in: .global).maxY) { _, value in fieldBottom = value }
            }
        }
        .overlay(alignment: .topLeading) {
            if isSuggestionPanelVisible {
                GeometryReader { geometry in
                    suggestionPanel
                        .frame(width: geometry.size.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: style.suggestionOffset)
                        .transition(suggestionPanelTransition)
                        .onHover { hovering in
                            isHoveringSuggestions = hovering
                            if !hovering && activeAddressField != focusTarget {
                                isEditingAddress = false
                            }
                        }
                }
                // The dropdown is drawn outside the one-line field. Give its
                // overlay host real bounds so pointer hits reach its buttons,
                // sized to the rows this display can actually show rather than
                // to a number that happens to be tall enough on one machine.
                .frame(height: suggestionHostHeight, alignment: .topLeading)
                .zIndex(10)
            }
        }
        .zIndex(isSuggestionPanelVisible ? 10 : 0)
        .onHover { isHovering = $0 }
        .animation(suggestionPanelAnimation, value: isSuggestionPanelVisible)
        .task(id: suggestionTaskID) {
            guard !suggestionQuery.isEmpty else {
                suggestions = []
                highlightedSuggestion = 0
                return
            }

            suggestions = []
            highlightedSuggestion = 0
            // Keep the first rows immediate and the network debounce short
            // enough that suggestions feel like they unfold with typing.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let results = await SearchSuggestions.fetch(for: suggestionQuery, engine: searchEngine)
            guard !Task.isCancelled else { return }
            suggestions = results
        }
        .onAppear {
            if focusOnAppear {
                isEditingAddress = true
                activeAddressField = focusTarget
            }
        }
        .onChange(of: activeAddressField) { _, focusedField in
            if focusedField == focusTarget {
                isEditingAddress = true
            } else if !isHoveringSuggestions {
                isEditingAddress = false
                inlinePrefix = nil
                activeShortcut = nil
            }
        }
        .onChange(of: assistantOnly) { _, isAssistantOnly in
            guard isAssistantOnly else { return }
            activeShortcut = nil
            suggestions = []
            highlightedSuggestion = 0
            inlinePrefix = nil
        }
        .onChange(of: focusRequest) { _, request in
            guard request != nil, style == .toolbar else { return }
            // A menu command can target the same focus target as the
            // address editor's last focus. Explicitly enter editing mode so
            // the collapsed display button does not swallow the request.
            activateAddressField()
        }
        .onChange(of: completionQuery) { _, _ in highlightedSuggestion = 0 }
    }

    private var suggestionPanel: some View {
        let shape = RoundedRectangle(cornerRadius: suggestionCornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        return ScrollViewReader { reader in
            ScrollView {
                suggestionRows
                    .padding(.horizontal, 9)
                    .padding(.vertical, 9)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { suggestionContentHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { _, height in suggestionContentHeight = height }
                        }
                    }
            }
            .scrollIndicators(.hidden)
            .frame(height: suggestionPanelHeight)
            .onChange(of: highlightedSuggestion) { _, index in
                reader.scrollTo(index, anchor: .center)
            }
        }
        .background { shape.fill(ComposerAccessoryPalette.composerSurface(isDark: dark)) }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(ComposerAccessoryPalette.composerSurfaceEdge(isDark: dark), lineWidth: 1.0)
        }
        .overlay {
            shape.strokeBorder(Color.white.opacity(dark ? 0.07 : 0.86), lineWidth: 0.75)
                .padding(1)
                .allowsHitTesting(false)
        }
        .shadow(color: ComposerAccessoryPalette.lavender.opacity(dark ? 0.025 : 0.12), radius: dark ? 7 : 13, x: 0, y: 5)
        .shadow(color: Color.black.opacity(dark ? 0.16 : 0.045), radius: 12, x: 0, y: 5)
        .shadow(color: Color.primary.opacity(0.045), radius: 2, x: 0, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(assistantOnly ? "Assistant route for attached files" : "\(searchEngine.displayName) search suggestions")
    }

    private var suggestionRows: some View {
        VStack(spacing: 5) {
            if assistantOnly {
                routeSuggestion(
                    index: 0,
                    symbol: "bubble.left",
                    suffix: "— Assistant",
                    shortcut: "↩"
                ) {
                    searchWithAssistant()
                }
            } else {
            routeSuggestion(
                index: 0,
                symbol: "magnifyingglass",
                // With a shortcut committed the destination is not the default
                // engine any more, and saying "Google" over a Google Maps search
                // is simply wrong.
                suffix: "— \(activeShortcut?.displayName(using: searchEngine) ?? searchEngine.displayName)",
                shortcut: "↩"
            ) {
                submitAddress()
            }

            if activeShortcut == nil {
                routeSuggestion(
                    index: 1,
                    symbol: "bubble.left",
                    suffix: "— Chat",
                    shortcut: "⌘↩"
                ) {
                    searchWithAssistant()
                }
            }

            if !visibleBookmarks.isEmpty {
                suggestionSection("Bookmarks")
                VStack(spacing: 2) {
                    ForEach(Array(visibleBookmarks.enumerated()), id: \.element.id) { offset, bookmark in
                        localCompletionSuggestion(
                            title: bookmark.displayTitle,
                            subtitle: bookmark.urlString,
                            symbol: "bookmark.fill",
                            index: offset + routeRowCount
                        ) {
                            onOpenBookmark(bookmark)
                        }
                    }
                }
            }

            if !visibleRecentSearches.isEmpty {
                suggestionSection("Recent searches")
                VStack(spacing: 2) {
                    ForEach(Array(visibleRecentSearches.enumerated()), id: \.offset) { offset, query in
                        localCompletionSuggestion(
                            title: query,
                            subtitle: "Search with \(searchEngine.displayName)",
                            symbol: "clock.arrow.circlepath",
                            index: offset + routeRowCount + visibleBookmarks.count
                        ) {
                            text = query
                            activeShortcut = nil
                            submitAddress()
                        }
                    }
                }
            }

            if !visibleOpenTabs.isEmpty {
                suggestionSection("Tabs")
                VStack(spacing: 2) {
                    ForEach(Array(visibleOpenTabs.enumerated()), id: \.element.id) { offset, tab in
                        localCompletionSuggestion(
                            title: tab.displayTitle,
                            subtitle: tab.hostLabel,
                            symbol: "rectangle.on.rectangle",
                            index: offset + routeRowCount + visibleBookmarks.count + visibleRecentSearches.count
                        ) {
                            onSelectTab(tab)
                        }
                    }
                }
            }

            if !visibleSuggestions.isEmpty {
                suggestionSection("Search suggestions · \(searchEngine.displayName)")

                VStack(spacing: 2) {
                    ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { offset, suggestion in
                        completionSuggestion(suggestion, index: offset + routeRowCount + visibleLocalSuggestionCount)
                    }
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.075))
                .frame(height: 1)
                .padding(.horizontal, 9)
                .padding(.top, 6)

            HStack(spacing: 10) {
                Label("Search the web", systemImage: "magnifyingglass")
                    .font(KestrelTypography.chromeLabel.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: submitAddress) {
                    HStack(spacing: 8) {
                        Text(activeShortcut?.displayName(using: searchEngine) ?? searchEngine.displayName)
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                    }
                    .font(KestrelTypography.chromeLabel.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .background(Color.primary.opacity(0.88), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search with \(activeShortcut?.displayName(using: searchEngine) ?? searchEngine.displayName)")
            }
            .padding(.horizontal, 7)
            .padding(.top, 7)
            }
        }
        .padding(9)
    }

    private func routeSuggestion(
        index: Int,
        symbol: String,
        suffix: String,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(index == highlightedSuggestion ? Color.primary : Color.secondary)
                    .frame(width: 22)

                (Text(completionQuery).foregroundColor(.primary)
                    + Text(" \(suffix)").foregroundColor(.secondary))
                    .font(KestrelTypography.searchSuggestion)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(shortcut)
                    .font(KestrelTypography.chromeDetail.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 7)
            }
            .padding(.horizontal, 13)
            .frame(height: 46)
            .background {
                if index == highlightedSuggestion {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .id(index)
        .accessibilityLabel(assistantOnly
            ? "Ask the assistant about \(completionQuery)"
            : "Search for \(completionQuery) with \(index == 0 ? (activeShortcut?.displayName(using: searchEngine) ?? searchEngine.displayName) : "Chat")")
    }

    private func suggestionSection(_ title: String) -> some View {
        Text(title.uppercased())
            .font(KestrelTypography.chromeDetail.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.top, 5)
    }

    private func localCompletionSuggestion(
        title: String,
        subtitle: String,
        symbol: String,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(index == highlightedSuggestion ? Color.primary : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(KestrelTypography.searchSuggestion)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(KestrelTypography.chromeDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 13)
            .frame(height: 46)
            .background {
                if index == highlightedSuggestion {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .id(index)
    }

    private func completionSuggestion(_ suggestion: String, index: Int) -> some View {
        Button {
            chooseSuggestion(at: index)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                completionText(suggestion)
                    .font(KestrelTypography.searchSuggestion)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 13)
            .frame(height: 46)
            .background {
                if index == highlightedSuggestion {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .id(index)
        .accessibilityLabel(suggestion)
        .accessibilityHint("Search with \(searchEngine.displayName)")
    }

    private func completionText(_ suggestion: String) -> Text {
        guard let range = suggestion.range(
            of: completionQuery,
            options: [.caseInsensitive, .anchored]
        ) else {
            return Text(suggestion)
        }

        let matchedQuery = String(suggestion[..<range.upperBound])
        let completion = String(suggestion[range.upperBound...])
        return Text(matchedQuery) + Text(completion).fontWeight(.semibold)
    }

    private func chooseSuggestion(at index: Int) {
        if assistantOnly, index == 0 {
            searchWithAssistant()
            return
        }
        if index == 0 {
            submitAddress()
            return
        }
        // The assistant route is only drawn while no shortcut is committed, so
        // with one active index 1 means the first local row instead.
        if index == 1, activeShortcut == nil {
            searchWithAssistant()
            return
        }
        // Indexed against the same rows the panel drew, not against every
        // match: the two have to agree or a click lands on the wrong row.
        let localIndex = index - routeRowCount
        if visibleBookmarks.indices.contains(localIndex) {
            onOpenBookmark(visibleBookmarks[localIndex])
            return
        }
        let historyIndex = localIndex - visibleBookmarks.count
        if visibleRecentSearches.indices.contains(historyIndex) {
            text = visibleRecentSearches[historyIndex]
            activeShortcut = nil
            submitAddress()
            return
        }
        let tabIndex = historyIndex - visibleRecentSearches.count
        if visibleOpenTabs.indices.contains(tabIndex) {
            onSelectTab(visibleOpenTabs[tabIndex])
            return
        }
        let remoteIndex = tabIndex - visibleOpenTabs.count
        guard visibleSuggestions.indices.contains(remoteIndex) else { return }
        text = visibleSuggestions[remoteIndex]
        submitAddress()
    }

    private var addressSymbol: String {
        if assistantOnly { return "bubble.left" }
        return switch URL(string: text)?.scheme?.lowercased() {
        case "https": "lock.fill"
        case "http": "exclamationmark.triangle.fill"
        default: "magnifyingglass"
        }
    }

    private var addressTint: Color {
        URL(string: text)?.scheme?.lowercased() == "http" ? .orange : .secondary
    }

    private func activateAddressField() {
        isEditingAddress = true
        activeAddressField = focusTarget
    }

    private func submitAddress() {
        if assistantOnly {
            searchWithAssistant()
            return
        }
        guard let query = preparedQuery() else { return }
        suggestions = []
        activeAddressField = nil
        onSubmit(query)
    }

    private func searchWithAssistant() {
        guard let query = preparedQuery() else { return }
        suggestions = []
        activeAddressField = nil
        onAssistantSearch(query)
    }

    private func preparedQuery() -> String? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return assistantOnly ? "" : nil }
        let prepared = activeShortcut.map { "!\($0.rawValue) \(query)" } ?? query
        activeShortcut = nil
        return prepared
    }
}

private struct PageFaviconView: View {
    let tab: BrowserTab
    let isSelected: Bool
    let size: CGFloat
    let showsPinBadge: Bool
    let drawsTile: Bool
    let onAccentColour: ((Color) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    init(
        tab: BrowserTab,
        isSelected: Bool,
        size: CGFloat = 16,
        showsPinBadge: Bool = true,
        drawsTile: Bool = true,
        onAccentColour: ((Color) -> Void)? = nil
    ) {
        self.tab = tab
        self.isSelected = isSelected
        self.size = size
        self.showsPinBadge = showsPinBadge
        self.drawsTile = drawsTile
        self.onAccentColour = onAccentColour
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            favicon
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: min(size * 0.18, 4), style: .continuous))

            if tab.isPinned && showsPinBadge {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: drawsTile ? size + 9 : size, height: drawsTile ? size + 9 : size)
        .background {
            if drawsTile {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    // Neutral rather than accent-tinted: this tile sits inside
                    // the selected tab's near-white surface, where an accent
                    // wash would reintroduce the blue the surface exists to
                    // avoid.
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0), lineWidth: 0.6)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var favicon: some View {
        // An assistant tab has no site to draw a mark for. A globe there would
        // read as "a page that failed to load", so it gets the chat's own icon
        // and the rail says what the row is at a glance.
        if tab.isAssistant {
            assistantIcon
        } else if let url = tab.faviconSourceURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .onAppear {
                            if let onAccentColour { onAccentColour(Self.accentColour(for: image)) }
                        }
                } else {
                    fallbackIcon
                }
            }
        } else {
            fallbackIcon
        }
    }

    /// Samples only the already loaded favicon. Ignore transparent/grey pixels
    /// so a white surround does not turn Reddit's orange or YouTube's red grey.
    @MainActor
    private static func accentColour(for image: Image) -> Color {
        let renderer = ImageRenderer(content: image.resizable().frame(width: 24, height: 24))
        guard let cgImage = renderer.cgImage else { return .secondary }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var buckets = Array(repeating: (weight: 0.0, red: 0.0, green: 0.0, blue: 0.0), count: 12)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      colour.alphaComponent > 0.5, colour.saturationComponent > 0.35,
                      colour.brightnessComponent > 0.25 else { continue }
                let index = min(11, Int(colour.hueComponent * 12))
                let weight = Double(colour.saturationComponent * colour.alphaComponent)
                buckets[index].weight += weight
                buckets[index].red += Double(colour.redComponent) * weight
                buckets[index].green += Double(colour.greenComponent) * weight
                buckets[index].blue += Double(colour.blueComponent) * weight
            }
        }
        guard let best = buckets.max(by: { $0.weight < $1.weight }), best.weight > 1 else { return .secondary }
        return Color(red: best.red / best.weight, green: best.green / best.weight, blue: best.blue / best.weight)
    }

    private var assistantIcon: some View {
        Image(systemName: "bubble.left.and.bubble.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.secondary)
    }

    private var fallbackIcon: some View {
        Image(systemName: "globe")
            .font(.system(size: 11, weight: .medium))
            // On a selected tab the tile behind this is near-white in both
            // colour schemes, so the icon needs a fixed dark grey rather than
            // the scheme-dependent accent or `.secondary`.
            .foregroundStyle(Color.secondary)
    }
}

extension View {
    /// Prefer the clearer native glass style; keep a softer, lighter material
    /// treatment on the app's macOS 14 deployment baseline.
    @ViewBuilder
    func kestrelGlass<GlassShape: InsettableShape>(in shape: GlassShape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.clear, in: shape)
        } else {
            background(.thinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
                }
        }
    }
}

#endif
