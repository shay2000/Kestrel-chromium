import Foundation
import XCTest
@testable import KestrelWebKit

final class ChromiumExtensionCatalogTests: XCTestCase {
    func testEnabledStoreActionUsesLocalizedNameAndSafeIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = String(repeating: "a", count: 32)
        let directory = root.appendingPathComponent("Extensions/\(id)/1.2_0")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
        try write(["name":"__MSG_name__", "version":"1.2", "default_locale":"en", "action":["default_icon":["32":"icon.png"]]], to: directory.appendingPathComponent("manifest.json"))
        try write(["name":["message":"Real installed action"]], to: directory.appendingPathComponent("_locales/en/messages.json"))
        try Data([0,1,2]).write(to: directory.appendingPathComponent("icon.png"))
        try write(["extensions":["settings":[id:["state":1,"disable_reasons":[],"path":"\(id)/1.2_0"]]]], to: root.appendingPathComponent("Preferences"))
        let result = try ChromiumExtensionCatalog.read(profile: root, languages: ["en-GB"])
        XCTAssertEqual(result.map(\.id), [id])
        XCTAssertEqual(result.first?.name, "Real installed action")
        XCTAssertEqual(result.first?.iconURL?.lastPathComponent, "icon.png")
        XCTAssertEqual(result.first?.hasAction, true)
    }

    func testDisabledAndEscapingEntriesCannotBecomeShortcuts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = String(repeating: "b", count: 32)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write(["name":"Outside profile", "version":"1", "action":[:]], to: outside.appendingPathComponent("manifest.json"))
        try write(["extensions":["settings":[id:["state":1,"path":outside.path]]]], to: root.appendingPathComponent("Preferences"))
        XCTAssertTrue(try ChromiumExtensionCatalog.read(profile: root).isEmpty)
        XCTAssertEqual(try ChromiumExtensionCatalog.read(profile: root, approvedDirectories: [outside]).count, 1)
        try write(["extensions":["settings":[id:["state":1,"disable_reasons":[2],"path":outside.path]]]], to: root.appendingPathComponent("Preferences"))
        XCTAssertTrue(try ChromiumExtensionCatalog.read(profile: root, approvedDirectories: [outside]).isEmpty)
    }

    func testSecurePreferencesDoNotSilentlyReenableDisabledEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = String(repeating: "c", count: 32)
        try write(["extensions":["settings":[id:["state":1,"path":"\(id)/1_0"]]]], to: root.appendingPathComponent("Preferences"))
        try write(["extensions":["settings":[id:["state":0,"path":"\(id)/1_0"]]]], to: root.appendingPathComponent("Secure Preferences"))
        XCTAssertTrue(try ChromiumExtensionCatalog.read(profile: root).isEmpty)
    }

    func testRuntimeLocalisedNameMatchesTheNativeActionMenu() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = String(repeating: "d", count: 32)
        let directory = root.appendingPathComponent("Extensions/\(id)/1_0")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(["name":"English package name", "version":"1", "action":[:]], to: directory.appendingPathComponent("manifest.json"))
        try write(["extensions":["settings":[id:["state":1,"path":"\(id)/1_0","manifest":["name":"Nom du moteur"]]]]], to: root.appendingPathComponent("Preferences"))
        XCTAssertEqual(try ChromiumExtensionCatalog.read(profile: root, languages: ["en-GB"]).first?.name, "Nom du moteur")
    }

    private func write(_ value: [String:Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: file)
    }
}
