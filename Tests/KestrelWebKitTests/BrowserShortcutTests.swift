#if canImport(SwiftUI)
import XCTest
import SwiftUI
import AppKit
@testable import KestrelWebKit

@MainActor
final class BrowserShortcutTests: XCTestCase {
    func testCommandArrowUsesPhysicalArrowBeforeChromiumHistory() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .function, .numericPad], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        XCTAssertTrue(try XCTUnwrap(BrowserCommand.splitLeft.defaultShortcut).matches(event: event))
        XCTAssertFalse(try XCTUnwrap(BrowserCommand.splitRight.defaultShortcut).matches(event: event))
        XCTAssertFalse(AssistantSidebarShortcut(key: "\u{f702}", modifiers: ["command", "option"]).matches(event: event))
    }
    private func withSettings(_ check: (AppSettings, UserDefaults) throws -> Void) rethrows {
        let name = "kestrel-shortcut-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try check(AppSettings(defaults: defaults), defaults)
    }

    func testDefaultsIncludeCommandArrowsAndHaveNoDuplicates() {
        withSettings { settings, _ in
            XCTAssertEqual(settings.shortcut(for: .splitLeft)?.displayName, "⌘ ←")
            XCTAssertEqual(settings.shortcut(for: .splitRight)?.displayName, "⌘ →")
            for command in BrowserCommand.allCases {
                if let shortcut = settings.shortcut(for: command) {
                    XCTAssertTrue(shortcut.isValid, command.rawValue)
                    XCTAssertNil(settings.shortcutError(shortcut, for: command), command.rawValue)
                }
            }
        }
    }

    func testBindingsPersistAndResetWithoutChangingOtherSettings() {
        withSettings { settings, defaults in
            let value = AssistantSidebarShortcut(key: "\u{f702}", modifiers: ["command", "option"])
            XCTAssertNil(settings.setShortcut(value, for: .splitLeft))
            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.shortcut(for: .splitLeft), value)
            XCTAssertEqual(restored.shortcut(for: .splitRight), BrowserCommand.splitRight.defaultShortcut)
            XCTAssertNil(restored.resetShortcut(.splitLeft))
            XCTAssertEqual(AppSettings(defaults: defaults).shortcut(for: .splitLeft), BrowserCommand.splitLeft.defaultShortcut)
        }
    }

    func testDuplicateAndReservedBindingsAreRejectedWithoutSaving() {
        withSettings { settings, _ in
            XCTAssertNotNil(settings.setShortcut(AssistantSidebarShortcut(key: "t", modifiers: ["command"]), for: .splitLeft))
            XCTAssertNotNil(settings.setShortcut(AssistantSidebarShortcut(key: "q", modifiers: ["command"]), for: .splitLeft))
            XCTAssertNotNil(settings.setShortcut(AssistantSidebarShortcut(key: "j", modifiers: ["shift"]), for: .splitLeft))
            XCTAssertEqual(settings.shortcut(for: .splitLeft), BrowserCommand.splitLeft.defaultShortcut)
            XCTAssertTrue(AssistantSidebarShortcut(key: "j", modifiers: ["command", "shift"]).matches(
                AssistantSidebarShortcut(key: "J", modifiers: ["shift", "command"])))
        }
    }

    func testTextFormattingAndPasteBindingsCannotBeAssigned() {
        withSettings { settings, _ in
            let reserved = [
                AssistantSidebarShortcut(key: "b", modifiers: ["command"]),
                AssistantSidebarShortcut(key: "i", modifiers: ["command"]),
                AssistantSidebarShortcut(key: "u", modifiers: ["command"]),
                AssistantSidebarShortcut(key: "v", modifiers: ["command", "shift"]),
                AssistantSidebarShortcut(key: "c", modifiers: ["command", "option"]),
                AssistantSidebarShortcut(key: "v", modifiers: ["command", "option"]),
                AssistantSidebarShortcut(key: "v", modifiers: ["command", "option", "shift"])
            ]
            for shortcut in reserved {
                XCTAssertNotNil(settings.setShortcut(shortcut, for: .closeTab), shortcut.displayName)
            }
            XCTAssertEqual(settings.shortcut(for: .closeTab), BrowserCommand.closeTab.defaultShortcut)
        }
    }

    func testResetDoesNotStealAnotherActionBinding() {
        withSettings { settings, _ in
            XCTAssertNil(settings.setShortcut(AssistantSidebarShortcut(key: "y", modifiers: ["command"]), for: .newTab))
            XCTAssertNil(settings.setShortcut(AssistantSidebarShortcut(key: "t", modifiers: ["command"]), for: .splitLeft))
            XCTAssertNotNil(settings.resetShortcut(.newTab))
            XCTAssertEqual(settings.shortcut(for: .newTab)?.key, "y")
        }
    }

    func testExistingAssistantShortcutSurvivesMigration() {
        withSettings { settings, defaults in
            settings.assistantSidebarShortcut = AssistantSidebarShortcut(key: "t", modifiers: ["command"])
            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.shortcut(for: .assistant)?.key, "t")
            XCTAssertNil(restored.shortcut(for: .newTab))
        }
    }
    private final class RecorderState: ObservableObject {
        @Published var recording = false
        var captures: [AssistantSidebarShortcut] = []
        var acceptsCapture = true
    }

    private struct HostedRecorder: View {
        @ObservedObject var state: RecorderState
        var body: some View {
            KeyboardShortcutRecorder(isRecording: $state.recording, shortcut: nil, label: "Test") { value in
                state.captures.append(value)
                return state.acceptsCapture
            }
            .frame(width: 200, height: 40)
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func withHostedRecorder(
        _ check: (RecorderState, NSWindow, ShortcutRecorderButton) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let state = RecorderState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedRecorder(state: state))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 60))
        host.frame = container.bounds
        container.addSubview(host)
        window.contentView = container
        host.layoutSubtreeIfNeeded()
        defer { window.makeFirstResponder(nil); window.close() }
        let button = try XCTUnwrap(descendant(ShortcutRecorderButton.self, in: host))
        button.performClick(nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(state.recording)
        XCTAssertTrue(button.isRecording)
        XCTAssertTrue(window.firstResponder === button)
        try await check(state, window, button)
    }

    private func keyEvent(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags,
                          window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: key, charactersIgnoringModifiers: key,
                                      isARepeat: false, keyCode: code))
    }

    func testHostedRecorderConsumesKeyEquivalentExactlyOnce() async throws {
        try await withHostedRecorder { state, window, button in
            let event = try keyEvent("q", code: 12, flags: [.command], window: window)
            // A handled window key equivalent must not continue to the app's Quit menu.
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(state.captures, [AssistantSidebarShortcut(key: "q", modifiers: ["command"])])
            XCTAssertFalse(state.recording)
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertFalse(button.isRecording)
            XCTAssertFalse(button.performKeyEquivalent(with: event))
            XCTAssertEqual(state.captures.count, 1)
        }
    }

    func testHostedRecorderKeepsRejectedCaptureAndCancelsOnEscape() async throws {
        try await withHostedRecorder { state, window, button in
            state.acceptsCapture = false
            let event = try keyEvent("b", code: 11, flags: [.command], window: window)
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertTrue(state.recording)
            XCTAssertEqual(state.captures.count, 1)
            button.keyDown(with: try keyEvent("\u{1b}", code: 53, flags: [], window: window))
            XCTAssertFalse(state.recording)
            XCTAssertEqual(state.captures.count, 1)
        }
    }

    func testHostedRecorderCancelsWhenFocusMovesAway() async throws {
        try await withHostedRecorder { state, window, button in
            let other = NSButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            window.contentView?.addSubview(other)
            XCTAssertTrue(window.makeFirstResponder(other))
            XCTAssertFalse(state.recording)
            let event = try keyEvent("q", code: 12, flags: [.command], window: window)
            XCTAssertFalse(button.performKeyEquivalent(with: event))
            XCTAssertTrue(state.captures.isEmpty)
        }
    }

}
#endif
