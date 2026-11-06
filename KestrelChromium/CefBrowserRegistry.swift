#if canImport(CefKit) && canImport(CefSwiftUI)

import CefKit
import CefSwiftUI
import Foundation
import AppKit

/// CefChromeBrowser creates browsers outside CefWebView's hosting view, so
/// CefWebViewModel's package-internal attach hook is unavailable to Kestrel.
/// This registry gives the app's observable model access to its CEF browser.
@MainActor
enum CefBrowserRegistry {
    private struct Entry {
        weak var model: CefWebViewModel?
        let browser: CefBrowser
        weak var rootView: NSView?
        var headerHeight: CGFloat = 0
        var chromeOverlayVisible = false
    }
    private static var browsers: [ObjectIdentifier: Entry] = [:]

    static func browser(for model: CefWebViewModel) -> CefBrowser? {
        let key = ObjectIdentifier(model)
        guard let entry = browsers[key], entry.model === model else {
            browsers[key] = nil
            return nil
        }
        return entry.browser
    }

    static func attach(_ browser: CefBrowser, to model: CefWebViewModel) {
        browsers[ObjectIdentifier(model)] = Entry(model: model, browser: browser)
    }

    static func setPageLayout(for browser: CefBrowser, root: NSView, headerHeight: CGFloat) {
        guard let key = browsers.first(where: { $0.value.browser === browser })?.key else { return }
        browsers[key]?.rootView = root
        browsers[key]?.headerHeight = headerHeight
    }

    static func setChromeOverlayVisible(_ visible: Bool, for browser: CefBrowser) {
        guard let key = browsers.first(where: { $0.value.browser === browser })?.key else { return }
        browsers[key]?.chromeOverlayVisible = visible
    }

    static func hasChromeOverlay(for model: CefWebViewModel) -> Bool {
        browsers[ObjectIdentifier(model)]?.chromeOverlayVisible ?? false
    }

    static func pageBounds(for model: CefWebViewModel) -> CGRect {
        guard let entry = browsers[ObjectIdentifier(model)], entry.model === model,
              let view = entry.browser.nativeView else { return .zero }
        guard let root = entry.rootView, let window = root.window, window === view.window else {
            return entry.headerHeight > 0 ? .zero : view.bounds
        }
        let page = BrowserPageGeometry.contentRect(in: root.bounds,
            headerHeight: entry.headerHeight, isFlipped: root.isFlipped)
        return view.convert(page, from: root).intersection(view.bounds)
    }

    static func detach(from model: CefWebViewModel, matching browser: CefBrowser? = nil) {
        let key = ObjectIdentifier(model)
        guard browser == nil || browsers[key]?.browser === browser else { return }
        browsers[key] = nil
    }
}

@MainActor
extension CefWebViewModel {
    var kestrelBrowser: CefBrowser? { CefBrowserRegistry.browser(for: self) }
    var kestrelPageBounds: CGRect { CefBrowserRegistry.pageBounds(for: self) }
    var kestrelHasChromeOverlay: Bool { CefBrowserRegistry.hasChromeOverlay(for: self) }

    func kestrelAttach(_ browser: CefBrowser) {
        CefBrowserRegistry.attach(browser, to: self)
    }

    func kestrelDetach(matching browser: CefBrowser? = nil) {
        CefBrowserRegistry.detach(from: self, matching: browser)
    }

    func kestrelLoad(_ url: URL) {
        if self.url != url { self.url = url }
        kestrelBrowser?.load(url)
    }

    func kestrelGoBack() { kestrelBrowser?.goBack() }
    func kestrelGoForward() { kestrelBrowser?.goForward() }
    func kestrelReload() { kestrelBrowser?.reload() }
    func kestrelStopLoading() { kestrelBrowser?.stopLoading() }
    func kestrelExecuteJavaScript(_ source: String) { kestrelBrowser?.executeJavaScript(source) }
}

#endif
