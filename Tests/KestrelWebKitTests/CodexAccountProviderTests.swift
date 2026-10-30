import XCTest
#if canImport(Security)
import Security
#endif
@testable import KestrelWebKit

final class CodexAccountProviderTests: XCTestCase {
    #if canImport(Security) && canImport(WebKit)
    @MainActor func testPassiveMCPStartupCannotPromptOrReplaceAnInaccessibleToken() {
        var interactions: [Bool] = []
        var writes = 0
        let server = KestrelMCPServer(requestedPort: 0, tokenLookup: { interactive in
            interactions.append(interactive)
            return .inaccessible(status: errSecInteractionNotAllowed)
        }, tokenWriter: { _ in writes += 1; return true })
        server.start(allowKeychainInteraction: false)
        XCTAssertEqual(interactions, [])
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(server.isRunning)
        XCTAssertTrue(server.statusMessage.contains("Local MCP is paused"))
        server.start()
        XCTAssertEqual(interactions, [true])
        XCTAssertEqual(writes, 0)
        let query = KeychainSecretStore.lookupQuery(account: "fixture", service: "fixture", allowInteraction: false)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
    }
    #endif

    func testRuntimeDoesNotInheritHostCredentialsOrConfiguration() {
        let environment = CodexRuntime.environment(home: URL(fileURLWithPath: "/private/tmp/kestrel-owned"), inherited: [
            "CODEX_HOME": "/host/codex", "OPENAI_API_KEY": "[REDACTED]", "ACCESS_TOKEN": "[REDACTED]",
            "HOME": "/host/home", "PATH": "/host/bin", "HTTPS_PROXY": "https://example.invalid", "TMPDIR": "/private/tmp/"
        ])
        XCTAssertEqual(environment["CODEX_HOME"], "/private/tmp/kestrel-owned")
        XCTAssertEqual(environment["HOME"], "/private/tmp/kestrel-owned")
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ACCESS_TOKEN"])
        XCTAssertNil(environment["HTTPS_PROXY"])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
    }

    func testCompletedResponseUsesLunaMediumAndEphemeralReadOnlyThread() async throws {
        let fixture = try fixture(mode: "completed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = CodexAccountProvider(model: "gpt-6-luna", connect: {
            let rpc = CodexRPC(executable: fixture.executable, home: fixture.root)
            try await rpc.start(); return rpc
        })
        let response = try await provider.respond(to: AIRequest(messages: [AIMessage(role: .user, text: "Read this page")], model: "gpt-6-luna"))
        XCTAssertEqual(response.text, "Completed answer")
        let requests = try String(contentsOf: fixture.root.appendingPathComponent("requests.jsonl"))
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let thread = try XCTUnwrap(requests.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        XCTAssertEqual(thread["ephemeral"] as? Bool, true)
        XCTAssertEqual(thread["sandbox"] as? String, "read-only")
        XCTAssertEqual(thread["approvalPolicy"] as? String, "never")
        XCTAssertEqual(thread["model"] as? String, "gpt-6-luna")
        let config = try XCTUnwrap(thread["config"] as? [String: Any])
        XCTAssertEqual((config["features"] as? [String: Any])?["shell_tool"] as? Bool, false)
        let turn = try XCTUnwrap(requests.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        XCTAssertEqual(turn["effort"] as? String, "medium")
    }

    func testFailedTurnDoesNotReturnPartialAnswer() async throws {
        let fixture = try fixture(mode: "failed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = CodexAccountProvider(model: "gpt-6-luna", connect: {
            let rpc = CodexRPC(executable: fixture.executable, home: fixture.root)
            try await rpc.start(); return rpc
        })
        do {
            _ = try await provider.respond(to: AIRequest(messages: [AIMessage(role: .user, text: "Read this page")], model: "gpt-6-luna"))
            XCTFail("A failed turn must not return its partial answer")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Usage limit")) }
    }

    func testCommonAccountAndTurnFailuresProduceReadableErrors() async throws {
        let cases = [
            ("signed-out", "not signed in"),
            ("missing-thread", "did not start"),
            ("empty-answer", "without an answer"),
            ("interrupted", "Usage limit")
        ]
        for (mode, expected) in cases {
            let fixture = try fixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let provider = CodexAccountProvider(model: "gpt-6-luna", connect: {
                let rpc = CodexRPC(executable: fixture.executable, home: fixture.root)
                try await rpc.start(); return rpc
            })
            do {
                _ = try await provider.respond(to: AIRequest(messages: [AIMessage(role: .user, text: "Read this page")], model: "gpt-6-luna"))
                XCTFail("\(mode) must not return an answer")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(mode): \(error.localizedDescription)")
                XCTAssertFalse(error.localizedDescription.contains("final_answer"), "Protocol JSON must not become user copy")
            }
        }
    }

    func testCancellationClosesPendingRequest() async throws {
        let fixture = try fixture(mode: "hang")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = CodexRPC(executable: fixture.executable, home: fixture.root)
        try await rpc.start()
        let task = Task { try await rpc.request("hang", timeout: 20) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned") }
        catch { }
        do { _ = try await rpc.request("account/read"); XCTFail("Connection survived cancellation") }
        catch { }
    }

    func testProtocolFailuresAndOversizedFramesCloseConnection() async throws {
        for mode in ["malformed", "oversized"] {
            let fixture = try fixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let rpc = CodexRPC(executable: fixture.executable, home: fixture.root)
            try await rpc.start()
            do { _ = try await rpc.request("invalid", timeout: 5); XCTFail("Invalid stream returned a result") }
            catch { }
            await rpc.close()
        }
    }

    func testRuntimeToolRequestIsRejectedWithoutGrantingApproval() async throws {
        let fixture = try fixture(mode: "completed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = CodexRPC(executable: fixture.executable, home: fixture.root)
        try await rpc.start()
        _ = try await rpc.request("request-tool")
        // This following response acts as a barrier: the fixture has consumed
        // Kestrel's denial before answering the account request.
        _ = try await rpc.request("account/read")
        await rpc.close()
        let lines = try String(contentsOf: fixture.root.appendingPathComponent("requests.jsonl"))
        let messages = try lines.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let denial = try XCTUnwrap(messages.first { $0["id"] as? String == "tool-request" })
        XCTAssertNotNil(denial["error"])
        XCTAssertNil(denial["result"])
    }

    func testRequestTimeoutClosesProcess() async throws {
        let fixture = try fixture(mode: "hang")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rpc = CodexRPC(executable: fixture.executable, home: fixture.root)
        try await rpc.start()
        do { _ = try await rpc.request("hang", timeout: 1); XCTFail("Timed-out request returned") }
        catch let error as AIProviderError {
            guard case .processTimedOut = error else { XCTFail("Wrong timeout error: \(error)"); return }
        }
        await rpc.close()
    }

    func testOfficialRuntimeStartsWithPrivateEmptyHomeWithoutReadingHostSignIn() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_LIVE_CODEX_RUNTIME_TESTS"] == "1" else {
            throw XCTSkip("Opt-in real Codex app-server runtime smoke check")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = CodexRPC(executable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), home: root)
        try await rpc.start()
        do {
            let account = try await rpc.request("account/read")
            XCTAssertTrue(account["account"] is NSNull)
            let models = try await rpc.request("model/list", ["includeHidden": false, "limit": 100])
            let rows = try XCTUnwrap(models["data"] as? [[String: Any]])
            XCTAssertTrue(rows.contains { $0["model"] as? String == "gpt-6-luna" })
            await rpc.close()
        } catch { await rpc.close(); throw error }
    }

    private struct Fixture: @unchecked Sendable { let root: URL; let executable: URL }
    private func fixture(mode: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-codex")
        // Python is a test fixture only, never a production browser action.
        let script = """
        #!/usr/bin/env python3
        import json, os, sys
        def emit(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            r=json.loads(line)
            with open(os.path.join(os.environ['CODEX_HOME'], 'requests.jsonl'), 'a') as f: f.write(line)
            method=r.get('method')
            if method=='invalid':
                if '\(mode)'=='oversized': sys.stdout.write('x'*2200000); sys.stdout.flush()
                else: print('not json', flush=True)
                continue
            if method=='request-tool': emit({'id':'tool-request','method':'item/commandExecution/requestApproval','params':{'command':'unexpected'}})
            if 'id' not in r or method is None: continue
            if method=='hang': continue
            result={}
            if method=='account/read': result={'account': None if '\(mode)'=='signed-out' else {'type':'chatgpt'}}
            if method=='thread/start' and '\(mode)'!='missing-thread': result={'thread': {'id':'thread-1'}}
            emit({'id':r['id'], 'result':result})
            if method=='turn/start':
                emit({'method':'item/completed', 'params':{'threadId':'thread-1','item':{'type':'agentMessage','phase':'commentary','text':'Ignore commentary'}}})
                emit({'method':'item/completed', 'params':{'threadId':'thread-1','item':{'type':'agentMessage','phase':'final_answer','text':'' if '\(mode)'=='empty-answer' else 'Completed answer'}}})
                emit({'method':'turn/completed','params':{'threadId':'thread-1','turn':{'status':'completed' if '\(mode)'=='empty-answer' else '\(mode)', 'error':{'message':'Usage limit reached'}}}})
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return Fixture(root: root, executable: executable)
    }
}
