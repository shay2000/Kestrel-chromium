#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI

/// A toolbar hosted in a CEF child still drags its owning document.
struct NativeDocumentDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard let source = window else { return }
            let owner = source.parent ?? source
            guard owner.isMovable, owner.attachedSheet == nil, source.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return }
            if !owner.isKeyWindow { owner.makeKey() }
            owner.makeMain()
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased() {
                case "minimize": owner.miniaturize(nil)
                case "none": break
                default: owner.performZoom(nil)
                }
                return
            }
            let point = owner.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
            guard let drag = NSEvent.mouseEvent(with: event.type, location: point,
                modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                windowNumber: owner.windowNumber, context: nil, eventNumber: event.eventNumber,
                clickCount: event.clickCount, pressure: event.pressure) else { return }
            owner.performDrag(with: drag)
        }
    }
}
#endif
