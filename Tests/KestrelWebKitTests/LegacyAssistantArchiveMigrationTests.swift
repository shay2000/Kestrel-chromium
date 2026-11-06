import Foundation
import XCTest
@testable import KestrelWebKit

final class LegacyAssistantArchiveMigrationTests: XCTestCase {
    private func fixture(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "kestrel.legacy-archive-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(defaults, directory.appendingPathComponent("legacy.plist"))
    }

    private func archive() throws -> Data {
        try JSONEncoder().encode([AssistantConversation(title: "Legacy saved chat", messages: [
            AIMessage(role: .user, text: "Synthetic archive migration entry.")
        ], updatedAt: Date(timeIntervalSinceReferenceDate: 123456)))
    }

    private func write(_ archive: Data, to url: URL) throws {
        let values: [String: Any] = [
            LegacyAssistantArchiveMigration.archiveKey: archive,
            "kestrel.ai.settings.v1": Data("Unrelated legacy settings".utf8),
            "codexHostHelperEnabled": true
        ]
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: url)
    }

    func testImportsOnlyValidatedTranscriptsAndLeavesTheLegacyFileUntouched() throws {
        try fixture { defaults, url in
            var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: archive()) as? [[String: Any]])
            entries[0]["unknownLegacyField"] = "Must not be copied"
            let original = try JSONSerialization.data(withJSONObject: entries)
            try write(original, to: url)
            let legacyBytes = try Data(contentsOf: url)
            XCTAssertTrue(LegacyAssistantArchiveMigration.importIfNeeded(defaults: defaults, from: url))
            let imported = try XCTUnwrap(defaults.data(forKey: LegacyAssistantArchiveMigration.archiveKey))
            let chats = try JSONDecoder().decode([AssistantConversation].self, from: imported)
            XCTAssertEqual(chats.count, 1)
            XCTAssertEqual(chats[0].messages[0].text, "Synthetic archive migration entry.")
            let copied = try XCTUnwrap(JSONSerialization.jsonObject(with: imported) as? [[String: Any]])
            XCTAssertNil(copied[0]["unknownLegacyField"])
            XCTAssertNil(defaults.object(forKey: "kestrel.ai.settings.v1"))
            XCTAssertNil(defaults.object(forKey: "codexHostHelperEnabled"))
            XCTAssertEqual(try Data(contentsOf: url), legacyBytes)
        }
    }

    func testNeverOverwritesExistingOrIntentionallyDeletedChats() throws {
        try fixture { defaults, url in
            try write(archive(), to: url)
            for current in [Data("[]".utf8), try archive()] {
                defaults.set(current, forKey: LegacyAssistantArchiveMigration.archiveKey)
                XCTAssertFalse(LegacyAssistantArchiveMigration.importIfNeeded(defaults: defaults, from: url))
                XCTAssertEqual(defaults.data(forKey: LegacyAssistantArchiveMigration.archiveKey), current)
            }
        }
    }

    func testMissingAndMalformedPreferencesLeaveTheCurrentStoreAlone() throws {
        try fixture { defaults, url in
            XCTAssertFalse(LegacyAssistantArchiveMigration.importIfNeeded(defaults: defaults, from: url))
            try Data("Not a property list".utf8).write(to: url)
            XCTAssertFalse(LegacyAssistantArchiveMigration.importIfNeeded(defaults: defaults, from: url))
            try write(Data("Not an archive".utf8), to: url)
            XCTAssertFalse(LegacyAssistantArchiveMigration.importIfNeeded(defaults: defaults, from: url))
            XCTAssertNil(defaults.object(forKey: LegacyAssistantArchiveMigration.archiveKey))
        }
    }

    func testRejectsOversizedPreferencesBeforeReadingThem() throws {
        try fixture { defaults, url in
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let file = try FileHandle(forWritingTo: url)
            try file.truncate(atOffset: UInt64(LegacyAssistantArchiveMigration.maximumPreferencesBytes + 1))
            try file.close()
            XCTAssertFalse(LegacyAssistantArchiveMigration.importIfNeeded(defaults: defaults, from: url))
            XCTAssertNil(defaults.object(forKey: LegacyAssistantArchiveMigration.archiveKey))
        }
    }

    func testRejectsSymbolicLinks() throws {
        try fixture { defaults, url in
            let other = url.deletingLastPathComponent().appendingPathComponent("other.plist")
            try write(archive(), to: other)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
            XCTAssertFalse(LegacyAssistantArchiveMigration.importIfNeeded(defaults: defaults, from: url))
            XCTAssertNil(defaults.object(forKey: LegacyAssistantArchiveMigration.archiveKey))
        }
    }
}
