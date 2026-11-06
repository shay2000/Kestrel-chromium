import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The shipped WebKit app stored preferences in its App Sandbox container.
/// Chromium uses its own preferences domain; migrate transcripts without
/// overwriting new chats or copying browser data, credentials or opt-ins.
enum LegacyAssistantArchiveMigration {
    static let archiveKey = "kestrel.assistant.conversations.v1"
    static let maximumPreferencesBytes = 8 * 1024 * 1024
    static let maximumArchiveBytes = 4 * 1024 * 1024

    static func preferencesURL(accountHome: URL) -> URL {
        accountHome.appendingPathComponent("Library/Containers/com.shayprasad.Kestrel/Data/Library/Preferences/com.shayprasad.Kestrel.plist")
    }

    @discardableResult
    static func importIfNeeded(defaults: UserDefaults, from url: URL) -> Bool {
        // An encoded empty array is the user's deliberate deletion, not an
        // invitation to restore old chats. Preserve any existing value.
        guard defaults.object(forKey: archiveKey) == nil else { return false }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_size >= 0,
              metadata.st_size <= Int64(maximumPreferencesBytes),
              let data = try? file.read(upToCount: maximumPreferencesBytes + 1),
              data.count <= maximumPreferencesBytes,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archive = values[archiveKey] as? Data, archive.count <= maximumArchiveBytes,
              let conversations = try? JSONDecoder().decode([AssistantConversation].self, from: archive),
              let encoded = try? JSONEncoder().encode(conversations),
              encoded.count <= maximumArchiveBytes else { return false }
        // Re-encoding the transcript schema drops unknown legacy fields and
        // AIMessage attachments. AIChatStore applies its normal archive bounds
        // and message policy immediately after this startup import.
        defaults.set(encoded, forKey: archiveKey)
        return true
    }
}
