import Foundation

/// The tab and address a browser action was derived from. Approval is rejected
/// if the user changes tabs or navigates before accepting the proposal.
struct BrowserActionContext: Equatable, Sendable {
    let tabID: UUID
    let pageURL: String
}

/// The complete set of things the model may ask the browser to do. This is an
/// allow-list, not a scripting surface: there is no way to express arbitrary
/// Swift, JavaScript, shell commands or CSS selectors here, and adding a case
/// is a deliberate, reviewable change.
enum BrowserActionKind: String, CaseIterable, Codable, Sendable {
    case openURL = "open_url"
    case goBack = "go_back"
    case goForward = "go_forward"
    case reload = "reload"
    case stop = "stop"
    case readPageText = "read_page_text"
    case readSelectedText = "read_selected_text"
    case findText = "find_text"
    case clickText = "click_text"
    case selectOption = "select_option"
    case fillProfile = "fill_profile"
    case searchPage = "search_page"

    /// A short label for the conversation row.
    var displayName: String {
        switch self {
        case .openURL: return "Open URL"
        case .goBack: return "Go back"
        case .goForward: return "Go forward"
        case .reload: return "Reload page"
        case .stop: return "Stop loading"
        case .readPageText: return "Read page text"
        case .readSelectedText: return "Read selected text"
        case .findText: return "Find on page"
        case .clickText: return "Click control"
        case .selectOption: return "Select option"
        case .fillProfile: return "Fill saved details"
        case .searchPage: return "Search this site"
        }
    }
}

enum BrowserAction: Equatable, Sendable {
    case openURL(String)
    case goBack
    case goForward
    case reload
    case stop
    case readPageText(maxCharacters: Int)
    case readSelectedText(maxCharacters: Int)
    case findText(String)
    case clickText(String)
    case clickReferencedControl(reference: String, label: String)
    case selectOption(String)
    case fillProfile(UUID?)
    case searchPage(String)

    var kind: BrowserActionKind {
        switch self {
        case .openURL: return .openURL
        case .goBack: return .goBack
        case .goForward: return .goForward
        case .reload: return .reload
        case .stop: return .stop
        case .readPageText: return .readPageText
        case .readSelectedText: return .readSelectedText
        case .findText: return .findText
        case .clickText, .clickReferencedControl: return .clickText
        case .selectOption: return .selectOption
        case .fillProfile: return .fillProfile
        case .searchPage: return .searchPage
        }
    }

    /// Reading the current page is automatic but bounded and always shown.
    /// Everything that navigates, finds or clicks changes what the page is
    /// doing and needs an explicit approval in the sidebar before it runs.
    var isReadOnly: Bool {
        switch self {
        case .readPageText, .readSelectedText:
            return true
        case .openURL, .goBack, .goForward, .reload, .stop, .findText, .clickText, .clickReferencedControl, .selectOption, .searchPage, .fillProfile:
            return false
        }
    }

    var requiresApproval: Bool {
        !isReadOnly
    }

    /// Actions that can be skipped past the per-action prompt when the user
    /// explicitly enables safe-browsing auto-approval. Generic clicks stay
    /// excluded because the same control can submit, purchase, post,
    /// authenticate, download or change account data.
    var isEligibleForSafeBrowsingAutoApproval: Bool {
        switch self {
        case .openURL, .goBack, .goForward, .reload, .stop, .findText, .searchPage:
            return true
        case .readPageText, .readSelectedText, .clickText, .clickReferencedControl, .selectOption, .fillProfile:
            return false
        }
    }

    /// A plain sentence shown in the proposal row and in the transcript.
    var summary: String {
        switch self {
        case .openURL(let value):
            return "Open \(value)"
        case .goBack:
            return "Go back one page"
        case .goForward:
            return "Go forward one page"
        case .reload:
            return "Reload the current page"
        case .stop:
            return "Stop loading the current page"
        case .readPageText(let maxCharacters):
            return "Read up to \(PageContextBuilder.clampLimit(maxCharacters)) characters of the page"
        case .readSelectedText(let maxCharacters):
            return "Read up to \(PageContextBuilder.clampLimit(maxCharacters)) characters of the selected text"
        case .findText(let query):
            return "Find “\(query)” on the page"
        case .clickText(let query), .clickReferencedControl(_, let query):
            return "Click the “\(query)” control on the page"
        case .selectOption(let query):
            return "Select the “\(query)” option on the page"
        case .fillProfile:
            return "Preview and fill saved contact/address details"
        case .searchPage(let query):
            return "Search this site for “\(query)”"
        }
    }
}

/// Auto mode never treats an arbitrary click as safe. Product choices are
/// scoped to buying pages; ambiguous controls still require review.
enum AgentAutoPolicy {
    enum Decision: Equatable { case allow, review, stop }
    static func isBasketAddition(_ label: String) -> Bool {
        let value = PageContextBuilder.normalise(label).lowercased()
        return ["add to cart", "add to basket", "add to bag"].contains(value)
            || value.range(of: #"^add \[[^\]\r\n]{1,160}\] to (basket|bag|cart)$"#, options: .regularExpression) != nil
    }
    static func decision(_ action: BrowserAction, context: BrowserActionContext?) -> Decision {
        if case .fillProfile = action { return .review }
        let value: String
        switch action {
        case .clickText(let text), .clickReferencedControl(_, let text), .selectOption(let text), .openURL(let text): value = (text.removingPercentEncoding ?? text).lowercased()
        default: value = ""
        }
        let blocked = #"\b(check\s*out|checkout|place\s+order|pay\s+now|complete\s+purchase|confirm\s+purchase|buy\s+now|subscribe|accept\s+terms|agree\s+to)\b"#
        if value.range(of: blocked, options: .regularExpression) != nil { return .stop }
        if case .openURL = action, value.range(of: #"/(payment|purchase|order/confirm)(/|\?|$)"#, options: .regularExpression) != nil { return .stop }
        if value.range(of: #"\b(delete|erase|destroy|reset|format|send|post|publish|transfer|sign\s+in|log\s+in)\b"#, options: .regularExpression) != nil { return .review }
        if action.isReadOnly || action.isEligibleForSafeBrowsingAutoApproval { return .allow }
        if ["view bag", "view basket", "view cart", "review bag", "review basket", "shopping bag", "go to basket"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           context.flatMap({ URL(string: $0.pageURL) })?.scheme == "https" {
            switch action {
            case .clickText, .clickReferencedControl: return .allow
            default: break
            }
        }
        if case .clickReferencedControl(_, let label) = action,
           (label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "view product" || isBasketAddition(label)),
           context.flatMap({ URL(string: $0.pageURL) })?.scheme == "https" { return .allow }
        guard let url = context.flatMap({ URL(string: $0.pageURL) }),
              url.scheme == "https",
              url.path.range(of: #"(?i)/(?:shop/buy[^/]*|products?)(?:/|$)"#, options: .regularExpression) != nil else { return .review }
        switch action {
        case .clickText, .clickReferencedControl:
            // Retail product links often expose colour/storage choices rather than radios.
            // Keep these exact and bounded; runtime destination/checkout checks still apply.
            if value.range(of: #"^select colou?r (black|white|blue|green|purple|pink|red|yellow|orange|silver|gold|grey|gray|cream|lavender|sage|mist blue|burgundy)$"#, options: .regularExpression) != nil
                || value.range(of: #"^(?:select (?:hard_drive_capacity|storage) )?(?:64|128|256|512)\s?gb$|^(?:select (?:hard_drive_capacity|storage) )?(?:1|2|4)\s?tb$"#, options: .regularExpression) != nil { return .allow }
            return ["add to bag", "add to basket", "add to cart", "view bag", "view basket", "view cart", "review bag", "review basket", "bag", "basket", "cart", "view product", "continue without cover", "continue without insurance", "no thanks", "no thank you", "continue to basket", "continue", "next", "skip", "not now", "close", "dismiss"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines)) ? .allow : .review
        case .selectOption:
            // Declining an optional extra is not buying that extra. Keep exact
            // negative choices distinct from labels which select paid cover.
            if ["no applecare coverage", "no applecare+ coverage", "no extra cover", "no coverage"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return .allow }
            // No financing, account, consent or paid protection choices.
            if value.range(of: #"(?i)\b(credit|finance|monthly|insurance|applecare|cover|account|consent|terms|payment)\b"#, options: .regularExpression) != nil { return .review }
            return value.range(of: #"^(?:black|white|blue|green|purple|pink|red|yellow|orange|silver|gold|grey|gray|cream|lavender|sage|mist blue|burgundy|(?:64|128|256|512)\s?gb|(?:1|2|4)\s?tb|no trade[- ]?in)$"#, options: .regularExpression) != nil ? .allow : .review
        default: return .review
        }
    }
}

/// Decodes model-proposed actions from strict JSON. Anything that does not
/// match the allow-list exactly is rejected with a readable reason rather than
/// guessed at.
enum BrowserActionDecoder {
    struct DecodingError: Error, Equatable, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static let maximumQueryLength = 200

    static func decode(jsonString: String) throws -> BrowserAction {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw DecodingError(reason: "The action block was empty.")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw DecodingError(reason: "The action block was not valid JSON.")
        }
        return try decode(jsonObject: object)
    }

    static func decode(jsonObject: Any) throws -> BrowserAction {
        guard let object = jsonObject as? [String: Any] else {
            throw DecodingError(reason: "An action must be a JSON object.")
        }

        let rawName = (object["action"] as? String)
            ?? (object["name"] as? String)
            ?? (object["type"] as? String)
        guard let rawName else {
            throw DecodingError(reason: "The action object needs an \"action\" field.")
        }
        guard let kind = BrowserActionKind(rawValue: rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw DecodingError(reason: "“\(rawName)” is not an allowed browser action.")
        }

        switch kind {
        case .openURL:
            guard let value = stringValue(in: object, keys: ["url", "address", "value"]) else {
                throw DecodingError(reason: "open_url needs a \"url\" string.")
            }
            guard URLNormalisation.isOpenableAddress(value) else {
                throw DecodingError(reason: "Only http and https addresses can be opened.")
            }
            return .openURL(value)
        case .goBack:
            return .goBack
        case .goForward:
            return .goForward
        case .reload:
            return .reload
        case .stop:
            return .stop
        case .readPageText:
            return .readPageText(maxCharacters: characterLimit(in: object))
        case .readSelectedText:
            return .readSelectedText(maxCharacters: characterLimit(in: object))
        case .findText:
            return .findText(try boundedQuery(in: object, keys: ["query", "text", "value"], actionName: "find_text", queryNoun: "find"))
        case .clickText:
            let label = try boundedQuery(in: object, keys: ["query", "text"], actionName: "click_text", queryNoun: "click")
            if object["control"] != nil {
                guard let reference = object["control"] as? String,
                      reference.range(of: #"^c[a-f0-9]{1,32}_[0-9]{1,3}$"#, options: .regularExpression) != nil else {
                    throw DecodingError(reason: "The control reference was not a captured page control.")
                }
                return .clickReferencedControl(reference: reference, label: label)
            }
            return .clickText(label)
        case .selectOption:
            return .selectOption(try boundedQuery(in: object, keys: ["query", "text"], actionName: "select_option", queryNoun: "select"))
        case .fillProfile:
            guard Set(object.keys).isSubset(of: ["action", "rationale"]) else {
                throw DecodingError(reason: "fill_profile accepts no values, selectors or identifiers.")
            }
            return .fillProfile(nil)
        case .searchPage:
            return .searchPage(try boundedQuery(in: object, keys: ["query", "text"], actionName: "search_page", queryNoun: "search"))
        }
    }

    /// Pulls one action object from a provider reply. JSON is the primary
    /// protocol. A few text-only models instead serialise the same arguments
    /// as `<tool_call>…<arg_key>…</arg_key><arg_value>…</arg_value></tool_call>`;
    /// that form is converted to JSON only after strict shape and field checks.
    static func candidateActionJSON(in text: String) -> String? {
        actionPayload(in: text)?.json
    }

    /// Removes the machine-readable operator payload from assistant prose
    /// before it is shown in chat. The provider history keeps its original
    /// protocol response; the verified action is rendered separately.
    static func visibleAssistantText(from reply: String) -> String? {
        let range = actionPayload(in: reply)?.range ?? firstToolCallEnvelope(in: reply)
        guard let range else {
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let before = reply[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = reply[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return visible.isEmpty ? nil : visible
    }

    private struct ActionPayload {
        let json: String
        let range: Range<String.Index>
    }

    private static func actionPayload(in text: String) -> ActionPayload? {
        if text.contains("<tool_call>") {
            return taggedActionPayload(in: text)
        }
        guard let start = text.firstIndex(of: "{") else {
            return nil
        }
        guard let end = text.lastIndex(of: "}") , end > start else {
            return nil
        }
        let candidate = String(text[start...end])
        guard candidate.contains("\"action\"") || candidate.contains("\"name\"") || candidate.contains("\"type\"") else {
            return nil
        }
        return ActionPayload(json: candidate, range: start..<text.index(after: end))
    }

    /// Accepts exactly one flat tagged call. Unknown keys, duplicate fields,
    /// extra markup, multiple calls and nested tags are rejected.
    private static func taggedActionPayload(in text: String) -> ActionPayload? {
        let opening = "<tool_call>"
        let closing = "</tool_call>"
        guard text.components(separatedBy: opening).count == 2,
              text.components(separatedBy: closing).count == 2,
              let openRange = text.range(of: opening),
              let closeRange = text.range(of: closing, range: openRange.upperBound..<text.endIndex)
        else { return nil }

        let body = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let argumentStart = body.range(of: "<arg_key>")
        let actionName = String(argumentStart.map { body[..<$0.lowerBound] } ?? Substring(body))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIdentifier(actionName) else { return nil }

        let allowedKeys: Set<String> = [
            "action", "name", "type", "url", "address", "value", "maxCharacters",
            "max_characters", "limit", "query", "text", "rationale"
        ]
        var object: [String: Any] = ["action": actionName]
        if let argumentStart {
            let arguments = String(body[argumentStart.lowerBound...])
            let expression = try! NSRegularExpression(
                pattern: #"<arg_key>\s*([A-Za-z_][A-Za-z0-9_]*)\s*</arg_key>\s*<arg_value>([^<]*)</arg_value>"#,
                options: [.dotMatchesLineSeparators]
            )
            let nsArguments = arguments as NSString
            let matches = expression.matches(in: arguments, range: NSRange(location: 0, length: nsArguments.length))
            var cursor = 0
            var seen: Set<String> = []
            for match in matches {
                guard match.range.location >= cursor,
                      nsArguments.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let keyRange = Range(match.range(at: 1), in: arguments),
                      let valueRange = Range(match.range(at: 2), in: arguments)
                else { return nil }

                let key = String(arguments[keyRange])
                let value = String(arguments[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard allowedKeys.contains(key), seen.insert(key).inserted else { return nil }
                if ["action", "name", "type"].contains(key) {
                    guard value.caseInsensitiveCompare(actionName) == .orderedSame else { return nil }
                } else if ["maxCharacters", "max_characters", "limit"].contains(key) {
                    guard let number = Int(value) else { return nil }
                    object[key] = number
                } else {
                    object[key] = value
                }
                cursor = NSMaxRange(match.range)
            }
            guard nsArguments.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
        }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return ActionPayload(json: json, range: openRange.lowerBound..<closeRange.upperBound)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, isASCIILetter(first) || first == 95 else { return false }
        return bytes.dropFirst().allSatisfy { isASCIILetter($0) || (48...57).contains($0) || $0 == 95 }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// Used only to keep malformed protocol markup out of the transcript. A
    /// malformed call is never executable; its envelope is hidden and the
    /// operator adds a readable notice that it was ignored.
    private static func firstToolCallEnvelope(in text: String) -> Range<String.Index>? {
        guard let opening = text.range(of: "<tool_call>") else { return nil }
        if text.components(separatedBy: "<tool_call>").count > 2 {
            return opening.lowerBound..<text.endIndex
        }
        if let closing = text.range(of: "</tool_call>", range: opening.upperBound..<text.endIndex) {
            if text.components(separatedBy: "</tool_call>").count > 2 {
                return opening.lowerBound..<text.endIndex
            }
            return opening.lowerBound..<closing.upperBound
        }
        return opening.lowerBound..<text.endIndex
    }

    /// Reads a required, bounded, non-empty query from an action object. Used by
    /// the find and click actions, both of which take a short piece of text.
    private static func boundedQuery(in object: [String: Any], keys: [String], actionName: String, queryNoun: String) throws -> String {
        guard let query = stringValue(in: object, keys: keys) else {
            throw DecodingError(reason: "\(actionName) needs a \"query\" string.")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError(reason: "\(actionName) needs a non-empty query.")
        }
        guard trimmed.count <= maximumQueryLength else {
            throw DecodingError(reason: "The \(queryNoun) query is longer than \(maximumQueryLength) characters.")
        }
        return trimmed
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func characterLimit(in object: [String: Any]) -> Int {
        let raw = (object["maxCharacters"] as? Int)
            ?? (object["max_characters"] as? Int)
            ?? (object["limit"] as? Int)
            ?? PageContextBuilder.defaultCharacterLimit
        return PageContextBuilder.clampLimit(raw)
    }
}

/// The result of running, or declining, an action. Shown as an auditable row in
/// the conversation.
struct ActionResult: Equatable, Sendable {
    enum Status: String, Sendable {
        case succeeded
        case failed
        case declined
        case skipped
    }

    let kind: BrowserActionKind
    let status: Status
    let summary: String
    let detail: String?

    static func declined(_ action: BrowserAction) -> ActionResult {
        ActionResult(kind: action.kind, status: .declined, summary: "Declined: \(action.summary)", detail: nil)
    }

    static func skipped(_ action: BrowserAction, reason: String) -> ActionResult {
        ActionResult(kind: action.kind, status: .skipped, summary: action.summary, detail: reason)
    }
}

/// Ephemeral local approval data. Never include in model requests or transcripts.
struct ProfileFillPreview: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        let key: String
        let label: String
        let value: String
    }
    let id: UUID
    let context: BrowserActionContext
    let destination: String
    let fields: [Field]
}
