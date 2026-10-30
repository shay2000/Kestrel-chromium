import Foundation

/// Best-effort removal of credential-shaped text before anything is shown,
/// logged or sent back to a model. It is defence in depth, not a guarantee:
/// Kestrel never reads cookies, password fields or hidden form values, and
/// secrets are only ever held in memory or in the macOS Keychain.
enum Redaction {
    static let placeholder = "[redacted]"

    private struct Rule {
        let pattern: String
        let replacement: String
    }

    /// Ordered from the most specific token shapes to the more general
    /// key/value patterns so a long token is removed as one piece.
    private static let rules: [Rule] = [
        // Bearer tokens and Authorization headers.
        Rule(pattern: "(?i)(bearer|token)\\s+[A-Za-z0-9._~+/=-]{8,}", replacement: "$1 \(placeholder)"),
        // Common provider key prefixes (OpenAI/OpenRouter/Mistral-style).
        Rule(pattern: "\\b(sk|pk|rk)-[A-Za-z0-9_-]{8,}", replacement: placeholder),
        // JSON-ish or INI-ish "key": "value" pairs for secret-sounding names.
        Rule(
            pattern: "(?i)((?:api[_-]?key|apikey|secret|password|passwd|access[_-]?token|refresh[_-]?token|authorization)\"?\\s*[:=]\\s*\"?)([^\"\\s,}]{4,})",
            replacement: "$1\(placeholder)"
        ),
        // Long opaque tokens that are not obviously anything else.
        Rule(pattern: "\\b[A-Za-z0-9_-]{32,}\\b", replacement: placeholder)
    ]

    private static let compiledRules: [(NSRegularExpression, String)] = rules.compactMap { rule in
        guard let expression = try? NSRegularExpression(pattern: rule.pattern) else {
            return nil
        }
        return (expression, rule.replacement)
    }

    static func redacted(_ text: String) -> String {
        guard !text.isEmpty else {
            return text
        }

        var result = text
        for (expression, replacement) in compiledRules {
            // Recompute the range each pass: an earlier rule can change the
            // string's length, and a stale NSRange can overrun the new value.
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }

    /// Environment variables are referenced by name only. This helper exists so
    /// callers can report which names were consulted without ever printing a
    /// value.
    static func describeEnvironmentNames(_ names: [String]) -> String {
        names.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A short, safe description of a secret's presence. Never the value.
    static func describePresence(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "not configured"
        }
        return "configured (\(value.count) characters, value hidden)"
    }
}
