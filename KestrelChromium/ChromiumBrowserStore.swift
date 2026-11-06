#if canImport(SwiftUI) && canImport(CefSwiftUI)

import AppKit
import CefKit
import CefSwiftUI
import Combine
import Foundation
import Observation

struct AgentCursorPresentation: Equatable {
    enum Phase: Equatable { case moving, selected }
    let id: UUID
    let point: CGPoint
    let targetRect: CGRect
    let phase: Phase

    init(id: UUID = UUID(), point: CGPoint, targetRect: CGRect, phase: Phase) {
        self.id = id
        self.point = point
        self.targetRect = targetRect
        self.phase = phase
    }
}

/// Per-tab browser state backed by Chromium. It preserves Kestrel's existing
/// UI contract while navigation and page evaluation go through CefSwift.
@MainActor
final class BrowserStore: ObservableObject {
    var searchEngine: SearchEngine = .default
    @Published var addressText = ""
    @Published private(set) var pageTitle = "New Tab"
    @Published private(set) var isLoading = false
    @Published private(set) var navigationFailure: BrowserNavigationFailure?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var pageBackgroundColor: NSColor?
    @Published private(set) var themeColor: NSColor?
    @Published private(set) var reflectionColor: NSColor?
    @Published private(set) var leftPageEdgeSample: NSImage?
    @Published private(set) var rightPageEdgeSample: NSImage?
    @Published private(set) var faviconURL: String?
    @Published private(set) var agentCursorPresentation: AgentCursorPresentation?
    @Published private(set) var passkeyHandoffNeeded = false
    @Published private(set) var browserHandoffError: String?

    private weak var engine: CefWebViewModel?
    private var tabID: UUID?
    private var isObservingEngine = false
    private var navigationWaiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var retryURL: URL?
    private var navigationDidStart = false
    private var navigationStartWaiterID: UUID?
    private var passkeyWatcherGeneration = 0
    private var zoomLevel = 0.0

    deinit {
        navigationTimeoutTask?.cancel()
        navigationWaiter?.continuation.resume(returning: false)
    }

    func attach(to engine: CefWebViewModel, tabID: UUID? = nil) {
        guard self.engine !== engine else { return }
        self.engine = engine
        self.tabID = tabID
        if let tabID { CefPasskeyHandoff.shared.attach(self, tabID: tabID) }
        if engine.url == nil, let destination = Self.destinationURL(from: addressText, searchEngine: searchEngine) {
            engine.kestrelLoad(destination)
        }
        // Browser views are materialised from ContentView's body. Publishing
        // the initial engine state inline would mutate SwiftUI-observed state
        // while that view update is still being evaluated.
        Task { @MainActor [weak self, weak engine] in
            await Task.yield()
            guard let self, let engine, self.engine === engine else { return }
            self.synchronize(from: engine)
            self.observeEngine()
            if !engine.isLoading { self.schedulePasskeyWatcher() }
        }
    }

    func submitAddress() {
        guard let url = Self.destinationURL(from: addressText, searchEngine: searchEngine) else { return }
        loadURL(url)
    }

    func goBack() {
        guard engine?.canGoBack == true else { return }
        beginNavigation { $0.kestrelGoBack() }
    }

    func goForward() {
        guard engine?.canGoForward == true else { return }
        beginNavigation { $0.kestrelGoForward() }
    }

    func reload() {
        if navigationFailure != nil, let retryURL {
            loadURL(retryURL)
            return
        }
        beginNavigation { $0.kestrelReload() }
    }

    func stopLoading() {
        engine?.kestrelStopLoading()
        isLoading = false
        navigationFailure = nil
        restorePageTitle()
        finishNavigationWait(success: false)
    }

    func find(_ text: String, backwards: Bool = false) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        engine?.kestrelBrowser?.find(query, forward: !backwards, matchCase: false)
    }

    func changePageZoom(by amount: Double) {
        guard let browser = engine?.kestrelBrowser else { return }
        zoomLevel = min(5, max(-4, browser.zoomLevel + amount))
        browser.zoomLevel = zoomLevel
    }

    func resetPageZoom() {
        zoomLevel = 0
        engine?.kestrelBrowser?.zoomLevel = 0
    }

    func reportPasskeyHandoffNeeded() {
        browserHandoffError = nil
        passkeyHandoffNeeded = true
    }

    func reportLoadFailure(code: Int, failedURL: String) {
        guard code != -3,
              let failed = URL(string: failedURL),
              failed.absoluteString == engine?.url?.absoluteString else { return }
        guard let failure = BrowserNavigationFailure.chromium(code: code) else { return }
        navigationFailure = failure
        isLoading = false
        pageTitle = "Kestrel"
        finishNavigationWait(success: false)
    }

    func reportRendererTermination() {
        navigationFailure = .contentProcessStopped
        isLoading = false
        pageTitle = "Kestrel"
        finishNavigationWait(success: false)
    }

    func dismissBrowserHandoff() {
        passkeyHandoffNeeded = false
        browserHandoffError = nil
    }

    func completeBrowserHandoff(opened: Bool) {
        if opened {
            dismissBrowserHandoff()
        } else {
            browserHandoffError = "The other browser could not be opened. Try again, or open this address in another browser yourself."
        }
    }

    func updateAgentCursorPresentation(_ presentation: AgentCursorPresentation?) {
        if let presentation { agentCursorPresentation = presentation }
    }

    func clearAgentCursorPresentation() { agentCursorPresentation = nil }

    func loadAndWait(for url: URL, timeoutNanoseconds: UInt64 = 25_000_000_000) async -> Bool {
        guard await waitForBrowserCreation(timeoutNanoseconds: timeoutNanoseconds), let engine else { return false }
        if engine.url == url, !engine.isLoading {
            return navigationFailure == nil
        }
        if engine.url == url, engine.isLoading {
            return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds, start: nil)
        }
        return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds) { self.loadURL(url) }
    }

    func navigateAndWait(_ action: BrowserAction, timeoutNanoseconds: UInt64 = 25_000_000_000) async -> Bool {
        switch action {
        case .goBack:
            guard canGoBack else { return false }
            return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds) { self.goBack() }
        case .goForward:
            guard canGoForward else { return false }
            return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds) { self.goForward() }
        case .reload:
            return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds) { self.reload() }
        default:
            return false
        }
    }

    func waitUntilReady(timeoutNanoseconds: UInt64 = 25_000_000_000) async -> Bool {
        guard await waitForBrowserCreation(timeoutNanoseconds: timeoutNanoseconds), let engine, !Task.isCancelled else { return false }
        guard isLoading || engine.isLoading else { return navigationFailure == nil }
        return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds, start: nil)
    }

    private func waitForBrowserCreation(timeoutNanoseconds: UInt64) async -> Bool {
        guard let engine else { return false }
        var remaining = timeoutNanoseconds
        let interval: UInt64 = 50_000_000
        while engine.kestrelBrowser == nil || engine.kestrelBrowser?.id == -1 {
            guard !Task.isCancelled, remaining > 0 else { return false }
            let delay = min(interval, remaining)
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return false }
            remaining -= delay
        }
        guard let browser = engine.kestrelBrowser else { return false }
        return browser.id != -1
    }

    private func waitForNavigation(timeoutNanoseconds: UInt64, start: (() -> Void)?) async -> Bool {
        guard engine != nil, !Task.isCancelled, navigationWaiter == nil else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                navigationDidStart = false
                navigationWaiter = (waiterID, continuation)
                navigationStartWaiterID = waiterID
                start?()
                navigationStartWaiterID = nil
                if engine?.isLoading == true {
                    navigationDidStart = true
                    isLoading = true
                }
                navigationTimeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    guard let self, self.navigationWaiter?.id == waiterID else { return }
                    self.navigationFailure = .timedOut
                    self.engine?.kestrelStopLoading()
                    self.finishNavigationWait(success: false)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.navigationWaiter?.id == waiterID else { return }
                self?.stopLoading()
            }
        }
    }

    private func beginNavigation(_ command: (CefWebViewModel) -> Void) {
        guard let engine else { return }
        if navigationWaiter?.id != navigationStartWaiterID {
            finishNavigationWait(success: false)
        }
        navigationFailure = nil
        command(engine)
    }

    private func loadURL(_ url: URL) {
        retryURL = url
        addressText = url.absoluteString
        pageTitle = "Loading…"
        navigationFailure = nil
        faviconURL = nil
        dismissBrowserHandoff()
        beginNavigation { $0.kestrelLoad(url) }
    }

    private func observeEngine() {
        guard let engine, !isObservingEngine else { return }
        isObservingEngine = true
        withObservationTracking {
            _ = engine.url
            _ = engine.title
            _ = engine.isLoading
            _ = engine.canGoBack
            _ = engine.canGoForward
            _ = engine.estimatedProgress
            _ = engine.faviconURL
        } onChange: { [weak self, weak engine] in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                self.isObservingEngine = false
                self.synchronize(from: engine)
                self.observeEngine()
            }
        }
    }

    private func synchronize(from engine: CefWebViewModel) {
        if let url = engine.url {
            if addressText != url.absoluteString {
                addressText = url.absoluteString
                dismissBrowserHandoff()
            }
            retryURL = url
        }
        canGoBack = engine.canGoBack
        canGoForward = engine.canGoForward
        if !engine.title.isEmpty { pageTitle = engine.title }

        if engine.isLoading {
            navigationDidStart = true
            isLoading = true
            navigationFailure = nil
        } else {
            isLoading = false
            if navigationDidStart {
                navigationDidStart = false
                let succeeded = navigationFailure == nil
                if succeeded {
                    pageTitle = engine.title.isEmpty ? "Kestrel" : engine.title
                    updatePageDecorations()
                    schedulePasskeyWatcher()
                }
                finishNavigationWait(success: succeeded)
            }
        }
        if let icon = engine.faviconURL, Self.validFaviconURL(icon) != nil {
            faviconURL = icon.absoluteString
        }
    }

    private func updatePageDecorations() {
        guard let engine, let tabID else {
            updatePageDecorationsWithoutIdentity()
            return
        }
        let decoratedURL = engine.url
        Task { @MainActor [weak self, weak engine] in
            guard let self, let engine else { return }
            let value = await CefScriptRunner.shared.evaluate(
                "(() => { const icon = [...document.querySelectorAll('link[rel][href]')].find(e => e.rel.toLowerCase().split(/\\s+/).includes('icon')); return icon ? icon.href : (location.origin === 'null' ? '' : new URL('/favicon.ico', location.origin).href); })()",
                in: engine, tabID: tabID
            ) as? String
            guard self.engine === engine, engine.url == decoratedURL, !engine.isLoading else { return }
            if let value, let candidate = URL(string: value), let url = Self.validFaviconURL(candidate) {
                self.faviconURL = url.absoluteString
            }
            let colors = await CefScriptRunner.shared.evaluate(
                "(() => ({background: getComputedStyle(document.body || document.documentElement).backgroundColor, canvas: getComputedStyle(document.documentElement).backgroundColor, theme: document.querySelector('meta[name=theme-color]')?.content || ''}))()",
                in: engine, tabID: tabID
            ) as? [String: String]
            guard self.engine === engine, engine.url == decoratedURL, !engine.isLoading else { return }
            if let colors {
                // HTML paints the canvas when it has an opaque background.
                // A transparent body must not hide that colour from chrome.
                self.pageBackgroundColor = ["canvas", "background"]
                    .compactMap { NSColor(cssColor: colors[$0] ?? "") }
                    .first { $0.alphaComponent >= 0.98 }
                self.themeColor = NSColor(cssColor: colors["theme"] ?? "")
            }
        }
    }

    private func updatePageDecorationsWithoutIdentity() {
        // The tab store supplies the authoritative tab ID to page evaluation.
        // Until then, keep engine-reported favicon and colour state neutral.
        pageBackgroundColor = nil
        themeColor = nil
    }

    private func schedulePasskeyWatcher() {
        guard let engine, let tabID, engine.url != nil else { return }
        passkeyWatcherGeneration += 1
        let generation = passkeyWatcherGeneration
        let loadedURL = engine.url
        Task { @MainActor [weak self, weak engine] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, let engine, self.passkeyWatcherGeneration == generation,
                  !engine.isLoading, engine.url == loadedURL else { return }
            engine.kestrelExecuteJavaScript(CefPasskeyHandoff.watcherScript(tabID: tabID))
        }
    }

    private func restorePageTitle() {
        pageTitle = engine?.title.isEmpty == false ? engine?.title ?? "Kestrel" : "Kestrel"
    }

    private func finishNavigationWait(success: Bool) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        guard let waiter = navigationWaiter else { return }
        navigationWaiter = nil
        waiter.continuation.resume(returning: success)
    }

    static func destinationURL(from input: String, searchEngine: SearchEngine = .default) -> URL? {
        URLNormalisation.destinationURL(from: input, searchEngine: searchEngine)
    }

    private static func validFaviconURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

private extension NSColor {
    convenience init?(cssColor: String) {
        let value = cssColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "transparent" { self.init(srgbRed: 0, green: 0, blue: 0, alpha: 0); return }
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            guard [6, 8].contains(hex.count), let number = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let red = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255
            let green = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255
            let blue = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255
            let alpha = hasAlpha ? CGFloat(number & 0xff) / 255 : 1
            self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
            return
        }
        guard value.hasPrefix("rgb(") || value.hasPrefix("rgba("),
              let open = value.firstIndex(of: "("), value.last == ")" else { return nil }
        let body = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let parts = body.split { $0 == "," || $0 == "/" || $0.isWhitespace }
        guard [3, 4].contains(parts.count) else { return nil }
        func component(_ part: Substring, alpha: Bool = false) -> CGFloat? {
            let isPercent = part.hasSuffix("%")
            let raw = isPercent ? part.dropLast() : part[...]
            guard let number = Double(raw), number.isFinite else { return nil }
            let scale = isPercent ? 100.0 : (alpha ? 1.0 : 255.0)
            return CGFloat(min(1, max(0, number / scale)))
        }
        guard let red = component(parts[0]), let green = component(parts[1]),
              let blue = component(parts[2]) else { return nil }
        let alpha: CGFloat
        if parts.count == 4 {
            guard let parsedAlpha = component(parts[3], alpha: true) else { return nil }
            alpha = parsedAlpha
        } else {
            alpha = 1
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

#endif
