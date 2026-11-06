#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI

/// AppKit's own controls, routed to the document surrounding a hosted page.
struct NativeDocumentWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) { view.updateControls() }

    final class ControlsView: NSView {
        private let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        private var buttons: [NSButton] = []
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let labels = ["Close Kestrel window", "Minimize Kestrel window", "Zoom Kestrel window"]
            for (index, type) in types.enumerated() {
                guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                button.tag = index
                button.target = self
                button.action = #selector(performDocumentAction(_:))
                button.setAccessibilityLabel(labels[index])
                addSubview(button)
                buttons.append(button)
            }
        }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateControls() }
        override func layout() {
            super.layout()
            for button in buttons {
                button.setFrameOrigin(NSPoint(x: 12 + CGFloat(button.tag) * 23,
                    y: bounds.midY - button.frame.height / 2))
            }
        }
        func updateControls() {
            guard let source = window else { return }
            let owner = source.parent ?? source
            for button in buttons {
                guard let original = owner.standardWindowButton(types[button.tag]) else { button.isEnabled = false; continue }
                button.isEnabled = original.isEnabled && owner.attachedSheet == nil
                    && source.attachedSheet == nil && NSApp.modalWindow == nil
                if button.frame.size != original.frame.size { button.setFrameSize(original.frame.size) }
            }
            needsLayout = true
        }
        @objc private func performDocumentAction(_ sender: NSButton) {
            guard let source = window, types.indices.contains(sender.tag) else { return }
            let owner = source.parent ?? source
            guard owner.attachedSheet == nil, source.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            owner.standardWindowButton(types[sender.tag])?.performClick(sender)
        }
    }
}
#endif
