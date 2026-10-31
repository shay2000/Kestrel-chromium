#if canImport(CefKit) && canImport(CefSwiftUI)

import CefKit
import CefSwiftUI
import Foundation

/// CefChromeBrowser creates browsers outside CefWebView's hosting view, so
/// CefWebViewModel's package-internal attach hook is unavailable to Kestrel.
/// This registry gives the app's observable model access to its CEF browser.
@MainActor
enum CefBrowserRegistry {
    private static var browsers: [ObjectIdentifier: CefBrowser] = [:]

    static func browser(for model: CefWebViewModel) -> CefBrowser? {
        browsers[ObjectIdentifier(model)]
    }

    static func attach(_ browser: CefBrowser, to model: CefWebViewModel) {
        browsers[ObjectIdentifier(model)] = browser
    }

    static func detach(from model: CefWebViewModel) {
        browsers[ObjectIdentifier(model)] = nil
    }
}

@MainActor
extension CefWebViewModel {
    var kestrelBrowser: CefBrowser? { CefBrowserRegistry.browser(for: self) }

    func kestrelAttach(_ browser: CefBrowser) {
        CefBrowserRegistry.attach(browser, to: self)
    }

    func kestrelDetach() {
        CefBrowserRegistry.detach(from: self)
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
