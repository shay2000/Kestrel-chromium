#if canImport(SwiftUI) && canImport(CefSwiftUI)

import AppKit
import CefKit
import CefSwiftUI
import SwiftUI

@MainActor
enum BrowserScrollbars {
    static func apply(to view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.verticalScroller?.isHidden = true
            scroll.horizontalScroller?.isHidden = true
        }
        view.subviews.forEach(apply)
    }
}

/// Page overlays depend on more than the title/address mirrored by TabStore.
/// Observe the actual page so loading, failure and handoff changes redraw them.
@MainActor
struct ObservedBrowserPage<Content: View>: View {
    @ObservedObject var browser: BrowserStore
    let content: (BrowserStore) -> Content

    init(browser: BrowserStore, @ViewBuilder content: @escaping (BrowserStore) -> Content) {
        self.browser = browser
        self.content = content
    }

    var body: some View { content(browser) }
}

/// Hosts a persistent Chrome-runtime browser in Kestrel's page region. The CEF
/// browser itself is owned by TabStore, so removing this SwiftUI host while
/// changing tabs only hides the page; it does not destroy it.
@MainActor
struct BrowserView: View {
    let browserID: UUID
    let browserGeneration: Int
    let makeChromeBrowser: @MainActor () -> CefChromeBrowser?
    let pageOverlay: AnyView
    var header: AnyView? = nil
    var headerHeight: CGFloat = 0
    var showsWindowControls = false
    var isSelectedPane: Bool? = nil
    var isOverlayVisible = true
    var interactiveOverlayHeight: CGFloat = 0
    var onFocus: (() -> Void)? = nil
    var isHidden = false
    var isVisible = true
    @State private var chromeBrowser: CefChromeBrowser?
    @State private var hostedBrowserID: UUID?
    @State private var hostedBrowserGeneration: Int?
    @State private var lifecycleEpoch = 0

    var body: some View {
        Group {
            if let chromeBrowser, hostedBrowserID == browserID,
               hostedBrowserGeneration == browserGeneration, !isHidden {
                PersistentChromeHost(browser: chromeBrowser, pageOverlay: pageOverlay,
                                     header: header, headerHeight: headerHeight,
                                     showsWindowControls: showsWindowControls, isSelectedPane: isSelectedPane,
                                     isOverlayVisible: isOverlayVisible,
                                     isVisible: isVisible,
                                     interactiveOverlayHeight: interactiveOverlayHeight,
                                     onFocus: onFocus)
            } else {
                Color.clear
            }
        }
        .task(id: "\(browserID.uuidString):\(browserGeneration):\(isHidden):\(lifecycleEpoch)") {
            // Existing tabs may be revealed for an unload choice during quit;
            // TabStore's factory admits no new native browser in that state.
            guard !isHidden,
                  chromeBrowser?.isWindowAlive != true || hostedBrowserID != browserID || hostedBrowserGeneration != browserGeneration else { return }
            chromeBrowser = nil
            hostedBrowserID = nil
            hostedBrowserGeneration = nil
            chromeBrowser = makeChromeBrowser()
            hostedBrowserID = browserID
            hostedBrowserGeneration = browserGeneration
        }
        .onReceive(NotificationCenter.default.publisher(for: CefRuntime.terminationCancelled)) { _ in
            lifecycleEpoch &+= 1
        }
        .contentShape(Rectangle())
    }
}

private struct PersistentChromeHost: NSViewRepresentable {
    let browser: CefChromeBrowser
    let pageOverlay: AnyView
    let header: AnyView?
    let headerHeight: CGFloat
    let showsWindowControls: Bool
    let isSelectedPane: Bool?
    let isOverlayVisible: Bool
    let isVisible: Bool
    let interactiveOverlayHeight: CGFloat
    let onFocus: (() -> Void)?

    func makeNSView(context: Context) -> PersistentChromeHostView {
        let view = PersistentChromeHostView()
        view.browser = browser
        view.pageOverlay = pageOverlay
        view.header = header
        view.headerHeight = headerHeight
        view.showsWindowControls = showsWindowControls
        view.isSelectedPane = isSelectedPane
        view.isOverlayVisible = isOverlayVisible
        view.isVisible = isVisible
        view.interactiveOverlayHeight = interactiveOverlayHeight
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ nsView: PersistentChromeHostView, context: Context) {
        nsView.browser = browser
        nsView.pageOverlay = pageOverlay
        nsView.header = header
        nsView.headerHeight = headerHeight
        nsView.showsWindowControls = showsWindowControls
        nsView.isSelectedPane = isSelectedPane
        nsView.isOverlayVisible = isOverlayVisible
        nsView.isVisible = isVisible
        nsView.interactiveOverlayHeight = interactiveOverlayHeight
        nsView.onFocus = onFocus
        nsView.updateOverlay()
    }

    static func dismantleNSView(_ nsView: PersistentChromeHostView, coordinator: ()) {
        nsView.parkBrowser()
    }
}

@MainActor
private final class PersistentChromeHostView: NSView {
    var browser: CefChromeBrowser? {
        didSet {
            if browser !== oldValue { insetHeight = nil; rebindWindowObservers() }
            updateOverlay()
        }
    }
    var isVisible = true {
        didSet { updateOverlay() }
    }
    var pageOverlay: AnyView? {
        didSet { updateNativeOverlay() }
    }
    var isOverlayVisible = true {
        didSet { updateNativeOverlay() }
    }
    var interactiveOverlayHeight: CGFloat = 0 {
        didSet { updateNativeOverlay() }
    }
    var onFocus: (() -> Void)?
    var header: AnyView?
    var headerHeight: CGFloat = 0
    var showsWindowControls = false
    var isSelectedPane: Bool?

    private var windowObservers: [NSObjectProtocol] = []
    private var nativeOverlay: ClickThroughHostingView?
    private var nativeHeader: HeaderHostingView?
    private var insetHeight: CGFloat?
    private let attachment = ChromiumWindowAttachment()
    private var loggedWindowGeometry = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebindWindowObservers()
        updateOverlay()
    }

    override func layout() {
        super.layout()
        updateOverlay()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateOverlay()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateOverlay()
    }

    func updateOverlay() {
        updateNativeOverlay()
        guard let overlay = browser?.nsWindow else { return }
        let visible = isVisible && window != nil && !isHiddenOrHasHiddenAncestor
            && (window?.isVisible ?? false) && !(window?.isMiniaturized ?? true)
            && bounds.width > 1 && bounds.height > 1

        if visible, let window {
            if overlay.parent !== window {
                overlay.parent?.removeChildWindow(overlay)
                window.addChildWindow(overlay, ordered: .above)
            }
            attachment.onFocus = onFocus
            attachment.attach(owner: window, page: overlay)
            attachment.headerHeight = headerHeight
            // The native CEF window contains the toolbar and page together.
            // Its system corner clip now surrounds the complete card rather
            // than cutting a second curve below the toolbar.
            if insetHeight != headerHeight {
                browser?.setContentInsets(top: Double(headerHeight))
                insetHeight = headerHeight
            }
            overlay.titlebarAppearsTransparent = true
            overlay.titleVisibility = .hidden
            overlay.styleMask.insert(.fullSizeContentView)
            overlay.appearance = window.effectiveAppearance
            overlay.isMovable = false
            overlay.hasShadow = false
            overlay.isOpaque = false
            overlay.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.001)
            var card = window.convertToScreen(convert(bounds, to: nil))
            card.size.height += headerHeight
            let target = BrowserPageGeometry.coveringFrame(card, scale: window.backingScaleFactor)
            if overlay.frame != target { overlay.setFrame(target, display: true) }
            if let root = browser?.rootView {
                if let browser { CefBrowserRegistry.setPageLayout(for: browser.browser, root: root, headerHeight: headerHeight) }
                updateNativeOverlay()
                updateNativeHeader(root: root, owner: window)
                configureWindowButtons(page: overlay, owner: window)
                if !loggedWindowGeometry {
                    loggedWindowGeometry = true
                    let diagnostic = "KESTREL_LIFECYCLE windowGeometry integratedHeader=\(headerHeight) root=\(type(of: root)) card=\(NSStringFromRect(root.bounds))"
                    try? FileHandle.standardError.write(contentsOf: Data((diagnostic + "\n").utf8))
                }
            }
            overlay.orderFront(nil)
        } else {
            attachment.detach()
            overlay.parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
    }

    /// Detaches the child window but leaves its CEF browser and page running.
    func parkBrowser() {
        attachment.detach()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        // The persistent CEF root outlives this SwiftUI host. Remove this
        // host's overlay so old spinners/banners cannot remain on the page.
        nativeOverlay?.removeFromSuperview()
        nativeOverlay = nil
        nativeHeader?.removeFromSuperview()
        nativeHeader = nil
        guard let overlay = browser?.nsWindow else { return }
        overlay.parent?.removeChildWindow(overlay)
        overlay.orderOut(nil)
    }

    private func updateNativeOverlay() {
        guard isOverlayVisible, let pageOverlay, let root = browser?.rootView else {
            nativeOverlay?.removeFromSuperview()
            nativeOverlay = nil
            return
        }
        let host = nativeOverlay ?? ClickThroughHostingView(rootView: pageOverlay)
        host.rootView = pageOverlay
        let page = BrowserPageGeometry.contentRect(in: root.bounds, headerHeight: headerHeight, isFlipped: root.isFlipped)
        host.frame = page
        let interactionWidth = min(624, root.bounds.width)
        let interactionHeight = min(max(0, interactiveOverlayHeight), page.height)
        let interactionY = root.isFlipped
            ? page.minY
            : page.maxY - interactionHeight
        host.interactiveRegion = CGRect(
            x: root.bounds.midX - interactionWidth / 2,
            y: interactionY,
            width: interactionWidth,
            height: interactionHeight
        )
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        if host.superview !== root {
            host.removeFromSuperview()
            root.addSubview(host, positioned: .above, relativeTo: nil)
        }
        nativeOverlay = host
    }

    private func updateNativeHeader(root: NSView, owner: NSWindow) {
        guard let header, headerHeight > 0 else {
            nativeHeader?.removeFromSuperview(); nativeHeader = nil
            return
        }
        let host = nativeHeader ?? HeaderHostingView(rootView: AnyView(EmptyView()))
        host.headerHeight = headerHeight
        let radius: CGFloat
        if #available(macOS 26, *) { radius = 20 } else { radius = 16 }
        host.rootView = AnyView(ZStack {
            VStack(spacing: 0) {
                header.frame(height: headerHeight)
                Spacer(minLength: 0).allowsHitTesting(false)
            }
            if let isSelectedPane {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelectedPane ? 0.25 : 0.06), lineWidth: isSelectedPane ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.browserViewportHeight, max(1, root.bounds.height - headerHeight))
        .environment(\.controlActiveState, BrowserWindowFocus.isActive(owner) ? .active : .inactive)
        .environment(\.colorScheme, owner.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
        .onPreferenceChange(BrowserHeaderHitRegions.self) { [weak host] regions in host?.dropdownRegions = regions })
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        if host.superview !== root {
            host.removeFromSuperview()
            root.addSubview(host, positioned: .above, relativeTo: nil)
        } else if root.subviews.last !== host {
            root.addSubview(host, positioned: .above, relativeTo: nil)
        }
        nativeHeader = host
    }

    private func configureWindowButtons(page: NSWindow, owner: NSWindow) {
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = page.standardWindowButton(type) else { continue }
            button.isHidden = !showsWindowControls || owner.styleMask.contains(.fullScreen)
            button.isEnabled = (owner.standardWindowButton(type)?.isEnabled ?? false)
                && owner.attachedSheet == nil && page.attachedSheet == nil && NSApp.modalWindow == nil
            button.tag = index
            button.target = self
            button.action = #selector(performDocumentWindowAction(_:))
            if let container = button.superview {
                let origin = NSPoint(x: 12 + CGFloat(index) * 23,
                    y: container.bounds.midY - button.frame.height / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }

    @objc private func performDocumentWindowAction(_ sender: NSButton) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard types.indices.contains(sender.tag), let owner = window,
              owner.attachedSheet == nil, browser?.nsWindow?.attachedSheet == nil,
              NSApp.modalWindow == nil else { return }
        owner.standardWindowButton(types[sender.tag])?.performClick(sender)
    }

    private final class HeaderHostingView: NSHostingView<AnyView> {
        var headerHeight: CGFloat = 0
        var dropdownRegions: [CGRect] = []
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview else { return nil }
            let local = convert(point, from: superview)
            let top = CGPoint(x: local.x - bounds.minX,
                y: isFlipped ? local.y - bounds.minY : bounds.maxY - local.y)
            guard top.y >= 0, top.y <= headerHeight || dropdownRegions.contains(where: { $0.contains(top) }) else { return nil }
            return super.hitTest(point)
        }
    }

    /// The SwiftUI overlay lives above CEF's view. Its decorative contents
    /// should not intercept page clicks or text selection; only the small
    /// centered banner area remains interactive when a banner is visible.
    private final class ClickThroughHostingView: NSHostingView<AnyView> {
        var interactiveRegion = CGRect.zero

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard interactiveRegion.contains(point) else { return nil }
            return super.hitTest(point)
        }
    }

    private func rebindWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didMoveNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOverlay() }
            })
        }
    }
}

#endif
