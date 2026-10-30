import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A deliberately small editor for Kestrel's Codex MCP entry. It never
/// invokes a shell or parses unrelated Codex settings into application state.
enum CodexMCPConfigManager {
    static let configurationName = "kestrel"
    static let beginMarker = "# BEGIN Kestrel managed MCP entry"
    static let endMarker = "# END Kestrel managed MCP entry"

    enum Update: Equatable {
        case added
        case updated
        case unchanged
    }

    private struct ManagedEntry {
        let range: Range<Int>
        let originalFinalNewline: Bool
    }

    enum ConfigError: Error, Equatable, LocalizedError {
        case invalidEndpoint
        case missingConfiguration
        case unreadableConfiguration
        case symbolicLinkNotAllowed
        case existingEntry
        case malformedManagedEntry
        case concurrentModification

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "Kestrel could not validate its local MCP address. Turn the local server off and on, then try again."
            case .missingConfiguration:
                return "Codex's config file is not there yet. Open Codex once, then choose Connect Codex again."
            case .unreadableConfiguration:
                return "Kestrel could not safely complete the Codex config update. Check the config file before trying again."
            case .symbolicLinkNotAllowed:
                return "Codex's config file is a symbolic link. Kestrel left it unchanged for safety."
            case .existingEntry:
                return "Codex already has a Kestrel MCP entry that Kestrel did not create. Rename or remove that entry in Codex settings, then try again."
            case .malformedManagedEntry:
                return "Kestrel's managed Codex entry is incomplete or was edited. No changes were made; review the Kestrel entry in Codex's config file."
            case .concurrentModification:
                return "Codex's config changed while Kestrel was preparing the update. No changes were made; try again."
            }
        }
    }

    static var defaultConfigurationURL: URL {
        // Foundation's current home is redirected into the app container.
        // Resolve the account's home for the existing, exact config-file
        // sandbox exception; never inspect other Codex files.
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let accountHome = buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(getuid(), &account, storage.baseAddress!, storage.count, &result) == 0,
                  result != nil, let path = account.pw_dir else { return nil }
            return String(cString: path)
        }
        return URL(fileURLWithPath: accountHome ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// Updates only the managed table, preserving every byte outside that
    /// block at the text level. A pre-existing user-owned `kestrel` entry is
    /// treated as a conflict rather than overwritten.
    static func updatedContents(_ source: String, endpointURL: String) throws -> (contents: String, update: Update) {
        guard isSafeLoopbackEndpoint(endpointURL) else { throw ConfigError.invalidEndpoint }

        let lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
        let lines = source.components(separatedBy: lineEnding)
        let entry = try managedBlockRange(in: lines)

        guard let entry else {
            guard !containsUnmanagedKestrelEntry(lines) else { throw ConfigError.existingEntry }
            let originalFinalNewline = source.hasSuffix(lineEnding)
            let separator = source.isEmpty || originalFinalNewline ? "" : lineEnding
            let block = managedBlock(endpointURL: endpointURL, originalFinalNewline: originalFinalNewline)
            return (source + separator + block.joined(separator: lineEnding) + lineEnding, .added)
        }

        var updatedLines = lines
        updatedLines.replaceSubrange(
            entry.range,
            with: managedBlock(endpointURL: endpointURL, originalFinalNewline: entry.originalFinalNewline)
        )
        let updated = updatedLines.joined(separator: lineEnding)
        return (updated, updated == source ? .unchanged : .updated)
    }

    /// Removes only a complete, canonical Kestrel-managed block. Returns nil
    /// when no managed block exists; user-authored tables are never removed.
    static func contentsRemovingManagedEntry(_ source: String) throws -> String? {
        let lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
        let lines = source.components(separatedBy: lineEnding)
        guard let entry = try managedBlockRange(in: lines) else { return nil }
        var updatedLines = lines
        updatedLines.removeSubrange(entry.range)
        var updated = updatedLines.joined(separator: lineEnding)
        let remainingLinesAfterBlock = lines.dropFirst(entry.range.upperBound)
        if !entry.originalFinalNewline,
           remainingLinesAfterBlock.elementsEqual([""]),
           updated.hasSuffix(lineEnding) {
            updated.removeLast(lineEnding.count)
        }
        return updated
    }

    @discardableResult
    static func connect(endpointURL: String, configurationURL: URL = defaultConfigurationURL) throws -> Update {
        try withLockedConfiguration(at: configurationURL) { descriptor, original in
            guard let source = String(data: original, encoding: .utf8) else {
                throw ConfigError.unreadableConfiguration
            }
            let result = try updatedContents(source, endpointURL: endpointURL)
            guard result.contents != source else { return .unchanged }
            try writeConfiguration(Data(result.contents.utf8), replacing: original, descriptor: descriptor, at: configurationURL)
            return result.update
        }
    }

    @discardableResult
    static func disconnect(configurationURL: URL = defaultConfigurationURL) throws -> Bool {
        try withLockedConfiguration(at: configurationURL) { descriptor, original in
            guard let source = String(data: original, encoding: .utf8) else {
                throw ConfigError.unreadableConfiguration
            }
            guard let updated = try contentsRemovingManagedEntry(source), updated != source else { return false }
            try writeConfiguration(Data(updated.utf8), replacing: original, descriptor: descriptor, at: configurationURL)
            return true
        }
    }

    private static func managedBlock(endpointURL: String, originalFinalNewline: Bool) -> [String] {
        [
            beginMarker,
            "# Kestrel original final newline: \(originalFinalNewline)",
            "[mcp_servers.\(configurationName)]",
            "url = \"\(endpointURL)\"",
            endMarker
        ]
    }

    private static func managedBlockRange(in lines: [String]) throws -> ManagedEntry? {
        let beginIndexes = lines.indices.filter { lines[$0] == beginMarker }
        let endIndexes = lines.indices.filter { lines[$0] == endMarker }
        guard beginIndexes.isEmpty == endIndexes.isEmpty else { throw ConfigError.malformedManagedEntry }
        guard !beginIndexes.isEmpty else { return nil }
        guard beginIndexes.count == 1,
              endIndexes.count == 1,
              let begin = beginIndexes.first,
              let end = endIndexes.first,
              begin < end,
              end - begin == 4,
              let originalFinalNewline = originalFinalNewline(from: lines[begin + 1]),
              lines[begin + 2] == "[mcp_servers.\(configurationName)]",
              lines[begin + 3].hasPrefix("url = \""),
              lines[begin + 3].hasSuffix("\""),
              let endpoint = endpoint(fromManagedURLLine: lines[begin + 3]),
              isSafeLoopbackEndpoint(endpoint) else {
            throw ConfigError.malformedManagedEntry
        }
        return ManagedEntry(range: begin..<(end + 1), originalFinalNewline: originalFinalNewline)
    }

    private static func originalFinalNewline(from line: String) -> Bool? {
        switch line {
        case "# Kestrel original final newline: true": true
        case "# Kestrel original final newline: false": false
        default: nil
        }
    }

    private static func endpoint(fromManagedURLLine line: String) -> String? {
        let prefix = "url = \""
        guard line.hasPrefix(prefix), line.hasSuffix("\"") else { return nil }
        return String(line.dropFirst(prefix.count).dropLast())
    }

    private static func withLockedConfiguration<Result>(
        at url: URL,
        _ body: (Int32, Data) throws -> Result
    ) throws -> Result {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw ConfigError.missingConfiguration }
            if errno == ELOOP { throw ConfigError.symbolicLinkNotAllowed }
            throw ConfigError.unreadableConfiguration
        }
        defer { _ = close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else { throw ConfigError.unreadableConfiguration }
        defer { _ = flock(descriptor, LOCK_UN) }

        var initialStat = stat()
        guard fstat(descriptor, &initialStat) == 0 else { throw ConfigError.unreadableConfiguration }
        guard (initialStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ConfigError.unreadableConfiguration
        }
        try ensurePathStillReferencesFile(url, device: initialStat.st_dev, inode: initialStat.st_ino)
        let original = try readAll(from: descriptor)
        return try body(descriptor, original)
    }

    private static func writeConfiguration(_ data: Data, replacing original: Data, descriptor: Int32, at url: URL) throws {
        // Advisory locking prevents collisions with other cooperating clients.
        // The byte and inode recheck also catches ordinary concurrent Codex
        // rewrites before Kestrel truncates the file.
        let current = try readAll(from: descriptor)
        guard current == original else { throw ConfigError.concurrentModification }
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0 else { throw ConfigError.unreadableConfiguration }
        try ensurePathStillReferencesFile(url, device: fileStat.st_dev, inode: fileStat.st_ino)

        do {
            guard ftruncate(descriptor, 0) == 0 else { throw ConfigError.unreadableConfiguration }
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw ConfigError.unreadableConfiguration }
        } catch {
            // Best-effort restoration protects the user's original TOML if a
            // short write or storage error occurs after truncation.
            _ = ftruncate(descriptor, 0)
            try? writeAll(original, to: descriptor)
            _ = fsync(descriptor)
            throw ConfigError.unreadableConfiguration
        }
    }

    private static func readAll(from descriptor: Int32) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw ConfigError.unreadableConfiguration }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return result }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ConfigError.unreadableConfiguration }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw ConfigError.unreadableConfiguration }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ConfigError.unreadableConfiguration }
                offset += count
            }
        }
        guard ftruncate(descriptor, off_t(data.count)) == 0 else { throw ConfigError.unreadableConfiguration }
    }

    private static func ensurePathStillReferencesFile(_ url: URL, device: dev_t, inode: ino_t) throws {
        var pathStat = stat()
        guard lstat(url.path, &pathStat) == 0 else { throw ConfigError.concurrentModification }
        guard (pathStat.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
            throw ConfigError.symbolicLinkNotAllowed
        }
        guard pathStat.st_dev == device, pathStat.st_ino == inode else {
            throw ConfigError.concurrentModification
        }
    }

    private static func isSafeLoopbackEndpoint(_ endpoint: String) -> Bool {
        guard let components = URLComponents(string: endpoint),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port,
              (1...65_535).contains(port),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return false }
        let pattern = #"^/mcp/[0-9a-f]{64}/mcp$"#
        return components.path.range(of: pattern, options: .regularExpression) != nil
    }

    /// Conservatively detects every common TOML spelling of the root table,
    /// a Kestrel subtable, and dotted assignments, including quoted keys and
    /// array-of-table syntax. False positives are safer than overwriting data.
    private static func containsUnmanagedKestrelEntry(_ lines: [String]) -> Bool {
        let root = #"(?:mcp_servers|\"mcp_servers\"|'mcp_servers')"#
        let kestrel = #"(?:kestrel|\"kestrel\"|'kestrel')"#
        let directTable = #"^\s*\[{1,2}\s*"# + root + #"\s*\.\s*"# + kestrel + #"(?:\s*\.\s*[^\]]*)?\s*\]{1,2}(?:\s*#.*)?\s*$"#
        let rootTable = #"^\s*\[{1,2}\s*"# + root + #"\s*\]{1,2}(?:\s*#.*)?\s*$"#
        let dottedAssignment = #"^\s*"# + root + #"\s*\.\s*"# + kestrel + #"(?:\s*\.\s*[^=]*)?\s*="#
        let rootAssignment = #"^\s*"# + root + #"\s*="#
        let keyAssignment = #"^\s*"# + kestrel + #"\s*="#
        var insideRootTable = false

        for line in lines {
            if line.range(of: directTable, options: .regularExpression) != nil
                || line.range(of: dottedAssignment, options: .regularExpression) != nil
                || line.range(of: rootAssignment, options: .regularExpression) != nil {
                return true
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                insideRootTable = line.range(of: rootTable, options: .regularExpression) != nil
            } else if insideRootTable,
                      line.range(of: keyAssignment, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}
