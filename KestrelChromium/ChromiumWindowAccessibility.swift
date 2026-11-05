#if canImport(AppKit)
import AppKit

/// Refresh the standard AppKit children after CEF creates its native tree.
/// Leave the CEF window class, content view and accessibility implementation intact.
@MainActor
enum ChromiumWindowAccessibility {
    @discardableResult
    static func update(window: NSWindow, header: NSView?) -> Bool {
        // CEF's native root supplies the engine tree; NSWindow's stored
        // children attribute can otherwise hide that tree, even when nil.
        let children = window.contentView?.accessibilityChildren() ?? []
        guard let header, header.window === window else {
            window.setAccessibilityChildren(children)
            return true
        }
        window.setAccessibilityChildren(children.filter { ($0 as AnyObject) !== header } + [header])
        return true
    }
}
#endif
