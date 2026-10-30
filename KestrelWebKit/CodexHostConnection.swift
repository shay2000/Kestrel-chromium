#if os(macOS)
import Foundation

/// Transport only: no credential APIs or file access to the host Codex home.
final class CodexHostConnection: @unchecked Sendable {
    private let connection: NSXPCConnection
    init() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KestrelCodexHost.app/Contents/MacOS/KestrelCodexHost")
        connection = NSXPCConnection(machServiceName: CodexBridgeIdentity.serviceName)
        connection.setCodeSigningRequirement(try CodexBridgeIdentity.requirement(for: helper))
        connection.remoteObjectInterface = NSXPCInterface(with: KestrelCodexBridgeProtocol.self)
        connection.resume()
    }
    func launch(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ReplyOnce(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                once.finish(.failure(Self.unavailable))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.finish(.failure(Self.unavailable)) }
            guard let remote = proxy as? KestrelCodexBridgeProtocol else { once.finish(.failure(Self.unavailable)); return }
            remote.launch(arguments: arguments) { message in
                if message != nil { once.finish(.failure(Self.unavailable)) }
                else { once.finish(.success(())) }
            }
        }
    }
    func write(_ data: Data, onError: @escaping @Sendable () -> Void) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in onError() }
        guard let remote = proxy as? KestrelCodexBridgeProtocol else { onError(); return }
        remote.write(data) { if $0 != nil { onError() } }
    }
    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let once = ReplyOnce<Data>(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.finish(.failure(Self.unavailable)) }
            guard let remote = proxy as? KestrelCodexBridgeProtocol else { once.finish(.failure(Self.unavailable)); return }
            remote.read { data, error in
                if let data, error == nil { once.finish(.success(data)) }
                else { once.finish(.failure(Self.unavailable)) }
            }
        }
    }
    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = ReplyOnce(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                reply.finish(.failure(Self.unavailable))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish(.failure(Self.unavailable)) }
            guard let remote = proxy as? KestrelCodexBridgeProtocol else { reply.finish(.failure(Self.unavailable)); return }
            remote.ready { reply.finish(.success(())) }
        }
    }

    func respondWorkBuddy(executablePath: String, model: String, instructions: String, prompt: String, imageData: Data? = nil, reasoningEffort: String = "medium") async throws -> (Data, Int32) {
        try await waitUntilReady()
        let reply = ReplyOnce<(Data, Int32)>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(AIProviderError.cancelled)); close(); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [self] in
                    if reply.finish(.failure(AIProviderError.processTimedOut(executable: "WorkBuddy"))) { close() }
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish(.failure(Self.unavailable)) }
                guard let remote = proxy as? KestrelCodexBridgeProtocol else { reply.finish(.failure(Self.unavailable)); return }
                remote.respondWorkBuddy(executablePath: executablePath, model: model, instructions: instructions, prompt: prompt, imageData: imageData, reasoningEffort: reasoningEffort) { data, status, error in
                    if let data, error == nil { reply.finish(.success((data, status))) }
                    else { reply.finish(.failure(AIProviderError.invalidResponse(error ?? "The Mac CLI helper could not run WorkBuddy."))) }
                }
            }
        } onCancel: { [self] in
            reply.finish(.failure(AIProviderError.cancelled)); close()
        }
    }

    func close() {
        // Invalidation triggers the agent's session cleanup. Sending a
        // one-way Stop first can itself wait on an unavailable launchd job.
        connection.invalidate()
    }
    private static var unavailable: AIProviderError {
        .notConfigured("Kestrel couldn’t connect to its Mac CLI helper. Check Settings → Assistant and macOS Login Items. If already enabled, this build may need a valid helper signature.")
    }
}

private final class ReplyOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    init() {}
    convenience init(_ continuation: CheckedContinuation<Value, Error>) { self.init(); install(continuation) }
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}
#endif
