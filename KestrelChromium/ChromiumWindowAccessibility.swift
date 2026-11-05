#if canImport(AppKit)
import AppKit

/// Refresh the standard AppKit children after CEF creates its native tree.
/// Leave the CEF window class, content view and accessibility implementation intact.
@MainActor
enum ChromiumWindowAccessibility {
    @discardableResult
    static func update(window: NSWindow, header: NSView?) -> Bool {
        window.setAccessibilityChildren(nil)
        guard let header, header.window === window else { return true }
        let children = window.accessibilityChildren()?.filter { ($0 as AnyObject) !== header } ?? []
        window.setAccessibilityChildren(children + [header])
        return true
    }
}
#endif
