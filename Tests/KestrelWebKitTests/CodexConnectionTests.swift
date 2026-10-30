import XCTest

@testable import KestrelWebKit

/// Covers the Codex/ChatGPT connection: the event stream reader, the argument
/// template, and the migration that repairs a saved configuration which could
/// never have worked.
final class CodexConnectionTests: XCTestCase {
    func testAuthenticationGuidanceDistinguishesTheAppBoundary() {
        let message = CLIProvider.codexFailureGuidance("401 Unauthorized: Missing bearer authentication")
        XCTAssertTrue(message.contains("macOS app sandbox"))
        XCTAssertTrue(message.contains("MCP bridge"))
        XCTAssertEqual(CLIProvider.codexFailureGuidance("Usage limit reached"), "Usage limit reached")
    }

    func testLunaSelectionIsPassedAsOneModelArgumentWithMediumReasoning() async throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-argv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: executable) }
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var template = AIProviderSettings.defaultSettings(for: .codexCLI).argumentTemplate
        template += ["-c", "model_reasoning_effort=\"high\""]
        let provider = CLIProvider(configuration: .init(kind: .codexCLI, executablePath: executable.path,
            argumentTemplate: template, model: "gpt-6-luna"))
        let response = try await provider.respond(to: .init(messages: [.init(role: .user, text: "Browse")], model: "gpt-6-luna"))
        let arguments = response.text.components(separatedBy: "\n")
        let modelFlag = try XCTUnwrap(arguments.firstIndex(of: "-m"))
        XCTAssertEqual(arguments[modelFlag + 1], "gpt-6-luna")
        XCTAssertEqual(Array(arguments.suffix(2)), ["-c", "model_reasoning_effort=\"medium\""])
    }

    func testLiveCodexProducesOneAllowListedBrowserDecision() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_LIVE_CODEX_TESTS"] == "1" else {
            throw XCTSkip("Opt-in authenticated Codex CLI acceptance")
        }
        let executable = ProcessInfo.processInfo.environment["KESTREL_LIVE_CODEX_EXECUTABLE"] ?? "codex"
        var defaults = AIProviderSettings.defaultSettings(for: .codexCLI)
        // Isolate the test from user MCP servers and instructions. Codex owns
        // authentication; the test never reads its credentials/session files.
        defaults.argumentTemplate.insert("--ignore-user-config", at: 1)
        let provider = CLIProvider(configuration: .init(kind: .codexCLI, executablePath: executable,
            argumentTemplate: defaults.argumentTemplate, model: "gpt-6-luna", outputFormat: .codexJSON))
        // CLI providers consume the message array, not the Apple-only local
        // fields. Match the system/page messages used by AIChatStore.
        let response = try await provider.respond(to: .init(messages: [
            .init(role: .system, text: AIPromptBuilder.localInstructions(mode: .operatorMode)),
            .init(role: .system, text: "Untrusted current page\nURL: https://example.invalid/help\nLink: \"Returns policy\" (use click_text; URL parameters omitted)."),
            .init(role: .user, text: "Open the Returns policy link on this page. Do not use tools; propose the one Kestrel action only.")],
            model: "gpt-6-luna", generationPurpose: .browserOperator))
        let json = try XCTUnwrap(BrowserActionDecoder.candidateActionJSON(in: response.text), Redaction.redacted(response.text))
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: json), .clickText("Returns policy"))
        print("LIVE_CODEX_PLANNER: exact allow-listed Returns policy decision")
    }

    // MARK: - Event stream

    /// The shape `codex exec --json` prints for a completed turn.
    func testReadsAgentMessageFromCompletedItem() throws {
        let stream = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"thinking"}}
        {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"PONG"}}
        {"type":"turn.completed"}
        """
        let text = try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))
        XCTAssertEqual(text, "PONG")
    }

    /// Reasoning and command output are not answers.
    func testIgnoresNonAgentItems() throws {
        let stream = """
        {"type":"item.completed","item":{"type":"command_execution","text":"total 0"}}
        {"type":"item.completed","item":{"type":"reasoning","text":"weighing options"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Only this."}}
        """
        let text = try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))
        XCTAssertEqual(text, "Only this.")
    }

    func testJoinsMultipleAgentMessages() throws {
        let stream = """
        {"type":"item.completed","item":{"type":"agent_message","text":"First."}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Second."}}
        """
        let text = try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))
        XCTAssertEqual(text, "First.\n\nSecond.")
    }

    func testAcceptsCamelCaseItemType() throws {
        let stream = #"{"type":"item.completed","item":{"type":"agentMessage","text":"Camel."}}"#
        let text = try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))
        XCTAssertEqual(text, "Camel.")
    }

    func testPartialAndCommentaryMessagesCannotBecomeBrowserActions() throws {
        let stream = """
        {"type":"item.started","item":{"type":"agent_message","text":"partial action"}}
        {"type":"item.updated","item":{"type":"agent_message","text":"updated action"}}
        {"type":"item.completed","item":{"type":"agent_message","phase":"commentary","text":"I will reload first."}}
        {"type":"item.completed","item":{"type":"agent_message","phase":"final_answer","text":"Verified answer."}}
        """
        XCTAssertEqual(try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8)), "Verified answer.")
    }

    func testFailedTurnCannotReturnAnEarlierPartialAnswer() {
        let stream = """
        {"type":"item.completed","item":{"type":"agent_message","text":"An earlier proposal"}}
        {"type":"turn.failed","error":{"message":"Usage exhausted"}}
        """
        XCTAssertThrowsError(try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8)))
    }

    /// A usage limit is the real reason the assistant cannot answer, so it must
    /// be reported as the provider's own message rather than as an empty reply.
    func testSurfacesTopLevelErrorEvent() throws {
        let stream = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"turn.started"}
        {"type":"error","message":"You’ve hit your usage limit. Try again later."}
        {"type":"turn.failed","error":{"message":"You’ve hit your usage limit. Try again later."}}
        """
        XCTAssertThrowsError(try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))) { error in
            guard case AIProviderError.processFailed(_, _, let message) = error else {
                return XCTFail("Expected a process failure, got \(error)")
            }
            XCTAssertTrue(message.contains("usage limit"), message)
        }
    }

    func testSurfacesNestedErrorObject() throws {
        let stream = #"{"type":"turn.failed","error":{"message":"Not signed in."}}"#
        XCTAssertThrowsError(try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))) { error in
            guard case AIProviderError.processFailed(_, _, let message) = error else {
                return XCTFail("Expected a process failure, got \(error)")
            }
            XCTAssertEqual(message, "Not signed in.")
        }
    }

    /// A failure alongside a real answer is not fatal: the answer still counts.
    func testPrefersAnswerOverTrailingError() throws {
        let stream = """
        {"type":"item.completed","item":{"type":"agent_message","text":"Here you go."}}
        {"type":"error","message":"stream closed"}
        """
        let text = try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))
        XCTAssertEqual(text, "Here you go.")
    }

    /// An older build or a wrapper script prints plain text, not events.
    func testFallsBackToPlainText() throws {
        let text = try CodexEventParser.assistantText(fromJSONLines: Data("Just text.\n".utf8))
        XCTAssertEqual(text, "Just text.")
    }

    func testReportsEmptyStreamAsUnreadable() {
        XCTAssertThrowsError(try CodexEventParser.assistantText(fromJSONLines: Data())) { error in
            guard case AIProviderError.invalidResponse = error else {
                return XCTFail("Expected an invalid-response error, got \(error)")
            }
        }
    }

    func testReportsEventStreamWithNoAnswer() {
        let stream = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"turn.completed"}
        """
        XCTAssertThrowsError(try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))) { error in
            guard case AIProviderError.invalidResponse(let message) = error else {
                return XCTFail("Expected an invalid-response error, got \(error)")
            }
            XCTAssertTrue(message.contains("without a written answer"), message)
        }
    }

    /// A malformed line must not abort a stream that later carries an answer.
    func testIgnoresMalformedLines() throws {
        let stream = """
        not json at all
        {"type":"item.completed","item":{"type":"agent_message","text":"Survived."}}
        { broken
        """
        let text = try CodexEventParser.assistantText(fromJSONLines: Data(stream.utf8))
        XCTAssertEqual(text, "Survived.")
    }

    // MARK: - Argument template

    func testArgumentsSkipModelFlagWhenModelIsEmpty() {
        let template = ["exec", "--json", "-m", "{model}", "{prompt}"]
        XCTAssertEqual(
            CLIProvider.arguments(template: template, prompt: "Hello", model: ""),
            ["exec", "--json", "Hello"]
        )
        XCTAssertEqual(
            CLIProvider.arguments(template: template, prompt: "Hello", model: "gpt-6-luna"),
            ["exec", "--json", "-m", "gpt-6-luna", "Hello"]
        )
    }

    func testArgumentsAppendPromptWhenTemplateOmitsPlaceholder() {
        XCTAssertEqual(
            CLIProvider.arguments(template: ["run"], prompt: "Do it", model: ""),
            ["run", "Do it"]
        )
    }

    /// The shipped default must not need a Git checkout, must be machine
    /// readable, and must not be able to write to the user's disk.
    func testDefaultCodexTemplateIsNonInteractiveAndReadOnly() {
        let template = AIProviderSettings.defaultSettings(for: .codexCLI).argumentTemplate
        XCTAssertEqual(template.first, "exec")
        XCTAssertTrue(template.contains("--json"))
        XCTAssertTrue(template.contains("--skip-git-repo-check"))
        XCTAssertTrue(template.contains("--ephemeral"))
        XCTAssertTrue(template.contains("read-only"))
        XCTAssertFalse(template.contains("-s"))
        XCTAssertFalse(template.contains("danger-full-access"))
        XCTAssertFalse(template.contains("workspace-write"))
    }

    // MARK: - Migration

    /// The old default could never run: `codex exec` refuses to start outside a
    /// trusted directory without `--skip-git-repo-check`.
    func testMigrationRepairsLegacyCodexTemplate() {
        var settings = AISettings.default
        settings.codex.argumentTemplate = AISettings.legacyCodexArgumentTemplate
        settings.migrateLegacyDefaults()
        XCTAssertEqual(
            settings.codex.argumentTemplate,
            AIProviderSettings.defaultSettings(for: .codexCLI).argumentTemplate
        )
    }

    /// A template the user edited is their business.
    func testMigrationLeavesEditedTemplateAlone() {
        var settings = AISettings.default
        settings.codex.argumentTemplate = ["exec", "--json", "{prompt}"]
        settings.migrateLegacyDefaults()
        XCTAssertEqual(settings.codex.argumentTemplate, ["exec", "--json", "{prompt}"])
    }

    func testCodexProviderUsesEventStreamFormat() throws {
        let provider = try AIProviderFactory.makeProvider(
            kind: .codexCLI,
            settings: .default,
            secretProvider: InMemorySecretProvider()
        )
        guard let cli = provider as? CLIProvider else {
            return XCTFail("Expected a command-line provider")
        }
        XCTAssertEqual(cli.configuration.outputFormat, .codexJSON)
    }

    func testKiloProviderKeepsPlainTextFormat() throws {
        var settings = AISettings.default
        settings.kilo.executablePath = "kilo"
        let provider = try AIProviderFactory.makeProvider(
            kind: .kiloCLI,
            settings: settings,
            secretProvider: InMemorySecretProvider()
        )
        guard let cli = provider as? CLIProvider else {
            return XCTFail("Expected a command-line provider")
        }
        XCTAssertEqual(cli.configuration.outputFormat, .plainText)
    }
}
