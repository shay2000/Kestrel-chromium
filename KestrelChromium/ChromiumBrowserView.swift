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
    let isOverlayVisible: Bool
    let isVisible: Bool
    let interactiveOverlayHeight: CGFloat
    let onFocus: (() -> Void)?

    func makeNSView(context: Context) -> PersistentChromeHostView {
        let view = PersistentChromeHostView()
        view.browser = browser
        view.pageOverlay = pageOverlay
        view.isOverlayVisible = isOverlayVisible
        view.isVisible = isVisible
        view.interactiveOverlayHeight = interactiveOverlayHeight
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ nsView: PersistentChromeHostView, context: Context) {
        nsView.browser = browser
        nsView.pageOverlay = pageOverlay
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
            if browser !== oldValue { rebindWindowObservers() }
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

    private var windowObservers: [NSObjectProtocol] = []
    private var nativeOverlay: ClickThroughHostingView?
    private let attachment = ChromiumWindowAttachment()

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
            // The enclosing SwiftUI card owns its top corners and toolbar.
            // A separately rounded/shadowed CEF window creates a visible notch
            // below that toolbar because SwiftUI cannot clip another NSWindow.
            overlay.hasShadow = false
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            if let root = overlay.contentView {
                root.wantsLayer = true
                if let layer = root.layer {
                    layer.cornerRadius = 10
                    layer.maskedCorners = layer.isGeometryFlipped
                        ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                        : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                    layer.masksToBounds = true
                }
            }
            let target = BrowserPageGeometry.coveringFrame(window.convertToScreen(convert(bounds, to: nil)), scale: window.backingScaleFactor)
            if overlay.frame != target { overlay.setFrame(target, display: true) }
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
        host.frame = root.bounds
        let interactionWidth = min(624, root.bounds.width)
        let interactionHeight = min(max(0, interactiveOverlayHeight), root.bounds.height)
        let interactionY = root.isFlipped
            ? root.bounds.minY
            : root.bounds.maxY - interactionHeight
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
