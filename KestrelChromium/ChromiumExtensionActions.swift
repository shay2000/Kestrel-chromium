#if canImport(AppKit) && canImport(CefKit)
import AppKit
import CefKit

/// Activates Chromium's genuine action controls in the selected Kestrel page.
/// No helper browser, popup URL navigation, DevTools or system AX permission.
@MainActor
enum ChromiumExtensionActions {
    private static var cachedMenuLabels: Set<String>?
    private static var menuLabels: Set<String> {
        if let cachedMenuLabels { return cachedMenuLabels }
        let names = ["IDS_ACC_NAME_EXTENSIONS_BUTTON", "IDS_TOOLTIP_EXTENSIONS_BUTTON",
                     "IDS_ACC_NAME_EXTENSIONS_BUTTON_ALL_EXTENSIONS_BLOCKED",
                     "IDS_ACC_NAME_EXTENSIONS_BUTTON_ANY_EXTENSION_HAS_ACCESS"]
        let labels = Set(names.compactMap { CefChromeBrowser.localizedChromeString(named: $0) }.filter { !$0.isEmpty })
        cachedMenuLabels = labels.isEmpty ? ["Extensions"] : labels
        return cachedMenuLabels!
    }

    static func pinnedActions(in chrome: CefChromeBrowser, installed: [ChromiumExtensionDescriptor]) -> [String] {
        guard chrome.isWindowAlive, chrome.nsWindow?.isVisible == true else { return [] }
        let labels = nativeActionControls(in: chrome)
            .map { label($0).components(separatedBy: "\n").first ?? "" }
        return installed.filter { labels.contains($0.name) }.map(\.id)
    }

    static func show(in chrome: CefChromeBrowser, name: String? = nil, anchorLabel: String? = nil,
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
            ChromiumExtensionPopover.begin(page: page, owner: owner,
                anchorLabel: anchorLabel, isCurrent: isCurrent)
            if let name {
                let pinned = unique(nativeActionControls(in: chrome).filter {
                    label($0).components(separatedBy: "\n").first == name
                })
                if pinned.count == 1 { _ = pinned[0].accessibilityPerformPress(); return }
            }
            let existingSurfaces = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            var button = menuButton(in: chrome)
            for _ in 0..<12 where button == nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard isCurrent(), chrome.isWindowAlive else { return }
                button = menuButton(in: chrome)
            }
            guard let button, button.accessibilityPerformPress() else { unavailable(owner: owner); return }
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

    private static func menuButton(in chrome: CefChromeBrowser) -> NSAccessibilityProtocol? {
        let values = unique(nodes(in: [chrome.rootView].compactMap { $0 }).filter {
            $0.accessibilityRole() == .popUpButton && menuLabels.contains(label($0))
        })
        return values.count == 1 ? values[0] : nil
    }

    private static func nativeActionControls(in chrome: CefChromeBrowser) -> [NSAccessibilityProtocol] {
        guard let page = chrome.nsWindow else { return [] }
        return unique(nodes(in: [chrome.rootView].compactMap { $0 }).filter {
            guard $0.accessibilityRole() == .popUpButton,
                  !menuLabels.contains(label($0)) else { return false }
            let window = $0.accessibilityWindow() as AnyObject?
            return window === page || label($0).contains("\n")
        })
    }

    private static func nodes(in roots: [Any]) -> [NSAccessibilityProtocol] {
        var pending = roots, seen = Set<ObjectIdentifier>(), result: [NSAccessibilityProtocol] = []
        while !pending.isEmpty && seen.count < 4096 {
            let next = pending.removeFirst() as AnyObject
            guard seen.insert(ObjectIdentifier(next)).inserted,
                  let element = next as? NSAccessibilityProtocol else { continue }
            guard element.accessibilityRole()?.rawValue != "AXWebArea",
                  element.accessibilityLabel() != "Kestrel browser controls" else { continue }
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
