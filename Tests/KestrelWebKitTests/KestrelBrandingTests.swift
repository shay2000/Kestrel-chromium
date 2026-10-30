#if canImport(AppKit) && canImport(SwiftUI)

import AppKit
import XCTest
@testable import KestrelWebKit

final class KestrelBrandingTests: XCTestCase {
    #if SWIFT_PACKAGE
    @MainActor
    func testPackagedAssetsLoadFromTheAppResourcesDirectory() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("KestrelAssets-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Fixture.app")
        let contents = appURL.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.kestrel.assets", "CFBundlePackageType": "APPL", "CFBundleName": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let packagedURL = resources.appendingPathComponent("KestrelWebKit_KestrelWebKit.bundle")
        try manager.copyItem(at: KestrelAssets.bundle.bundleURL, to: packagedURL)
        let application = try XCTUnwrap(Bundle(url: appURL))
        let assets = KestrelAssets.resolve(in: application)
        XCTAssertEqual(assets.bundleURL.standardizedFileURL, packagedURL.standardizedFileURL)
        for name in ["KestrelIconBasic", "KestrelIconDark"] {
            let url = try XCTUnwrap(assets.url(forResource: "icon@2x", withExtension: "png",
                                              subdirectory: "Assets.xcassets/\(name).imageset"))
            XCTAssertNotNil(NSImage(contentsOf: url))
        }
    }
    #endif

    @MainActor
    func testAppearanceChangesUpdateTheRunningAppIcon() throws {
        let defaultsName = "KestrelBrandingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let application = NSApplication.shared
        let originalIcon = application.applicationIconImage
        let originalAppearance = application.appearance
        defer {
            application.appearance = originalAppearance
            application.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let settings = AppSettings(defaults: defaults)
        settings.appearanceMode = .light
        let branding = KestrelBranding(settings: settings, application: application)
        try withExtendedLifetime(branding) {
            try assertIcon(application.applicationIconImage, matchesDark: false)
            settings.appearanceMode = .dark
            try assertIcon(application.applicationIconImage, matchesDark: true)
            settings.appearanceMode = .system
            application.appearance = NSAppearance(named: .aqua)
            try assertIcon(application.applicationIconImage, matchesDark: false)
            application.appearance = NSAppearance(named: .darkAqua)
            try assertIcon(application.applicationIconImage, matchesDark: true)
            settings.appearanceMode = .light
            try assertIcon(application.applicationIconImage, matchesDark: false)
        }
    }

    @MainActor
    private func assertIcon(_ image: NSImage?, matchesDark: Bool,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        // AppKit copies an assigned Dock icon, so compare rendered pixels rather
        // than NSImage object identity.
        func colour(_ image: NSImage?) throws -> NSColor {
            let data = try XCTUnwrap(image?.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                               y: bitmap.pixelsHigh / 5)?.usingColorSpace(.deviceRGB))
        }
        let actual = try colour(image)
        // AppKit may normalise the assigned image's colour profile. These
        // separated ranges identify the approved purple/charcoal surfaces
        // without asserting device-dependent RGB conversions.
        if matchesDark {
            XCTAssertLessThan(actual.redComponent, 0.45, file: file, line: line)
            XCTAssertLessThan(actual.blueComponent, 0.55, file: file, line: line)
        } else {
            XCTAssertGreaterThan(actual.redComponent, 0.6, file: file, line: line)
            XCTAssertGreaterThan(actual.blueComponent, 0.8, file: file, line: line)
        }
    }

    @MainActor
    func testBothIconAppearancesLoadFromTheResourceBundle() throws {
        for isDark in [false, true] {
            let image = try XCTUnwrap(KestrelBranding.image(isDark: isDark))
            XCTAssertFalse(image.isTemplate)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 512)
            XCTAssertEqual(bitmap.pixelsWide, bitmap.pixelsHigh)
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
            let tile = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                                  y: bitmap.pixelsHigh / 5)?.usingColorSpace(.deviceRGB))
            if isDark {
                XCTAssertLessThan(tile.redComponent, 0.45)
                XCTAssertLessThan(tile.blueComponent, 0.5)
            } else {
                XCTAssertGreaterThan(tile.redComponent, 0.6)
                XCTAssertGreaterThan(tile.blueComponent, 0.8)
            }
        }
    }
}

#endif
