import XCTest

@testable import KestrelWebKit

/// These tests lock in the honesty and the platform-neutral decisions of
/// Kestrel's extension support. They never import WebKit, so they run on Linux
/// as well as macOS. The WebKit-backed `BrowserExtensionHost` is availability
/// gated and is not exercised here.
final class ExtensionsSupportTests: XCTestCase {

    /// Mirrors the boundary `ExtensionSupport` reports, so these tests stay
    /// honest on Linux and on macOS 14 without importing WebKit.
    private var hasPublicWebKitExtensionAPI: Bool {
        #if canImport(WebKit)
        if #available(macOS 15.4, *) { return true }
        return false
        #else
        return false
        #endif
    }

    // MARK: - Capability reporting

    func testChromiumCRXImportIsNeverClaimed() {
        XCTAssertFalse(ExtensionSupport.supportsChromiumCRXImport)
    }

    func testUnpackedDirectoryCapabilityTracksThePublicAPI() {
        XCTAssertEqual(
            ExtensionSupport.supportsUnpackedWebExtensionDirectories,
            hasPublicWebKitExtensionAPI
        )
    }

    func testZIPArchiveCapabilityTracksThePublicAPI() {
        XCTAssertEqual(ExtensionSupport.supportsZIPArchiveImport, hasPublicWebKitExtensionAPI)
    }

    func testPermissionsAreNeverGrantedOnImport() {
        XCTAssertFalse(ExtensionSupport.grantsPermissionsOnImport)
    }

    func testExplicitApprovalIsAlwaysRequired() {
        XCTAssertTrue(ExtensionSupport.requiresExplicitPermissionApproval)
        XCTAssertFalse(ExtensionSupport.grantsPermissionsOnImport)
    }

    func testSupportLevelIsAvailableOnlyWithThePublicAPI() {
        if hasPublicWebKitExtensionAPI {
            XCTAssertEqual(ExtensionSupport.supportLevel(), .available)
        } else {
            XCTAssertNotEqual(ExtensionSupport.supportLevel(), .available)
            XCTAssertEqual(ExtensionSupport.supportLevel(), .unsupported)
        }
    }

    func testSupportLevelDescriptionIsNonEmptyAndHonest() {
        let description = ExtensionSupport.statusDescription
        XCTAssertFalse(description.isEmpty)
        XCTAssertFalse(description.lowercased().contains("crx import is implemented"))
        XCTAssertFalse(description.lowercased().contains("full chromium"))
    }

    func testAvailableDescriptionNeverPromisesChromiumCRX() {
        XCTAssertFalse(ExtensionSupportLevel.available.description.lowercased().contains("crx package is supported"))
        XCTAssertTrue(ExtensionSupportLevel.available.description.lowercased().contains("crx"))
    }

    func testMinimumVersionRecordsThePublicAPIRelease() {
        XCTAssertEqual(ExtensionSupport.minimumMacOSVersion, "15.4")
    }

    func testDefaultSettingsDoNotEnableUnpackedImports() {
        XCTAssertFalse(ExtensionsSettings.default.allowsUnpackedImports)
    }

    // MARK: - Package classification

    func testDirectoryKindUsesFileSystemTruth() {
        let url = URL(fileURLWithPath: "/tmp/example-extension", isDirectory: true)
        XCTAssertEqual(ExtensionPackageClassifier.kind(for: url, isDirectory: true), .directory)
    }

    func testZIPArchiveKindIsRecognised() {
        let url = URL(fileURLWithPath: "/tmp/example-extension.zip")
        XCTAssertEqual(ExtensionPackageClassifier.kind(for: url, isDirectory: false), .zipArchive)
    }

    func testUpperCasedZIPExtensionIsRecognised() {
        let url = URL(fileURLWithPath: "/tmp/example-extension.ZIP")
        XCTAssertEqual(ExtensionPackageClassifier.kind(for: url, isDirectory: false), .zipArchive)
    }

    func testChromiumCRXKindIsRecognisedButNotLoadable() {
        let url = URL(fileURLWithPath: "/tmp/example-extension.crx")
        XCTAssertEqual(ExtensionPackageClassifier.kind(for: url, isDirectory: false), .chromiumCRX)
        XCTAssertFalse(ExtensionPackageDecision.forKind(.chromiumCRX).isLoadable)
    }

    func testUnknownFormatsAreNotLoadable() {
        let url = URL(fileURLWithPath: "/tmp/example-extension.tar.gz")
        XCTAssertEqual(ExtensionPackageClassifier.kind(for: url, isDirectory: false), .unsupported)
        XCTAssertFalse(ExtensionPackageDecision.forKind(.unsupported).isLoadable)
    }

    // MARK: - Import decisions

    func testPublicAPIAcceptsUnpackedDirectoriesAndZIPArchives() {
        XCTAssertTrue(ExtensionPackageDecision.forKind(.directory).isLoadable)
        XCTAssertTrue(ExtensionPackageDecision.forKind(.zipArchive).isLoadable)
        XCTAssertNil(ExtensionPackageDecision.forKind(.zipArchive).rejectionReason)
    }

    func testRejectionsCarryAReason() {
        for kind in [ExtensionPackageKind.chromiumCRX, .unsupported] {
            let decision = ExtensionPackageDecision.forKind(kind)
            XCTAssertFalse(decision.isLoadable)
            XCTAssertEqual(decision.rejectionReason?.isEmpty, false)
        }
    }

    // MARK: - Pending permissions

    func testEmptyPendingPermissionsSummariseHonestly() {
        XCTAssertTrue(PendingExtensionPermissions.none.isEmpty)
        XCTAssertEqual(PendingExtensionPermissions.none.count, 0)
        XCTAssertTrue(PendingExtensionPermissions.none.summary.contains("does not request any permissions"))
    }

    func testPendingPermissionsReportPermissionsAndHostPatterns() {
        let pending = PendingExtensionPermissions(
            permissions: ["storage", "tabs"],
            hostPatterns: ["https://example.com/*"]
        )
        XCTAssertFalse(pending.isEmpty)
        XCTAssertEqual(pending.count, 3)
        XCTAssertTrue(pending.summary.contains("storage"))
        XCTAssertTrue(pending.summary.contains("https://example.com/*"))
        XCTAssertTrue(pending.summary.contains("approval"))
    }

    // MARK: - Install resolutions

    func testPendingApprovalAwaitsApprovalAndExposesPreview() {
        let preview = ExtensionInstallPreview(
            id: UUID(),
            displayName: "Example",
            version: "1.0",
            packageKind: .directory,
            requested: PendingExtensionPermissions(permissions: ["storage"], hostPatterns: []),
            warnings: []
        )
        let resolution = ExtensionInstallResolution.pendingApproval(preview)
        XCTAssertTrue(resolution.awaitsApproval)
        XCTAssertEqual(resolution.preview, preview)
        XCTAssertNil(resolution.failureReason)
    }

    func testRejectedAndUnsupportedResolutionsDoNotAwaitApproval() {
        let rejected = ExtensionInstallResolution.rejected(reason: "bad manifest")
        XCTAssertFalse(rejected.awaitsApproval)
        XCTAssertNil(rejected.preview)
        XCTAssertEqual(rejected.failureReason, "bad manifest")

        let unsupported = ExtensionInstallResolution.unsupported(reason: "macOS 14")
        XCTAssertFalse(unsupported.awaitsApproval)
        XCTAssertEqual(unsupported.failureReason, "macOS 14")
    }
}
