#if canImport(AppKit) && canImport(CefKit)
import AppKit
import CefKit

/// Activates Chromium's genuine action controls in the selected Kestrel page.
/// No helper browser, popup URL navigation, DevTools or system AX permission.
@MainActor
enum ChromiumExtensionActions {
    static func show(in chrome: CefChromeBrowser, name: String? = nil,
                     isCurrent: @escaping @MainActor () -> Bool) {
        guard let page = chrome.nsWindow, let owner = page.parent,
              page.isVisible, owner.isVisible, owner.attachedSheet == nil,
              NSApp.modalWindow == nil, isCurrent() else { return }
        // Let Kestrel's command menu finish dismissing before Chromium opens a bubble.
        Task { @MainActor [weak chrome, weak page, weak owner] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let chrome, let page, let owner, chrome.isWindowAlive,
                  chrome.nsWindow === page, page.parent === owner, isCurrent(),
                  owner.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            owner.makeMain()
            page.makeKey()
            let buttons = unique(nodes(in: [page]).filter {
                $0.accessibilityRole() == .popUpButton && label($0) == "Extensions"
            })
            let existingSurfaces = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            guard buttons.count == 1, buttons[0].accessibilityPerformPress() else { unavailable(owner: owner); return }
            guard let name else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard isCurrent(), chrome.isWindowAlive, page.parent === owner else { return }
            // Native Views bubbles are separate transient surfaces owned by the
            // existing page. Exclude all renderer web areas during traversal.
            let surfaces = NSApp.windows.filter {
                $0.isVisible && $0 !== owner && ($0 === page || !existingSurfaces.contains(ObjectIdentifier($0)))
            }
            let actions = unique(nodes(in: surfaces).filter {
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
