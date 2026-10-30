import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The official runtime owns authentication. Its opt-in host agent reuses
/// Codex’s existing sign-in without Kestrel reading or copying credentials.
enum CodexRuntime {
    static var executableURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KestrelCodexHost.app/Contents/MacOS/codex")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var homeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kestrel/Codex", isDirectory: true)
    }

    static let configuration: [String: Any] = [
        "model_reasoning_effort": "medium", "web_search": "disabled",
        "project_doc_max_bytes": 0, "mcp_servers": [String: Any](),
        "tools": ["view_image": false, "web_search": false],
        "computer_use": ["default_app_access": "deny"],
        "check_for_update_on_startup": false,
        "features": ["shell_tool": false, "unified_exec": false, "shell_snapshot": false,
                     "view_image": false, "multi_agent": false, "plugins": false,
                     "hooks": false, "memories": false, "sleep_tool": false,
                     "in_app_browser": false, "in_app_local_automation": false,
                     "workspace_dependencies": false, "tool_suggest": false,
                     "unbounded_connection_retries": false],
        "apps": ["_default": ["enabled": false]]
    ]

    static func environment(home: URL, inherited: [String: String]) -> [String: String] {
        // Do not inherit API keys, a host CODEX_HOME or proxy/auth overrides.
        var result: [String: String] = ["CODEX_HOME": home.path, "HOME": home.path,
                                      "PATH": "/usr/bin:/bin", "LANG": "en_GB.UTF-8"]
        if let temporary = inherited["TMPDIR"] { result["TMPDIR"] = temporary }
        return result
    }

    static func connect() async throws -> CodexRPC {
        guard let executableURL else {
            throw AIProviderError.notConfigured("This build does not include Codex. Install a Kestrel build with the Codex runtime to sign in with ChatGPT.")
        }
        let connection = CodexRPC(executable: executableURL, home: homeURL, useHostBridge: true)
        try await connection.start()
        return connection
    }
}

/// A bounded stdio JSON-RPC connection. It never opens a socket or grants a
/// tool request. Closing it cancels pending requests and kills a stuck child.
actor CodexRPC {
    private let executable: URL
    private let home: URL
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var notifications: [[String: Any]] = []
    private var notificationWaiter: CheckedContinuation<[String: Any], Error>?
    private var notificationDeadline: Task<Void, Never>?
    private var closed = false
    private var notificationBytes = 0
    private let useHostBridge: Bool
    #if os(macOS)
    private var host: CodexHostConnection?
    #endif

    init(executable: URL, home: URL, useHostBridge: Bool = false) {
        self.executable = executable; self.home = home; self.useHostBridge = useHostBridge
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let child = Process()
        child.executableURL = executable
        child.currentDirectoryURL = home
        child.environment = CodexRuntime.environment(home: home, inherited: ProcessInfo.processInfo.environment)
        var arguments = ["app-server", "--listen", "stdio://"]
        for key in CodexRuntime.configuration.keys.sorted() {
            let value = CodexRuntime.configuration[key]!
            // JSON literals also satisfy TOML for these scalars. Tables use
            // individual dotted overrides, never a model-supplied argument.
            if let table = value as? [String: Any] {
                if table.isEmpty { arguments += ["-c", "\(key)={}"] }
                for subkey in table.keys.sorted() {
                    if let nested = table[subkey] as? [String: Any] {
                        for leaf in nested.keys.sorted() {
                            arguments += ["-c", "\(key).\(subkey).\(leaf)=\(Self.literal(nested[leaf]!))"]
                        }
                    } else { arguments += ["-c", "\(key).\(subkey)=\(Self.literal(table[subkey]!))"] }
                }
            } else { arguments += ["-c", "\(key)=\(Self.literal(value))"] }
        }
        #if os(macOS)
        if useHostBridge {
            let bridge = try CodexHostConnection()
            host = bridge
            do { try await bridge.launch(arguments: arguments) }
            catch { close(); throw error }
            Task { [weak self] in
                do {
                    while true {
                        let data = try await bridge.read()
                        if data.isEmpty { await self?.close(); break }
                        await self?.receive(data)
                    }
                } catch { await self?.close() }
            }
            do {
                _ = try await request("initialize", ["clientInfo": ["name": "kestrel", "title": "Kestrel", "version": "1.0"]])
                try send(["method": "initialized"])
                return
            } catch { close(); throw error }
        }
        #endif
        child.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        process = child; input = stdin.fileHandleForWriting
        Task.detached { [weak self] in
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { await self?.close(); break }
                await self?.receive(data)
            }
        }
        // Drain diagnostics without retaining potentially sensitive output.
        Task.detached {
            while !stderr.fileHandleForReading.availableData.isEmpty { }
        }
        do {
            _ = try await request("initialize", ["clientInfo": ["name": "kestrel", "title": "Kestrel", "version": "1.0"]])
            try send(["method": "initialized"])
        } catch { close(); throw error }
    }

    private static func literal(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    func request(_ method: String, _ params: [String: Any] = [:], timeout: UInt64 = 30) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !closed else { throw Self.unavailable }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    if !Task.isCancelled { await self?.expire(id) }
                }
                do { try send(["id": id, "method": method, "params": params]) }
                catch { finish(id, .failure(error)) }
            }
        } onCancel: { Task { await self.close() } }
    }

    func nextNotification(timeout: UInt64 = 120) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !closed else { throw Self.unavailable }
        if !notifications.isEmpty {
            let value = notifications.removeFirst()
            notificationBytes -= (try? JSONSerialization.data(withJSONObject: value).count) ?? 0
            return value
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                notificationWaiter = continuation
                notificationDeadline = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    if !Task.isCancelled { await self?.close() }
                }
            }
        } onCancel: { Task { await self.close() } }
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
        guard data.count <= 1_048_576 else { throw Self.unavailable }
        #if os(macOS)
        if let host {
            host.write(data) { Task { await self.close() } }
            return
        }
        #endif
        guard let input else { throw Self.unavailable }
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        buffer.append(data)
        guard buffer.count <= 2_097_152 else { close(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                close(); return
            }
            if let id = message["id"] as? Int, message["method"] == nil {
                if let error = message["error"] as? [String: Any] {
                    let detail = Redaction.redacted(String((error["message"] as? String ?? "Codex request failed.").prefix(2_000)))
                    finish(id, .failure(AIProviderError.invalidResponse(detail)))
                } else { finish(id, .success(message["result"] as? [String: Any] ?? [:])) }
            } else if let id = message["id"], message["method"] != nil {
                // Never approve arbitrary commands, file changes or dynamic
                // tools: only Kestrel's own operator can execute page actions.
                try? send(["id": id, "error": ["code": -32601, "message": "Kestrel does not expose Codex runtime tools."]])
            } else if let method = message["method"] as? String,
                      ["item/completed", "turn/completed", "account/login/completed"].contains(method) {
                if let waiter = notificationWaiter {
                    notificationWaiter = nil; notificationDeadline?.cancel(); notificationDeadline = nil
                    waiter.resume(returning: message)
                } else {
                    notificationBytes += line.count
                    guard notifications.count < 128, notificationBytes <= 4_194_304 else { close(); return }
                    notifications.append(message)
                }
            }
        }
    }

    private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func expire(_ id: Int) {
        finish(id, .failure(AIProviderError.processTimedOut(executable: "Codex")))
        close()
    }
    func close() {
        guard !closed else { return }; closed = true
        #if os(macOS)
        host?.close(); host = nil
        #endif
        try? input?.close(); input = nil
        for id in Array(pending.keys) { finish(id, .failure(Self.unavailable)) }
        notificationDeadline?.cancel(); notificationDeadline = nil
        notificationWaiter?.resume(throwing: Self.unavailable); notificationWaiter = nil
        notifications.removeAll(); buffer.removeAll()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    #if canImport(Darwin)
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    #elseif canImport(Glibc)
                    Glibc.kill(process.processIdentifier, SIGKILL)
                    #endif
                }
            }
        }
        process = nil
    }
    private static var unavailable: AIProviderError {
        .invalidResponse("Codex disconnected or timed out. Check your existing Codex sign-in and Kestrel’s helper in Settings → Assistant.")
    }
}

struct CodexAccountProvider: AIProvider {
    let kind: AIProviderKind = .codexCLI
    let model: String
    var reasoningEffort: String = "medium"
    var connect: @Sendable () async throws -> CodexRPC = { try await CodexRuntime.connect() }

    func respond(to request: AIRequest) async throws -> AIResponse {
        let rpc = try await connect()
        do {
            let account = try await rpc.request("account/read")
            guard let identity = account["account"] as? [String: Any], identity["type"] as? String == "chatgpt" else {
                throw AIProviderError.notConfigured("Codex is not signed in with ChatGPT. Sign in to the Codex app or CLI, then retry in Kestrel; Kestrel uses that existing Codex session.")
            }
            var parameters: [String: Any] = ["ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never",
                "cwd": CodexRuntime.homeURL.path, "config": CodexRuntime.configuration,
                "baseInstructions": "You are Kestrel's browser assistant. Respond in British English using only the supplied context. You cannot execute tools. Propose browser actions only in the format requested by Kestrel; Kestrel handles execution and approval. Never invent page content or claim an action occurred without supplied evidence."]
            if !model.isEmpty { parameters["model"] = model }
            let started = try await rpc.request("thread/start", parameters)
            guard let thread = started["thread"] as? [String: Any], let id = thread["id"] as? String else {
                throw AIProviderError.invalidResponse("Codex did not start a browsing request.")
            }
            _ = try await rpc.request("turn/start", ["threadId": id, "effort": reasoningEffort,
                "input": [["type": "text", "text": request.flattenedPrompt()]]])
            var answer = ""
            let deadline = Date().addingTimeInterval(120)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw AIProviderError.processTimedOut(executable: "Codex") }
                let event = try await rpc.nextNotification(timeout: UInt64(max(1, remaining)))
                let params = event["params"] as? [String: Any] ?? [:]
                guard params["threadId"] as? String == id else { continue }
                if event["method"] as? String == "item/completed",
                   let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                   let text = item["text"] as? String, item["phase"] as? String != "commentary" {
                    answer = text
                }
                if event["method"] as? String == "turn/completed" {
                    let turn = params["turn"] as? [String: Any] ?? [:]
                    guard turn["status"] as? String == "completed" else {
                        let error = turn["error"] as? [String: Any]
                        throw AIProviderError.invalidResponse(Redaction.redacted(String((error?["message"] as? String ?? "Codex could not complete the request. Check your plan limits or sign-in.").prefix(2_000))))
                    }
                    guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AIProviderError.invalidResponse("Codex completed without an answer.")
                    }
                    await rpc.close()
                    return AIResponse(text: answer, model: model.isEmpty ? nil : model)
                }
            }
        } catch { await rpc.close(); throw error }
    }
}

#if canImport(AppKit)
import AppKit
import Combine
import ServiceManagement

@MainActor final class CodexAccountController: ObservableObject {
    @Published var status = "Uses your existing Codex sign-in. No separate Kestrel account or API key."
    @Published var isBusy = false
    @Published var isSignedIn = false
    @Published var helperStatus = ""
    @Published var helperReady = false
    @Published var requiresApproval = false
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "codexHostHelperEnabled") }
    private var companionURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KestrelCodexHost.app")
    }

    func refresh() async {
        guard !isBusy, CodexRuntime.executableURL != nil else { return }
        guard UserDefaults.standard.bool(forKey: "codexHostHelperEnabled") else {
            helperReady = false; isSignedIn = false; requiresApproval = false
            status = "Enable the local helper to use your existing Codex sign-in inside Kestrel."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let rpc = try await CodexRuntime.connect()
            let result: [String: Any]
            do { result = try await rpc.request("account/read"); await rpc.close() }
            catch { await rpc.close(); throw error }
            helperReady = true; requiresApproval = false
            isSignedIn = (result["account"] as? [String: Any])?["type"] as? String == "chatgpt"
            status = isSignedIn ? "Connected using your existing Codex sign-in. Uses your Codex allowance. Choose Thinking in the model picker." : "Codex is not signed in with ChatGPT. Sign in to the Codex app or CLI, then refresh here."
        } catch {
            helperReady = false; isSignedIn = false
            status = Redaction.redacted(error.localizedDescription)
        }
    }
    func enable(refreshCodexAccount: Bool = true) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--enable"]
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            do {
                let companion = try await NSWorkspace.shared.openApplication(at: companionURL, configuration: configuration)
                // Registration is asynchronous. Do not claim success merely
                // because Launch Services accepted the request.
                for _ in 0..<100 {
                    if companion.isTerminated { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard companion.isTerminated else {
                    throw AIProviderError.notConfigured("The Mac CLI helper is still waiting for registration. Check for a helper error or approval dialogue, then refresh again.")
                }
                UserDefaults.standard.set(true, forKey: "codexHostHelperEnabled")
                let connection = try CodexHostConnection()
                do { try await connection.waitUntilReady(); connection.close() }
                catch { connection.close(); throw error }
                helperReady = true; requiresApproval = false; isBusy = false
                helperStatus = "Mac CLI helper connected."
                if refreshCodexAccount { await refresh() }
            } catch {
                isBusy = false; helperReady = false
                helperStatus = "Could not enable the Mac CLI helper: " + error.localizedDescription
                status = helperStatus
            }
        }
    }
    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
    func disable() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--disable"]
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: companionURL, configuration: configuration)
                UserDefaults.standard.set(false, forKey: "codexHostHelperEnabled")
                helperReady = false; isSignedIn = false; requiresApproval = false
                helperStatus = "Mac CLI helper disabled."
                status = "Codex helper disabled. Your Codex sign-in is unchanged."
            } catch { helperStatus = error.localizedDescription; status = helperStatus }
        }
    }
}
#endif
