import Foundation

// MARK: - Settings

/// Settings for Kestrel's extension capability. The menu-bar toggle is a
/// Kestrel-side preference: when it is off, Kestrel does not build an
/// Extensions command menu at all. Nothing here touches the global macOS menu
/// bar, which would need private APIs.
struct ExtensionsSettings: Codable, Equatable, Sendable {
    /// Whether Kestrel draws its own Extensions command menu beside File/Edit.
    var menuBarVisible: Bool
    /// Whether the user may point Kestrel at a local extension package. Kept
    /// separate from the menu toggle so the menu can be hidden while the
    /// capability stays available.
    var allowsUnpackedImports: Bool

    static let `default` = ExtensionsSettings(menuBarVisible: true, allowsUnpackedImports: false)
}

// MARK: - Capability reporting

enum ExtensionSupportLevel: String, Codable, Sendable {
    /// No public WebKit extension API on this machine.
    case unsupported
    /// The public API exists, but Kestrel's user-facing import flow is not
    /// enabled on this build or platform.
    case limited
    /// The public API exists and a safe, user-approved import flow is wired.
    case available

    var description: String {
        switch self {
        case .unsupported:
            return "Extensions are unavailable. Kestrel targets macOS 14, while the public WKWebExtension API begins in macOS 15.4."
        case .limited:
            return "WKWebExtension is available on this macOS version, but Kestrel's import flow is not enabled on this build. Chromium CRX packages are not supported."
        case .available:
            return "Extensions are available on this macOS version. Kestrel can import an unpacked WebExtension directory or a standard ZIP archive, show every requested API permission and host pattern, and load only what you explicitly tick. Chromium-origin WebExtensions may work where WebKit supports the APIs they use; nothing is granted automatically, and Chromium CRX packages are not supported."
        }
    }
}

/// The single boundary that answers one question honestly: what can Kestrel
/// actually do on this machine with public APIs only?
enum ExtensionSupport {
    /// The macOS release where `WKWebExtension` and `WKWebExtensionController`
    /// became publicly usable. Documented here so the baseline gap is explicit.
    static let minimumMacOSVersion = "15.4"

    /// Kestrel never grants an extension's requested permissions on import.
    /// Every permission and host pattern needs an explicit approval before a
    /// context is loaded.
    static let grantsPermissionsOnImport = false

    /// Kestrel's Settings flow stages a package, lists every requested
    /// permission and host pattern with all choices off, and loads the
    /// extension only when the user presses the approval button. This is a
    /// statement about Kestrel's code rather than the host OS, so it can be
    /// asserted on Linux without importing WebKit.
    static let requiresExplicitPermissionApproval = true

    static func supportLevel() -> ExtensionSupportLevel {
        #if canImport(WebKit)
        if #available(macOS 15.4, *) {
            // The public API exists and Settings wires the file importer plus
            // the explicit approval sheet, so the safe import flow is complete.
            return .available
        }
        return .unsupported
        #else
        return .unsupported
        #endif
    }

    static var statusDescription: String {
        supportLevel().description
    }

    /// True only where the public `WKWebExtension` API exists (macOS 15.4+),
    /// because that is where Settings offers the unpacked-directory importer.
    static var supportsUnpackedWebExtensionDirectories: Bool {
        #if canImport(WebKit)
        if #available(macOS 15.4, *) { return true }
        #endif
        return false
    }

    /// True only where the public `WKWebExtension` API exists (macOS 15.4+),
    /// because that is where Settings offers the standard ZIP importer.
    static var supportsZIPArchiveImport: Bool {
        #if canImport(WebKit)
        if #available(macOS 15.4, *) { return true }
        #endif
        return false
    }

    /// Deliberately false: there is no public API for Chromium CRX packages
    /// and Kestrel does not ship an unpacker or a Chromium runtime.
    static var supportsChromiumCRXImport: Bool {
        false
    }

    static let chromiumCRXRejectionReason =
        "Chromium CRX packages are not supported by the public WKWebExtension API. Ask the extension's author for an unpacked directory or a standard ZIP archive."

    static let unsupportedFormatRejectionReason =
        "Kestrel can only load an unpacked WebExtension directory or a standard ZIP archive that contains manifest.json."
}

// MARK: - Package classification

/// What kind of local package the user pointed Kestrel at. This is decided by
/// name and file-system kind only; WebKit performs the real manifest
/// validation after a package is accepted for loading.
enum ExtensionPackageKind: String, Equatable, Sendable {
    case directory
    case zipArchive
    case chromiumCRX
    case unsupported
}

enum ExtensionPackageClassifier {
    /// Classifies a local URL. `isDirectory` comes from the caller's
    /// file-system check so this function stays pure and testable.
    static func kind(for url: URL, isDirectory: Bool) -> ExtensionPackageKind {
        if isDirectory {
            return .directory
        }
        switch url.pathExtension.lowercased() {
        case "zip":
            return .zipArchive
        case "crx":
            return .chromiumCRX
        default:
            return .unsupported
        }
    }
}

/// The import decision for a package kind. Chromium CRX and unknown formats
/// are rejected before WebKit is asked to parse anything.
enum ExtensionPackageDecision: Equatable, Sendable {
    case loadable
    case unsupportedFormat(reason: String)

    var isLoadable: Bool {
        if case .loadable = self { return true }
        return false
    }

    var rejectionReason: String? {
        if case .unsupportedFormat(let reason) = self { return reason }
        return nil
    }

    static func forKind(_ kind: ExtensionPackageKind) -> ExtensionPackageDecision {
        switch kind {
        case .directory, .zipArchive:
            return .loadable
        case .chromiumCRX:
            return .unsupportedFormat(reason: ExtensionSupport.chromiumCRXRejectionReason)
        case .unsupported:
            return .unsupportedFormat(reason: ExtensionSupport.unsupportedFormatRejectionReason)
        }
    }
}

// MARK: - Install and permission models

/// What a staged extension asks for. The lists are raw manifest values so they
/// can be shown to the user and matched against an explicit approval without
/// importing WebKit on this side of the boundary.
struct PendingExtensionPermissions: Equatable, Sendable {
    var permissions: [String]
    var hostPatterns: [String]

    static let none = PendingExtensionPermissions(permissions: [], hostPatterns: [])

    var isEmpty: Bool {
        permissions.isEmpty && hostPatterns.isEmpty
    }

    var count: Int {
        permissions.count + hostPatterns.count
    }

    var summary: String {
        if isEmpty {
            return "This extension does not request any permissions."
        }
        var parts: [String] = []
        if !permissions.isEmpty {
            parts.append("permissions: \(permissions.joined(separator: ", "))")
        }
        if !hostPatterns.isEmpty {
            parts.append("site access: \(hostPatterns.joined(separator: ", "))")
        }
        return "Waiting for your approval — " + parts.joined(separator: "; ") + "."
    }
}

/// A validated extension that is ready to load once the user approves the
/// permissions it asked for.
struct ExtensionInstallPreview: Equatable, Sendable, Identifiable {
    var id: UUID
    var displayName: String
    var version: String?
    var packageKind: ExtensionPackageKind
    var requested: PendingExtensionPermissions
    var warnings: [String]
}

/// The outcome of staging a local package. `pendingApproval` is the only
/// success case and it never means the extension is running.
enum ExtensionInstallResolution: Equatable, Sendable {
    case unsupported(reason: String)
    case rejected(reason: String)
    case pendingApproval(ExtensionInstallPreview)

    var awaitsApproval: Bool {
        if case .pendingApproval = self { return true }
        return false
    }

    var preview: ExtensionInstallPreview? {
        if case .pendingApproval(let preview) = self { return preview }
        return nil
    }

    var failureReason: String? {
        switch self {
        case .unsupported(let reason), .rejected(let reason):
            return reason
        case .pendingApproval:
            return nil
        }
    }
}
