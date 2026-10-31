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

/// Hosts a persistent Chrome-runtime browser in Kestrel's page region. The CEF
/// browser itself is owned by TabStore, so removing this SwiftUI host while
/// changing tabs only hides the page; it does not destroy it.
struct BrowserView: View {
    let chromeBrowser: CefChromeBrowser?
    let pageOverlay: AnyView
    var onFocus: (() -> Void)? = nil
    var isHidden = false
    var isVisible = true

    var body: some View {
        Group {
            if let chromeBrowser, !isHidden {
                PersistentChromeHost(browser: chromeBrowser, pageOverlay: pageOverlay,
                                     isVisible: isVisible, onFocus: onFocus)
            } else {
                Color.clear
            }
        }
        .contentShape(Rectangle())
    }
}

private struct PersistentChromeHost: NSViewRepresentable {
    let browser: CefChromeBrowser
    let pageOverlay: AnyView
    let isVisible: Bool
    let onFocus: (() -> Void)?

    func makeNSView(context: Context) -> PersistentChromeHostView {
        let view = PersistentChromeHostView()
        view.browser = browser
        view.pageOverlay = pageOverlay
        view.isVisible = isVisible
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ nsView: PersistentChromeHostView, context: Context) {
        nsView.browser = browser
        nsView.pageOverlay = pageOverlay
        nsView.isVisible = isVisible
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
        didSet { updateOverlay() }
    }
    var isVisible = true {
        didSet { updateOverlay() }
    }
    var pageOverlay: AnyView? {
        didSet { updateNativeOverlay() }
    }
    var onFocus: (() -> Void)?

    private var windowObservers: [NSObjectProtocol] = []
    private var nativeOverlay: NSHostingView<AnyView>?

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
            let target = window.convertToScreen(convert(bounds, to: nil))
            if overlay.frame != target { overlay.setFrame(target, display: true) }
            overlay.orderFront(nil)
        } else {
            overlay.parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
    }

    /// Detaches the child window but leaves its CEF browser and page running.
    func parkBrowser() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let overlay = browser?.nsWindow else { return }
        overlay.parent?.removeChildWindow(overlay)
        overlay.orderOut(nil)
    }

    private func updateNativeOverlay() {
        guard let pageOverlay, let root = browser?.rootView else {
            nativeOverlay?.removeFromSuperview()
            nativeOverlay = nil
            return
        }
        let host = nativeOverlay ?? NSHostingView(rootView: pageOverlay)
        host.rootView = pageOverlay
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        if host.superview !== root {
            host.removeFromSuperview()
            root.addSubview(host, positioned: .above, relativeTo: nil)
        }
        nativeOverlay = host
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
        if let child = browser?.nsWindow {
            windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: child, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocus?() }
            })
        }
    }
}

#endif
