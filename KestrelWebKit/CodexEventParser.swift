import Foundation

/// Reads the JSONL event stream printed by `codex exec --json`.
///
/// The command line tool is a full agent, so its stdout is a sequence of
/// machine events rather than an answer. Kestrel must take only the assistant's
/// final text and report a genuine failure (a usage limit, an authentication
/// problem, a sandbox refusal) as that failure, instead of showing the raw
/// event log or an empty reply.
///
/// This type is deliberately tolerant. It accepts the documented
/// `item.completed` / `agent_message` shape, tolerates camelCase variants, and
/// falls back to plain text when the executable printed no JSON at all (for
/// example an older build or a wrapper script).
enum CodexEventParser {
    /// Item kinds that carry assistant-visible prose.
    static let agentMessageTypes: Set<String> = ["agent_message", "agentMessage", "assistant_message", "assistantMessage"]

    /// Event kinds that mean the turn did not produce an answer.
    static let failureTypes: Set<String> = ["error", "turn.failed", "turn_failed", "stream_error"]

    /// Extracts the assistant text. Throws `AIProviderError.processFailed` with
    /// the provider's own message when the stream reports a failure, and
    /// `AIProviderError.invalidResponse` when the stream is readable JSON but
    /// contains no answer.
    static func assistantText(fromJSONLines data: Data) throws -> String {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw AIProviderError.invalidResponse("Codex wrote output that was not valid UTF-8.")
        }

        var collected: [String] = []
        var reportedFailure: String?
        var turnFailed = false
        var sawEvent = false

        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                continue
            }
            sawEvent = true
            if ["turn.failed", "turn_failed"].contains(object["type"] as? String ?? "") { turnFailed = true }

            // Started/updated items can contain a partial action proposal.
            // Only completed messages are eligible for browser execution.
            let eventType = object["type"] as? String ?? ""
            if eventType != "item.started", eventType != "item.updated", let text = agentText(in: object) {
                collected.append(text)
                continue
            }
            if let message = failureMessage(in: object) {
                reportedFailure = reportedFailure ?? message
            }
        }

        if !sawEvent {
            // No JSON events at all: treat the output as plain text so a wrapper
            // or an older build still works.
            let plain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else {
                throw AIProviderError.invalidResponse("Codex returned no text.")
            }
            return plain
        }

        let answer = collected
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if turnFailed || (reportedFailure != nil && answer.isEmpty) {
            throw AIProviderError.processFailed(
                executable: "codex",
                exitCode: 1,
                message: Redaction.redacted(bound(reportedFailure ?? "Codex's turn failed before it completed."))
            )
        }
        guard !answer.isEmpty else {
            throw AIProviderError.invalidResponse(
                "Codex finished without a written answer. Check that the account is signed in and has remaining usage."
            )
        }
        return answer
    }

    /// Pulls assistant prose out of one event. Only an item that is explicitly
    /// an agent message counts: command output and reasoning traces are not
    /// answers and must never be shown as one.
    static func agentText(in object: [String: Any]) -> String? {
        if let item = object["item"] as? [String: Any],
           let text = text(fromAgentItem: item) {
            return text
        }
        // `--output-last-message`-style and app-server shapes nest the item one
        // level deeper.
        if let payload = object["payload"] as? [String: Any],
           let text = text(fromAgentItem: payload) {
            return text
        }
        if let msg = object["msg"] as? [String: Any],
           let text = text(fromAgentItem: msg) {
            return text
        }
        return nil
    }

    private static func text(fromAgentItem item: [String: Any]) -> String? {
        guard let type = item["type"] as? String, agentMessageTypes.contains(type) else { return nil }
        if item["phase"] as? String == "commentary" { return nil }
        for key in ["text", "message", "content"] {
            if let value = item[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Reads a failure message from the shapes the tool has used: a top-level
    /// `message`, a nested `error.message`, or a bare `error` string.
    static func failureMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        if let type = object["type"] as? String, failureTypes.contains(type),
           let message = object["message"] as? String,
           !message.isEmpty {
            return message
        }
        return nil
    }

    private static func bound(_ text: String, limit: Int = 600) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[collapsed.startIndex..<end]) + "…"
    }
}
