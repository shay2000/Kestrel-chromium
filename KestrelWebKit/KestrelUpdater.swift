#if canImport(Sparkle)

import Combine
import Sparkle

/// Owns Sparkle's native updater and exposes menu validation to SwiftUI.
@MainActor
final class KestrelUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

#endif
