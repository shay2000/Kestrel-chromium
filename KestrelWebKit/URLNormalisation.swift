import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SearchEngine: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case google
    case duckDuckGo
    case bing

    static let `default`: SearchEngine = .google

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        Self.makeURL(host: searchHost, path: searchPath, items: [URLQueryItem(name: "q", value: query)])
    }

    func searchURL(for query: String, mode: WebSearchMode) -> URL? {
        switch mode {
        case .web:
            searchURL(for: query)
        case .images:
            SearchShortcut.images.destinationURL(for: query, using: self)
        }
    }

    fileprivate var searchHost: String {
        switch self {
        case .google: "www.google.com"
        case .duckDuckGo: "duckduckgo.com"
        case .bing: "www.bing.com"
        }
    }

    fileprivate var searchPath: String {
        self == .duckDuckGo ? "/" : "/search"
    }

    fileprivate static func makeURL(host: String, path: String, items: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items
        return components.url
    }
}

enum WebSearchMode: Equatable, Sendable {
    case web
    case images

    var displayName: String {
        switch self {
        case .web: "Web"
        case .images: "Images"
        }
    }
}

/// A small, explicit set of useful search modes. This intentionally is not an
/// open-ended DuckDuckGo bang registry: every shortcut maps to a known HTTPS
/// destination and never interprets user input as a URL or script.
enum SearchShortcut: String, CaseIterable, Equatable, Identifiable, Sendable {
    case maps
    case images
    case news
    case videos
    case shopping
    case youtube
    case wikipedia
    case amazon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .maps: "Maps"
        case .images: "Images"
        case .news: "News"
        case .videos: "Videos"
        case .shopping: "Shopping"
        case .youtube: "YouTube"
        case .wikipedia: "Wikipedia"
        case .amazon: "Amazon"
        }
    }

    var triggerWords: [String] {
        switch self {
        case .maps: ["maps", "map", "!maps", "!map"]
        case .images: ["images", "image", "!images", "!image", "!i"]
        case .news: ["news", "!news", "!n"]
        case .videos: ["videos", "video", "!videos", "!video"]
        case .shopping: ["shopping", "shop", "!shopping", "!shop"]
        case .youtube: ["youtube", "yt", "!youtube", "!yt"]
        case .wikipedia: ["wikipedia", "wiki", "!wikipedia", "!w"]
        case .amazon: ["amazon", "!amazon", "!a"]
        }
    }

    var bangTokens: [String] {
        triggerWords.filter { $0.hasPrefix("!") }
    }

    /// The shortcut a raw query opens with, if it opens with one.
    ///
    /// Only the bang form counts. The bare trigger words ("maps", "news") are
    /// ordinary search terms when the user types them, and treating those as a
    /// shortcut here would silently rewrite a search for the word itself.
    static func leadingShortcut(in query: String) -> SearchShortcut? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!") else { return nil }
        let token = trimmed.prefix { !$0.isWhitespace }.lowercased()
        return allCases.first { $0.bangTokens.contains(token) }
    }

    /// The searchable part of a query, with any leading shortcut removed.
    ///
    /// Search history is for the words the user searched for. The bang is how
    /// they asked for them, and keeping it makes the history list read as
    /// command syntax and makes re-running an entry repeat a mode the user did
    /// not choose a second time.
    static func strippingLeadingShortcut(from query: String) -> String {
        guard leadingShortcut(in: query) != nil else {
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            .drop { !$0.isWhitespace }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func displayName(using engine: SearchEngine) -> String {
        switch self {
        case .maps, .images, .news, .videos, .shopping:
            "\(engine.displayName) \(displayName)"
        case .youtube, .wikipedia, .amazon:
            displayName
        }
    }

    func destinationURL(for query: String, using engine: SearchEngine) -> URL? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch self {
        case .maps:
            switch engine {
            case .google:
                return SearchEngine.makeURL(
                    host: "www.google.com",
                    path: "/maps/search/",
                    items: [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: value)]
                )
            case .duckDuckGo:
                return SearchEngine.makeURL(
                    host: "duckduckgo.com",
                    path: "/",
                    items: [URLQueryItem(name: "q", value: value), URLQueryItem(name: "ia", value: "maps")]
                )
            case .bing:
                return SearchEngine.makeURL(host: "www.bing.com", path: "/maps", items: [URLQueryItem(name: "q", value: value)])
            }
        case .images:
            switch engine {
            case .google:
                return SearchEngine.makeURL(host: "www.google.com", path: "/search", items: [URLQueryItem(name: "tbm", value: "isch"), URLQueryItem(name: "q", value: value)])
            case .duckDuckGo:
                return SearchEngine.makeURL(host: "duckduckgo.com", path: "/", items: [URLQueryItem(name: "q", value: value), URLQueryItem(name: "iax", value: "images"), URLQueryItem(name: "ia", value: "images")])
            case .bing:
                return SearchEngine.makeURL(host: "www.bing.com", path: "/images/search", items: [URLQueryItem(name: "q", value: value)])
            }
        case .news:
            switch engine {
            case .google:
                return SearchEngine.makeURL(host: "www.google.com", path: "/search", items: [URLQueryItem(name: "tbm", value: "nws"), URLQueryItem(name: "q", value: value)])
            case .duckDuckGo:
                return SearchEngine.makeURL(host: "duckduckgo.com", path: "/", items: [URLQueryItem(name: "q", value: value), URLQueryItem(name: "iar", value: "news"), URLQueryItem(name: "ia", value: "news")])
            case .bing:
                return SearchEngine.makeURL(host: "www.bing.com", path: "/news/search", items: [URLQueryItem(name: "q", value: value)])
            }
        case .videos:
            switch engine {
            case .google:
                return SearchEngine.makeURL(host: "www.google.com", path: "/search", items: [URLQueryItem(name: "tbm", value: "vid"), URLQueryItem(name: "q", value: value)])
            case .duckDuckGo:
                return SearchEngine.makeURL(host: "duckduckgo.com", path: "/", items: [URLQueryItem(name: "q", value: value), URLQueryItem(name: "iax", value: "videos"), URLQueryItem(name: "ia", value: "videos")])
            case .bing:
                return SearchEngine.makeURL(host: "www.bing.com", path: "/videos/search", items: [URLQueryItem(name: "q", value: value)])
            }
        case .shopping:
            switch engine {
            case .google:
                return SearchEngine.makeURL(host: "www.google.com", path: "/search", items: [URLQueryItem(name: "tbm", value: "shop"), URLQueryItem(name: "q", value: value)])
            case .duckDuckGo:
                return SearchEngine.makeURL(host: "duckduckgo.com", path: "/", items: [URLQueryItem(name: "q", value: "shopping \(value)")])
            case .bing:
                return SearchEngine.makeURL(host: "www.bing.com", path: "/shop", items: [URLQueryItem(name: "q", value: value)])
            }
        case .youtube:
            return SearchEngine.makeURL(host: "www.youtube.com", path: "/results", items: [URLQueryItem(name: "search_query", value: value)])
        case .wikipedia:
            return SearchEngine.makeURL(host: "en.wikipedia.org", path: "/w/index.php", items: [URLQueryItem(name: "search", value: value)])
        case .amazon:
            return SearchEngine.makeURL(host: "www.amazon.com", path: "/s", items: [URLQueryItem(name: "k", value: value)])
        }
    }

    static func tabCompletion(in input: String) -> (shortcut: SearchShortcut, remainingQuery: String)? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let pieces = value.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let token = pieces.first,
              let shortcut = allCases.first(where: { $0.triggerWords.contains(String(token).lowercased()) }) else {
            return nil
        }
        let remainder = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (shortcut, remainder)
    }

    static func bangDestination(from input: String, using engine: SearchEngine) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = value.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let token = pieces.first,
              token.hasPrefix("!"),
              let shortcut = allCases.first(where: { $0.bangTokens.contains(String(token).lowercased()) }),
              pieces.count > 1 else {
            return nil
        }
        return shortcut.destinationURL(for: String(pieces[1]), using: engine)
    }
}

/// Turns whatever a person types into the address Kestrel should load.
/// Deliberately free of WebKit and SwiftUI so it can be unit-tested on any
/// platform, including the Linux development host.
enum URLNormalisation {
    static let searchEngineHost = "www.google.com"

    static func destinationURL(from input: String, searchEngine: SearchEngine = .default) -> URL? {
        destinationURL(from: input, search: searchEngine.searchURL, engineForBangs: searchEngine)
    }

    /// Kept as a host override for focused tests and internal compatibility.
    static func destinationURL(from input: String, searchEngineHost: String) -> URL? {
        destinationURL(
            from: input,
            search: { query in searchURL(for: query, searchEngineHost: searchEngineHost) },
            engineForBangs: .google
        )
    }

    private static func destinationURL(
        from input: String,
        search: (String) -> URL?,
        engineForBangs: SearchEngine
    ) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let internalPage = chromiumInternalURL(from: value) { return internalPage }
        if let extensionPage = chromiumExtensionURL(from: value) { return extensionPage }

        if let url = explicitHTTPURL(from: value) { return url }
        if let url = SearchShortcut.bangDestination(from: value, using: engineForBangs) { return url }

        // Dotted hosts remain direct navigations, while ordinary single words
        // are useful search queries. "example.com" should not become a search.
        if !value.contains(where: \.isWhitespace),
           isLikelyHostInput(value),
           let url = hostLikeURL(from: value) {
            return url
        }

        return search(value)
    }

    /// Safe Chromium WebUI pages exposed as first-party browser destinations.
    /// Other chrome:// and all chrome-untrusted:// URLs stay blocked.
    static func chromiumInternalURL(from value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "chrome",
              let host = components.host?.lowercased(),
              ["extensions", "settings", "history", "downloads", "version", "help"].contains(host),
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// Preserve a Chromium extension's own origin when its options page opens.
    /// Chromium still enforces installed-resource and extension-origin access.
    static func chromiumExtensionURL(from value: String) -> URL? {
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "chrome-extension", let host = parts.host,
              host.count == 32, host.allSatisfy({ ("a"..."p").contains(String($0)) }),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        return parts.url
    }

    /// Returns a URL only when the text already names an http/https address.
    static func explicitHTTPURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Provider endpoints carry an API key in an Authorization header, so they
    /// must use HTTPS and may not embed a second set of URL credentials.
    static func isHTTPSURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return false }
        return true
    }

    /// Returns HTTPS for a bare host, including a port or local path. A colon
    /// in an authority is a port separator only when its suffix is numeric;
    /// it must not turn an arbitrary URI scheme into a browser navigation.
    static func hostLikeURL(from value: String) -> URL? {
        guard !value.contains(where: \.isWhitespace) else { return nil }
        if schemePrefix(in: value) != nil {
            let authority = value.prefix { !"/?#".contains($0) }
            guard let colon = authority.lastIndex(of: ":") else { return nil }
            let host = String(authority[..<colon]).lowercased()
            let port = authority[authority.index(after: colon)...]
            guard (host.contains(".") || host == "localhost"), !port.isEmpty,
                  port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        }
        guard let components = URLComponents(string: "https://\(value)"),
              components.host?.isEmpty == false,
              components.port.map({ (0...65535).contains($0) }) ?? true else { return nil }
        return components.url
    }

    /// Classify the authority, not the path/port, so localhost and IPv6 remain
    /// direct navigations while ordinary words still become search queries.
    static func isLikelyHostInput(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = hostLikeURL(from: trimmed)?.host?.lowercased() else { return false }
        return host == "localhost" || host.contains(".") || host.contains(":")
    }

    static func searchURL(for query: String, searchEngine: SearchEngine = .default) -> URL? {
        searchEngine.searchURL(for: query)
    }

    static func searchURL(for query: String, searchEngineHost: String) -> URL? {
        SearchEngine.makeURL(host: searchEngineHost, path: "/", items: [URLQueryItem(name: "q", value: query)])
    }

    /// A conservative scheme detector. `URL(string:)` is happy to parse text
    /// with no scheme at all, so a small scanner is clearer than guessing.
    static func schemePrefix(in value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let candidate = value[value.startIndex..<colon]
        guard !candidate.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return String(candidate)
    }

    /// Whether a model-proposed address is something Kestrel will open. Only
    /// http and https, always with a host. Used by the operator allow-list.
    static func isOpenableAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let url = explicitHTTPURL(from: trimmed) { return url.host?.isEmpty == false }
        return hostLikeURL(from: trimmed)?.host?.isEmpty == false
    }
}

struct AddressBarLabel: Equatable {
    let primary: String
    let detail: String?
}

/// A Dia-style, short location label for the unfocused toolbar. The editable
/// field still uses the complete address; this only changes its resting view.
enum AddressBarPresentation {
    static func label(for address: String) -> AddressBarLabel? {
        guard let url = URL(string: address),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else { return nil }

        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let engine = SearchEngine.allCases.first { candidate in
            switch candidate {
            case .google: host == "google.com"
            case .duckDuckGo: host == "duckduckgo.com"
            case .bing: host == "bing.com"
            }
        }

        if let engine,
           let query = components.queryItems?.first(where: { ["q", "query", "search_query"].contains($0.name) })?.value,
           !query.isEmpty {
            let isSearchURL = switch engine {
            case .google:
                components.path == "/search" || components.path.hasPrefix("/maps/")
            case .duckDuckGo:
                components.path == "/" || components.path.isEmpty
            case .bing:
                ["/search", "/images/search", "/videos/search", "/news/search", "/shop", "/maps"].contains(components.path)
            }
            if isSearchURL {
                let prefix = components.path.hasPrefix("/maps") ? "Maps · " : ""
                return AddressBarLabel(primary: engine.displayName, detail: prefix + query)
            }
        }

        let port = components.port.map { ":\($0)" } ?? ""
        let primary = host + port
        let pathSegments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .prefix(2)
            .map { segment -> String in
                let decoded = String(segment).removingPercentEncoding ?? String(segment)
                return decoded.count > 28 ? String(decoded.prefix(27)) + "…" : decoded
            }
        let detail = pathSegments.isEmpty ? nil : pathSegments.joined(separator: " / ")
        return AddressBarLabel(primary: primary, detail: detail)
    }
}

/// Search-engine suggestions are requested only while the address field is
/// focused and after a short pause. The selected engine receives the typed
/// query; URL-shaped input is excluded and response size is bounded.
enum SearchSuggestions {
    private static let maximumQueryLength = 120
    private static let maximumResponseBytes = 64 * 1024

    static func endpoint(for query: String, engine: SearchEngine = .default) -> URL? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              value.count <= maximumQueryLength,
              URLNormalisation.explicitHTTPURL(from: value) == nil,
              URLNormalisation.schemePrefix(in: value) == nil,
              value.contains(where: \.isWhitespace) || !URLNormalisation.isLikelyHostInput(value)
        else { return nil }

        switch engine {
        case .google:
            return SearchEngine.makeURL(
                host: "suggestqueries.google.com",
                path: "/complete/search",
                items: [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: value)]
            )
        case .duckDuckGo:
            return SearchEngine.makeURL(
                host: "ac.duckduckgo.com",
                path: "/ac/",
                items: [URLQueryItem(name: "q", value: value), URLQueryItem(name: "type", value: "list")]
            )
        case .bing:
            return SearchEngine.makeURL(
                host: "api.bing.com",
                path: "/osjson.aspx",
                items: [URLQueryItem(name: "query", value: value)]
            )
        }
    }

    static func fetch(for query: String, engine: SearchEngine = .default) async -> [String] {
        guard let url = endpoint(for: query, engine: engine) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard data.count <= maximumResponseBytes,
                  let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else { return [] }
            return parse(data, engine: engine)
        } catch {
            return []
        }
    }

    static func parse(_ data: Data, engine: SearchEngine = .default) -> [String] {
        guard data.count <= maximumResponseBytes,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }

        let values: [String]
        if engine == .duckDuckGo, let phrases = payload as? [[String: Any]] {
            values = phrases.compactMap { $0["phrase"] as? String }
        } else {
            guard payload.count > 1, let suggestions = payload[1] as? [String] else { return [] }
            values = suggestions
        }

        var seen = Set<String>()
        return values
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(7)
            .map { $0 }
    }
}

/// Deterministic address completion: recent searches first, then known sites,
/// then the suggestions already fetched for the typed prefix. Never invent a URL.
enum InlineAddressCompletion {
    static func complete(
        _ prefix: String,
        recentSearches: [String],
        bookmarks: [BrowserBookmark],
        openTabs: [BrowserTab],
        suggestions: [String] = []
    ) -> String? {
        guard prefix.count >= 2, prefix.count <= 2_048,
              prefix == prefix.trimmingCharacters(in: .whitespacesAndNewlines),
              !prefix.hasPrefix("!"), !prefix.contains("\n") else { return nil }

        let sites = (bookmarks.map(\.urlString) + openTabs.filter { !$0.isAssistant }.map(\.urlString))
            .compactMap { value -> String? in
                guard let components = URLComponents(string: value),
                      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                      components.user == nil, components.password == nil,
                      let host = components.host, !host.isEmpty else { return nil }
                if prefix.contains("://") { return value }
                let displayHost = host.hasPrefix("www.") && !prefix.lowercased().hasPrefix("www.")
                    ? String(host.dropFirst(4)) : host
                let port = components.port.map { ":\($0)" } ?? ""
                return displayHost + port + components.percentEncodedPath
            }
        for candidate in recentSearches + sites + suggestions {
            guard candidate.count <= 2_048,
                  let range = candidate.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]),
                  range.upperBound < candidate.endIndex else { continue }
            return prefix + candidate[range.upperBound...]
        }
        return nil
    }
}
