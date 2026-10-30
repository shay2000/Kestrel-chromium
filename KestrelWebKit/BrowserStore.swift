#if canImport(SwiftUI) && canImport(WebKit)

import Combine
import Foundation
import AppKit
import WebKit

struct AgentCursorPresentation: Equatable {
    enum Phase: Equatable {
        case moving
        case selected
    }

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

/// Fixed user-facing messages: never surface a failing URL or a provider's
/// raw error description, which may include credentials or query tokens.
enum BrowserNavigationFailure: Equatable {
    case unavailable, timedOut, offline, secureConnection, contentProcessStopped

    var message: String {
        switch self {
        case .unavailable: return "This page could not be loaded. Check the address or try again."
        case .timedOut: return "This page took too long to respond. Try again."
        case .offline: return "The connection was interrupted. Check your internet connection and try again."
        case .secureConnection: return "A secure connection could not be established."
        case .contentProcessStopped: return "The page stopped responding. Reload it to continue."
        }
    }
}

final class BrowserStore: NSObject, ObservableObject {
    var searchEngine: SearchEngine = .default
    /// Empty means "no page yet". A new tab shows the new tab page rather than
    /// loading a site the user did not ask for.
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
    /// Set after an unsuccessful explicit passkey attempt when platform
    /// authentication is unavailable. This offers a handoff, not a diagnosis
    /// of whether the user cancelled or another authenticator could work.
    @Published private(set) var passkeyHandoffNeeded = false
    @Published private(set) var browserHandoffError: String?

    private weak var webView: WKWebView?
    private var titleObservation: NSKeyValueObservation?
    private var pageBackgroundObservation: NSKeyValueObservation?
    private var themeColorObservation: NSKeyValueObservation?
    private var scrollBoundsObservers: [NSObjectProtocol] = []
    private var reflectionTask: Task<Void, Never>?
    private var navigationWaiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    private var navigationTimeoutTask: Task<Void, Never>?
    private let supersededNavigations = NSHashTable<WKNavigation>.weakObjects()
    private var activeNavigation: WKNavigation?
    private var mainFrameHTTPStatus: Int?
    private var retryURL: URL?

    deinit {
        navigationTimeoutTask?.cancel()
        navigationWaiter?.continuation.resume(returning: false)
        scrollBoundsObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Fixed app-owned lookup only; page content is never interpolated into
    /// JavaScript. Resolve the declared icon against the document URL and use
    /// the origin favicon convention when the page has no declared icon.
    private static let faviconURLJavaScript = #"""
    (() => {
      const links = [...document.querySelectorAll("link[rel][href]")];
      const icon = links.find(link =>
        link.rel.toLowerCase().split(/\s+/).includes("icon"));
      return icon ? icon.href : new URL("/favicon.ico", location.origin).href;
    })()
    """#

    func attach(to webView: WKWebView) {
        if let oldView = self.webView, oldView !== webView {
            stopLoading()
            oldView.navigationDelegate = nil
        }
        self.webView = webView
        observePageScroll(in: webView)
        titleObservation?.invalidate()
        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.webView === view,
                      view.url != nil, !self.isLoading, self.navigationFailure == nil else { return }
                self.restorePageTitle()
            }
        }
        pageBackgroundObservation?.invalidate()
        pageBackgroundObservation = webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] view, _ in
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.webView === view else { return }
                self.pageBackgroundColor = view.underPageBackgroundColor
            }
        }
        themeColorObservation?.invalidate()
        themeColorObservation = webView.observe(\.themeColor, options: [.initial, .new]) { [weak self] observedWebView, _ in
            DispatchQueue.main.async { [weak self, weak observedWebView] in
                guard let self, let observedWebView, self.webView === observedWebView else { return }
                self.themeColor = observedWebView.themeColor
            }
        }
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        if webView.url == nil {
            loadAddress(addressText)
        } else {
            updateNavigationState(for: webView)
        }
    }

    /// macOS WKWebView is an NSView (it has no iOS-style `scrollView`
    /// property). Observe its standard AppKit clip views so the edge strips
    /// follow the visible page as the user scrolls.
    private func observePageScroll(in webView: WKWebView) {
        scrollBoundsObservers.forEach(NotificationCenter.default.removeObserver)
        scrollBoundsObservers.removeAll()

        func visit(_ view: NSView) {
            if let clipView = view as? NSClipView {
                clipView.postsBoundsChangedNotifications = true
                let observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self, weak webView] _ in
                    guard let self, let webView else { return }
                    self.scheduleReflectionSnapshot(for: webView, delay: 180_000_000)
                }
                scrollBoundsObservers.append(observer)
            }
            view.subviews.forEach(visit)
        }

        visit(webView)
    }

    func submitAddress() {
        loadAddress(addressText)
    }

    func goBack() {
        guard let webView, webView.canGoBack else { return }
        startNavigation { webView.goBack() }
    }

    func goForward() {
        guard let webView, webView.canGoForward else { return }
        startNavigation { webView.goForward() }
    }

    func reload() {
        if navigationFailure != nil, let retryURL {
            loadURL(retryURL)
            return
        }
        guard let webView else { return }
        startNavigation { webView.reload() }
    }

    func stopLoading() {
        supersedeActiveNavigation()
        webView?.stopLoading()
        isLoading = false
        navigationFailure = nil
        restorePageTitle()
        finishNavigationWait(success: false)
    }

    func find(_ text: String, backwards: Bool = false) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        webView?.find(query, configuration: configuration) { _ in }
    }

    func changePageZoom(by amount: Double) {
        guard let webView else { return }
        webView.pageZoom = min(3, max(0.5, webView.pageZoom + amount))
    }

    func resetPageZoom() {
        webView?.pageZoom = 1
    }

    /// Called by the watcher after a rejected request and unavailable
    /// platform authentication. No credential data crosses this bridge.
    func reportPasskeyHandoffNeeded() {
        browserHandoffError = nil
        passkeyHandoffNeeded = true
    }

    func dismissBrowserHandoff() {
        passkeyHandoffNeeded = false
        browserHandoffError = nil
    }

    func completeBrowserHandoff(opened: Bool) {
        if opened {
            dismissBrowserHandoff()
        } else {
            // An ordinary menu handoff is not evidence of a passkey attempt.
            // Preserve an existing passkey notice, but never invent one.
            browserHandoffError = "The other browser could not be opened. Try again, or open this address in another browser yourself."
        }
    }

    func updateAgentCursorPresentation(_ presentation: AgentCursorPresentation?) {
        // A completed move retains its destination between model requests.
        // The page overlay clears it when the task ends or its tab loses focus.
        if let presentation { agentCursorPresentation = presentation }
    }

    func clearAgentCursorPresentation() {
        agentCursorPresentation = nil
    }

    private func scheduleReflectionSnapshot(for webView: WKWebView, delay: UInt64 = 220_000_000) {
        reflectionTask?.cancel()
        reflectionTask = Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, let webView, self.webView === webView else { return }
            webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
                guard let self, let webView,
                      self.webView === webView,
                      webView.url != nil else { return }
                guard let image else { return }
                self.leftPageEdgeSample = Self.pageEdgeStrip(in: image, side: .left)
                self.rightPageEdgeSample = Self.pageEdgeStrip(in: image, side: .right)
                self.reflectionColor = self.rightPageEdgeSample.flatMap(Self.dominantPageColor)
            }
        }
    }

    private enum PageEdge { case left, right }

    /// Retains only a 30-point strip from the visible viewport edge. The
    /// samples stay local and are used only for restrained browser-chrome
    /// accents; they are never drawn over the webpage or sent to a provider.
    private static func pageEdgeStrip(in image: NSImage, side: PageEdge) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let pixelsPerPoint = CGFloat(cgImage.width) / image.size.width
        let stripPoints: CGFloat = min(30, image.size.width / 3)
        let stripWidth = min(cgImage.width, max(1, Int((stripPoints * pixelsPerPoint).rounded())))
        let originX = side == .left ? 0 : cgImage.width - stripWidth
        let rect = CGRect(x: originX, y: 0, width: stripWidth, height: cgImage.height)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: stripPoints, height: image.size.height))
    }

    /// Estimates a quiet toolbar tint from the right-edge sample, not a broad
    /// average of unrelated content elsewhere on the page.
    private static func dominantPageColor(in image: NSImage) -> NSColor? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let startX = 0
        let endY = height * 92 / 100
        let startY = height * 8 / 100
        let xStep = max(1, width / 30)
        let yStep = max(1, (endY - startY) / 96)
        let binCount = 30
        var weights = [Double](repeating: 0, count: binCount)
        var saturationTotals = weights
        var brightnessTotals = weights

        for y in stride(from: startY, to: endY, by: yStep) {
            for x in stride(from: startX, to: width, by: xStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard alpha > 0.2, saturation > 0.17, brightness > 0.12, brightness < 0.97 else { continue }

                let index = min(binCount - 1, Int(hue * CGFloat(binCount)))
                let weight = Double(saturation * saturation * min(brightness, 1 - brightness + 0.2))
                weights[index] += weight
                saturationTotals[index] += Double(saturation) * weight
                brightnessTotals[index] += Double(brightness) * weight
            }
        }

        guard let dominant = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[dominant] > 0 else { return nil }
        let weight = weights[dominant]
        return NSColor(
            calibratedHue: (CGFloat(dominant) + 0.5) / CGFloat(binCount),
            saturation: CGFloat(saturationTotals[dominant] / weight),
            brightness: CGFloat(brightnessTotals[dominant] / weight),
            alpha: 1
        )
    }

    /// Loads a known-safe search URL and waits for the visible results page to
    /// finish before the assistant captures its bounded text.
    @MainActor
    func loadAndWait(for url: URL, timeoutNanoseconds: UInt64 = 25_000_000_000) async -> Bool {
        await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds) { self.loadURL(url) }
    }

    /// Use the same delegate-backed completion gate for history and refresh.
    @MainActor
    func navigateAndWait(_ action: BrowserAction, timeoutNanoseconds: UInt64 = 25_000_000_000) async -> Bool {
        guard let webView else { return false }
        switch action {
        case .goBack:
            guard webView.canGoBack else { return false }
            return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds) { self.goBack() }
        case .goForward:
            guard webView.canGoForward else { return false }
            return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds) { self.goForward() }
        case .reload:
            return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds) { self.reload() }
        default:
            return false
        }
    }

    /// Clicks/searches can start navigation inside WebKit. Never read their
    /// destination while it is loading, or mistake a failed load for success.
    @MainActor
    func waitUntilReady(timeoutNanoseconds: UInt64 = 25_000_000_000) async -> Bool {
        guard let webView, !Task.isCancelled else { return false }
        guard isLoading || webView.isLoading else { return navigationFailure == nil }
        // Do not steal another request's completion waiter.
        guard navigationWaiter == nil else { return false }
        return await waitForNavigation(timeoutNanoseconds: timeoutNanoseconds, start: nil)
    }

    @MainActor
    private func waitForNavigation(timeoutNanoseconds: UInt64, start: (() -> Void)?) async -> Bool {
        guard webView != nil, !Task.isCancelled else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                start?()
                guard activeNavigation != nil else { continuation.resume(returning: false); return }
                navigationWaiter = (waiterID, continuation)
                navigationTimeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    guard let self, self.navigationWaiter?.id == waiterID else { return }
                    self.supersedeActiveNavigation()
                    self.webView?.stopLoading()
                    self.recordNavigationFailure(URLError(.timedOut))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.navigationWaiter?.id == waiterID else { return }
                self?.stopLoading()
            }
        }
    }

    private func supersedeActiveNavigation() {
        if let activeNavigation { supersededNavigations.add(activeNavigation) }
        activeNavigation = nil
    }

    private func startNavigation(_ load: () -> WKNavigation?) {
        finishNavigationWait(success: false)
        supersedeActiveNavigation()
        mainFrameHTTPStatus = nil
        activeNavigation = load()
        if activeNavigation != nil {
            isLoading = true
            navigationFailure = nil
        }
    }

    private func accepts(_ navigation: WKNavigation?, from view: WKWebView) -> Bool {
        guard webView === view else { return false }
        if let navigation, supersededNavigations.contains(navigation) { return false }
        return activeNavigation == nil || navigation === activeNavigation
    }

    private func loadAddress(_ input: String) {
        guard let url = Self.destinationURL(from: input, searchEngine: searchEngine) else {
            return
        }

        loadURL(url)
    }

    private func loadURL(_ url: URL) {
        // A retry already has a URL. Never send it back through address/search
        // interpretation, which could turn an unsupported scheme into a query.
        addressText = url.absoluteString
        pageTitle = "Loading…"
        navigationFailure = nil
        retryURL = url
        startNavigation { webView?.load(URLRequest(url: url)) }
    }

    private func updateNavigationState(for webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func updateFavicon(for webView: WKWebView) {
        guard let pageURL = webView.url else { return }
        webView.evaluateJavaScript(Self.faviconURLJavaScript) { [weak self, weak webView] value, _ in
            guard
                let self,
                let webView,
                self.webView === webView,
                webView.url == pageURL,
                let rawURL = value as? String,
                let iconURL = Self.validFaviconURL(rawURL)
            else {
                return
            }
            self.faviconURL = iconURL.absoluteString
        }
    }

    private static func validFaviconURL(_ value: String) -> URL? {
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            return nil
        }
        return url
    }

    static func destinationURL(from input: String, searchEngine: SearchEngine = .default) -> URL? {
        URLNormalisation.destinationURL(from: input, searchEngine: searchEngine)
    }

    private func restorePageTitle() {
        pageTitle = webView?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Kestrel"
    }

    private func recordNavigationFailure(_ error: Error) {
        isLoading = false
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // A timeout may stop WebKit and then receive its cancellation.
            // Preserve that actionable failure rather than hiding it.
            if navigationFailure == nil { restorePageTitle() }
        } else {
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorTimedOut): navigationFailure = .timedOut
            case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
                 (NSURLErrorDomain, NSURLErrorNetworkConnectionLost): navigationFailure = .offline
            case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
                 (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
                 (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
                 (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
                 (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid): navigationFailure = .secureConnection
            default: navigationFailure = .unavailable
            }
            pageTitle = "Page unavailable"
        }
        finishNavigationWait(success: false)
    }
}

extension BrowserStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // A provisional failure can leave webView.url pointing at the previous
        // page. Remember the actual main-frame request for a truthful retry.
        if navigationAction.targetFrame?.isMainFrame == true {
            retryURL = navigationAction.request.url
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if self.webView === webView, navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse {
            recordMainFrameHTTPStatus(response.statusCode)
        }
        // Render the site's own error page, but never call it successful agent
        // navigation. No response headers, bodies or request tokens are stored.
        decisionHandler(.allow)
    }

    func recordMainFrameHTTPStatus(_ status: Int) {
        mainFrameHTTPStatus = status
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard self.webView === webView else { return }
        if let navigation, supersededNavigations.contains(navigation) { return }
        if activeNavigation !== navigation {
            finishNavigationWait(success: false)
            supersedeActiveNavigation()
            activeNavigation = navigation
        }
        isLoading = true
        mainFrameHTTPStatus = nil
        navigationFailure = nil
        faviconURL = nil
        // A new document gets a fresh chance: the old page's passkey attempt
        // no longer describes what is on screen.
        dismissBrowserHandoff()
        reflectionTask?.cancel()
        reflectionColor = nil
        leftPageEdgeSample = nil
        rightPageEdgeSample = nil
        updateNavigationState(for: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard accepts(navigation, from: webView) else { return }
        retryURL = webView.url ?? retryURL
        addressText = webView.url?.absoluteString ?? addressText
        updateNavigationState(for: webView)
        scheduleReflectionSnapshot(for: webView, delay: 350_000_000)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard accepts(navigation, from: webView) else { return }
        isLoading = false
        navigationFailure = (mainFrameHTTPStatus ?? 200) >= 400 ? .unavailable : nil
        addressText = webView.url?.absoluteString ?? addressText
        if let title = webView.title, !title.isEmpty {
            pageTitle = title
        } else {
            pageTitle = "Kestrel"
        }
        updateFavicon(for: webView)
        updateNavigationState(for: webView)
        observePageScroll(in: webView)
        scheduleReflectionSnapshot(for: webView)
        finishNavigationWait(success: navigationFailure == nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        guard accepts(navigation, from: webView) else { return }
        recordNavigationFailure(error)
        updateNavigationState(for: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        guard accepts(navigation, from: webView) else { return }
        recordNavigationFailure(error)
        updateNavigationState(for: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        supersedeActiveNavigation()
        isLoading = false
        navigationFailure = .contentProcessStopped
        pageTitle = "Page unavailable"
        retryURL = webView.url ?? retryURL
        finishNavigationWait(success: false)
    }
}

private extension BrowserStore {
    func finishNavigationWait(success: Bool) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        guard let waiter = navigationWaiter else { return }
        navigationWaiter = nil
        waiter.continuation.resume(returning: success)
    }
}

#endif
