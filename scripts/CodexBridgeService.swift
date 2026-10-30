// Independent native transport implementation; no BrowserOS code is copied.
// launchd runs this opt-in agent outside the browser sandbox. Only the signed
// enclosing Kestrel build can connect. The agent never reads login files: the
// official Codex executable manages its own existing sign-in.
import Foundation
import Darwin

final class BridgeSession: NSObject, KestrelCodexBridgeProtocol {
    private let queue = DispatchQueue(label: "Kestrel.CodexAgent.session")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var workspace: URL?
    private var stopped = false

    func ready(withReply reply: @escaping () -> Void) { reply() }

    func launch(arguments: [String], withReply reply: @escaping (String?) -> Void) {
        queue.async {
            guard !self.stopped, self.process == nil,
                  arguments.prefix(3) == ["app-server", "--listen", "stdio://"],
                  arguments.count <= 100 else { reply("Invalid or duplicate Codex launch."); return }
            // The caller is code-signing authenticated. Still constrain argv
            // to app-server plus fixed config overrides, never shell commands.
            let overrides = Array(arguments.dropFirst(3))
            guard overrides.count.isMultiple(of: 2), stride(from: 0, to: overrides.count, by: 2).allSatisfy({ overrides[$0] == "-c" }) else {
                reply("Unsupported Codex arguments."); return
            }
            let helper = CodexBridgeIdentity.currentExecutableURL
            let codex = helper.deletingLastPathComponent().appendingPathComponent("codex")
            let child = Process()
            child.executableURL = codex
            child.arguments = arguments
            let home = FileManager.default.homeDirectoryForCurrentUser
            // Codex itself uses its normal account/configuration. Do not
            // inherit API keys or copy any auth/session files into Kestrel.
            child.environment = ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path,
                                 "PATH": "/usr/bin:/bin", "LANG": "en_GB.UTF-8", "TMPDIR": NSTemporaryDirectory()]
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("KestrelCodex-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                child.currentDirectoryURL = workspace
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
                try child.run()
                self.process = child; self.input = stdin.fileHandleForWriting; self.output = stdout.fileHandleForReading
                self.workspace = workspace
                DispatchQueue.global().async { while !stderr.fileHandleForReading.availableData.isEmpty { } }
                reply(nil)
            } catch { try? FileManager.default.removeItem(at: workspace); reply("Could not start the packaged Codex runtime.") }
        }
    }
    /// The signed browser supplies only its configured executable and request.
    /// Fixed arguments prevent enabling tools, MCP, shell or continuation.
    func respondWorkBuddy(executablePath: String, model: String, instructions: String, prompt: String, imageData: Data?, reasoningEffort: String,
                          withReply reply: @escaping (Data?, Int32, String?) -> Void) {
        queue.async {
            guard !self.stopped, self.process == nil, executablePath.hasPrefix("/"),
                  executablePath.utf8.count <= 4_096, !executablePath.contains("\0"),
                  model.utf8.count <= 200, instructions.utf8.count <= 65_536, prompt.utf8.count <= 524_288, (imageData?.count ?? 0) <= WorkBuddyInvocation.maximumImageBytes else {
                reply(nil, -1, "Invalid WorkBuddy request or duplicate helper session."); return
            }
            let executable = URL(fileURLWithPath: executablePath)
            let child = Process()
            child.executableURL = executable
            child.arguments = WorkBuddyInvocation.arguments(prompt: prompt, model: model, instructions: instructions, hasImage: imageData != nil, effort: reasoningEffort)
            let home = FileManager.default.homeDirectoryForCurrentUser
            child.environment = ["HOME": home.path, "PATH": executable.deletingLastPathComponent().path + ":/usr/bin:/bin",
                                 "LANG": "en_GB.UTF-8", "TMPDIR": NSTemporaryDirectory()]
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("KestrelWorkBuddy-" + UUID().uuidString)
            let stdout = Pipe(), stderr = Pipe()
            let group = DispatchGroup()
            group.enter()
            child.terminationHandler = { _ in group.leave() }
            let imageInput = imageData == nil ? nil : Pipe()
            child.standardInput = imageInput.map { $0 as Any } ?? FileHandle.nullDevice
            child.standardOutput = stdout; child.standardError = stderr
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                child.currentDirectoryURL = workspace
                self.workspace = workspace
                try child.run()
                self.process = child
            } catch {
                try? FileManager.default.removeItem(at: workspace)
                reply(nil, -1, "Could not start the configured CodeBuddy executable. Check its absolute path in Kestrel Settings."); return
            }
            if let imageData, let imageInput {
                self.input = imageInput.fileHandleForWriting
                group.enter()
                DispatchQueue.global().async {
                    defer { try? imageInput.fileHandleForWriting.close(); group.leave() }
                    do { try imageInput.fileHandleForWriting.write(contentsOf: WorkBuddyInvocation.imageInput(prompt: prompt, image: imageData)) }
                    catch { self.stop() }
                }
            }
            let captured = WorkBuddyOutput()
            for (handle, retain) in [(stdout.fileHandleForReading, true), (stderr.fileHandleForReading, false)] {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        if !captured.append(chunk, retain: retain) { self.stop(); break }
                    }
                }
            }
            group.notify(queue: self.queue) {
                let output = captured.result()
                reply(output.data, child.terminationStatus, output.exceeded ? "WorkBuddy output exceeded the 2 MB transport limit." : nil)
                self.stop()
            }
        }
    }
    func write(_ data: Data, withReply reply: @escaping (String?) -> Void) {
        queue.async {
            guard !self.stopped, data.count <= 1_048_576, let input = self.input else { reply("Codex is disconnected."); return }
            do { try input.write(contentsOf: data); reply(nil) }
            catch { reply("Could not send a Codex request.") }
        }
    }
    func read(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            guard !self.stopped, let output = self.output else { reply(nil, "Codex is disconnected."); return }
            // A separate queue lets Stop close stdin/terminate a hung child
            // while stdout is blocked. Never retain a transcript in the agent.
            DispatchQueue.global().async {
                // read(upToCount:) can wait for a full count on a pipe,
                // deadlocking the initialise/request-response handshake.
                let data = output.availableData
                guard data.count <= 2_097_152 else { reply(nil, "Codex response exceeded the transport bound."); return }
                reply(data, nil)
            }
        }
    }
    func stop() {
        queue.async {
            guard !self.stopped else { return }; self.stopped = true
            try? self.input?.close(); self.input = nil
            if let child = self.process, child.isRunning {
                child.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
            self.process = nil
            if let workspace = self.workspace { try? FileManager.default.removeItem(at: workspace) }
        }
    }
}

final class BridgeListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = BridgeSession()
        connection.exportedInterface = NSXPCInterface(with: KestrelCodexBridgeProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.stop() }
        connection.interruptionHandler = { session.stop() }
        connection.resume()
        return true
    }
}

enum CodexAgentMain {
    static func main() throws {
        let executable = CodexBridgeIdentity.currentExecutableURL
        var app = executable
        for _ in 0..<6 { app.deleteLastPathComponent() }
        let listener = NSXPCListener(machServiceName: CodexBridgeIdentity.serviceName)
        listener.setConnectionCodeSigningRequirement(try CodexBridgeIdentity.requirement(for: app))
        let delegate = BridgeListener()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}

private final class WorkBuddyOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var bytes = 0
    private var exceeded = false
    func append(_ chunk: Data, retain: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        bytes += chunk.count
        if bytes > 2_097_152 { exceeded = true; return false }
        if retain { data.append(chunk) }
        return true
    }
    func result() -> (data: Data, exceeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (data, exceeded)
    }
}
