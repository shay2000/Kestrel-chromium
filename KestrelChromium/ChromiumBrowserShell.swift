#if canImport(SwiftUI) && canImport(CefSwiftUI)

import CefKit
import CefSwiftUI
import Foundation
import Observation

@Observable
@MainActor
final class ChromiumBrowserTab: Identifiable {
    let id = UUID()
    let engine: CefWebViewModel

    init(url: URL) {
        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy
        options.profile = CefProfile.default
        engine = CefWebViewModel(url: url, options: options)
    }

    var title: String {
        engine.title.isEmpty ? (engine.url?.host() ?? "New Tab") : engine.title
    }
}

@Observable
@MainActor
final class ChromiumBrowserShell {
    static let homeURL = URL(string: "https://duckduckgo.com")!

    private(set) var tabs: [ChromiumBrowserTab] = []
    var selectedTabID: UUID?
    private(set) var addressFocusToken = 0

    init(initialURL: URL? = nil) {
        newTab(url: initialURL ?? Self.homeURL)
    }

    var selectedTab: ChromiumBrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var canGoBack: Bool { selectedTab?.engine.canGoBack ?? false }
    var canGoForward: Bool { selectedTab?.engine.canGoForward ?? false }
    var isLoading: Bool { selectedTab?.engine.isLoading ?? false }
    var progress: Double { selectedTab?.engine.estimatedProgress ?? 0 }

    @discardableResult
    func newTab(url: URL = Self.homeURL, select: Bool = true) -> ChromiumBrowserTab {
        let tab = ChromiumBrowserTab(url: url)
        tab.engine.onWindowOpen = { [weak self] request in
            guard let targetURL = request.targetURL else { return .deny }
            let scheme = targetURL.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { return .deny }
            self?.open(targetURL, inNewTab: true, select: request.disposition.prefersForeground)
            return .handled
        }
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        return tab
    }

    func select(_ tab: ChromiumBrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        selectedTabID = tab.id
    }

    func close(_ tab: ChromiumBrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            _ = newTab()
        } else if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelectedTab() {
        if let selectedTab { close(selectedTab) }
    }

    func open(_ url: URL, inNewTab: Bool, select: Bool = true) {
        guard Self.isSupportedPageURL(url) else { return }
        if inNewTab {
            _ = newTab(url: url, select: select)
        } else {
            selectedTab?.engine.load(url)
        }
    }

    func submitAddress(_ text: String) {
        guard let url = Self.destination(for: text) else { return }
        selectedTab?.engine.load(url)
    }

    func goBack() { selectedTab?.engine.goBack() }
    func goForward() { selectedTab?.engine.goForward() }
    func reload() { selectedTab?.engine.reload() }
    func stopLoading() { selectedTab?.engine.stopLoading() }
    func toggleDevTools() { selectedTab?.engine.browser?.toggleDevTools() }
    func requestAddressFocus() { addressFocusToken &+= 1 }

    static func destination(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.lowercased() == "about:blank" { return URL(string: "about:blank") }
        if let url = URL(string: value), isSupportedPageURL(url) { return url }

        if !value.contains(where: \.isWhitespace), !value.hasPrefix("/") {
            let hostPart = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
            if hostPart.contains(".") || hostPart == "localhost" || hostPart.contains(":") {
                let url = URL(string: "https://\(value)")
                if url?.host != nil { return url }
            }
        }

        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: value)]
        return components?.url
    }

    private static func isSupportedPageURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" { return url.host != nil }
        return url.absoluteString == "about:blank"
    }
}

#endif
