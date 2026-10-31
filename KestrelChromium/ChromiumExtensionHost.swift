#if canImport(CefKit) && canImport(AppKit)

import AppKit
import Combine
import CefKit
import Foundation

struct InstalledChromiumExtension: Identifiable, Equatable {
    let path: String
    let displayName: String
    let version: String?
    var id: String { path }
}

/// Reviews and stages approved WebExtensions for CEF's Chrome runtime.
@MainActor
final class BrowserExtensionHost: ObservableObject {
    static let shared = BrowserExtensionHost()
    static let approvedPathsKey = "kestrel.chromium.approved-extension-paths.v1"

    private struct Staged {
        let url: URL
        let preview: ExtensionInstallPreview
        let manifest: ChromiumExtensionManifest
    }
    private var staged: [UUID: Staged] = [:]
    @Published private(set) var installed: [InstalledChromiumExtension] = []
    private init() { refreshInstalled() }

    static func approvedExtensionPaths(defaults: UserDefaults = .standard) -> [String] {
        let paths = defaults.stringArray(forKey: approvedPathsKey) ?? []
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        if paths != existing { defaults.set(existing, forKey: approvedPathsKey) }
        return existing
    }

    static func commandLineSwitches(defaults: UserDefaults = .standard) -> [String: String?] {
        let paths = approvedExtensionPaths(defaults: defaults)
        return paths.isEmpty ? [:] : ["load-extension": paths.joined(separator: ",")]
    }

    func refreshInstalled() {
        installed = Self.approvedExtensionPaths().compactMap { path in
            let manifestURL = URL(fileURLWithPath: path).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ChromiumExtensionManifest.self, from: data) else { return nil }
            return InstalledChromiumExtension(path: path, displayName: manifest.name, version: manifest.version)
        }
    }

    func removeInstalled(path: String) throws {
        let root = try Self.extensionRoot().standardizedFileURL.path + "/"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix(root), UUID(uuidString: url.lastPathComponent) != nil else {
            throw BrowserExtensionHostError.invalidPackage("Kestrel cannot remove an extension outside its managed extension folder.")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let paths = Self.approvedExtensionPaths().filter { URL(fileURLWithPath: $0).standardizedFileURL != url }
        UserDefaults.standard.set(paths, forKey: Self.approvedPathsKey)
        refreshInstalled()
    }

    func stage(url: URL) async -> ExtensionInstallResolution {
        var isDirectory: ObjCBool = false
        if let sourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           sourceValues.isSymbolicLink == true {
            return .rejected(reason: "Choose the extension folder or package itself, not a symbolic link.")
        }
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .rejected(reason: "That file or folder could not be found.")
        }
        let kind = ExtensionPackageClassifier.kind(for: url, isDirectory: isDirectory.boolValue)
        guard ExtensionPackageDecision.forKind(kind).isLoadable else {
            return .rejected(reason: ExtensionSupport.chromiumCRXRejectionReason)
        }
        do {
            let data = kind == .directory
                ? try Self.readManifest(from: url)
                : try Self.readZippedManifest(from: url)
            guard data.count <= 1_000_000 else { return .rejected(reason: "The extension manifest is too large to review.") }
            let manifest = try JSONDecoder().decode(ChromiumExtensionManifest.self, from: data)
            guard manifest.manifestVersion == 3 else {
                return .rejected(reason: "This Chromium build accepts Manifest V3 extensions. Manifest V2 is no longer supported by current Chromium releases.")
            }
            let preview = ExtensionInstallPreview(
                id: UUID(),
                displayName: String(manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                version: manifest.version,
                packageKind: kind,
                requested: PendingExtensionPermissions(
                    permissions: manifest.permissions.sorted(),
                    hostPatterns: Set(manifest.hostPermissions + manifest.contentScriptMatches).sorted()
                ),
                warnings: manifest.optionalPermissions.isEmpty
                    ? []
                    : ["Optional permissions are requested later through Chromium's permission prompt."]
            )
            staged[preview.id] = Staged(url: url, preview: preview, manifest: manifest)
            return .pendingApproval(preview)
        } catch {
            return .rejected(reason: Self.safeMessage(for: error))
        }
    }

    @discardableResult
    func approve(id: UUID, granting permissions: Set<String>, hostPatterns: Set<String>) throws -> ExtensionInstallPreview {
        guard let item = staged[id] else { throw BrowserExtensionHostError.notStaged }
        guard Set(item.preview.requested.permissions).isSubset(of: permissions),
              Set(item.preview.requested.hostPatterns).isSubset(of: hostPatterns) else {
            throw BrowserExtensionHostError.incompletePermissionReview
        }
        let root = try Self.extensionRoot()
        let destination = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BrowserExtensionHostError.destinationExists
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if item.preview.packageKind == .directory {
                try Self.copyDirectory(item.url, to: destination)
            } else {
                try Self.extractArchive(item.url, to: destination)
            }
            let paths = Self.approvedExtensionPaths() + [destination.path]
            UserDefaults.standard.set(Array(Set(paths)).sorted(), forKey: Self.approvedPathsKey)
            staged[id] = nil
            refreshInstalled()
            return item.preview
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw BrowserExtensionHostError.installFailed(Self.safeMessage(for: error))
        }
    }

    func discard(id: UUID) { staged[id] = nil }

    private static let maximumArchiveBytes = 50 * 1_048_576
    private static let maximumInstalledBytes = 100 * 1_048_576
    private static let maximumFiles = 10_000

    private static func extensionRoot() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BrowserExtensionHostError.installFailed("The application-support folder is unavailable.")
        }
        let root = support.appendingPathComponent("Kestrel/ChromiumExtensions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    private static func readManifest(from directory: URL) throws -> Data {
        let manifest = directory.appendingPathComponent("manifest.json")
        try requireRegularFile(manifest)
        return try Data(contentsOf: manifest, options: [.mappedIfSafe])
    }

    private static func readZippedManifest(from url: URL) throws -> Data {
        try requireArchiveSize(url)
        let rawData = try Data(contentsOf: url, options: [.mappedIfSafe])
        let data = try zipPayload(from: rawData)
        guard data.count <= maximumArchiveBytes else {
            throw BrowserExtensionHostError.invalidPackage("The ZIP archive is larger than 50 MB.")
        }
        let archive = ZipArchive(data: data)
        let entries = archive.entries()
        let manifests = entries.filter { URL(fileURLWithPath: $0.name).lastPathComponent == "manifest.json" }
        guard !entries.isEmpty, manifests.count == 1, let entry = manifests.first,
              entry.uncompressedSize <= 1_000_000, archiveRoot(for: entry.name) != nil else {
            throw BrowserExtensionHostError.invalidPackage("The archive must contain exactly one manifest.json file at its root.")
        }
        return try archive.contents(of: entry)
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BrowserExtensionHostError.invalidPackage("The manifest must be a regular file, not a symbolic link.")
        }
    }

    private static func archiveRoot(for rawPath: String) -> String? {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard safeComponents(path) != nil else { return nil }
        guard let range = path.range(of: "/manifest.json", options: .backwards) else {
            return path == "manifest.json" ? "" : nil
        }
        return String(path[..<range.lowerBound]) + "/"
    }

    private static func zipPayload(from data: Data) throws -> Data {
        guard data.count <= maximumArchiveBytes else {
            throw BrowserExtensionHostError.invalidPackage("The extension package is larger than 50 MB.")
        }
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return data }
        guard bytes.count >= 12, Array(bytes[0..<4]) == [0x43, 0x72, 0x32, 0x34] else {
            throw BrowserExtensionHostError.invalidPackage("The extension package is not a ZIP or Chromium CRX file.")
        }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        let version = uint32(4)
        let headerLength: UInt64
        switch version {
        case 2:
            guard bytes.count >= 16 else { throw BrowserExtensionHostError.invalidPackage("The Chromium CRX header is incomplete.") }
            headerLength = 16 + UInt64(uint32(8)) + UInt64(uint32(12))
        case 3:
            headerLength = 12 + UInt64(uint32(8))
        default:
            throw BrowserExtensionHostError.invalidPackage("This Chromium CRX version is not supported.")
        }
        guard headerLength < UInt64(data.count), headerLength <= 1_000_000 else {
            throw BrowserExtensionHostError.invalidPackage("The Chromium CRX header is invalid.")
        }
        return data.dropFirst(Int(headerLength))
    }

    private static func copyDirectory(_ source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
              ) else {
            throw BrowserExtensionHostError.invalidPackage("Choose an unpacked extension folder.")
        }
        var count = 0
        var total = 0
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw BrowserExtensionHostError.invalidPackage("Extensions containing symbolic links cannot be imported.")
            }
            if values.isDirectory == true || values.isRegularFile != true { continue }
            count += 1
            total += values.fileSize ?? 0
            guard count <= maximumFiles, total <= maximumInstalledBytes else {
                throw BrowserExtensionHostError.invalidPackage("The extension contains too many or too-large files.")
            }
            let relative = String(file.path.dropFirst(source.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let parts = safeComponents(relative), !parts.isEmpty else {
                throw BrowserExtensionHostError.invalidPackage("The extension contains an unsafe file path.")
            }
            let target = parts.reduce(destination) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: file, options: [.mappedIfSafe]).write(to: target, options: .atomic)
        }
        try requireRegularFile(destination.appendingPathComponent("manifest.json"))
    }

    private static func extractArchive(_ source: URL, to destination: URL) throws {
        try requireArchiveSize(source)
        let rawData = try Data(contentsOf: source, options: [.mappedIfSafe])
        let data = try zipPayload(from: rawData)
        guard data.count <= maximumArchiveBytes else {
            throw BrowserExtensionHostError.invalidPackage("The ZIP archive is larger than 50 MB.")
        }
        let archive = ZipArchive(data: data)
        let entries = archive.entries()
        guard let manifest = entries.first(where: { URL(fileURLWithPath: $0.name).lastPathComponent == "manifest.json" }),
              let root = archiveRoot(for: manifest.name) else {
            throw BrowserExtensionHostError.invalidPackage("The archive must contain a manifest.json file at its root.")
        }
        var names = Set<String>()
        var total = 0
        var count = 0
        for entry in entries {
            let path = entry.name.replacingOccurrences(of: "\\", with: "/")
            let relativePath = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
            if relativePath?.isEmpty == true, path.hasSuffix("/") { continue }
            guard let relativePath, let parts = safeComponents(relativePath) else {
                throw BrowserExtensionHostError.invalidPackage("The ZIP archive contains an unsafe file path.")
            }
            if parts.isEmpty { continue }
            if path.hasSuffix("/") {
                let dir = parts.reduce(destination) { $0.appendingPathComponent($1, isDirectory: true) }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                continue
            }
            guard (entry.externalAttributes >> 16) & 0xF000 != 0xA000 else {
                throw BrowserExtensionHostError.invalidPackage("Extensions containing symbolic links cannot be imported.")
            }
            let relative = parts.joined(separator: "/")
            guard names.insert(relative).inserted else {
                throw BrowserExtensionHostError.invalidPackage("The ZIP archive contains duplicate file paths.")
            }
            count += 1
            total += entry.uncompressedSize
            guard count <= maximumFiles, total <= maximumInstalledBytes else {
                throw BrowserExtensionHostError.invalidPackage("The extension contains too many or too-large files.")
            }
            let target = parts.reduce(destination) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archive.contents(of: entry).write(to: target, options: .atomic)
        }
        try requireRegularFile(destination.appendingPathComponent("manifest.json"))
    }

    private static func safeComponents(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    private static func requireArchiveSize(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= 0, size <= maximumArchiveBytes else {
            throw BrowserExtensionHostError.invalidPackage("The extension package is larger than 50 MB or its size could not be checked.")
        }
    }

    private static func safeMessage(for error: Error) -> String {
        if let error = error as? BrowserExtensionHostError { return error.localizedDescription }
        return "The extension package could not be read or copied."
    }
}

private struct ChromiumExtensionManifest: Decodable {
    struct ContentScript: Decodable { let matches: [String] }
    let manifestVersion: Int
    let name: String
    let version: String?
    let permissions: [String]
    let optionalPermissions: [String]
    let hostPermissions: [String]
    let contentScriptMatches: [String]

    private enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version", name, version, permissions
        case optionalPermissions = "optional_permissions"
        case hostPermissions = "host_permissions"
        case contentScripts = "content_scripts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = try c.decode(Int.self, forKey: .manifestVersion)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        optionalPermissions = try c.decodeIfPresent([String].self, forKey: .optionalPermissions) ?? []
        hostPermissions = try c.decodeIfPresent([String].self, forKey: .hostPermissions) ?? []
        contentScriptMatches = try c.decodeIfPresent([ContentScript].self, forKey: .contentScripts)?.flatMap(\.matches) ?? []
    }
}

enum BrowserExtensionHostError: LocalizedError {
    case notStaged
    case incompletePermissionReview
    case destinationExists
    case invalidPackage(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .notStaged: return "That extension is no longer staged for approval."
        case .incompletePermissionReview:
            return "Select every required extension permission and site pattern before approving the import. Chromium does not let Kestrel silently remove permissions from a manifest."
        case .destinationExists: return "An extension with this review ID already exists. Stage the package again."
        case .invalidPackage(let message), .installFailed(let message): return message
        }
    }
}

#endif
