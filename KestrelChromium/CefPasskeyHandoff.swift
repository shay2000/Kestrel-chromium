#if canImport(CefKit) && canImport(CefSwiftUI)

import CefKit
import CefSwiftUI
import Foundation

/// Reports only whether a page's WebAuthn operation succeeded or whether the
/// platform authenticator appears unavailable. No credential data crosses the
/// bridge.
@MainActor
final class CefPasskeyHandoff {
    static let shared = CefPasskeyHandoff()

    private struct Signal: Decodable, Sendable {
        let tabID: String
        let reason: String
    }
    private struct Acknowledgement: Encodable, Sendable { let received: Bool }
    private struct WeakStore { weak var value: BrowserStore? }

    private var stores: [UUID: WeakStore] = [:]
    private var isInstalled = false

    private init() {}

    func installBridge() {
        guard !isInstalled else { return }
        isInstalled = true
        CefRuntime.shared.bridge.register("kestrel_passkey_signal") { [weak self] (signal: Signal) async throws -> Acknowledgement in
            await self?.receive(signal)
            return Acknowledgement(received: true)
        }
    }

    func attach(_ store: BrowserStore, tabID: UUID) {
        stores[tabID] = WeakStore(value: store)
    }

    func detach(tabID: UUID) { stores[tabID] = nil }

    private func receive(_ signal: Signal) {
        guard let id = UUID(uuidString: signal.tabID), let store = stores[id]?.value else { return }
        switch signal.reason {
        case "rejected": store.reportPasskeyHandoffNeeded()
        case "succeeded": store.dismissBrowserHandoff()
        default: break
        }
    }

    static func watcherScript(tabID: UUID) -> String {
        let id = JavaScriptStringLiteral.escape(tabID.uuidString)
        return """
        (function () {
          var tabID = \(id);
          if (window.__kestrelPasskeyWatcherInstalled || !navigator.credentials) return;
          function install() {
            if (!window.cefSwift || typeof window.cefSwift.invoke !== 'function') {
              install.attempts = (install.attempts || 0) + 1;
              if (window.setTimeout && install.attempts < 50) window.setTimeout(install, 100);
              return;
            }
            if (window.__kestrelPasskeyWatcherInstalled) return;
            window.__kestrelPasskeyWatcherInstalled = true;
            var latestAttempt = 0;
            function notify(reason) {
              try { window.cefSwift.invoke('kestrel_passkey_signal', { tabID: tabID, reason: reason }).catch(function () {}); } catch (e) {}
            }
            function platformUnavailable(done) {
              try {
                var credential = window.PublicKeyCredential;
                if (!credential || typeof credential.isUserVerifyingPlatformAuthenticatorAvailable !== 'function') { done(false); return; }
                credential.isUserVerifyingPlatformAuthenticatorAvailable().then(
                  function (available) { done(available === false); }, function () { done(false); }
                );
              } catch (e) { done(false); }
            }
            ['get', 'create'].forEach(function (name) {
              var original = navigator.credentials[name];
              if (typeof original !== 'function') return;
              try {
                navigator.credentials[name] = function (options) {
                  var result = original.apply(this, arguments);
                  var isPasskey = !!(options && options.publicKey);
                  var conditional = !!(options && options.mediation === 'conditional');
                  if (isPasskey && !conditional && result && typeof result.then === 'function') {
                    var attempt = ++latestAttempt;
                    result.then(function () {
                      if (attempt === latestAttempt) notify('succeeded');
                    }, function (error) {
                      if (!error || (error.name !== 'NotAllowedError' && error.name !== 'NotSupportedError')
                          || (options.signal && options.signal.aborted)) return;
                      platformUnavailable(function (unavailable) {
                        if (unavailable && attempt === latestAttempt
                            && !(options.signal && options.signal.aborted)) notify('rejected');
                      });
                    });
                  }
                  return result;
                };
              } catch (e) {}
            });
          }
          install();
        })();
        """
    }
}

#endif
