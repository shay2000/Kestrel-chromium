#if canImport(SwiftUI) && canImport(CefSwiftUI)

import CefKit
import CefSwiftUI
import SwiftUI

@main
@MainActor
struct KestrelChromiumApp: CefSwiftApp {
    @State private var browser: ChromiumBrowserShell

    init() {
        _browser = State(initialValue: ChromiumBrowserShell(initialURL: Self.launchURL))
    }

    private static var launchURL: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--open-url"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return URL(string: CommandLine.arguments[index + 1])
    }

    static var cefConfiguration: CefConfiguration {
        var configuration = CefConfiguration()
        configuration.noSandbox = false
        configuration.windowlessRenderingEnabled = true
        configuration.defaultRuntimeStyle = .alloy
        configuration.userAgentProduct = "KestrelChromium/1.0"
        return configuration
    }

    var body: some Scene {
        WindowGroup("Kestrel Chromium") {
            ChromiumBrowserWindow(browser: browser)
                .frame(minWidth: 720, minHeight: 520)
                .onOpenURL { browser.open($0, inNewTab: true) }
        }
        .defaultSize(width: 1_200, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { browser.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { browser.closeSelectedTab() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Open Location…") { browser.requestAddressFocus() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Reload Page") { browser.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Chromium") {
                Button("Toggle DevTools") { browser.toggleDevTools() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

#else

import Foundation

@main
struct KestrelChromiumUnavailable {
    static func main() {
        print("Kestrel Chromium requires macOS and its bundled Chromium Embedded Framework.")
    }
}

#endif
