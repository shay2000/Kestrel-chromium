#if canImport(CefSwiftUI)

import CefKit
import CefSwiftUI
import Foundation

/// Asynchronous, bounded JavaScript evaluation over CefSwift's native bridge.
/// The bridge carries results only; page scripts never receive native powers.
@MainActor
final class CefScriptRunner {
    static let shared = CefScriptRunner()

    private struct PendingEvaluation {
        let tabID: String
        let continuation: CheckedContinuation<Any?, Never>
    }

    private struct EvaluationReply: Decodable, Sendable {
        let requestID: String
        let tabID: String
        let value: String?
        let error: String?
    }

    private struct BridgeAcknowledgement: Encodable, Sendable {
        let received: Bool
    }

    private var pending: [String: PendingEvaluation] = [:]
    private var isInstalled = false
    private let maximumReplyBytes = 1_000_000

    private init() {}

    func installBridge() {
        guard !isInstalled else { return }
        isInstalled = true
        CefRuntime.shared.bridge.register("kestrel_evaluate_result") { [weak self] (reply: EvaluationReply) async throws -> BridgeAcknowledgement in
            await self?.receive(reply)
            return BridgeAcknowledgement(received: true)
        }
    }

    /// Evaluates an expression in a browser tab and returns its JSON value.
    /// The random request identifier and tab identifier bind replies to one
    /// outstanding call, and late or cross-tab replies are discarded.
    func evaluate(_ expression: String, in model: CefWebViewModel, tabID: UUID,
                  timeoutNanoseconds: UInt64 = 8_000_000_000) async -> Any? {
        guard let browser = model.kestrelBrowser, browser.id != -1, !Task.isCancelled else { return nil }
        installBridge()
        return await evaluateSource("return await (\(expression));", in: model, tabID: tabID,
                                    timeoutNanoseconds: timeoutNanoseconds)
    }

    /// Evaluates a fixed function body whose statements contain explicit
    /// `return` statements (for example the approved profile-fill adapter).
    func evaluateBody(_ body: String, in model: CefWebViewModel, tabID: UUID,
                      timeoutNanoseconds: UInt64 = 8_000_000_000) async -> Any? {
        guard let browser = model.kestrelBrowser, browser.id != -1, !Task.isCancelled else { return nil }
        installBridge()
        return await evaluateSource(body, in: model, tabID: tabID,
                                    timeoutNanoseconds: timeoutNanoseconds)
    }

    private func evaluateSource(_ source: String, in model: CefWebViewModel, tabID: UUID,
                                timeoutNanoseconds: UInt64) async -> Any? {
        let requestID = UUID().uuidString
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                pending[requestID] = PendingEvaluation(tabID: tabID.uuidString, continuation: continuation)
                model.kestrelExecuteJavaScript(Self.wrapper(source, requestID: requestID, tabID: tabID.uuidString))
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    self?.finish(requestID, value: nil)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(requestID, value: nil) }
        }
    }

    private func receive(_ reply: EvaluationReply) {
        guard let evaluation = pending[reply.requestID],
              evaluation.tabID == reply.tabID,
              reply.error == nil,
              let rawValue = reply.value,
              rawValue.utf8.count <= maximumReplyBytes,
              let data = rawValue.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            finish(reply.requestID, value: nil)
            return
        }
        finish(reply.requestID, value: value)
    }

    private func finish(_ requestID: String, value: Any?) {
        guard let evaluation = pending.removeValue(forKey: requestID) else { return }
        evaluation.continuation.resume(returning: value)
    }

    private static func wrapper(_ source: String, requestID: String, tabID: String) -> String {
        let request = JavaScriptStringLiteral.escape(requestID)
        let tab = JavaScriptStringLiteral.escape(tabID)
        return """
        (async function () {
          const requestID = \(request), tabID = \(tab);
          if (!window.cefSwift || typeof window.cefSwift.invoke !== 'function') return;
          let value = null, error = null;
          try { value = await (async function () {\n\(source)\n}).call(window); }
          catch (caught) { error = String(caught && caught.message || caught).slice(0, 500); }
          let encoded = null;
          try { encoded = JSON.stringify(value === undefined ? null : value); }
          catch (caught) { error = 'The page result could not be encoded.'; }
          window.cefSwift.invoke('kestrel_evaluate_result', {
            requestID: requestID, tabID: tabID, value: encoded, error: error
          }).catch(function () {});
        })();
        """
    }
}

#endif
