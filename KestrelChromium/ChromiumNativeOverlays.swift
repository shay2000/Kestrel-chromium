#if canImport(AppKit)
import AppKit
import ObjectiveC.runtime

/// CEF's native root must remain the window's contentView. Its Views hit-test
/// override otherwise skips AppKit overlays. Give only that instance a public
/// NSView.hitTest override, preserving the original implementation for pages.
/// Normal NSWindow dispatch then drives native gestures and field editors.
@MainActor
enum ChromiumNativeOverlays {
    private final class Context: NSObject {
        weak var header: NSView?
        weak var pageOverlay: NSView?
    }
    private static var contextKey: UInt8 = 0
    private static var subclasses: [ObjectIdentifier: AnyClass] = [:]

    @discardableResult
    static func update(root: NSView, header: NSView?, pageOverlay: NSView?) -> Bool {
        let context: Context
        if let existing = objc_getAssociatedObject(root, &contextKey) as? Context {
            context = existing
        } else {
            guard let original = object_getClass(root), let subclass = subclass(for: original) else { return false }
            context = Context()
            objc_setAssociatedObject(root, &contextKey, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            object_setClass(root, subclass)
        }
        context.header = header
        context.pageOverlay = pageOverlay
        return true
    }

    private static func subclass(for original: AnyClass) -> AnyClass? {
        let key = ObjectIdentifier(original)
        if let existing = subclasses[key] { return existing }
        let selector = #selector(NSView.hitTest(_:))
        guard let method = class_getInstanceMethod(original, selector),
              let encoding = method_getTypeEncoding(method),
              let implementation = class_getMethodImplementation(original, selector) else { return nil }
        typealias HitTest = @convention(c) (AnyObject, Selector, NSPoint) -> NSView?
        let originalHitTest = unsafeBitCast(implementation, to: HitTest.self)
        let name = "KestrelNativeHitTest_" + NSStringFromClass(original).replacingOccurrences(of: ".", with: "_")
        guard let subclass = objc_allocateClassPair(original, name, 0) else { return nil }
        let hitTest: @convention(block) (NSView, NSPoint) -> NSView? = { root, point in
            MainActor.assumeIsolated {
                if let context = objc_getAssociatedObject(root, &contextKey) as? Context {
                    let local = root.convert(point, from: root.superview)
                    for overlay in [context.header, context.pageOverlay] {
                        if let overlay, overlay.superview === root, let target = overlay.hitTest(local) {
                            return target
                        }
                    }
                }
                return originalHitTest(root, selector, point)
            }
        }
        let hitTestImplementation = imp_implementationWithBlock(hitTest)
        guard class_addMethod(subclass, selector, hitTestImplementation, encoding) else {
            imp_removeBlock(hitTestImplementation)
            objc_disposeClassPair(subclass)
            return nil
        }
        objc_registerClassPair(subclass)
        subclasses[key] = subclass
        return subclass
    }
}
#endif
