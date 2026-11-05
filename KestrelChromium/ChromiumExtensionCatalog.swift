import Foundation

struct ChromiumExtensionDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let directory: URL
    let iconURL: URL?
    let hasAction: Bool
}

/// Reads only installed-extension metadata in Kestrel's own profile and
/// explicitly approved import folders. Never writes Chrome preferences.
enum ChromiumExtensionCatalog {
    enum ReadError: Error { case unreadablePreferences }

    static func read(profile: URL, approvedDirectories: [URL] = [], languages: [String] = Locale.preferredLanguages) throws -> [ChromiumExtensionDescriptor] {
        let files = ["Preferences", "Secure Preferences"].map { profile.appendingPathComponent($0) }
        var settings: [String: Any] = [:]
        var found = false
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            found = true
            guard let document = json(file, limit: 32 * 1024 * 1024) else { throw ReadError.unreadablePreferences }
            if let values = (document["extensions"] as? [String: Any])?["settings"] as? [String: Any] {
                settings.merge(values) { _, newer in newer }
            }
        }
        guard found else { return [] }
        let managed = profile.appendingPathComponent("Extensions", isDirectory: true).resolvingSymlinksInPath()
        let approved = Set(approvedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        return settings.keys.sorted().prefix(512).compactMap { id in
            guard validID(id), let value = settings[id] as? [String: Any], enabled(value),
                  let path = value["path"] as? String, path.utf8.count <= 4096 else { return nil }
            let directory = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : managed.appendingPathComponent(path))
                .standardizedFileURL.resolvingSymlinksInPath()
            let ownID = managed.appendingPathComponent(id, isDirectory: true).path + "/"
            guard directory.path.hasPrefix(ownID) || approved.contains(directory.path),
                  let manifest = json(directory.appendingPathComponent("manifest.json"), limit: 1024 * 1024),
                  let rawName = manifest["name"] as? String,
                  let version = manifest["version"] as? String else { return nil }
            let name = localized(rawName, manifest: manifest, directory: directory, languages: languages)
            guard !name.isEmpty, name.utf8.count <= 1024, version.utf8.count <= 128 else { return nil }
            let action = manifest["action"] as? [String: Any] ?? manifest["browser_action"] as? [String: Any]
            return ChromiumExtensionDescriptor(id: id, name: name, version: version, directory: directory,
                iconURL: icon(action?["default_icon"] ?? manifest["icons"], directory: directory),
                hasAction: action != nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
    }

    private static func enabled(_ value: [String: Any]) -> Bool {
        if let state = value["state"] as? Int, state != 1 { return false }
        if let reasons = value["disable_reasons"] as? Int { return reasons == 0 }
        if let reasons = value["disable_reasons"] as? [Int] { return reasons.allSatisfy { $0 == 0 } }
        return true
    }

    private static func json(_ url: URL, limit: Int) -> [String: Any]? {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= limit,
              let data = try? Data(contentsOf: url), data.count <= limit else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func localized(_ value: String, manifest: [String: Any], directory: URL, languages: [String]) -> String {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
        let key = String(value.dropFirst(6).dropLast(2))
        let candidates = languages.flatMap { language -> [String] in
            let normalized = language.replacingOccurrences(of: "-", with: "_")
            return [normalized, String(normalized.split(separator: "_").first ?? "")]
        } + [manifest["default_locale"] as? String ?? "en"]
        for locale in candidates where !locale.isEmpty && locale.utf8.count <= 40 && locale.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) {
            let file = directory.appendingPathComponent("_locales/\(locale)/messages.json")
            guard file.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
                  let messages = json(file, limit: 1024 * 1024),
                  let entry = messages.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value as? [String: Any],
                  let text = entry["message"] as? String else { continue }
            return text
        }
        return value
    }

    private static func icon(_ value: Any?, directory: URL) -> URL? {
        let path: String?
        if let string = value as? String { path = string }
        else if let icons = value as? [String: String] {
            path = icons.compactMap { key, value -> (Int, String)? in
                guard let size = Int(key), size > 0, size <= 1024 else { return nil }
                return (abs(size - 32), value)
            }.sorted { $0.0 < $1.0 }.first?.1
        } else { path = nil }
        guard let path, !path.hasPrefix("/"), path.utf8.count <= 4096 else { return nil }
        let file = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.path + "/"), ["png", "jpg", "jpeg", "webp", "ico", "icns"].contains(file.pathExtension.lowercased()),
              let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let size = info.fileSize, size <= 1024 * 1024 else { return nil }
        return file
    }
}
