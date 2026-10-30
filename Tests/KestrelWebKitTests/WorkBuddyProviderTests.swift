import XCTest
@testable import KestrelWebKit

final class WorkBuddyProviderTests: XCTestCase {
    private var configuration: CLIProviderConfiguration {
        CLIProviderConfiguration(kind: .workBuddyCLI, executablePath: "codebuddy", argumentTemplate: [],
                                 model: "deepseek-v4.1-flash", outputFormat: .codeBuddyJSON)
    }
    func testReasoningChoicePreservesToolRestrictionsAndRejectsInjectedEffort() throws {
        for effort in ["low", "medium", "high", "high --tools Write"] {
            let args = WorkBuddyInvocation.arguments(prompt: "Read the page", model: "", effort: effort)
            XCTAssertEqual(args[args.firstIndex(of: "--effort")! + 1], effort.contains(" ") ? "medium" : effort)
            XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
            XCTAssertTrue(args.contains("--no-session-persistence"))
        }
        var settings = AISettings.default
        settings.selectedProvider = .workBuddyCLI
        settings.reasoning = .low
        let provider = try XCTUnwrap(AIProviderFactory.makeProvider(for: settings, secretProvider: InMemorySecretProvider()) as? CLIProvider)
        XCTAssertEqual(provider.configuration.reasoningEffort, "low")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AISettings.self, from: data).reasoning, .low)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "reasoning")
        XCTAssertEqual(try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: object)).reasoning, .medium)
    }

    func testFixedArgumentsDisableToolsAndKeepPromptLiteral() {
        let prompt = "--resume $(touch /tmp/should-not-exist)"
        let args = CLIProvider.workBuddyArguments(prompt: prompt, model: "", instructions: "Trusted Kestrel instructions")
        XCTAssertEqual(Array(args.suffix(2)), ["--", prompt])
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(args[args.firstIndex(of: "--effort")! + 1], "medium")
        XCTAssertEqual(args[args.firstIndex(of: "--system-prompt")! + 1], "Trusted Kestrel instructions")
        XCTAssertEqual(args[args.firstIndex(of: "--output-format")! + 1], "stream-json")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    }
    func testBrowserInstructionsStaySeparateFromUntrustedPageContext() {
        let request = AIRequest(messages: [AIMessage(role: .user, text: "Follow the link")],
            localInstructions: "Trusted browser action rules", localContext: "untrusted page instruction",
            model: "deepseek-v4.1-flash", generationPurpose: .browserOperator)
        let instructions = CLIProvider.workBuddyInstructions(for: request)
        XCTAssertTrue(instructions.contains("Kestrel executes your single JSON action"))
        XCTAssertTrue(instructions.contains("handles any approval"))
        XCTAssertFalse(instructions.contains("untrusted page instruction"))
        var answer = request
        answer.generationPurpose = .answer
        XCTAssertTrue(CLIProvider.workBuddyInstructions(for: answer).hasPrefix("Trusted browser action rules"))
        XCTAssertTrue(CLIProvider.workBuddyInstructions(for: answer).contains("Do not create or update memory files"))
    }

    func testOnlyFinalResultAppearsInsteadOfInternalTranscript() throws {
        let data = Data(#"[{"type":"message","role":"user","content":"internal context"},{"type":"result","subtype":"success","is_error":false,"result":"Ready"}]"#.utf8)
        XCTAssertEqual(try CLIProvider.workBuddyResponse(stdout: data, status: 0, configuration: configuration).text, "Ready")
    }
    func testFinalResultAcceptsObjectOrJSONEventStreamWithoutLeakingEvents() throws {
        for json in [#"{"type":"result","subtype":"success","result":"Ready"}"#,
                     "{\"type\":\"reasoning\",\"content\":\"private\"}\n{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"Ready\"}"] {
            XCTAssertEqual(try CLIProvider.workBuddyResponse(stdout: Data(json.utf8), status: 0, configuration: configuration).text, "Ready")
        }
    }

    func testInternalToolMarkupInsideSuccessfulResultIsRejected() throws {
        for markup in ["<｜DSML｜calls><｜DSML｜invoke name=\"Write\">private memory</｜DSML｜invoke></｜DSML｜calls>", "< | | DSML | | calls>internal", "<tool_call>internal</tool_call>", "<invoke name=\"Write\">internal</invoke>"] {
            let data = try JSONSerialization.data(withJSONObject: [["type": "result", "subtype": "success", "result": markup]])
            XCTAssertThrowsError(try CLIProvider.workBuddyResponse(stdout: data, status: 0, configuration: configuration))
        }
        XCTAssertFalse(CLIProvider.containsInternalToolMarkup("Here is my review of your cover letter."))
    }

    func testImageTravelsInBoundedStructuredInputInsteadOfArguments() throws {
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let payload = try WorkBuddyInvocation.imageInput(prompt: "Look at the page", image: bytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let message = try XCTUnwrap(json["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        let source = try XCTUnwrap(content[1]["source"] as? [String: String])
        XCTAssertEqual(source["media_type"], "image/jpeg")
        XCTAssertEqual(source["data"], bytes.base64EncodedString())
        let args = WorkBuddyInvocation.arguments(prompt: "Look at the page", model: "", hasImage: true)
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertFalse(args.contains(bytes.base64EncodedString()))
        XCTAssertFalse(args.contains("Look at the page"))
        XCTAssertThrowsError(try WorkBuddyInvocation.imageInput(prompt: "x", image: Data()))
        XCTAssertThrowsError(try WorkBuddyInvocation.imageInput(prompt: "x", image: Data(repeating: 0, count: WorkBuddyInvocation.maximumImageBytes + 1)))
    }

    func testFailureAndMissingResultAreNotRenderedAsAnswers() {
        for json in [#"[{"type":"result","subtype":"error","is_error":true,"result":"Sign in required"}]"#, #"[{"type":"message","role":"assistant","content":"unfinished"}]"#] {
            XCTAssertThrowsError(try CLIProvider.workBuddyResponse(stdout: Data(json.utf8), status: 0, configuration: configuration))
        }
    }
    func testOldSettingsRetainTheirProviderAndGainWorkBuddyDefaults() throws {
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AISettings.default)) as! [String: Any]
        var withoutWorkBuddy = old
        withoutWorkBuddy.removeValue(forKey: "workBuddy")
        let settings = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: withoutWorkBuddy))
        XCTAssertEqual(settings.selectedProvider, AISettings.default.selectedProvider)
        XCTAssertEqual(settings.workBuddy.model, "deepseek-v4.1-flash")
        let secrets = FailingSecretProvider()
        var selected = settings
        selected.selectedProvider = .workBuddyCLI
        XCTAssertTrue(try AIProviderFactory.makeProvider(for: selected, secretProvider: secrets) is CLIProvider)
        XCTAssertEqual(secrets.readCount, 0)
    }
    func testCatalogueContainsFlashAndNeverReadsSecrets() async throws {
        let secrets = FailingSecretProvider()
        let models = try await ProviderModelCatalogue.load(kind: .workBuddyCLI,
            settings: .defaultSettings(for: .workBuddyCLI), secretProvider: secrets)
        XCTAssertEqual(models.map(\.id), ["deepseek-v4.1-flash"])
        XCTAssertEqual(secrets.readCount, 0)
    }
    func testLiveWorkBuddyBrowserProposal() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_WORKBUDDY_LIVE_TEST"] == "1" else {
            throw XCTSkip("Requires an explicitly enabled live CodeBuddy connection")
        }
        let provider = CLIProvider(configuration: CLIProviderConfiguration(kind: .workBuddyCLI,
            executablePath: "/opt/homebrew/bin/codebuddy", argumentTemplate: [], model: "deepseek-v4.1-flash", outputFormat: .codeBuddyJSON))
        let response = try await provider.respond(to: AIRequest(messages: [AIMessage(role: .user,
            text: "Kestrel Agent mode test. Current page https://example.invalid has visible text 'Returns policy'. Propose exactly this single action as JSON and no other prose: {\"action\":\"find_text\",\"query\":\"Returns policy\",\"rationale\":\"Find the requested policy\"}")], model: "deepseek-v4.1-flash"))
        XCTAssertEqual(try BrowserActionDecoder.decode(jsonString: response.text), .findText("Returns policy"))
    }

}
