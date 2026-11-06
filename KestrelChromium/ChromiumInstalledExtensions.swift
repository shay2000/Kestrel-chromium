#if canImport(AppKit) && canImport(CefKit)
import AppKit
import Combine
import Foundation

/// Metadata for Kestrel's own Chromium profile. Chromium owns installation,
/// permissions and action execution; this catalogue only supplies shortcut labels.
@MainActor
final class ChromiumInstalledExtensions: ObservableObject {
    static let shared = ChromiumInstalledExtensions()
    @Published private(set) var installed: [ChromiumExtensionDescriptor] = []
    @Published private(set) var readFailed = false
    @Published private(set) var pinnedActionIDs: [String] = []
    var nativePinnedActions: @MainActor ([ChromiumExtensionDescriptor]) -> [String] = { _ in [] }
    var actions: [ChromiumExtensionDescriptor] { installed.filter(\.hasAction) }
    private var polling: Task<Void, Never>?

    private init() {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refresh() async {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let profile = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
            .appendingPathComponent("CefSwift/Default", isDirectory: true)
        let approved = BrowserExtensionHost.approvedExtensionPaths().map { URL(fileURLWithPath: $0) }
        let result = await Task.detached(priority: .utility) {
            Result { try ChromiumExtensionCatalog.read(profile: profile, approvedDirectories: approved) }
        }.value
        switch result {
        case .success(let values):
            if installed != values { installed = values }
            if readFailed { readFailed = false }
        case .failure:
            // A partially written preference file must not leave stale actions live.
            if !installed.isEmpty { installed = [] }
            if !readFailed { readFailed = true }
        }
        let pinned = nativePinnedActions(actions)
        if pinnedActionIDs != pinned { pinnedActionIDs = pinned }
    }
}
#endif
