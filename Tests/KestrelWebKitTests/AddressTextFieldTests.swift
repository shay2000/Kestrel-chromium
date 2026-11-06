#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
import XCTest
@testable import KestrelWebKit

@MainActor
final class AddressTextFieldTests: XCTestCase {
    private final class HostedState: ObservableObject {
        @Published var text = "https://example.com/"
        @Published var prefix: String?
        @Published var focused = true
    }

    private struct HostedField: View {
        @ObservedObject var state: HostedState
        var body: some View {
            AddressTextField(text: $state.text, completionPrefix: $state.prefix,
                isFocused: $state.focused, placeholder: "Address", fontSize: 14,
                selectAllOnFocus: true, completion: { _ in nil }, onSubmit: {},
                onAssistant: {}, onMove: { _ in true }, onTab: { false }, onEscape: {})
                .frame(width: 400, height: 33)
        }
    }

    func testHostedToolbarFocusSelectsURLAndSurvivesViewUpdates() async throws {
        _ = NSApplication.shared
        let state = HostedState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        BrowserWindowFocus.register(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView = NSHostingView(rootView: HostedField(state: state))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.makeFirstResponder(nil); window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(state.focused)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: state.text.utf16.count))
        editor.insertText("redd", replacementRange: editor.selectedRange())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(state.focused)
        XCTAssertEqual(state.text, "redd")
        XCTAssertTrue(window.firstResponder === editor)
    }

    private final class State {
        var text = ""
        var prefix: String?
        var focused = true
        var index = 0
        var submitted: [Int] = []
        var assistantCount = 0
        var escaped = false
        var candidate = "kestrel browser"
        var consumeTabKeyword = false
        var typedChanges: [String] = []
        var searchModeIsActive = false
    }

    private func withEditor(_ check: (State, AddressTextField.Coordinator, NSTextField, NSTextView) throws -> Void) throws {
        _ = NSApplication.shared
        let state = State()
        let view = AddressTextField(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            completionPrefix: Binding(get: { state.prefix }, set: { state.prefix = $0 }),
            isFocused: Binding(get: { state.focused }, set: { state.focused = $0 }),
            placeholder: "Search", fontSize: 14, selectAllOnFocus: false,
            completion: { state.candidate.hasPrefix($0) && $0.count >= 2 ? state.candidate : nil },
            onSubmit: { state.submitted.append(state.index) },
            onAssistant: { state.assistantCount += 1 },
            onMove: { state.index = min(max(state.index + $0, 0), 3); return true },
            onTab: {
                guard state.consumeTabKeyword else { return false }
                state.text = ""
                state.prefix = nil
                return true
            }, onEscape: { state.escaped = true },
            onTypedChange: { state.typedChanges.append($0) },
            onBackspaceAtStart: {
                guard state.searchModeIsActive else { return false }
                state.searchModeIsActive = false
                return true
            }
        )
        let coordinator = view.makeCoordinator()
        let field = AddressTextField.Field(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        field.delegate = coordinator
        let window = NSWindow(contentRect: field.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        window.makeFirstResponder(field)
        defer { window.makeFirstResponder(nil); window.close() }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        try check(state, coordinator, field, editor)
    }

    private func type(_ value: String, field: NSTextField, editor: NSTextView, coordinator: AddressTextField.Coordinator) {
        editor.insertText(value, replacementRange: editor.selectedRange())
        // Field-editor notifications are synchronously delivered by AppKit.
        if coordinator.typedText != editor.string && coordinator.parent.completionPrefix == nil {
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
    }

    func testReturnUsesArrowSelectionExactlyOnce() throws {
        try withEditor { state, coordinator, field, editor in
            XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
            XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
            XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(state.submitted, [2])
        }
    }

    func testCompletionSelectsOnlySuffixAndTypingReplacesIt() throws {
        try withEditor { state, coordinator, field, editor in
            type("ke", field: field, editor: editor, coordinator: coordinator)
            XCTAssertEqual(state.text, "kestrel browser")
            XCTAssertEqual(state.prefix, "ke")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 13))
            type("y", field: field, editor: editor, coordinator: coordinator)
            XCTAssertEqual(state.text, "key")
            XCTAssertNil(state.prefix)
        }
    }

    func testBackspaceDismissesSuffixWithoutRefilling() throws {
        try withEditor { state, coordinator, field, editor in
            type("ke", field: field, editor: editor, coordinator: coordinator)
            XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
            coordinator.applyCompletion(in: field)
            XCTAssertEqual(state.text, "ke")
            XCTAssertEqual(editor.string, "ke")
            XCTAssertNil(state.prefix)
        }
    }

    func testTabConsumesSearchKeywordBeforeFurtherTyping() throws {
        try withEditor { state, coordinator, field, editor in
            type("maps", field: field, editor: editor, coordinator: coordinator)
            state.consumeTabKeyword = true
            XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
            XCTAssertEqual(editor.string, "")
            type("London", field: field, editor: editor, coordinator: coordinator)
            XCTAssertEqual(state.text, "London")
            XCTAssertEqual(editor.string, "London")
            // Consuming the keyword is not a user deletion that cancels the
            // newly selected search mode; only real editor changes are sent.
            XCTAssertEqual(state.typedChanges, ["maps", "London"])
            editor.selectAll(nil)
            editor.deleteBackward(nil)
            XCTAssertEqual(state.typedChanges.last, "")
        }
    }

    func testBackspaceAtStartExitsSearchModeAndPreservesQuery() throws {
        try withEditor { state, coordinator, field, editor in
            let backspace = #selector(NSResponder.deleteBackward(_:))
            state.searchModeIsActive = true
            XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: backspace))
            XCTAssertFalse(state.searchModeIsActive)
            XCTAssertTrue(editor.string.isEmpty)
            XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: backspace))

            type("London", field: field, editor: editor, coordinator: coordinator)
            state.searchModeIsActive = true
            // Ordinary Backspace within a query remains normal text editing.
            XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: backspace))
            XCTAssertTrue(state.searchModeIsActive)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: backspace))
            XCTAssertFalse(state.searchModeIsActive)
            XCTAssertEqual(editor.string, "London")
        }
    }

    func testLateCompletionDoesNotSubmitOrMoveDropdownSelection() throws {
        try withEditor { state, coordinator, field, editor in
            state.candidate = ""
            type("ke", field: field, editor: editor, coordinator: coordinator)
            _ = coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
            state.candidate = "kestrel browser"
            coordinator.applyCompletion(in: field)
            XCTAssertEqual(state.text, "kestrel browser")
            XCTAssertEqual(state.index, 1)
            XCTAssertTrue(state.submitted.isEmpty)
        }
    }

    func testRightAndTabAcceptCompletionAndEscapeDismissesIt() throws {
        for command in [#selector(NSResponder.moveRight(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.cancelOperation(_:))] {
            try withEditor { state, coordinator, field, editor in
                type("ke", field: field, editor: editor, coordinator: coordinator)
                XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: command))
                XCTAssertNil(state.prefix)
                XCTAssertEqual(state.text, command == #selector(NSResponder.cancelOperation(_:)) ? "ke" : "kestrel browser")
                XCTAssertEqual(editor.selectedRange().length, 0)
                XCTAssertFalse(state.escaped)
            }
        }
    }

    func testCompletionDoesNotChangeMarkedTextOrMidStringEdits() throws {
        try withEditor { state, coordinator, field, editor in
            state.candidate = ""
            type("ke", field: field, editor: editor, coordinator: coordinator)
            state.candidate = "kestrel browser"
            editor.setSelectedRange(NSRange(location: 1, length: 0))
            coordinator.applyCompletion(in: field)
            XCTAssertEqual(state.text, "ke")
            editor.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 2))
            coordinator.applyCompletion(in: field)
            XCTAssertNil(state.prefix)
            XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertTrue(state.submitted.isEmpty)
        }
    }
}
#endif
