#if canImport(SwiftUI)

import Combine
import Foundation
import SwiftUI

enum KestrelAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum NewTabAssistantDestination: String, CaseIterable, Identifiable {
    case assistantPage
    case assistantSidebar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistantPage: "Assistant page"
        case .assistantSidebar: "Sidebar"
        }
    }
}

/// User-entered contact details, local only. Never included in AI settings or requests.
struct PersonalProfile: Codable, Equatable, Sendable {
    var name = ""
    var email = ""
    var phone = ""
    var addressLine1 = ""
    var addressLine2 = ""
    var city = ""
    var county = ""
    var postcode = ""
    var country = ""
    var preferences = ""

    var normalised: Self {
        var result = self
        for key in [\Self.name, \Self.email, \Self.phone, \Self.addressLine1, \Self.addressLine2,
                    \Self.city, \Self.county, \Self.postcode, \Self.country, \Self.preferences] {
            result[keyPath: key] = String(result[keyPath: key].trimmingCharacters(in: .whitespacesAndNewlines).prefix(key == \Self.preferences ? 2_000 : 512))
        }
        return result
    }

    /// Fixed semantic fields only. Free-form preferences never leave this store.
    var formValues: [String: String] {
        let p = normalised
        let parts = p.name.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        return ["name": p.name, "given-name": parts.first ?? "", "family-name": parts.count > 1 ? parts[1] : "",
                "street-address": [p.addressLine1, p.addressLine2].filter { !$0.isEmpty }.joined(separator: "\n"),
                "email": p.email, "tel": p.phone,
                "address-line1": p.addressLine1, "address-line2": p.addressLine2,
                "address-level2": p.city, "address-level1": p.county,
                "postal-code": p.postcode, "country-name": p.country]
            .filter { !$0.value.isEmpty }
    }

    /// Deliberately excludes free-form preferences from a checkout clipboard export.
    var deliveryText: String {
        let value = normalised
        return [value.name, value.addressLine1, value.addressLine2, value.city, value.county,
                value.postcode, value.country, value.email, value.phone].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Non-secret settings, persisted as JSON in `UserDefaults`. Secret values
/// never pass through here: the API key field goes straight to the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    @Published var searchEngine: SearchEngine {
        didSet { persist(searchEngine, key: Self.searchEngineKey) }
    }

    @Published var appearanceMode: KestrelAppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey) }
    }

    /// Safari-style translucent tint for the browser backing and both sidebars.
    @Published var translucentChromeEnabled: Bool {
        didSet { defaults.set(translucentChromeEnabled, forKey: Self.translucentChromeEnabledKey) }
    }

    @Published var newTabAssistantDestination: NewTabAssistantDestination {
        didSet { defaults.set(newTabAssistantDestination.rawValue, forKey: Self.newTabAssistantDestinationKey) }
    }

    @Published var personalProfile: PersonalProfile {
        didSet { persist(personalProfile.normalised, key: Self.personalProfileKey) }
    }

    @Published var ai: AISettings {
        didSet { persist(ai, key: Self.aiKey) }
    }

    @Published var extensions: ExtensionsSettings {
        didSet { persist(extensions, key: Self.extensionsKey) }
    }

    @Published var agentMCP: AgentMCPSettings {
        didSet { persist(agentMCP, key: Self.agentMCPKey) }
    }

    @Published var assistantSidebarShortcut: AssistantSidebarShortcut {
        didSet { persist(assistantSidebarShortcut, key: Self.assistantSidebarShortcutKey) }
    }

    @Published var browserShortcuts: [String: AssistantSidebarShortcut] {
        didSet { persist(browserShortcuts, key: Self.browserShortcutsKey) }
    }

    /// Skips per-action approvals for low-risk search/navigation after the user
    /// explicitly chooses cursor assistance. Mutating page controls remain gated.
    @Published var autoApproveSafeBrowsing: Bool {
        didSet { defaults.set(autoApproveSafeBrowsing, forKey: Self.autoApproveSafeBrowsingKey) }
    }

    /// Whether the Assistant may search the web for a question that needs it.
    ///
    /// This is permission, not a command. It used to force a search before
    /// every reply, which meant the Assistant never actually answered anything:
    /// each question opened a results page in a new tab. The router now decides
    /// whether a question needs the web, and this switch can only hold a search
    /// back, so turning it off answers everything from the model itself.
    @Published var assistantWebSearchEnabled: Bool {
        didSet { defaults.set(assistantWebSearchEnabled, forKey: Self.assistantWebSearchEnabledKey) }
    }

    @Published var exaSearchEnabled: Bool {
        didSet { defaults.set(exaSearchEnabled, forKey: Self.exaSearchEnabledKey) }
    }

    /// Whether the model picker opens straight to the full, searchable model
    /// list instead of the plain-language Free/Cheap/Fast/Quality quick picks.
    /// Off by default so the first choice is simple; advanced picking is always
    /// one disclosure away even when this is off.
    @Published var advancedModelPicking: Bool {
        didSet { defaults.set(advancedModelPicking, forKey: Self.advancedModelPickingKey) }
    }

    /// Whether a coarse, locale-derived region is included in assistant
    /// requests. On by default because it is only a country and time zone read
    /// from this device, never precise location; off removes it entirely.
    @Published var shareRegionWithAssistant: Bool {
        didSet { defaults.set(shareRegionWithAssistant, forKey: Self.shareRegionWithAssistantKey) }
    }

    @Published private(set) var bookmarks: [BrowserBookmark] {
        didSet { persist(bookmarks, key: Self.bookmarksKey) }
    }

    /// Search terms entered in Kestrel's address fields. This is local app
    /// state only; it is not imported from another browser or shared with MCP.
    @Published private(set) var recentSearches: [String] {
        didSet { persist(recentSearches, key: Self.recentSearchesKey) }
    }

    /// Assistant transcripts stay in this app's local preferences. Page text,
    /// operator proposals and credentials are never included in the archive.
    @Published var assistantConversations: [AssistantConversation] {
        didSet { persist(assistantConversations, key: Self.assistantConversationsKey) }
    }

    /// Transient state used while the shortcut recorder owns keyboard input.
    @Published var recordingShortcut: BrowserCommand?
    var isCapturingShortcut: Bool { recordingShortcut != nil }

    private let defaults: UserDefaults
    private static let searchEngineKey = "kestrel.browser.search-engine.v1"
    private static let appearanceModeKey = "kestrel.appearance.mode.v1"
    private static let translucentChromeEnabledKey = "kestrel.appearance.translucent-chrome.v1"
    private static let newTabAssistantDestinationKey = "kestrel.assistant.new-tab-destination.v1"
    private static let personalProfileKey = "kestrel.personal-profile.v1"
    private static let aiKey = "kestrel.ai.settings.v1"
    private static let extensionsKey = "kestrel.extensions.settings.v1"
    private static let agentMCPKey = "kestrel.agent-mcp.settings.v1"
    private static let browserShortcutsKey = "kestrel.shortcuts.browser.v1"
    private static let assistantSidebarShortcutKey = "kestrel.shortcuts.assistant-sidebar.v1"
    private static let autoApproveSafeBrowsingKey = "kestrel.assistant.auto-approve-safe-browsing.v1"
    private static let assistantWebSearchEnabledKey = "kestrel.assistant.web-search-enabled.v1"
    private static let exaSearchEnabledKey = "kestrel.assistant.exa-search-enabled.v1"
    private static let advancedModelPickingKey = "kestrel.assistant.advanced-model-picking.v1"
    private static let shareRegionWithAssistantKey = "kestrel.assistant.share-region.v1"
    private static let bookmarksKey = "kestrel.browser.bookmarks.v1"
    private static let recentSearchesKey = "kestrel.browser.recent-searches.v1"
    private static let assistantConversationsKey = "kestrel.assistant.conversations.v1"
    private static let recentSearchesLimit = 50

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.personalProfile = Self.load(PersonalProfile.self, key: Self.personalProfileKey, from: defaults)?.normalised ?? .init()
        self.searchEngine = Self.load(SearchEngine.self, key: Self.searchEngineKey, from: defaults) ?? .default
        self.appearanceMode = KestrelAppearanceMode(rawValue: defaults.string(forKey: Self.appearanceModeKey) ?? "") ?? .system
        self.translucentChromeEnabled = defaults.object(forKey: Self.translucentChromeEnabledKey) as? Bool ?? true
        self.newTabAssistantDestination = NewTabAssistantDestination(
            rawValue: defaults.string(forKey: Self.newTabAssistantDestinationKey) ?? ""
        ) ?? .assistantPage
        var loadedAI = Self.load(AISettings.self, key: Self.aiKey, from: defaults) ?? .default
        loadedAI.migrateLegacyDefaults()
        self.ai = loadedAI
        self.extensions = Self.load(ExtensionsSettings.self, key: Self.extensionsKey, from: defaults) ?? .default
        self.agentMCP = Self.load(AgentMCPSettings.self, key: Self.agentMCPKey, from: defaults) ?? .default
        let savedShortcut = Self.load(AssistantSidebarShortcut.self, key: Self.assistantSidebarShortcutKey, from: defaults)
        self.assistantSidebarShortcut = savedShortcut?.isValid == true ? savedShortcut! : .default
        self.browserShortcuts = (Self.load([String: AssistantSidebarShortcut].self, key: Self.browserShortcutsKey, from: defaults) ?? [:])
            .filter { BrowserCommand(rawValue: $0.key) != nil && $0.value.isValid }
        self.autoApproveSafeBrowsing = defaults.object(forKey: Self.autoApproveSafeBrowsingKey) as? Bool ?? true
        self.assistantWebSearchEnabled = defaults.object(forKey: Self.assistantWebSearchEnabledKey) as? Bool ?? true
        self.exaSearchEnabled = defaults.bool(forKey: Self.exaSearchEnabledKey)
        self.advancedModelPicking = defaults.object(forKey: Self.advancedModelPickingKey) as? Bool ?? false
        self.shareRegionWithAssistant = defaults.object(forKey: Self.shareRegionWithAssistantKey) as? Bool ?? true
        self.bookmarks = Self.load([BrowserBookmark].self, key: Self.bookmarksKey, from: defaults) ?? []
        self.recentSearches = Self.load([String].self, key: Self.recentSearchesKey, from: defaults) ?? []
        self.assistantConversations = Self.load([AssistantConversation].self, key: Self.assistantConversationsKey, from: defaults) ?? []
    }

    var secrets: SecretProviding {
        Secrets.defaultProvider()
    }

    /// Which environment variable names are consulted for the current provider,
    /// reported by name only.
    var currentSecretEnvironmentNames: String {
        let provider = ai.settings(for: ai.selectedProvider)
        let names = [provider.apiKeyEnvironmentVariable, "KESTREL_* (reserved for future provider keys)"]
        return Redaction.describeEnvironmentNames(names)
    }

    func isBookmarked(_ address: String) -> Bool {
        guard let candidate = BrowserBookmark(title: "", urlString: address).normalizedURLString else { return false }
        return bookmarks.contains { $0.normalizedURLString == candidate }
    }

    @discardableResult
    func toggleBookmark(title: String, address: String, faviconURL: String?) -> Bool {
        let candidate = BrowserBookmark(title: title, urlString: address, faviconURL: faviconURL)
        guard let normalized = candidate.normalizedURLString else { return false }
        if let existing = bookmarks.first(where: { $0.normalizedURLString == normalized }) {
            bookmarks.removeAll { $0.id == existing.id }
            return false
        }
        bookmarks.insert(candidate, at: 0)
        return true
    }

    func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }

    func recordSearch(_ input: String) {
        // Record the words, not the mode. A query that arrived as "!maps eiffel
        // tower" is stored as "eiffel tower": history is a list of things the
        // user searched for, and a bang in front of every maps entry turns it
        // into a list of command syntax that also re-runs the mode when picked.
        let query = SearchShortcut.strippingLeadingShortcut(from: input)
        let isNavigableBareHost = !query.contains(where: \.isWhitespace)
            && URLNormalisation.isLikelyHostInput(query)
            && URLNormalisation.hostLikeURL(from: query) != nil
        guard !query.isEmpty,
              URLNormalisation.explicitHTTPURL(from: query) == nil,
              !isNavigableBareHost else { return }

        var updated = recentSearches.filter {
            $0.localizedCaseInsensitiveCompare(query) != .orderedSame
        }
        updated.insert(query, at: 0)
        recentSearches = Array(updated.prefix(Self.recentSearchesLimit))
    }

    func clearSearchHistory() {
        recentSearches = []
    }

    @discardableResult
    func importBookmarks(_ imported: [BrowserBookmark]) -> Int {
        var existing = Set(bookmarks.compactMap(\.normalizedURLString))
        let additions = imported.filter { bookmark in
            guard let normalized = bookmark.normalizedURLString else { return false }
            return existing.insert(normalized).inserted
        }
        bookmarks.insert(contentsOf: additions, at: 0)
        return additions.count
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct AgentMCPSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var sharesActiveTabMetadata: Bool
    var allowsPageReads: Bool

    static let `default` = AgentMCPSettings(
        isEnabled: false,
        sharesActiveTabMetadata: false,
        allowsPageReads: false
    )
}

struct AssistantSidebarShortcut: Codable, Equatable, Sendable {
    var key: String
    var modifiers: [String]

    static let `default` = AssistantSidebarShortcut(key: "e", modifiers: ["command"])

    static let specialKeyNames = ["\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→", "\r": "Return", "\t": "Tab", " ": "Space"]

    func matches(_ other: Self) -> Bool {
        key.lowercased() == other.key.lowercased() && Set(modifiers) == Set(other.modifiers)
    }

    private static let modifierOrder = ["command", "option", "control", "shift"]

    var isValid: Bool {
        guard key.count == 1, let character = key.first,
              character.isLetter || character.isNumber || character.isPunctuation || Self.specialKeyNames[key] != nil || key == "+",
              modifiers.contains(where: { ["command", "option", "control"].contains($0) }) else { return false }
        return modifiers.allSatisfy { Self.modifierOrder.contains($0) }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains("command") { result.insert(.command) }
        if modifiers.contains("option") { result.insert(.option) }
        if modifiers.contains("control") { result.insert(.control) }
        if modifiers.contains("shift") { result.insert(.shift) }
        return result
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(key.first ?? "e")
    }

    var displayName: String {
        let symbols = modifiers.compactMap { modifier -> String? in
            switch modifier {
            case "command": "⌘"
            case "option": "⌥"
            case "control": "⌃"
            case "shift": "⇧"
            default: nil
            }
        }
        return symbols.joined() + " " + (Self.specialKeyNames[key] ?? key.uppercased())
    }
}

#endif
