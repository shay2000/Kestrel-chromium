import Foundation

enum AssistantIntent: String, Sendable {
    case answer
    case search
    case imageSearch
    case cursor
}

/// Chooses the lightest route for a new user turn. On supported Macs the
/// decision is made by Apple's fast on-device model; the keyword fallback is
/// deterministic and works on older systems.
enum AssistantIntentRouter {
    static func classify(_ prompt: String) async -> AssistantIntent {
        let localDecision = await AppleLocalModelProvider.classifyIntent(prompt)
        return resolve(prompt, modelDecision: localDecision)
    }

    /// The first stage is intentionally a router, not an action generator. It
    /// gives clear user instructions priority over a small model's occasional
    /// misclassification, while leaving ambiguous requests to Apple's local
    /// classifier. The selected provider receives a separate, focused prompt
    /// only after the user chooses browser assistance.
    ///
    /// A request that only live data can answer outranks the classifier too. A
    /// small model does not know today's price or the current weather, and
    /// letting it answer anyway is confidently wrong — which is why "price of
    /// the latest iPhone" must reach a search rather than a guess.
    static func resolve(_ prompt: String, modelDecision: AssistantIntent?) -> AssistantIntent {
        if imageSearchQuery(from: prompt) != nil { return .imageSearch }
        if isExplicitBrowserOperation(prompt) { return .cursor }
        if isExplicitWebSearch(prompt) { return .search }
        if needsLiveInformation(prompt), !isAuthoringRequest(prompt) { return .search }
        return modelDecision ?? .answer
    }

    /// The answer-first default, used when there is no local classifier to ask.
    ///
    /// A question is answered unless the user asked for something the model
    /// cannot know. The order matters: an explicit search request wins, then a
    /// request for information that changes all the time — and only when the
    /// user has not asked for something the model can produce itself.
    static func fallbackClassification(_ prompt: String) -> AssistantIntent {
        resolve(prompt, modelDecision: nil)
    }

    /// Clear requests to interact with a website must not be downgraded to an
    /// answer by the fast classifier (for example, “find and add an iPhone to
    /// my basket on Apple's website”). This stays deliberately narrower than
    /// generic words such as “find” or “add” so instructional questions remain
    /// ordinary answers.
    static func isExplicitBrowserOperation(_ prompt: String) -> Bool {
        let expressions = Expressions.browserOperations
        return matches(expressions, in: prompt)
    }

    /// Clear requests to go and find something out on the web.
    ///
    /// Deliberately an instruction rather than a topic word. An earlier version
    /// also searched whenever a prompt merely contained "latest", "current",
    /// "recent", "news", "price", "compare" or "sources", which turned ordinary
    /// questions — "compare these two functions", "what are your sources" —
    /// into results pages the user never asked for. Those words are handled by
    /// `needsLiveInformation` instead, and only when there is nothing else to
    /// go on.
    static func isExplicitWebSearch(_ prompt: String) -> Bool {
        let expressions = Expressions.webSearch
        return matches(expressions, in: prompt)
    }

    /// Wording that only means anything with live data behind it.
    ///
    /// Kept to phrases that are almost never incidental in a question about
    /// something the model already knows. It is consulted before the local
    /// classifier, and only for prompts that are not asking for something the
    /// model can produce by itself. Prices and availability are here because a
    /// model cannot know today's price: answering anyway is the confident wrong
    /// answer a shopper notices immediately.
    static func needsLiveInformation(_ prompt: String) -> Bool {
        let expressions = Expressions.liveInformation
        return matches(expressions, in: prompt)
    }

    /// Requests to produce, explain or work on something.
    ///
    /// These are always answered. Without this guard, "explain how the current
    /// flows through a diode" and "write a weather app" would be sent to a
    /// search engine because of one word.
    static func isAuthoringRequest(_ prompt: String) -> Bool {
        let expressions = Expressions.authoring
        return matches(expressions, in: prompt)
    }

    /// Wording that usually means the answer depends on the user's own country:
    /// a price, a shop, a delivery or something nearby.
    static func isLocalCommerceQuery(_ prompt: String) -> Bool {
        let expressions = Expressions.localCommerce
        return matches(expressions, in: prompt)
    }

    /// Whether a follow-up should keep searching because the conversation has
    /// already researched something.
    ///
    /// The router only sees the new prompt, so "and the Pro model?" reads as a
    /// plain answer request. Once a chat has actually searched, that question is
    /// the next step of the same research and must search too, or the assistant
    /// answers from a model that does not know today's details. It is not
    /// unconditional: a request for something the model can produce itself (an
    /// explanation, a summary, a draft) is left to the model, and a bare
    /// acknowledgement ("thanks", "ok") is not a new question — though a
    /// one-word question ("why?") still is.
    static func followUpContinuesSearch(_ prompt: String, conversationSearched: Bool) -> Bool {
        guard conversationSearched else { return false }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAuthoringRequest(trimmed) else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count == 1, !trimmed.contains("?") { return false }
        return true
    }

    /// The query a follow-up search should actually use.
    ///
    /// "And the Pro model?" is meaningless to a search engine: the subject it
    /// refers to is in the earlier turn. Carrying the previous question forward
    /// keeps the search on the same subject, so a follow-up does not search for
    /// a dangling pronoun and come back with nothing. A leading "search the web
    /// for" is dropped because it is an instruction, not a subject.
    static func followUpSearchQuery(previousUserPrompt: String?, currentPrompt: String) -> String {
        let current = currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previous = previousUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !previous.isEmpty else {
            return current
        }
        let subject = strippingSearchInstruction(previous)
        guard !subject.isEmpty else { return current }
        if subject.localizedCaseInsensitiveContains(current) { return String(subject.prefix(200)) }
        // Bounded so a long opening question cannot dominate the query.
        return "\(String(subject.prefix(200))) \(current)"
    }

    /// Removes a leading search instruction ("search the web for …", "look up …")
    /// so only the subject is carried into a follow-up query.
    static func strippingSearchInstruction(_ prompt: String) -> String {
        let expressions = Expressions.searchInstructions
        var subject = prompt
        for expression in expressions {
            if let match = expression.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
               let range = Range(match.range, in: subject) {
                subject = String(subject[range.upperBound...])
            }
        }
        return subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds the user's country to a search that is about a price, product or
    /// local availability.    ///
    /// A search engine asked "latest iPhone price" answers with whatever market
    /// it guesses, which is why the same query returned US prices. Qualifying
    /// the query with the user's own country keeps the answer local. Only
    /// commerce-flavoured queries are qualified; "what is quantum computing" is
    /// left alone.
    static func localisedSearchQuery(_ prompt: String, regionName: String?) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regionName,
              !regionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isLocalCommerceQuery(trimmed),
              !trimmed.localizedCaseInsensitiveContains(regionName) else {
            return trimmed
        }
        return "\(trimmed) \(regionName)"
    }

    private static func matches(_ expressions: [NSRegularExpression], in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Pulls the subject out of explicit image-search requests so Kestrel can
    /// open an image-search results page instead of searching the instruction
    /// verbatim. The original request remains in the assistant conversation.
    static func imageSearchQuery(from prompt: String) -> String? {
        let expressions = Expressions.imageSearch

        for expression in expressions {
            guard let match = expression.firstMatch(
                    in: prompt,
                    range: NSRange(prompt.startIndex..., in: prompt)
            ),
            let range = Range(match.range(at: 1), in: prompt) else {
                continue
            }
            let capturedSubject = String(prompt[range])
            let captured = Expressions.trailingPlease.stringByReplacingMatches(
                in: capturedSubject,
                range: NSRange(capturedSubject.startIndex..., in: capturedSubject),
                withTemplate: ""
            )
            let query = captured.trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;.!?"))
            )
            if !query.isEmpty { return query }
        }
        return nil
    }

    /// Fixed expressions compile lazily once, rather than on every routing
    /// check. No prompt text or model decision is retained between requests.
    private enum Expressions {
        static let browserOperations = AssistantIntentRouter.compile([
            #"(?i)^\s*(?:please\s+)?(?:find|locate|look\s+for)\b.{0,180}\bhere\b.{0,100}\b(?:open|visit|navigate|select)\b.{0,100}\b(?:page|product|item)\b"#,
            #"(?i)^\s*(?:please\s+)?(?:open|click|tap|press|select|choose|fill(?:\s+in)?|submit|sign\s+in|sign\s+out|log\s+in|log\s+out|download|bookmark|visit|navigate|scroll|add|put|place|remove)\b"#,
            #"(?i)\b(?:can|could|would|will)\s+you\s+(?:please\s+)?(?:open|click|tap|press|select|choose|fill(?:\s+in)?|submit|sign\s+in|sign\s+out|log\s+in|log\s+out|download|bookmark|visit|navigate|scroll|add|put|place|remove)\b"#,
            #"(?i)\b(?:i want you to|help me|please)\s+(?:find\s+and\s+)?(?:open|click|tap|press|select|choose|fill(?:\s+in)?|submit|sign\s+in|sign\s+out|log\s+in|log\s+out|download|bookmark|visit|navigate|scroll|add|put|place|remove)\b"#,
            #"(?i)\bfind\s+and\s+(?:add|put|place|remove|click|select|choose|open|visit)\b"#,
            #"(?i)\b(?:can|could|would|will)\s+you\s+(?:please\s+)?(?:find|search|look\s+for)\b.{0,120}\b(?:on|in)\s+(?:[a-z0-9.'’-]+\s+)?(?:website|site|page|store)\b"#,
            #"(?i)\b(?:find|locate|look\s+for)\b.{0,100}\b(?:on|in)\s+(?:[a-z0-9.'’-]+\s+)?(?:website|site|page|store)\b"#,
            #"(?i)\b(?:i want to|i(?:'|’)d like to|help me)\s+(?:please\s+)?(?:find\s+and\s+)?(?:add|put|place|remove)\b.{0,100}\b(?:to|into|in|from)\s+(?:my\s+)?(?:shopping\s+)?(?:basket|bag|cart)\b"#,
            #"(?i)^\s*(?:i need|i want|i(?:'|’)d like)\b.{0,120}\b(?:in|into)\s+(?:my\s+)?(?:shopping\s+)?(?:basket|bag|cart)\b"#
        ])

        static let webSearch = AssistantIntentRouter.compile([
            #"(?i)\b(?:search|look)\s+(?:the\s+)?(?:web|internet|online)\b"#,
            #"(?i)\b(?:look\s+up|find\s+online|research|search\s+for|google)\b"#,
            #"(?i)\b(?:find|show|get|look\s+for|check)\s+(?:me\s+)?(?:the\s+)?(?:latest|current|recent|newest|upcoming)\b"#
        ])

        static let liveInformation = AssistantIntentRouter.compile([
            #"(?i)\b(?:weather|forecast|near\s+me|what\s+happened|breaking\s+news|stock\s+price|share\s+price|exchange\s+rate|opening\s+hours|live\s+scores?|traffic\s+report)\b"#,
            #"(?i)\b(?:price|prices|pricing|cost|costs)\b"#,
            #"(?i)\b(?:in\s+stock|out\s+of\s+stock|release\s+date|pre[- ]?order)\b"#,
            // "how much is a new iPad" is a price question; "how much is 2+2"
            // is arithmetic, so an article is required.
            #"(?i)\bhow\s+much\s+(?:is|are|does|do|would)\s+(?:a|an|the|this|that|it)\b"#
        ])

        static let authoring = AssistantIntentRouter.compile([
            #"(?i)\b(?:explain|describe|summari[sz]e|define|write|draft|translate|calculate|refactor|debug|rewrite|outline|brainstorm|design|implement)\b"#,
            #"(?i)\bhow\s+(?:do|does|can|should|would|might)\s+(?:i|you|we|one)\b"#,
            #"(?i)\bwhat\s+(?:is|are)\s+the\s+difference\b"#,
            #"(?i)\bgive\s+me\s+an?\s+example\b"#,
            #"(?i)\bhelp\s+me\s+(?:write|understand|learn|plan|think|decide)\b"#,
            #"(?i)\breview\s+my\b"#,
            // Technical "cost" is not a shop price: keep algorithmic and
            // performance questions with the model rather than a search engine.
            #"(?i)\b(?:time|space|memory|runtime|space[- ]?time)\s+cost\b"#,
            #"(?i)\b(?:complexity|algorithm|big[- ]?o|asymptotic|throughput|latency\s+budget)\b"#
        ])

        static let localCommerce = AssistantIntentRouter.compile([
            #"(?i)\b(?:price|prices|pricing|cost|costs|how\s+much|cheap|cheaper|cheapest|buy|purchase|deal|deals|discount|offer|offers|in\s+stock|out\s+of\s+stock|availability|available|delivery|shipping|near\s+me|shop|store|retailer|release\s+date|pre[- ]?order)\b"#,
            #"(?i)\b(?:£|\$|€)\s?\d"#
        ])

        static let searchInstructions = AssistantIntentRouter.compile([
            #"(?i)^\s*(?:please\s+)?(?:can\s+you\s+)?(?:search|look)\s+(?:the\s+)?(?:web|internet|online)\s+(?:for|about)\s+"#,
            #"(?i)^\s*(?:please\s+)?(?:can\s+you\s+)?(?:search|google|look\s+up|find)\s+(?:for\s+|about\s+)?"#
        ])

        static let imageSearch = AssistantIntentRouter.compile([
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:search|look(?:\s+up)?|find|show|get)\s+(?:(?:the\s+)?(?:web|internet)\s+)?(?:(?:for|up)\s+)?(?:(?:me|us)\s+)?(?:(?:some|a\s+few)\s+)?(?:images?|pictures?|photos?|photographs?)\s+(?:(?:of|for|showing|depicting|featuring)\s+)?(.+?)(?:\s+please)?\s*[?.!]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:find|show|get)\s+(?:me\s+)?(.+?)\s+(?:images?|pictures?|photos?|photographs?)(?:\s+please)?\s*[?.!]*\s*$"#
        ])

        static let trailingPlease = try! NSRegularExpression(pattern: #"(?i)[,;:]?\s+please$"#)
    }

}
