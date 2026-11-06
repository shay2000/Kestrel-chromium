#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

enum AddressFieldTarget: Hashable {
    case toolbar, pane(UUID), newTab
}

/// Owns the field editor rather than racing SwiftUI's submit and selection updates.
struct AddressTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var completionPrefix: String?
    @Binding var isFocused: Bool
    let placeholder: String
    let fontSize: CGFloat
    let selectAllOnFocus: Bool
    let completion: (String) -> String?
    let onSubmit: (String) -> Void
    let onAssistant: (String) -> Void
    let onMove: (Int) -> Bool
    let onTab: () -> Bool
    let onEscape: () -> Void
    var onTypedChange: (String) -> Void = { _ in }
    var onBackspaceAtStart: () -> Bool = { false }
    var focusTarget: AddressFieldTarget? = nil
    var isAccessible = true

    /// The toolbar keeps its native editor mounted beneath the formatted URL.
    /// A shortcut can therefore focus it before the next key event arrives.
    @MainActor static func focus(_ target: AddressFieldTarget, in owner: NSWindow) -> Bool {
        guard BrowserWindowFocus.keyboardOwner === owner,
              let field = Field.fields.allObjects.first(where: {
                  $0.focusTarget == target && $0.window != nil && ($0.window === owner || $0.window?.parent === owner)
              }) else { return false }
        return field.focusForCommand()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Address bar")
        field.delegate = context.coordinator
        field.focusTarget = focusTarget
        field.onFocusRequest = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isFocused = true
        }
        field.onAssistant = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            let value = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            coordinator.parent.text = value
            coordinator.parent.onAssistant(value)
        }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.focusTarget = focusTarget
        field.setAccessibilityElement(isAccessible)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .labelColor
        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != text || (editor != nil && editor?.string != text) {
            field.stringValue = text
            editor?.string = text
            editor?.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            coordinator.typedText = text
            coordinator.allowsCompletion = false
        }
        // Focus and late network completions run after SwiftUI finishes updating.
        DispatchQueue.main.async { [weak field, weak coordinator] in
            guard let field, let coordinator, let window = field.window else { return }
            if coordinator.parent.isFocused {
                guard NSApp.isActive, let owner = BrowserWindowFocus.keyboardOwner,
                      window === owner || window.parent === owner else { return }
                let editor = field.currentEditor() as? NSTextView
                if !window.isKeyWindow || editor == nil || window.firstResponder !== editor {
                    if !window.isKeyWindow { window.makeKey() }
                    window.makeFirstResponder(field)
                    if coordinator.parent.selectAllOnFocus, let editor = field.currentEditor() as? NSTextView {
                        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
                    }
                }
            } else if !coordinator.parent.isFocused, field.currentEditor() != nil {
                window.makeFirstResponder(nil)
            }
            coordinator.applyCompletion(in: field)
        }
    }

    final class Field: NSTextField {
        static let fields = NSHashTable<Field>.weakObjects()
        var focusTarget: AddressFieldTarget?
        var onFocusRequest: (() -> Void)?
        var onAssistant: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.fields.add(self) } else { Self.fields.remove(self) }
        }
        func focusForCommand() -> Bool {
            guard let window else { return false }
            if !window.isKeyWindow { window.makeKey() }
            // The editor, rather than the NSTextField, is first responder
            // during editing. Replacing it with its field ends the session
            // and lets the end-editing callback clear the focus binding.
            if let editor = currentEditor() as? NSTextView, window.firstResponder === editor {
                onFocusRequest?()
                editor.selectAll(nil)
                return true
            }
            onFocusRequest?()
            guard window.makeFirstResponder(self), let editor = currentEditor() as? NSTextView else { return false }
            onFocusRequest?()
            editor.selectAll(nil)
            return true
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if currentEditor() != nil, flags == .command, [36, 76].contains(event.keyCode) {
                onAssistant?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressTextField
        var typedText: String
        var allowsCompletion = false

        init(_ parent: AddressTextField) {
            self.parent = parent
            typedText = parent.text
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            typedText = parent.text
            allowsCompletion = false
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            allowsCompletion = false
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            let value = editor.string
            allowsCompletion = !editor.hasMarkedText() && value.count > typedText.count && value.hasPrefix(typedText)
            typedText = value
            parent.completionPrefix = nil
            parent.text = value
            parent.onTypedChange(value)
            applyCompletion(in: field)
        }

        func applyCompletion(in field: NSTextField) {
            guard allowsCompletion, parent.completionPrefix == nil,
                  let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText(), editor.string == typedText,
                  editor.selectedRange() == NSRange(location: typedText.utf16.count, length: 0),
                  let completed = parent.completion(typedText), completed.hasPrefix(typedText),
                  completed.utf16.count > typedText.utf16.count else { return }
            // Programmatic completion is not a typed edit; preserve its prefix
            // separately so it cannot restart the suggestion request or selection.
            field.stringValue = completed
            editor.string = completed
            editor.setSelectedRange(NSRange(location: typedText.utf16.count,
                                            length: completed.utf16.count - typedText.utf16.count))
            parent.completionPrefix = typedText
            parent.text = completed
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            // Let the input method finish composing before interpreting browser commands.
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                // A paste and Return can arrive before SwiftUI renders the
                // changed binding. Submit the actual editor contents.
                parent.text = textView.string
                parent.onSubmit(textView.string)
                return true
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove(-1)
            case #selector(NSResponder.insertTab(_:)):
                if parent.onTab() {
                    // A search shortcut consumes its keyword immediately. The
                    // field editor must change with the binding before the next
                    // keystroke, even if SwiftUI has not rendered another frame.
                    control.stringValue = parent.text
                    textView.string = parent.text
                    textView.setSelectedRange(NSRange(location: parent.text.utf16.count, length: 0))
                    typedText = parent.text
                    allowsCompletion = false
                    return true
                }
                return acceptCompletion(in: textView)
            case #selector(NSResponder.moveRight(_:)):
                return acceptCompletion(in: textView)
            case #selector(NSResponder.cancelOperation(_:)):
                if dismissCompletion(in: control, editor: textView) { return true }
                parent.onEscape()
                return true
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
                allowsCompletion = false
                if dismissCompletion(in: control, editor: textView) { return true }
                if command == #selector(NSResponder.deleteBackward(_:)),
                   textView.selectedRange() == NSRange(location: 0, length: 0),
                   parent.onBackspaceAtStart() { return true }
                return false
            default:
                return false
            }
        }

        private func acceptCompletion(in editor: NSTextView) -> Bool {
            guard parent.completionPrefix != nil else { return false }
            parent.completionPrefix = nil
            typedText = editor.string
            allowsCompletion = false
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            return true
        }

        private func dismissCompletion(in control: NSControl, editor: NSTextView) -> Bool {
            guard let prefix = parent.completionPrefix,
                  editor.selectedRange() == NSRange(location: prefix.utf16.count,
                                                    length: editor.string.utf16.count - prefix.utf16.count) else { return false }
            control.stringValue = prefix
            editor.string = prefix
            editor.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            parent.completionPrefix = nil
            parent.text = prefix
            typedText = prefix
            allowsCompletion = false
            return true
        }
    }
}
#endif
