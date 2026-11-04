#if canImport(SwiftUI)
import SwiftUI
import AppKit

enum BrowserCommand: String, CaseIterable, Identifiable {
    case newTab, closeTab, reopenTab, nextTab, previousTab, toggleSidebar
    case splitLeft, splitRight, separateSplit, equalSplit
    case focusAddress, find, reload, back, forward, zoomIn, zoomOut, actualSize
    case openDefaultBrowser, assistant, assistantPage, clearConversation
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newTab: "New Tab / search bar"
        case .closeTab: "Close tab"
        case .reopenTab: "Reopen closed tab"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .toggleSidebar: "Show or hide tab sidebar"
        case .splitLeft: "Move tab / search to left split"
        case .splitRight: "Move tab / search to right split"
        case .separateSplit: "Separate split view"
        case .equalSplit: "Equal split widths"
        case .focusAddress: "Focus address bar"
        case .find: "Find on page"
        case .reload: "Reload page"
        case .back: "Go back"
        case .forward: "Go forward"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .actualSize: "Actual size"
        case .openDefaultBrowser: "Open page in default browser"
        case .assistant: "Show or hide Assistant"
        case .assistantPage: "Open Assistant page"
        case .clearConversation: "Clear conversation"
        case .tab9: "Select last tab"
        default: "Select tab \(rawValue.suffix(1))"
        }
    }

    var defaultShortcut: AssistantSidebarShortcut? {
        let key: String
        var modifiers = ["command", "control"]
        switch self {
        case .newTab: key = "t"; modifiers = ["command"]
        case .closeTab: key = "w"; modifiers = ["command"]
        case .reopenTab: key = "t"; modifiers = ["command", "shift"]
        case .nextTab: key = "\u{f703}"; modifiers.append("option")
        case .previousTab: key = "\u{f702}"; modifiers.append("option")
        case .toggleSidebar: key = "s"
        case .splitLeft: key = "\u{f702}"; modifiers = ["command"]
        case .splitRight: key = "\u{f703}"; modifiers = ["command"]
        case .focusAddress: key = "l"
        case .find: key = "f"
        case .reload: key = "r"
        case .back: key = "["
        case .forward: key = "]"
        case .zoomIn: key = "+"
        case .zoomOut: key = "-"
        case .actualSize: key = "0"
        case .openDefaultBrowser: key = "o"; modifiers = ["command", "shift"]
        case .assistant: return .default
        case .separateSplit, .equalSplit, .assistantPage, .clearConversation: return nil
        default: key = String(rawValue.suffix(1))
        }
        return AssistantSidebarShortcut(key: key, modifiers: modifiers)
    }
}

extension AppSettings {
    func shortcut(for command: BrowserCommand) -> AssistantSidebarShortcut? {
        if command == .assistant { return assistantSidebarShortcut }
        if let saved = browserShortcuts[command.rawValue] { return saved }
        guard let fallback = command.defaultShortcut else { return nil }
        // Keep an existing customised Assistant binding working during migration.
        guard !fallback.matches(assistantSidebarShortcut),
              !browserShortcuts.values.contains(where: { $0.matches(fallback) }) else { return nil }
        return fallback
    }

    func shortcutError(_ shortcut: AssistantSidebarShortcut, for command: BrowserCommand) -> String? {
        guard shortcut.isValid else { return "Include Command, Option or Control with one key." }
        let flags = Set(shortcut.modifiers)
        if flags == ["command"], ["q", "h", "m", "n", ",", "x", "c", "v", "a", "z", "b", "i", "u", "\r"].contains(shortcut.key.lowercased()) {
            return "That shortcut is used by a standard macOS or text-editing command."
        }
        if (flags == ["command", "shift"] && ["z", "n", "v"].contains(shortcut.key.lowercased()))
            || (flags == ["command", "option"] && ["h", "m", "c", "v"].contains(shortcut.key.lowercased()))
            || (flags == ["command", "option", "shift"] && shortcut.key.lowercased() == "v") {
            return "That shortcut is used by a standard macOS or text-editing command."
        }
        if let other = BrowserCommand.allCases.first(where: { $0 != command && self.shortcut(for: $0)?.matches(shortcut) == true }) {
            return "Already used by \(other.title). Choose another shortcut or change that action first."
        }
        return nil
    }

    @discardableResult
    func setShortcut(_ shortcut: AssistantSidebarShortcut, for command: BrowserCommand) -> String? {
        if let error = shortcutError(shortcut, for: command) { return error }
        if command == .assistant { assistantSidebarShortcut = shortcut }
        else { browserShortcuts[command.rawValue] = shortcut }
        return nil
    }

    func resetShortcut(_ command: BrowserCommand) -> String? {
        if let value = command.defaultShortcut, let error = shortcutError(value, for: command) { return error }
        if command == .assistant { assistantSidebarShortcut = .default }
        else { browserShortcuts.removeValue(forKey: command.rawValue) }
        return nil
    }
}

private struct BrowserWindowFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var isBrowserWindow: Bool? {
        get { self[BrowserWindowFocusKey.self] }
        set { self[BrowserWindowFocusKey.self] = newValue }
    }
}

private struct BrowserShortcutModifier: ViewModifier {
    @FocusedValue(\.isBrowserWindow) private var isBrowserWindow
    let command: BrowserCommand
    @ObservedObject var settings: AppSettings

    func body(content: Content) -> some View {
        let value = settings.shortcut(for: command)
        content
            .keyboardShortcut(settings.isCapturingShortcut || !(isBrowserWindow == true || BrowserWindowFocus.keyboardOwner != nil) ? nil : value.map {
                KeyboardShortcut($0.keyEquivalent, modifiers: $0.eventModifiers)
            })
            .disabled(!(isBrowserWindow == true || BrowserWindowFocus.keyboardOwner != nil))
    }
}

extension View {
    func kestrelShortcut(_ command: BrowserCommand, settings: AppSettings) -> some View {
        modifier(BrowserShortcutModifier(command: command, settings: settings))
    }
}

/// Native Close Window also owns Command-W. Route the configured Close Tab
/// binding before that responder action, only while this browser window owns
/// keyboard input. Settings, sheets and the shortcut recorder keep their keys.
struct BrowserCloseShortcut: NSViewRepresentable {
    let tabs: TabStore
    let settings: AppSettings

    func makeNSView(context: Context) -> CloseKeyView {
        CloseKeyView(tabs: tabs, settings: settings)
    }

    func updateNSView(_ view: CloseKeyView, context: Context) {}

    static func dismantleNSView(_ view: CloseKeyView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CloseKeyView: NSView {
        private let tabs: TabStore
        private let settings: AppSettings
        private var monitor: Any?

        init(tabs: TabStore, settings: AppSettings) {
            self.tabs = tabs
            self.settings = settings
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      BrowserWindowFocus.keyboardOwner === window, window.attachedSheet == nil,
                      !self.settings.isCapturingShortcut,
                      let shortcut = self.settings.shortcut(for: .closeTab),
                      event.charactersIgnoringModifiers?.lowercased() == shortcut.key.lowercased() else { return event }
                var expected: NSEvent.ModifierFlags = []
                for modifier in shortcut.modifiers {
                    switch modifier {
                    case "command": expected.insert(.command)
                    case "option": expected.insert(.option)
                    case "control": expected.insert(.control)
                    case "shift": expected.insert(.shift)
                    default: return event
                    }
                }
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == expected else { return event }
                self.tabs.closeSelectedTab()
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
