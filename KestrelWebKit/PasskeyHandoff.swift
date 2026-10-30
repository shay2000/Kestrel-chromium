import Foundation

/// A bounded outcome signal, never a credential or proof of authentication.
enum PasskeyHandoffSignal: Equatable {
    case rejected
    case succeeded

    /// Parses the small, fixed payload the injected script posts. Anything
    /// else is ignored rather than guessed at.
    init?(messageBody: Any) {
        guard let body = messageBody as? [String: Any],
              let reason = body["reason"] as? String else { return nil }
        switch reason {
        case "rejected":
            self = .rejected
        case "succeeded":
            self = .succeeded
        default:
            return nil
        }
    }
}

/// The fixed, app-owned bridge between a page's WebAuthn call and Kestrel.
///
/// The script is a constant: no page text, selector or model output is ever
/// interpolated into it, and it never reads page content. It only wraps
/// `navigator.credentials.create`/`get` so Kestrel learns that a passkey
/// attempt happened, and it returns the original promise untouched so the
/// page's own error handling still runs.
enum PasskeyHandoffBridge {
    static let messageName = "kestrelPasskey"

    static let scriptSource = #"""
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kestrelPasskey;
      if (!bridge || !navigator.credentials) { return; }
      var latestAttempt = 0;
      function notify(reason) {
        try { bridge.postMessage({ reason: reason }); } catch (e) {}
      }
      function platformUnavailable(done) {
        try {
          var credential = window.PublicKeyCredential;
          if (!credential || typeof credential.isUserVerifyingPlatformAuthenticatorAvailable !== "function") {
            done(false);
            return;
          }
          credential.isUserVerifyingPlatformAuthenticatorAvailable().then(
            function (available) { done(available === false); },
            function () { done(false); }
          );
        } catch (e) {
          done(false);
        }
      }
      function watch(name) {
        var original = navigator.credentials[name];
        if (typeof original !== "function") { return; }
        navigator.credentials[name] = function (options) {
          var result = original.apply(this, arguments);
          var isPasskey = !!(options && options.publicKey);
          // Conditional mediation is a passive autofill hint the site raises
          // on load. Never show a hand-off for this passive request.
          var conditional = !!(options && options.mediation === "conditional");
          if (isPasskey && !conditional) {
            var attempt = ++latestAttempt;
            if (result && typeof result.then === "function") {
              result.then(function () {
                if (attempt === latestAttempt) { notify("succeeded"); }
              }, function (error) {
                // Abort is not a capability failure. NotAllowedError also
                // covers user dismissal, so the UI offers a neutral retry
                // rather than claiming Kestrel cannot use this credential.
                if (!error || (error.name !== "NotAllowedError" && error.name !== "NotSupportedError")
                    || (options.signal && options.signal.aborted)) { return; }
                platformUnavailable(function (unavailable) {
                  if (unavailable && attempt === latestAttempt
                      && !(options.signal && options.signal.aborted)) { notify("rejected"); }
                });
              });
            }
          }
          return result;
        };
      }
      watch("get");
      watch("create");
    })();
    """#
}

#if canImport(WebKit)

import WebKit

/// Forwards the injected watcher's message to a callback without retaining the
/// owner that set it up.
final class PasskeyHandoffObserver: NSObject, WKScriptMessageHandler {
    private let report: (PasskeyHandoffSignal) -> Void

    init(report: @escaping (PasskeyHandoffSignal) -> Void) {
        self.report = report
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == PasskeyHandoffBridge.messageName,
              let signal = PasskeyHandoffSignal(messageBody: message.body) else { return }
        report(signal)
    }
}

#endif
