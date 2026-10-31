#if canImport(CefKit) && canImport(CefSwiftUI)

import AppKit
import CefKit
import CefSwiftUI
import Foundation

/// Keeps CefWebViewModel's normal state mirroring while forwarding the CEF
/// events that Kestrel needs for navigation errors and external URL handling.
@MainActor
final class CefBrowserDelegateProxy: CefBrowserDelegate {
    private weak var model: CefWebViewModel?
    private weak var store: BrowserStore?
    private weak var tabs: TabStore?

    init(model: CefWebViewModel, store: BrowserStore, tabs: TabStore) {
        self.model = model
        self.store = store
        self.tabs = tabs
    }

    func browser(_ browser: CefBrowser, didChangeTitle title: String) {
        model?.browser(browser, didChangeTitle: title)
    }

    func browser(_ browser: CefBrowser, didChangeURL url: URL?) {
        model?.browser(browser, didChangeURL: url)
    }

    func browser(_ browser: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        model?.browser(browser, didChangeLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func browser(_ browser: CefBrowser, didChangeProgress progress: Double) {
        model?.browser(browser, didChangeProgress: progress)
    }

    func browser(_ browser: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String) {
        store?.reportLoadFailure(code: code, failedURL: failedURL)
    }

    func browser(_ browser: CefBrowser, didChangeFavicon urls: [URL]) {
        model?.browser(browser, didChangeFavicon: urls)
    }

    func browser(_ browser: CefBrowser, requestsPopupFor url: URL?) -> CefPopupDecision {
        model?.browser(browser, requestsPopupFor: url) ?? .block
    }

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        model?.browser(browser, decideWindowOpenFor: request) ?? .deny
    }

    func browser(_ browser: CefBrowser, decidePolicyForNavigation url: URL?, isRedirect: Bool, userGesture: Bool) -> CefNavigationDecision {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https"].contains(scheme) { return url.host == nil ? .cancel : .allow }
        if URLNormalisation.chromiumInternalURL(from: url.absoluteString) != nil { return .allow }
        let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "maps", "itms-apps"]
        guard userGesture, externalSchemes.contains(scheme),
              tabs?.openExternalNavigation(url) == true else { return .cancel }
        return .cancel
    }

    func browserDidClose(_ browser: CefBrowser) {
        model?.kestrelDetach(matching: browser)
        model?.browserDidClose(browser)
    }

    func browser(_ browser: CefBrowser, runBeforeUnloadDialog message: String, isReload: Bool,
                 callback: CefJSDialogCallback) -> Bool {
        tabs?.revealBrowser(browser)
        return false // CefSwift presents the asynchronous native sheet.
    }

    func browser(_ browser: CefBrowser, didReceiveConsoleMessage message: String, level: CefLogSeverity, source: String, line: Int) {
        model?.browser(browser, didReceiveConsoleMessage: message, level: level, source: source, line: line)
    }

    func browser(_ browser: CefBrowser, decidePolicyForDownload download: CefDownload, suggestedName: String) -> CefDownloadDecision {
        model?.browser(browser, decidePolicyForDownload: download, suggestedName: suggestedName) ?? .allow(destination: nil)
    }

    func browser(_ browser: CefBrowser, downloadDidProgress download: CefDownload) {
        model?.browser(browser, downloadDidProgress: download)
    }

    func browser(_ browser: CefBrowser, configureContextMenu menu: CefMenuModel, params: CefContextMenuParams) {
        model?.browser(browser, configureContextMenu: menu, params: params)
    }

    func browser(_ browser: CefBrowser, contextMenuCommand commandID: Int, params: CefContextMenuParams) -> Bool {
        model?.browser(browser, contextMenuCommand: commandID, params: params) ?? false
    }

    func browser(_ browser: CefBrowser, requestsPermission request: CefPermissionRequest,
                 completion: @escaping @MainActor (CefPermissionDecision) -> Void) -> Bool {
        let originURL = URL(string: request.origin)
        guard let host = originURL?.host,
              let scheme = originURL?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { completion(.deny); return true }
        var labels: [String] = []
        if request.kinds.contains(.camera) { labels.append("camera") }
        if request.kinds.contains(.microphone) { labels.append("microphone") }
        if request.kinds.contains(.geolocation) { labels.append("location") }
        if request.kinds.contains(.notifications) { labels.append("notifications") }
        if request.kinds.contains(.clipboard) { labels.append("clipboard") }
        if request.kinds.contains(.midi) { labels.append("MIDI") }
        if request.kinds.contains(.pointerLock) { labels.append("pointer lock") }
        if request.kinds.contains(.storageAccess) { labels.append("storage access") }
        if request.kinds.contains(.sensors) { labels.append("device sensors") }
        if request.kinds.contains(.windowManagement) { labels.append("window management") }
        if request.kinds.contains(.downloads) { labels.append("multiple downloads") }
        if request.kinds.contains(.other) { labels.append("another browser capability") }
        guard !labels.isEmpty else { completion(.deny); return true }

        let alert = NSAlert()
        alert.messageText = "Allow \(host) to use \(labels.joined(separator: ", "))?"
        alert.informativeText = "Kestrel will allow this request for the current session. You can deny it if you did not expect this request."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        guard let window = browser.nativeView?.window else { completion(.dismiss); return true }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? .allow : .deny)
        }
        return true
    }

    func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason, errorCode: Int) {
        model?.browser(browser, renderProcessDidTerminate: reason, errorCode: errorCode)
        store?.reportRendererTermination()
    }
}

#endif
