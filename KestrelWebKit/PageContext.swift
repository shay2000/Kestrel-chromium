import Foundation

/// A deliberately small, bounded view of the page the sidebar is talking about.
///
/// It carries only what a person could read on screen: address, title and a
/// clipped run of visible text. The reader does not access cookies, storage or
/// form-control values; visible text can still contain sensitive material, so
/// callers apply best-effort credential-shaped redaction. It uses a fixed
/// script, not model output.
struct PageContext: Equatable, Sendable {
    var url: String
    var title: String
    var textSnapshot: String
    var wasTruncated: Bool
    var additionalSources: [PageContextSource]

    init(
        url: String,
        title: String,
        textSnapshot: String,
        wasTruncated: Bool,
        additionalSources: [PageContextSource] = []
    ) {
        self.url = url
        self.title = title
        self.textSnapshot = textSnapshot
        self.wasTruncated = wasTruncated
        self.additionalSources = additionalSources
    }

    static let empty = PageContext(url: "", title: "", textSnapshot: "", wasTruncated: false)

    var isEmpty: Bool {
        url.isEmpty && title.isEmpty && textSnapshot.isEmpty && additionalSources.allSatisfy(\.isEmpty)
    }
}

/// A labelled, bounded secondary source such as the visible search-results
/// page. It stays separate from the current-page excerpt in the prompt.
struct PageContextSource: Equatable, Sendable {
    var label: String
    var url: String
    var title: String
    var textSnapshot: String
    var wasTruncated: Bool

    init(label: String, context: PageContext) {
        self.label = label
        self.url = context.url
        self.title = context.title
        self.textSnapshot = context.textSnapshot
        self.wasTruncated = context.wasTruncated
    }

    var isEmpty: Bool {
        url.isEmpty && title.isEmpty && textSnapshot.isEmpty
    }
}

enum PageContextBuilder {
    /// Snapshot-bound control references are execution capabilities, not page
    /// progress. Keep surrounding labels/context when comparing observations.
    static func stableEvidence(_ text: String) -> String {
        text.replacingOccurrences(of: #" \| control: [A-Za-z0-9_-]+"#, with: "", options: .regularExpression)
    }
    /// Conservative fallback and hard ceiling for the automatically selected
    /// page-text budget. These are character budgets, not model token limits.
    static let defaultCharacterLimit = 4_000
    static let maximumCharacterLimit = 20_000

    static func clampLimit(_ value: Int) -> Int {
        min(max(value, 200), maximumCharacterLimit)
    }

    /// Selects a bounded page-text budget for the active backend. When the
    /// configured model ID includes a context hint such as `16k` or `128k`,
    /// Kestrel reserves roughly three quarters of a character per context
    /// token for page text, leaving room for instructions, conversation, and
    /// the answer. Unknown/custom model IDs use a cautious provider default.
    static func automaticCharacterLimit(for provider: AIProviderKind, model: String) -> Int {
        if let contextWindow = contextWindowHint(in: model) {
            return clampLimit(contextWindow * 3 / 4)
        }

        switch provider {
        case .appleLocalModel:
            return 4_000
        case .codexCLI:
            return 16_000
        case .workBuddyCLI, .kiloCLI, .openRouter, .mistral, .googleGemini, .groq, .deepSeek, .xAI, .customOpenAI:
            return 12_000
        }
    }

    private static func contextWindowHint(in model: String) -> Int? {
        let components = model.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }

        for component in components.reversed() {
            guard let suffix = component.last else { continue }
            let multiplier: Int
            switch suffix {
            case "k": multiplier = 1_000
            case "m": multiplier = 1_000_000
            default: continue
            }
            guard let magnitude = Int(component.dropLast()),
                  magnitude > 0,
                  magnitude <= 1_000_000 / multiplier else { continue }
            let value = magnitude * multiplier
            if (1_000...1_000_000).contains(value) {
                return value
            }
        }
        return nil
    }

    /// Collapses whitespace so a snapshot is compact and predictable.
    static func normalise(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the text clipped to `limit` and whether anything was dropped.
    /// The clip happens on a character boundary after normalisation so the
    /// result is valid UTF-8 and reads cleanly.
    static func bounded(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        clipped(text, limit: clampLimit(limit))
    }

    /// Sub-budgets may be smaller than the public 200-character minimum.
    /// Normalise only as far as the first omitted character, avoiding a full
    /// split/join and character count of a potentially very large page.
    private static func clipped(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        var result = ""
        var count = 0
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = count > 0
                continue
            }
            if pendingSpace && count < limit {
                result.append(" ")
                count += 1
            }
            guard count < limit else {
                if !result.isEmpty {
                    result.removeLast()
                    result.append("…")
                }
                return (result, true)
            }
            result.append(character)
            count += 1
            pendingSpace = false
        }
        return (result, false)
    }

    static func make(url: String, title: String, text: String, limit: Int = defaultCharacterLimit) -> PageContext {
        let clipped = bounded(text, limit: limit)
        return PageContext(
            url: url,
            title: normalise(title),
            textSnapshot: clipped.text,
            wasTruncated: clipped.truncated
        )
    }

    /// Combines the active page and a search-results page within one total
    /// character budget. The current page receives up to half; any unused
    /// space is available to search results. If only one source is available,
    /// it can use the full budget.
    static func combining(
        currentPage: PageContext?,
        searchResults: PageContext?,
        limit: Int
    ) -> PageContext? {
        let budget = clampLimit(limit)
        let current = currentPage.flatMap { $0.isEmpty ? nil : $0 }
        let results = searchResults.flatMap { $0.isEmpty ? nil : $0 }

        switch (current, results) {
        case (nil, nil):
            return nil
        case (let page?, nil):
            return boundedContext(page, limit: budget)
        case (nil, let results?):
            let bounded = boundedContext(results, limit: budget)
            if !bounded.additionalSources.isEmpty {
                // A search API returns one labelled source per result. Keeping
                // them gives the model a citation per result instead of one
                // merged block.
                return bounded
            }
            var context = PageContext.empty
            context.additionalSources = [
                PageContextSource(label: "Search results", context: bounded)
            ]
            return context
        case (let page?, let results?):
            let currentBudget = budget / 2
            let boundedPage = boundedContext(page, limit: currentBudget)
            let usedByCurrent = boundedPage.textSnapshot.count
                + boundedPage.additionalSources.reduce(0) { $0 + $1.textSnapshot.count }
            let resultsBudget = budget - usedByCurrent
            let boundedResults = boundedContext(results, limit: resultsBudget)
            var context = boundedPage
            if boundedResults.additionalSources.isEmpty {
                context.additionalSources.append(PageContextSource(label: "Search results", context: boundedResults))
            } else {
                context.additionalSources.append(contentsOf: boundedResults.additionalSources)
            }
            return context
        }
    }

    /// Shares one text budget across primary and secondary evidence, retaining
    /// citation metadata even when an individual excerpt has no room left.
    static func boundedContext(_ context: PageContext, limit: Int) -> PageContext {
        var boundedContext = context
        var remaining = max(0, limit)
        var slots = (context.textSnapshot.isEmpty ? 0 : 1)
            + context.additionalSources.filter { !$0.textSnapshot.isEmpty }.count
        func excerpt(_ text: String) -> (text: String, truncated: Bool) {
            guard !text.isEmpty else { return (text, false) }
            let clippedText = clipped(text, limit: remaining / max(1, slots))
            remaining -= clippedText.text.count
            slots -= 1
            return clippedText
        }
        let boundedText = excerpt(context.textSnapshot)
        boundedContext.textSnapshot = boundedText.text
        boundedContext.wasTruncated = context.wasTruncated || boundedText.truncated
        boundedContext.additionalSources = context.additionalSources.map { source in
            var copy = source
            let clipped = excerpt(source.textSnapshot)
            copy.textSnapshot = clipped.text
            copy.wasTruncated = source.wasTruncated || clipped.truncated
            return copy
        }
        return boundedContext
    }

    /// Returns a page address suitable for model context. Query strings and
    /// fragments are omitted because URLs commonly carry session identifiers,
    /// one-time tokens and other values that are not needed to identify a page.
    /// User-info credentials are removed as a second line of defence.
    static func safeURLString(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return Redaction.redacted(url.absoluteString)
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return Redaction.redacted(components.string ?? url.absoluteString)
    }

    /// The block handed to a provider as page context. Written plainly so a
    /// person can read exactly what is being sent.
    static func promptDescription(_ context: PageContext) -> String {
        var lines: [String] = []
        appendSource(
            label: "Current page",
            url: context.url,
            title: context.title,
            text: context.textSnapshot,
            wasTruncated: context.wasTruncated,
            to: &lines
        )
        for source in context.additionalSources {
            lines.append("")
            appendSource(
                label: source.label,
                url: source.url,
                title: source.title,
                text: source.textSnapshot,
                wasTruncated: source.wasTruncated,
                to: &lines
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func appendSource(
        label: String,
        url: String,
        title: String,
        text: String,
        wasTruncated: Bool,
        to lines: inout [String]
    ) {
        lines.append(label)
        lines.append("URL: \(url.isEmpty ? "(none)" : url)")
        lines.append("Title: \(title.isEmpty ? "(none)" : title)")
        if text.isEmpty {
            lines.append("Visible text: (none captured)")
        } else {
            lines.append("Visible text\(wasTruncated ? " (truncated)" : ""):")
            lines.append(text)
        }
    }
}
