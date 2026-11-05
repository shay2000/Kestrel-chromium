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
    private weak var headerAccessibilityWindow: NSWindow?
    private var originalAccessibilityChildren: [Any]?
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
            attachment.isNativeControlPoint = { [weak self] point in
                self?.nativeHeader?.containsNativeControl(pointInWindow: point) ?? false
            }
            attachment.handleNativeControlEvent = { [weak self] event in
                self?.nativeHeader?.routeNativeControlEvent(event) ?? false
            }
            // The native CEF window contains the toolbar and page together.
            // Its system corner clip now surrounds the complete card rather
            // than cutting a second curve below the toolbar.
            if insetHeight != headerHeight {
                browser?.setContentInsets(top: Double(headerHeight))
                insetHeight = headerHeight
            }
            overlay.titlebarAppearsTransparent = true
            overlay.titleVisibility = .hidden
            if !overlay.styleMask.contains(.fullSizeContentView) { overlay.styleMask.insert(.fullSizeContentView) }
            if overlay.appearance !== window.effectiveAppearance { overlay.appearance = window.effectiveAppearance }
            overlay.isExcludedFromWindowsMenu = true
            if !overlay.collectionBehavior.contains(.fullScreenAuxiliary) { overlay.collectionBehavior.insert(.fullScreenAuxiliary) }
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
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    overlay.standardWindowButton(type)?.isHidden = true
                }
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
        detachNativeHeader()
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
            detachNativeHeader()
            return
        }
        let host = nativeHeader ?? HeaderHostingView(rootView: AnyView(EmptyView()))
        host.headerHeight = headerHeight
        let radius: CGFloat
        if #available(macOS 26, *) { radius = 20 } else { radius = 16 }
        host.rootView = AnyView(ZStack {
            VStack(spacing: 0) {
                header.frame(height: headerHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Browser toolbar")
                Spacer(minLength: 0).allowsHitTesting(false)
            }
            if let isSelectedPane {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelectedPane ? 0.25 : 0.06), lineWidth: isSelectedPane ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
            if showsWindowControls && !owner.styleMask.contains(.fullScreen) {
                NativeDocumentWindowControls().frame(width: 84, height: headerHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // This hosting view is an overlay in CEF's full-size content view.
        // SwiftUI otherwise reserves the native titlebar's safe area a
        // second time, moving the toolbar below its native hit-test region
        // and covering the first rows of the webpage.
        .ignoresSafeArea()
        .environment(\.browserViewportHeight, max(1, root.bounds.height - headerHeight))
        .environment(\.controlActiveState, BrowserWindowFocus.isActive(owner) ? .active : .inactive)
        .environment(\.colorScheme, owner.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
        .onPreferenceChange(BrowserHeaderHitRegions.self) { [weak host, weak self] regions in
            host?.dropdownRegions = regions
            if let browser = self?.browser {
                CefBrowserRegistry.setChromeOverlayVisible(!regions.isEmpty, for: browser.browser)
            }
        })
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
        // BridgedContentView exposes Chromium's AX tree instead of ordinary
        // AppKit subviews. Preserve that tree and add our native toolbar at
        // the window level so VoiceOver and normal AX clients can reach it.
        if let page = root.window, headerAccessibilityWindow !== page {
            headerAccessibilityWindow = page
            originalAccessibilityChildren = page.accessibilityChildren()
            host.setAccessibilityElement(true)
            host.setAccessibilityRole(.toolbar)
            host.setAccessibilityLabel("Kestrel browser controls")
            host.setAccessibilityParent(page)
            page.setAccessibilityChildren((originalAccessibilityChildren ?? []) + [host])
        }
    }

    private func detachNativeHeader() {
        if let browser { CefBrowserRegistry.setChromeOverlayVisible(false, for: browser.browser) }
        headerAccessibilityWindow?.setAccessibilityChildren(originalAccessibilityChildren)
        headerAccessibilityWindow = nil
        originalAccessibilityChildren = nil
        nativeHeader?.setAccessibilityParent(nil)
        nativeHeader?.removeFromSuperview()
        nativeHeader = nil
    }

    private final class HeaderHostingView: NSHostingView<AnyView> {
        var headerHeight: CGFloat = 0
        var dropdownRegions: [CGRect] = []
        private weak var leftTarget: NSView?
        private weak var rightTarget: NSView?
        private weak var otherTarget: NSView?

        /// BridgedContentView returns itself for CEF Views' non-web areas,
        /// before asking AppKit subviews to hit-test. Dispatch the original
        /// event to our own native controls and consume it once. Keep a drag
        /// bound to its initial target, including release outside the header.
        /// Page gestures never acquire a toolbar target.
        func routeNativeControlEvent(_ event: NSEvent) -> Bool {
            switch event.type {
            case .leftMouseDragged:
                guard let target = leftTarget else { return false }
                target.mouseDragged(with: event); return true
            case .leftMouseUp:
                guard let target = leftTarget else { return false }
                leftTarget = nil; target.mouseUp(with: event); return true
            case .rightMouseDragged:
                guard let target = rightTarget else { return false }
                target.rightMouseDragged(with: event); return true
            case .rightMouseUp:
                guard let target = rightTarget else { return false }
                rightTarget = nil; target.rightMouseUp(with: event); return true
            case .otherMouseDragged:
                guard let target = otherTarget else { return false }
                target.otherMouseDragged(with: event); return true
            case .otherMouseUp:
                guard let target = otherTarget else { return false }
                otherTarget = nil; target.otherMouseUp(with: event); return true
            case .leftMouseDown: leftTarget = nil
            case .rightMouseDown: rightTarget = nil
            case .otherMouseDown: otherTarget = nil
            case .mouseMoved, .scrollWheel: break
            default: return false
            }
            guard let superview,
                  containsNativeControl(pointInWindow: event.locationInWindow),
                  let target = hitTest(superview.convert(event.locationInWindow, from: nil)) else { return false }
            switch event.type {
            case .leftMouseDown: leftTarget = target; target.mouseDown(with: event)
            case .rightMouseDown: rightTarget = target; target.rightMouseDown(with: event)
            case .otherMouseDown: otherTarget = target; target.otherMouseDown(with: event)
            case .mouseMoved: target.mouseMoved(with: event)
            case .scrollWheel: target.scrollWheel(with: event)
            default: return false
            }
            return true
        }

        override func accessibilityFrame() -> NSRect {
            guard let window else { return .zero }
            let height = min(bounds.height, max(headerHeight, dropdownRegions.map(\.maxY).max() ?? 0))
            let rect = NSRect(x: bounds.minX, y: isFlipped ? bounds.minY : bounds.maxY - height,
                              width: bounds.width, height: height)
            return window.convertToScreen(convert(rect, to: nil))
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview else { return nil }
            let local = convert(point, from: superview)
            guard containsNativeControl(localPoint: local) else { return nil }
            return super.hitTest(point)
        }
        func containsNativeControl(pointInWindow: NSPoint) -> Bool {
            containsNativeControl(localPoint: convert(pointInWindow, from: nil))
        }
        private func containsNativeControl(localPoint local: NSPoint) -> Bool {
            let top = CGPoint(x: local.x - bounds.minX,
                y: isFlipped ? local.y - bounds.minY : bounds.maxY - local.y)
            return top.y >= 0 && (top.y <= headerHeight || dropdownRegions.contains(where: { $0.contains(top) }))
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
