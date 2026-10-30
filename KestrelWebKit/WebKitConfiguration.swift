#if canImport(WebKit)

import WebKit

/// The single boundary where Kestrel chooses how WebKit pages are configured.
/// Keeping this separate makes tabs, private browsing and future policy work
/// possible without spreading WebKit setup across SwiftUI views.
enum KestrelWebKitConfiguration {
    /// Kestrel's baseline engine preferences, without any extension
    /// association. Used on macOS 14 and as the basis for the extension
    /// controller's own web-view configuration.
    static func baseConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // Hide page-provided scrollbars without disabling scroll gestures. The
        // native NSScrollView scroller can reappear after WebKit navigation, so
        // enforce this at document start for the main page and its frames too.
        let hidePageScrollbars = WKUserScript(
            source: """
            (() => {
              const style = document.createElement("style");
              style.textContent = "html { scrollbar-width: none !important; } *::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }";
              const install = () => (document.head || document.documentElement)?.appendChild(style);
              if (document.documentElement) install();
              else document.addEventListener("DOMContentLoaded", install, { once: true });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(hidePageScrollbars)
        // WKWebView's default UA omits Safari's compatibility token, so Google
        // and similar desktop sites can serve an unstyled fallback. Preserve
        // WebKit's engine identity while supplying the standard Safari tokens.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return configuration
    }

    /// The configuration every browser tab is built from.
    ///
    /// On macOS 15.4 and later this is derived from the shared
    /// `BrowserExtensionHost` controller, so loaded extension content scripts
    /// can attach to normal tabs. On macOS 14 the plain baseline is returned.
    /// The AI operator never receives extension data or secrets.
    @MainActor
    static func make() -> WKWebViewConfiguration {
        if #available(macOS 15.4, *) {
            return BrowserExtensionHost.shared.makeWebViewConfiguration()
        }
        return baseConfiguration()
    }
}

#endif
