import AppKit
import ObjectiveC.runtime

@MainActor
private class ViewsRoot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { self }
}

@MainActor
private class LiveAXWindow: NSWindow {
    var engineChildren: [Any] = []
    override func accessibilityChildren() -> [Any]? { engineChildren }
}

@main @MainActor
struct NativeOverlayRegression {
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 200, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = ViewsRoot(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = root
        window.orderFront(nil)
        let untouched = ViewsRoot(frame: root.bounds)
        let header = NSView(frame: NSRect(x: 0, y: 160, width: 200, height: 40))
        root.addSubview(header)
        let headerPoint = NSPoint(x: 30, y: 180), pagePoint = NSPoint(x: 30, y: 40)
        precondition(root.hitTest(headerPoint) === root, "baseline must reproduce CEF's interception")
        precondition(ChromiumNativeOverlays.update(root: root, header: header, pageOverlay: nil))
        precondition(root.hitTest(headerPoint) === header, "native overlays must receive ordinary window hit testing")
        precondition(root.hitTest(pagePoint) === root, "page hits must retain the original implementation")
        precondition(window.contentView === root && header.superview === root && root.window === window,
                     "CEF's native hierarchy and window ownership must remain unchanged")
        precondition(root.isKind(of: ViewsRoot.self), "CEF's original class must remain in the inheritance chain")
        precondition(untouched.hitTest(headerPoint) === untouched, "other instances must remain unchanged")
        let installedClass = object_getClass(root)
        precondition(ChromiumNativeOverlays.update(root: root, header: nil, pageOverlay: nil))
        precondition(root.hitTest(headerPoint) === root, "detaching overlays must restore original hit behaviour")
        precondition(object_getClass(root) === installedClass, "rebinding must not build subclass chains")
        weak var released: NSView?
        autoreleasepool {
            let transient = NSView(frame: header.frame)
            root.addSubview(transient)
            released = transient
            precondition(ChromiumNativeOverlays.update(root: root, header: transient, pageOverlay: nil))
            precondition(root.hitTest(headerPoint) === transient)
            transient.removeFromSuperview()
        }
        precondition(released == nil, "native overlay registration must not retain removed views")
        precondition(root.hitTest(headerPoint) === root)
        let live = LiveAXWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        live.isReleasedWhenClosed = false
        let nativeControls = NSView(frame: root.bounds)
        live.contentView?.addSubview(nativeControls)
        precondition(ChromiumWindowAccessibility.update(window: live, header: nativeControls))
        precondition(live.accessibilityChildren()?.count == 1)
        let lateEngineRoot = NSAccessibilityElement()
        live.engineChildren = [lateEngineRoot]
        precondition(live.accessibilityChildren()?.count == 2, "late CEF trees must remain accessible")
        precondition((live.accessibilityChildren()?.first as AnyObject?) === lateEngineRoot)
        precondition(ChromiumWindowAccessibility.update(window: live, header: nil))
        precondition(live.accessibilityChildren()?.count == 1, "detach must leave the current engine tree")
        live.close()
        window.close()
        print("Native overlay hit testing: dispatch, page fallback, ownership, instance isolation, rebinding and weak lifetime passed")
    }
}
