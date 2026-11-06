#if canImport(SwiftUI) && canImport(CefSwiftUI)
import AppKit
import SwiftUI

/// Native geometry is available even when macOS has no accessibility client.
/// These invisible background views never participate in pointer dispatch.
@MainActor
enum ChromiumExtensionAnchors {
    private final class Entry { weak var view: ExtensionControlAnchorView?; init(_ view: ExtensionControlAnchorView) { self.view = view } }
    private static var entries: [Entry] = []
    static func register(_ view: ExtensionControlAnchorView) { entries.append(Entry(view)) }
    static func frame(named name: String, in windows: [NSWindow]) -> CGRect? {
        entries.removeAll { $0.view == nil }
        for window in windows where window.isVisible {
            let views = entries.compactMap(\.view).filter {
                $0.name == name && $0.window === window && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty
            }
            if views.count == 1 {
                return window.convertToScreen(views[0].convert(views[0].bounds, to: nil))
            }
        }
        return nil
    }
}

@MainActor
final class ExtensionControlAnchorView: NSView {
    var name = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct ExtensionControlAnchor: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> ExtensionControlAnchorView {
        let view = ExtensionControlAnchorView()
        view.name = name
        view.setAccessibilityElement(false)
        ChromiumExtensionAnchors.register(view)
        return view
    }
    func updateNSView(_ view: ExtensionControlAnchorView, context: Context) { view.name = name }
}
#endif
