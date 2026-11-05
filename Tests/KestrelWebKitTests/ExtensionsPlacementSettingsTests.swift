import Foundation
import XCTest
@testable import KestrelWebKit

final class ExtensionsPlacementSettingsTests: XCTestCase {
    func testLegacySettingsKeepMenuAndImportChoicesWithSafePlacementDefaults() throws {
        let settings = try JSONDecoder().decode(ExtensionsSettings.self,
            from: Data(#"{"menuBarVisible":false,"allowsUnpackedImports":true}"#.utf8))
        XCTAssertFalse(settings.menuBarVisible)
        XCTAssertTrue(settings.allowsUnpackedImports)
        XCTAssertTrue(settings.toolbarActionsVisible)
        XCTAssertFalse(settings.sidebarActionsVisible)
        XCTAssertNil(settings.sidebarActionIDs)
    }

    func testIndependentPlacementAndExplicitSelectionSurviveRoundTrip() throws {
        let first = String(repeating: "a", count: 32), second = String(repeating: "b", count: 32)
        var settings = ExtensionsSettings(menuBarVisible: true, allowsUnpackedImports: false,
            toolbarActionsVisible: false, sidebarActionsVisible: true)
        settings.setSidebarAction(first, visible: false, availableIDs: [first, second])
        XCTAssertFalse(settings.showsSidebarAction(first))
        XCTAssertTrue(settings.showsSidebarAction(second))
        let decoded = try JSONDecoder().decode(ExtensionsSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.toolbarActionsVisible)
        XCTAssertTrue(decoded.sidebarActionsVisible)
        settings.setSidebarAction(second, visible: false, availableIDs: [first, second])
        XCTAssertEqual(settings.sidebarActionIDs, [])
        XCTAssertFalse(settings.showsSidebarAction(first))
    }

    func testInvalidAndDuplicateIDsDoNotBecomeActionDestinations() {
        let valid = String(repeating: "c", count: 32)
        let settings = ExtensionsSettings(menuBarVisible: true, allowsUnpackedImports: false,
            sidebarActionIDs: [valid, "../profile", "https://example.com", String(repeating: "z", count: 32), valid])
        XCTAssertEqual(settings.sidebarActionIDs, [valid])
    }
}
