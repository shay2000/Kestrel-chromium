#if canImport(AppKit)
import AppKit

/// A browser document and its hosted page share keyboard ownership. Actual
/// settings windows, sheets and other applications retain their own focus.
@MainActor
enum BrowserWindowFocus {
    private static let browserWindows = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) { browserWindows.add(window) }

    static var keyboardOwner: NSWindow? {
        guard NSApp.isActive, NSApp.modalWindow == nil else { return nil }
        var candidate = NSApp.keyWindow
        while let window = candidate {
            guard window.attachedSheet == nil, window.sheetParent == nil else { return nil }
            if browserWindows.contains(window), window.isVisible, !window.isMiniaturized { return window }
            candidate = window.parent
        }
        return nil
    }

    static func isActive(_ owner: NSWindow) -> Bool {
        guard NSApp.isActive else { return false }
        if owner.isMainWindow || owner.isKeyWindow { return true }
        var candidate = NSApp.keyWindow
        while let window = candidate {
            if window === owner { return true }
            candidate = window.parent ?? window.sheetParent
        }
        return false
    }
}
#endif
