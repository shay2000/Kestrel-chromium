import Foundation

/// A tab as data. It is intentionally separate from any web view: this is what
/// the tab strip draws and what a future session restore would persist. The
/// live `WKWebView` lives in `TabStore` and is created only when a tab is
/// first shown.
protocol BrowserTabModel: Identifiable {
    var id: UUID { get }
    var title: String { get }
    var urlString: String { get }
    var faviconURL: String? { get }
    var isPinned: Bool { get }
}

struct BrowserTab: BrowserTabModel, Equatable, Sendable {
    let id: UUID
    var title: String
    var urlString: String
    var faviconURL: String?
    var isPinned: Bool
    var createdAt: Date
    var customTitle: String?
    /// The shortcut stays anchored while its live page navigates elsewhere.
    var pinnedPage: BrowserBookmark?
    /// True when this tab holds the assistant conversation rather than a web
    /// page.
    ///
    /// A chat opened from the new tab page or from the Assistant control is a
    /// page in its own right — the reference this was built against shows the
    /// conversation as the selected row in the rail — so it lives in the tab
    /// model instead of being a mode of the window. That is what lets ⌘W close
    /// it, the rail name it, and the Chats menu select it like anything else.
    ///
    /// An assistant tab has no address and never gets a `WKWebView`: there is
    /// no page for WebKit to hold.
    var isAssistant: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        urlString: String = "",
        faviconURL: String? = nil,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        isAssistant: Bool = false
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.faviconURL = faviconURL
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.customTitle = nil
        self.pinnedPage = isPinned ? BrowserBookmark(id: id, title: title, urlString: urlString, faviconURL: faviconURL) : nil
        self.isAssistant = isAssistant
    }

    var displayTitle: String {
        let trimmed = (customTitle ?? (isPinned ? pinnedPage?.title : nil) ?? title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Tab" : trimmed
    }

    var canPin: Bool {
        !isAssistant && BrowserBookmark(title: title, urlString: urlString).normalizedURLString != nil
    }

    var faviconSourceURL: URL? {
        let page = isPinned ? pinnedPage : nil
        return BrowserBookmark(title: title, urlString: page?.urlString ?? urlString,
                               faviconURL: page?.faviconURL ?? faviconURL).faviconSourceURL
    }

    var hostLabel: String {
        guard let url = URL(string: urlString), let host = url.host else {
            return urlString
        }
        return host
    }

    /// The rail's second line. An assistant tab has no host, so it says what it
    /// is rather than leaving the line blank under the title.
    var detailLabel: String {
        isAssistant ? "Assistant" : hostLabel
    }
}

enum BrowserSplitSide: Equatable, Sendable {
    case left
    case right

    var opposite: BrowserSplitSide {
        self == .left ? .right : .left
    }
}

/// The two tab identities currently displayed side by side. A tab can occupy
/// only one pane; moving the opposite pane's tab across swaps the two panes.
struct BrowserSplit: Identifiable, Equatable, Sendable {
    let id = UUID()
    private(set) var leftTabID: UUID
    private(set) var rightTabID: UUID
    private(set) var leadingFraction = 0.5

    init(leftTabID: UUID, rightTabID: UUID) {
        precondition(leftTabID != rightTabID, "A split view requires two distinct tabs")
        self.leftTabID = leftTabID
        self.rightTabID = rightTabID
    }

    func tabID(for side: BrowserSplitSide) -> UUID {
        side == .left ? leftTabID : rightTabID
    }

    func side(containing tabID: UUID) -> BrowserSplitSide? {
        if leftTabID == tabID { return .left }
        if rightTabID == tabID { return .right }
        return nil
    }

    mutating func resize(to fraction: Double) {
        guard fraction.isFinite else { return }
        leadingFraction = min(0.8, max(0.2, fraction))
    }

    /// Keep both toolbars usable, including in a narrow window.
    func leadingWidth(availableWidth: Double) -> Double {
        guard availableWidth.isFinite, availableWidth > 0 else { return 0 }
        let minimum = min(280, availableWidth / 2)
        return min(availableWidth - minimum, max(minimum, availableWidth * leadingFraction))
    }

    mutating func place(_ tabID: UUID, on side: BrowserSplitSide) {
        let otherSide = side.opposite
        if self.tabID(for: otherSide) == tabID {
            let displacedTabID = self.tabID(for: side)
            set(displacedTabID, on: otherSide)
        }
        set(tabID, on: side)
    }

    private mutating func set(_ tabID: UUID, on side: BrowserSplitSide) {
        if side == .left {
            leftTabID = tabID
        } else {
            rightTabID = tabID
        }
    }
}

/// A split is one rail entry, in the position of its first member. Pins keep
/// their saved shortcuts as well; ordinary members appear only inside the pair.
enum BrowserTabRailItem: Identifiable, Equatable {
    case tab(BrowserTab)
    case split(BrowserSplit)

    var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .split(let split): split.id
        }
    }

    static func items(tabs: [BrowserTab], splits: [BrowserSplit]) -> [Self] {
        var seen = Set<UUID>()
        return tabs.compactMap { tab in
            if let split = splits.first(where: { $0.side(containing: tab.id) != nil }) {
                return seen.insert(split.id).inserted ? .split(split) : nil
            }
            return tab.isPinned ? nil : .tab(tab)
        }
    }
}

struct BrowserBookmark: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var urlString: String
    var faviconURL: String?

    init(id: UUID = UUID(), title: String, urlString: String, faviconURL: String? = nil) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.faviconURL = faviconURL
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let host = URL(string: urlString)?.host ?? urlString
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return trimmed
    }

    /// Use a saved site favicon when available; imported bookmarks without
    /// favicon metadata fall back to that same site's standard icon path.
    var faviconSourceURL: URL? {
        if let faviconURL,
           let icon = URL(string: faviconURL),
           let scheme = icon.scheme?.lowercased(),
           (scheme == "https" || scheme == "http"),
           icon.host?.isEmpty == false,
           icon.user == nil,
           icon.password == nil {
            return icon
        }

        guard let site = URLNormalisation.explicitHTTPURL(from: urlString),
              let components = URLComponents(url: site, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil else { return nil }
        var icon = components
        icon.scheme = "https"
        icon.path = "/favicon.ico"
        icon.query = nil
        icon.fragment = nil
        return icon.url
    }

    var normalizedURLString: String? {
        guard let url = URLNormalisation.explicitHTTPURL(from: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased() else { return nil }
        var normalized = components
        normalized.scheme = components.scheme?.lowercased()
        normalized.host = host
        normalized.fragment = nil
        if (normalized.scheme == "https" && normalized.port == 443)
            || (normalized.scheme == "http" && normalized.port == 80) {
            normalized.port = nil
        }
        return normalized.url?.absoluteString
    }
}

enum BrowserBookmarkImporter {
    static let maximumFileBytes = 10 * 1_024 * 1_024
    static let maximumBookmarks = 10_000

    enum ImportError: LocalizedError {
        case fileTooLarge
        case unsupportedFormat
        case malformedFile

        var errorDescription: String? {
            switch self {
            case .fileTooLarge: "That bookmark file is larger than the 10 MB import limit."
            case .unsupportedFormat: "Choose a Safari Bookmarks.plist file, Chrome Bookmarks JSON file, or exported bookmarks HTML file."
            case .malformedFile: "The selected browser bookmark file could not be read."
            }
        }
    }

    /// Imports bookmark records only. Passwords, cookies, browsing history and
    /// other profile databases are deliberately not read or copied.
    static func parse(data: Data, filename: String) throws -> [BrowserBookmark] {
        guard data.count <= maximumFileBytes else { throw ImportError.fileTooLarge }
        let trimmed = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()

        if ext == "plist" || data.starts(with: Data("bplist".utf8)) {
            return try parseSafariPropertyList(data)
        }
        if ext == "json" || trimmed.hasPrefix("{") {
            return try parseChromiumJSON(data)
        }
        if ext == "html" || trimmed.contains("<html") || trimmed.contains("<a ") || trimmed.contains("<a\n") {
            guard let html = String(data: data, encoding: .utf8) else { throw ImportError.malformedFile }
            return parseNetscapeHTML(html)
        }
        throw ImportError.unsupportedFormat
    }

    private static func parseChromiumJSON(_ data: Data) throws -> [BrowserBookmark] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw ImportError.malformedFile }
        var result: [BrowserBookmark] = []
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] as? [String: Any] { appendChromiumNode(node, to: &result) }
        }
        return deduplicated(result)
    }

    private static func appendChromiumNode(_ node: [String: Any], to result: inout [BrowserBookmark], depth: Int = 0) {
        guard result.count < maximumBookmarks, depth < 64 else { return }
        if node["type"] as? String == "url",
           let address = node["url"] as? String,
           let valid = validBookmarkURL(address) {
            result.append(BrowserBookmark(
                title: node["name"] as? String ?? valid.host ?? address,
                urlString: valid.absoluteString
            ))
            return
        }
        for child in node["children"] as? [[String: Any]] ?? [] {
            appendChromiumNode(child, to: &result, depth: depth + 1)
            if result.count >= maximumBookmarks { return }
        }
    }

    private static func parseSafariPropertyList(_ data: Data) throws -> [BrowserBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ImportError.malformedFile
        }
        var result: [BrowserBookmark] = []
        func walk(_ node: [String: Any], depth: Int) {
            guard result.count < maximumBookmarks, depth < 64 else { return }
            if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
               let address = node["URLString"] as? String,
               let valid = validBookmarkURL(address) {
                result.append(BrowserBookmark(
                    title: node["Title"] as? String ?? valid.host ?? address,
                    urlString: valid.absoluteString
                ))
                return
            }
            for child in node["Children"] as? [[String: Any]] ?? [] {
                walk(child, depth: depth + 1)
                if result.count >= maximumBookmarks { return }
            }
        }
        walk(root, depth: 0)
        return deduplicated(result)
    }

    private static func parseNetscapeHTML(_ html: String) -> [BrowserBookmark] {
        let pattern = #"(?is)<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(html.startIndex..., in: html)
        var result: [BrowserBookmark] = []
        for match in expression.matches(in: html, range: fullRange).prefix(maximumBookmarks) {
            let addressValue = (1...3).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: html) else { return nil }
                return String(html[range])
            }.first
            guard let addressValue, let address = validBookmarkURL(decodeHTMLEntities(addressValue)),
                  let titleRange = Range(match.range(at: 4), in: html) else { continue }
            let rawTitle = String(html[titleRange])
            let plainTitle = rawTitle.replacingOccurrences(
                of: #"(?is)<[^>]*>"#,
                with: " ",
                options: .regularExpression
            )
            result.append(BrowserBookmark(
                title: decodeHTMLEntities(plainTitle).trimmingCharacters(in: .whitespacesAndNewlines),
                urlString: address.absoluteString
            ))
        }
        return deduplicated(result)
    }

    private static func validBookmarkURL(_ address: String) -> URL? {
        guard let url = URLNormalisation.explicitHTTPURL(from: address) else { return nil }
        let bookmark = BrowserBookmark(title: "", urlString: url.absoluteString)
        guard bookmark.normalizedURLString != nil else { return nil }
        return url
    }

    private static func deduplicated(_ bookmarks: [BrowserBookmark]) -> [BrowserBookmark] {
        var seen = Set<String>()
        return bookmarks.filter { bookmark in
            guard let normalized = bookmark.normalizedURLString else { return false }
            return seen.insert(normalized).inserted
        }
    }

    private static func decodeHTMLEntities(_ source: String) -> String {
        var value = source
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")

        guard let expression = try? NSRegularExpression(pattern: #"&#(?:x([0-9a-fA-F]+)|([0-9]+));"#) else { return value }
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let number: UInt32?
            if let range = Range(match.range(at: 1), in: value) {
                number = UInt32(value[range], radix: 16)
            } else if let range = Range(match.range(at: 2), in: value) {
                number = UInt32(value[range], radix: 10)
            } else {
                number = nil
            }
            guard let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: value) else { continue }
            value.replaceSubrange(range, with: String(scalar))
        }
        return value
    }
}

/// The ordering, selection and pinning rules of a tab row, with no UI and no
/// web views. Keeping this pure makes the fiddly parts (closing the selected
/// tab, reordering past pinned tabs) easy to unit-test.
struct TabCollection: Equatable, Sendable {
    private(set) var tabs: [BrowserTab]
    private(set) var selectedID: UUID?

    init(tabs: [BrowserTab] = [], selectedID: UUID? = nil) {
        self.tabs = tabs
        self.selectedID = selectedID ?? tabs.first?.id
    }

    var selectedTab: BrowserTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    var isEmpty: Bool { tabs.isEmpty }

    var pinnedTabs: [BrowserTab] { tabs.filter(\.isPinned) }
    var unpinnedTabs: [BrowserTab] { tabs.filter { !$0.isPinned } }

    @discardableResult
    mutating func addTab(_ tab: BrowserTab = BrowserTab(), select: Bool = true) -> BrowserTab {
        if tab.isPinned {
            // Pinned tabs live at the front, in creation order.
            let insertionIndex = tabs.firstIndex { !$0.isPinned } ?? tabs.endIndex
            tabs.insert(tab, at: insertionIndex)
        } else {
            tabs.append(tab)
        }
        if select {
            selectedID = tab.id
        }
        return tab
    }

    mutating func select(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    mutating func selectNext() {
        guard let selectedID, let index = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else {
            return
        }
        let next = tabs.index(after: index)
        self.selectedID = tabs[next == tabs.endIndex ? tabs.startIndex : next].id
    }

    mutating func selectPrevious() {
        guard let selectedID, let index = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else {
            return
        }
        let previous = index == tabs.startIndex ? tabs.index(before: tabs.endIndex) : tabs.index(before: index)
        self.selectedID = tabs[previous].id
    }

    /// Closes a tab and moves the selection to a sensible neighbour. Closing
    /// the last tab is allowed and leaves an empty collection; callers decide
    /// whether to immediately open a fresh tab.
    mutating func close(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        guard selectedID == id else { return }
        guard !tabs.isEmpty else {
            selectedID = nil
            return
        }
        let neighbour = min(index, tabs.count - 1)
        selectedID = tabs[neighbour].id
    }

    mutating func setPinned(_ pinned: Bool, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].isPinned != pinned else { return }
        var tab = tabs.remove(at: index)
        tab.isPinned = pinned
        tab.pinnedPage = pinned ? BrowserBookmark(id: id, title: tab.title, urlString: tab.urlString, faviconURL: tab.faviconURL) : nil
        if pinned {
            let insertionIndex = tabs.firstIndex { !$0.isPinned } ?? tabs.endIndex
            tabs.insert(tab, at: insertionIndex)
        } else {
            tabs.append(tab)
        }
    }

    mutating func rename(id: UUID, to title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        tabs[index].customTitle = cleaned.isEmpty ? nil : cleaned
    }

    /// Reorders within a group; dragging cannot accidentally pin or unpin a page.
    @discardableResult
    mutating func move(id: UUID, to targetID: UUID) -> Bool {
        guard id != targetID,
              let source = tabs.firstIndex(where: { $0.id == id }),
              let target = tabs.firstIndex(where: { $0.id == targetID }),
              tabs[source].isPinned == tabs[target].isPinned else { return false }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: target)
        return true
    }

    mutating func resetPinnedPage(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let page = tabs[index].pinnedPage, tabs[index].isPinned else { return }
        tabs[index].title = page.title
        tabs[index].urlString = page.urlString
        tabs[index].faviconURL = page.faviconURL
    }

    mutating func update(id: UUID, title: String?, urlString: String?, faviconURL: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let title { tabs[index].title = title }
        if let urlString { tabs[index].urlString = urlString }
        tabs[index].faviconURL = faviconURL
    }

    /// Turns a tab into the assistant tab in place, keeping its identity and its
    /// position in the rail.
    ///
    /// Used when the assistant page opens on a tab that has nothing on it. The
    /// alternative — adding a tab and leaving the empty one behind — puts a
    /// blank row in the rail beside every chat started from the new tab page.
    mutating func makeAssistant(id: UUID, title: String = "Assistant") {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isAssistant = true
        tabs[index].title = title
        tabs[index].urlString = ""
        tabs[index].faviconURL = nil
    }
}

/// Only explicitly pinned HTTP(S) destinations are restored. No live page,
/// navigation history, assistant transcript or credentials enter this archive.
enum PinnedTabArchive {
    static let key = "Kestrel.tabs.pinned.v1"
    static let maximumCount = 48
    static let maximumBytes = 256 * 1_024

    private struct Record: Codable {
        let page: BrowserBookmark
        let customTitle: String?
    }

    static func encode(_ tabs: [BrowserTab]) -> Data? {
        let records = tabs.filter(\.isPinned).prefix(maximumCount).compactMap { tab -> Record? in
            guard let page = tab.pinnedPage, valid(page) else { return nil }
            return Record(page: page, customTitle: tab.customTitle.map { String($0.prefix(120)) })
        }
        guard let data = try? JSONEncoder().encode(records), data.count <= maximumBytes else { return nil }
        return data
    }

    static func decode(_ data: Data?) -> [BrowserTab] {
        guard let data, data.count <= maximumBytes,
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        var seen = Set<UUID>()
        return records.prefix(maximumCount).compactMap { record in
            let page = record.page
            guard valid(page), seen.insert(page.id).inserted else { return nil }
            var tab = BrowserTab(id: page.id, title: page.title, urlString: page.urlString,
                                 faviconURL: page.faviconURL, isPinned: true)
            tab.customTitle = record.customTitle.map { String($0.prefix(120)) }
            return tab
        }
    }

    private static func valid(_ page: BrowserBookmark) -> Bool {
        page.normalizedURLString != nil && page.urlString.utf8.count <= 8_192
            && page.title.utf8.count <= 4_096
            && (page.faviconURL?.utf8.count ?? 0) <= 8_192
    }
}
