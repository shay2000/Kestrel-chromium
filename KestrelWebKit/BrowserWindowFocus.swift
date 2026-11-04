#if canImport(AppKit)
import AppKit

/// A browser document and its hosted page share keyboard ownership. Actual
/// settings windows, sheets and other applications retain their own focus.
@MainActor
enum BrowserWindowFocus {
    private static let browserWindows = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) { browserWindows.add(window) }

    static var keyboardOwner: NSWindow? {
        guard NSApp.isActive, NSApp.modalWindow == nil, let key = NSApp.keyWindow,
              key.attachedSheet == nil, key.sheetParent == nil, !(key is NSPanel),
              let owner = browserWindows.contains(key) ? key : key.parent,
              browserWindows.contains(owner), owner.isVisible, !owner.isMiniaturized,
              owner.attachedSheet == nil else { return nil }
        // Only the document or its direct page owns browser commands. A
        // nested DevTools/menu/utility window keeps its own Close command.
        return owner
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
