#if canImport(AppKit) && canImport(SwiftUI)

import AppKit
import Combine
import SwiftUI

/// SwiftPM's generated accessor searches beside the executable's main bundle,
/// whereas a signed macOS app keeps its resources inside Contents/Resources.
enum KestrelAssets {
    static let bundle = resolve(in: .main)

    static func resolve(in application: Bundle) -> Bundle {
        #if SWIFT_PACKAGE
        if application.bundleURL.pathExtension == "app" {
            if let url = application.resourceURL?.appendingPathComponent("KestrelChromium_KestrelWebKit.bundle"),
               let packaged = Bundle(url: url) { return packaged }
            return application
        }
        return .module
        #else
        return application
        #endif
    }
}

/// Finder uses the bundled purple icon. The running app's Dock and About icons
/// follow Kestrel's appearance, including system changes with no window open.
@MainActor
final class KestrelBranding: ObservableObject {
    private var appearanceSubscription: AnyCancellable?

    init(settings: AppSettings, application: NSApplication = .shared) {
        appearanceSubscription = settings.$appearanceMode
            .combineLatest(application.publisher(for: \.effectiveAppearance))
            .map { mode, appearance in
                Self.usesDarkIcon(mode: mode, systemAppearance: appearance)
            }
            .removeDuplicates()
            .sink { [weak application] isDark in
                guard let image = Self.image(isDark: isDark) else { return }
                application?.applicationIconImage = image
            }
    }

    static func usesDarkIcon(mode: KestrelAppearanceMode, systemAppearance: NSAppearance) -> Bool {
        switch mode {
        case .light: false
        case .dark: true
        case .system: systemAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    static func image(isDark: Bool) -> NSImage? {
        let name = NSImage.Name(isDark ? "KestrelIconDark" : "KestrelIconBasic")
        #if SWIFT_PACKAGE
        if let image = KestrelAssets.bundle.image(forResource: name) { return image }
        // Command-line SwiftPM copies asset catalogues without invoking
        // actool. Load the approved raster directly from that same bundle;
        // Xcode builds continue to use the compiled catalogue below.
        guard let url = KestrelAssets.bundle.url(forResource: "icon@2x", withExtension: "png",
                                          subdirectory: "Assets.xcassets/\(name).imageset") else { return nil }
        return NSImage(contentsOf: url)
        #else
        return Bundle.main.image(forResource: name)
        #endif
    }

    static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = NSApplication.shared.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }
}

#endif
