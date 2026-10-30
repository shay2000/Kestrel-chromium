#if canImport(WebKit)

import Foundation
import WebKit

/// The single owner of Kestrel's `WKWebExtensionController`.
///
/// The public `WKWebExtension` API first appears in macOS 15.4, so this type is
/// only usable from that release. The rest of Kestrel still deploys to macOS 14
/// and reaches it only through an availability check in
/// `KestrelWebKitConfiguration`.
///
/// Responsibilities:
/// - own exactly one `WKWebExtensionController`;
/// - hand every browser `WKWebView` a configuration based on the controller's
///   configured web-view configuration, so loaded content scripts can attach;
/// - validate a local directory or ZIP archive through `WKWebExtension`;
/// - stage the requested permissions and load nothing until the caller
///   explicitly approves them.
///
/// Kestrel deliberately does not implement `WKWebExtensionControllerDelegate`.
/// Runtime permission prompts and window/tab requests therefore remain
/// unsupported rather than being silently granted. The explicit install sheet
/// handles initial permissions; delegate-backed runtime requests are a later
/// capability, not an implicit permission escalation.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensionHost {
    /// The app-wide instance. Creating it is cheap and it is built with the
    /// first tab's web-view configuration.
    static let shared = BrowserExtensionHost()

    /// The one extension controller every browser tab is associated with.
    let controller: WKWebExtensionController

    private struct StagedExtension {
        let webExtension: WKWebExtension
        let context: WKWebExtensionContext
        let preview: ExtensionInstallPreview
    }

    /// Validated packages waiting for permission approval. They are not loaded
    /// and are not visible to any web view yet.
    private var staged: [UUID: StagedExtension] = [:]

    private init() {
        let configuration = WKWebExtensionController.Configuration.default()
        // This is the basis for extension web views and for the app's own tab
        // web views, so Kestrel's engine preferences and the controller
        // association travel together.
        configuration.webViewConfiguration = KestrelWebKitConfiguration.baseConfiguration()
        controller = WKWebExtensionController(configuration: configuration)
    }

    /// A fresh web-view configuration for a Kestrel tab. It is derived from the
    /// controller's configured web-view configuration and is explicitly
    /// associated with the controller so content scripts inject into the page.
    ///
    /// WebKit copies the outer configuration but retains its user-content
    /// controller. Give each tab a fresh controller, preserving baseline
    /// scripts, so its message handlers cannot collide with another tab's.
    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let source = controller.configuration.webViewConfiguration
            ?? KestrelWebKitConfiguration.baseConfiguration()
        let configuration = (source.copy() as? WKWebViewConfiguration)
            ?? KestrelWebKitConfiguration.baseConfiguration()
        let content = WKUserContentController()
        source.userContentController.userScripts.forEach(content.addUserScript)
        configuration.userContentController = content
        configuration.webExtensionController = controller
        return configuration
    }

    // MARK: - Staged install

    /// Validates a local extension directory or ZIP archive with the public
    /// API. The manifest is parsed by `WKWebExtension`, which also surfaces
    /// parse-time errors. Success is a `pendingApproval` result: nothing is
    /// granted and nothing is loaded.
    func stage(url: URL) async -> ExtensionInstallResolution {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .rejected(reason: "That file or folder could not be found.")
        }

        let kind = ExtensionPackageClassifier.kind(for: url, isDirectory: isDirectory.boolValue)
        let decision = ExtensionPackageDecision.forKind(kind)
        guard decision.isLoadable else {
            return .rejected(reason: decision.rejectionReason ?? ExtensionSupport.unsupportedFormatRejectionReason)
        }

        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: url)
            let preview = Self.preview(for: webExtension, kind: kind)
            let context = WKWebExtensionContext(for: webExtension)
            staged[preview.id] = StagedExtension(webExtension: webExtension, context: context, preview: preview)
            return .pendingApproval(preview)
        } catch {
            return .rejected(reason: Self.message(for: error))
        }
    }

    /// Loads a staged extension, granting only the permissions and host
    /// patterns the caller lists. Every other requested item is explicitly
    /// denied so an unchecked approval cannot remain in WebKit's unknown state.
    /// There is no implicit or "approve all" path.
    @discardableResult
    func approve(
        id: UUID,
        granting permissions: Set<String>,
        hostPatterns: Set<String>
    ) throws -> ExtensionInstallPreview {
        guard let staged = staged[id] else {
            throw BrowserExtensionHostError.notStaged
        }

        for permission in staged.webExtension.requestedPermissions {
            let status: WKWebExtensionContext.PermissionStatus = permissions.contains(permission.rawValue)
                ? .grantedExplicitly
                : .deniedExplicitly
            staged.context.setPermissionStatus(status, for: permission)
        }
        for pattern in staged.webExtension.allRequestedMatchPatterns {
            let status: WKWebExtensionContext.PermissionStatus = hostPatterns.contains(pattern.string)
                ? .grantedExplicitly
                : .deniedExplicitly
            staged.context.setPermissionStatus(status, for: pattern)
        }

        try controller.load(staged.context)
        self.staged[id] = nil
        return staged.preview
    }

    /// Forgets a staged package without loading it.
    func discard(id: UUID) {
        staged[id] = nil
    }

    // MARK: - Helpers

    private static func preview(for webExtension: WKWebExtension, kind: ExtensionPackageKind) -> ExtensionInstallPreview {
        let permissions = webExtension.requestedPermissions.map { $0.rawValue }.sorted()
        // Include content-script/message match patterns as well as manifest
        // host permissions. Using only requestedPermissionMatchPatterns would
        // make an extension with content_scripts.matches appear approved while
        // silently preventing those scripts from being injected.
        let patterns = webExtension.allRequestedMatchPatterns.map { $0.string }.sorted()
        let warnings = webExtension.errors.map { $0.localizedDescription }
        return ExtensionInstallPreview(
            id: UUID(),
            displayName: webExtension.displayName ?? "Unnamed extension",
            version: webExtension.displayVersion,
            packageKind: kind,
            requested: PendingExtensionPermissions(permissions: permissions, hostPatterns: patterns),
            warnings: warnings
        )
    }

    private static func message(for error: Error) -> String {
        guard let extensionError = error as? WKWebExtension.Error else {
            return error.localizedDescription
        }
        switch extensionError.code {
        case .invalidManifest:
            return "The extension's manifest.json is missing or invalid."
        case .unsupportedManifestVersion:
            return "The extension's manifest version is not supported."
        case .invalidManifestEntry:
            return "The extension's manifest contains an invalid entry."
        case .invalidArchive:
            return "The archive is invalid or corrupt."
        case .resourceNotFound:
            return "The extension's resources could not be found."
        case .invalidResourceCodeSignature:
            return "An extension resource failed its code-signature check."
        default:
            return error.localizedDescription
        }
    }
}

enum BrowserExtensionHostError: LocalizedError {
    case notStaged

    var errorDescription: String? {
        switch self {
        case .notStaged:
            return "That extension is no longer staged for approval."
        }
    }
}

#endif
