#if canImport(SwiftUI) && canImport(WebKit)

import AppKit
import SwiftUI
import WebKit

/// Native overlay scrollers keep the page width stable as content grows.
@MainActor
enum BrowserScrollbars {
    static func apply(to view: NSView) {
        if let scroll = view as? NSScrollView {
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
            if scroll.verticalScroller?.isHidden == false { scroll.verticalScroller?.isHidden = true }
            if scroll.horizontalScroller?.isHidden == false { scroll.horizontalScroller?.isHidden = true }
        }
        for child in view.subviews { apply(to: child) }
    }
}

/// Keeps one web view alive while SwiftUI decides where to draw it. TabStore
/// owns the views, so switching tabs swaps the hosted child instead of
/// rebuilding the page. A tab that is not selected keeps its web view in
/// memory, which is what preserves scroll position and form state.
final class FocusAwareWKWebView: WKWebView {
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onFocus?()
        super.keyDown(with: event)
    }
}

final class BrowserHostView: NSView {
    var onFocus: (() -> Void)? {
        didSet {
            guard let hosted, hosted.superview === self else { return }
            (hosted as? FocusAwareWKWebView)?.onFocus = onFocus
        }
    }

    var hosted: WKWebView? {
        didSet {
            guard hosted !== oldValue else { return }
            if oldValue?.superview === self {
                (oldValue as? FocusAwareWKWebView)?.onFocus = nil
                oldValue?.removeFromSuperview()
            }
            guard let hosted else { return }
            hosted.removeFromSuperview()
            hosted.frame = bounds
            hosted.autoresizingMask = [.width, .height]
            (hosted as? FocusAwareWKWebView)?.onFocus = onFocus
            addSubview(hosted)
        }
    }

    override func layout() {
        super.layout()
        // SwiftUI can retain an outgoing host during an opacity transition.
        // Its cached WKWebView may already belong to the incoming host: never
        // resize that shared view to the outgoing host's stale bounds.
        guard let hosted, hosted.superview === self else { return }
        hosted.frame = bounds
        BrowserScrollbars.apply(to: hosted)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "kestrel.debug.layout") {
            func record(_ view: NSView, depth: Int) {
                let line = "KESTREL_LAYOUT \(String(repeating: " ", count: depth))\(type(of: view)) frame=\(NSStringFromRect(view.frame)) window=\(NSStringFromRect(view.convert(view.bounds, to: nil)))\n"
                FileHandle.standardError.write(Data(line.utf8))
                for child in view.subviews { record(child, depth: depth + 1) }
            }
            record(self, depth: 0)
        }
        #endif
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        // WebKit's content subviews receive the actual mouse events, so the
        // WKWebView subclass alone cannot reliably activate a clicked pane.
        if target != nil, let event = NSApp.currentEvent,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(event.type) {
            onFocus?()
        }
        return target
    }
}

struct BrowserView: NSViewRepresentable {
    let webView: WKWebView
    var onFocus: (() -> Void)? = nil
    /// Whether the hosted web view should be drawn.
    ///
    /// A tab with no page still owns a web view, and that view is not blank: it
    /// paints its own background. That background is white in the light
    /// appearance, and it can flash white when the window loses focus, so a new
    /// tab page was being painted by WebKit rather than by the surface behind it
    /// — which is why it looked light in dark mode and went bright on click-out.
    /// The view stays in the hierarchy while hidden, so a tab still loads and
    /// keeps its scroll position and form state.
    var isHidden: Bool = false

    func makeNSView(context: Context) -> BrowserHostView {
        let host = BrowserHostView()
        host.onFocus = onFocus
        host.hosted = webView
        host.isHidden = isHidden
        return host
    }

    func updateNSView(_ nsView: BrowserHostView, context: Context) {
        nsView.onFocus = onFocus
        nsView.hosted = webView
        nsView.isHidden = isHidden
    }
}

#endif
