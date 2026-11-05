#if canImport(AppKit)
import AppKit
import ObjectiveC.runtime

/// Append Kestrel's controls to the live CEF tree. A stored children snapshot
/// can replace an engine tree which has not finished initialising yet.
@MainActor
enum ChromiumWindowAccessibility {
    private final class Context: NSObject { weak var header: NSView? }
    private static var contextKey: UInt8 = 0
    private static var subclasses: [ObjectIdentifier: AnyClass] = [:]

    @discardableResult
    static func update(window: NSWindow, header: NSView?) -> Bool {
        let context: Context
        if let existing = objc_getAssociatedObject(window, &contextKey) as? Context { context = existing }
        else {
            guard let original = object_getClass(window), let subclass = subclass(for: original) else { return false }
            context = Context()
            objc_setAssociatedObject(window, &contextKey, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            object_setClass(window, subclass)
        }
        context.header = header
        return true
    }

    private static func subclass(for original: AnyClass) -> AnyClass? {
        let key = ObjectIdentifier(original)
        if let existing = subclasses[key] { return existing }
        let selector = #selector(NSWindow.accessibilityChildren)
        guard let method = class_getInstanceMethod(original, selector),
              let encoding = method_getTypeEncoding(method),
              let implementation = class_getMethodImplementation(original, selector) else { return nil }
        typealias Children = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let originalChildren = unsafeBitCast(implementation, to: Children.self)
        let name = "KestrelLiveAccessibility_" + NSStringFromClass(original).replacingOccurrences(of: ".", with: "_")
        guard let subclass = objc_allocateClassPair(original, name, 0) else { return nil }
        let getter: @convention(block) (NSWindow) -> NSArray? = { window in
            MainActor.assumeIsolated {
                let children = originalChildren(window, selector)?.takeUnretainedValue() as? [Any] ?? []
                guard let header = (objc_getAssociatedObject(window, &contextKey) as? Context)?.header,
                      header.window === window else { return children as NSArray }
                return (children.filter { ($0 as AnyObject) !== header } + [header]) as NSArray
            }
        }
        let getterIMP = imp_implementationWithBlock(getter)
        guard class_addMethod(subclass, selector, getterIMP, encoding) else {
            imp_removeBlock(getterIMP)
            objc_disposeClassPair(subclass)
            return nil
        }
        objc_registerClassPair(subclass)
        subclasses[key] = subclass
        return subclass
    }
}
#endif
