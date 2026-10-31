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
    /// The Chromium runtime is unavailable on this platform.
    case unsupported
    /// Chromium is present, but Kestrel's extension import flow is not enabled.
    case limited
    /// The Chromium runtime and user-approved extension import flow are wired.
    case available

    var description: String {
        switch self {
        case .unsupported:
            return "The Chromium extension runtime is unavailable on this platform."
        case .limited:
            return "Chromium is available, but extension imports are not enabled in this build."
        case .available:
            return "Kestrel uses Chromium's Chrome runtime. It reviews Manifest V3 extension permissions before loading unpacked, ZIP or CRX packages. Approved extensions load when Kestrel starts; Chromium manages their runtime and site access."
        }
    }
}

/// The single boundary that answers one question honestly: what can Kestrel
/// actually do on this machine with public APIs only?
enum ExtensionSupport {
    static let minimumMacOSVersion = "14.0"

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
        #if canImport(CefKit)
        return .available
        #else
        return .unsupported
        #endif
    }

    static var statusDescription: String {
        supportLevel().description
    }

    /// CEF can load approved unpacked extension directories.
    static var supportsUnpackedWebExtensionDirectories: Bool {
        #if canImport(CefKit)
        return true
        #endif
        return false
    }

    /// CEF's Chrome runtime can load packages extracted from a standard ZIP.
    static var supportsZIPArchiveImport: Bool {
        #if canImport(CefKit)
        return true
        #endif
        return false
    }

    static var supportsChromiumCRXImport: Bool {
        #if canImport(CefKit)
        return true
        #else
        return false
        #endif
    }

    static let chromiumCRXRejectionReason =
        "Kestrel could not read this Chromium extension package."

    static let unsupportedFormatRejectionReason =
        "Kestrel can only load an unpacked WebExtension directory, ZIP archive or Chromium CRX package."
}

// MARK: - Package classification

/// What kind of local package the user pointed Kestrel at.
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

/// The import decision for a package kind.
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
        case .directory, .zipArchive, .chromiumCRX:
            return .loadable
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
