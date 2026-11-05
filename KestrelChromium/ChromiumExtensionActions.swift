#if canImport(AppKit) && canImport(CefKit)
import AppKit
import CefKit

/// Activates Chromium's genuine action controls in the selected Kestrel page.
/// No helper browser, popup URL navigation, DevTools or system AX permission.
@MainActor
enum ChromiumExtensionActions {
    static func alignToolbar(in chrome: CefChromeBrowser, header: NSView, height: CGFloat) {
        guard let root = chrome.rootView, height > 0 else { return }
        let base = CGRect(x: 0, y: -height, width: root.bounds.width, height: height)
        chrome.setChromeToolbarBounds(base)
        guard let engine = menuButton(in: chrome, height: height),
              let control = nodes(in: [header]).first(where: {
                  $0.accessibilityRole() == .button && label($0) == "Show extensions"
              }) else { return }
        let native = engine.accessibilityFrame(), target = control.accessibilityFrame()
        guard !native.isEmpty, !target.isEmpty else { return }
        chrome.setChromeToolbarBounds(CGRect(x: target.midX - native.midX,
            y: -height + native.midY - target.midY, width: base.width, height: base.height))
    }

    static func pinnedActions(in chrome: CefChromeBrowser, installed: [ChromiumExtensionDescriptor]) -> [String] {
        guard chrome.isWindowAlive, chrome.nsWindow?.isVisible == true else { return [] }
        let labels = nodes(in: [chrome.rootView].compactMap { $0 })
            .filter { $0.accessibilityRole() == .popUpButton }
            .map { label($0).components(separatedBy: "\n").first ?? "" }
        return installed.filter { $0.name != "Extensions" && labels.contains($0.name) }.map(\.id)
    }

    static func show(in chrome: CefChromeBrowser, name: String? = nil,
                     isCurrent: @escaping @MainActor () -> Bool) {
        guard let page = chrome.nsWindow, let owner = page.parent,
              page.isVisible, owner.isVisible, owner.attachedSheet == nil, page.attachedSheet == nil,
              NSApp.modalWindow == nil, isCurrent() else { return }
        // Let Kestrel's command menu finish dismissing before Chromium opens a bubble.
        Task { @MainActor [weak chrome, weak page, weak owner] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let chrome, let page, let owner, chrome.isWindowAlive,
                  chrome.nsWindow === page, page.parent === owner, isCurrent(),
                  owner.attachedSheet == nil, page.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            owner.orderFront(nil)
            owner.makeMain()
            page.makeKey()
            if let header = chrome.rootView?.subviews.first(where: { $0.accessibilityLabel() == "Kestrel browser controls" }) {
                alignToolbar(in: chrome, header: header, height: BrowserChromeLayout.headerHeight)
            }
            if let name {
                let existing = unique(nodes(in: [chrome.rootView].compactMap { $0 }).filter { $0.accessibilityRole() == .button && label($0) == name })
                if existing.count == 1 { _ = existing[0].accessibilityPerformPress(); return }
            }
            let existingSurfaces = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            guard let button = menuButton(in: chrome, height: BrowserChromeLayout.headerHeight),
                  button.accessibilityPerformPress() else { unavailable(owner: owner); return }
            guard let name else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard isCurrent(), chrome.isWindowAlive, page.parent === owner else { return }
            // Native Views bubbles are separate transient surfaces owned by the
            // existing page. Exclude all renderer web areas during traversal.
            let surfaces = NSApp.windows.filter {
                $0.isVisible && $0 !== owner && ($0 === page || !existingSurfaces.contains(ObjectIdentifier($0)))
            }
            let actions = unique(nodes(in: surfaces.compactMap(\.contentView)).filter {
                $0.accessibilityRole() == .button && label($0) == name
            })
            // Duplicate names never choose an arbitrary action. Leave the real
            // Extensions menu open so the user can select the intended item.
            guard actions.count == 1 else { return }
            _ = actions[0].accessibilityPerformPress()
        }
    }

    private static func label(_ element: NSAccessibilityProtocol) -> String {
        let value = element.accessibilityLabel() ?? ""
        return value.isEmpty ? (element.accessibilityTitle() ?? "") : value
    }

    /// Chromium's Extensions control follows its pinned action buttons. Scope
    /// this to the reserved native toolbar so localised labels work and page
    /// controls cannot be mistaken for browser actions.
    private static func menuButton(in chrome: CefChromeBrowser, height: CGFloat) -> NSAccessibilityProtocol? {
        guard let page = chrome.nsWindow else { return nil }
        let strip = CGRect(x: page.frame.minX, y: page.frame.maxY - height - 8,
                           width: page.frame.width, height: height + 16)
        return unique(nodes(in: [chrome.rootView].compactMap { $0 }).filter {
            let frame = $0.accessibilityFrame()
            return $0.accessibilityRole() == .popUpButton && !frame.isEmpty
                && strip.contains(CGPoint(x: frame.midX, y: frame.midY))
        }).max { $0.accessibilityFrame().midX < $1.accessibilityFrame().midX }
    }

    private static func nodes(in roots: [Any]) -> [NSAccessibilityProtocol] {
        var pending = roots, seen = Set<ObjectIdentifier>(), result: [NSAccessibilityProtocol] = []
        while !pending.isEmpty && seen.count < 4096 {
            let next = pending.removeFirst() as AnyObject
            guard seen.insert(ObjectIdentifier(next)).inserted,
                  let element = next as? NSAccessibilityProtocol else { continue }
            guard element.accessibilityRole()?.rawValue != "AXWebArea" else { continue }
            result.append(element)
            pending += element.accessibilityChildren() ?? []
        }
        return result
    }

    private static func unique(_ values: [NSAccessibilityProtocol]) -> [NSAccessibilityProtocol] {
        var frames = Set<String>()
        return values.filter { frames.insert(NSStringFromRect($0.accessibilityFrame())).inserted }
    }

    private static func unavailable(owner: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Extensions are not ready"
        alert.informativeText = "Wait for this page to finish opening, then try again. You can manage installed extensions from Kestrel’s Extensions menu."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: owner)
    }
}
#endif
