#if canImport(AppKit)
import AppKit

/// Coordinates AppKit focus without reparenting CEF's render views, replacing
/// its window delegate, or changing the Chromium runtime/renderer sandbox.
@MainActor
final class ChromiumWindowAttachment {
    private weak var owner: NSWindow?
    private weak var page: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var loggedPointerEvents = 0
    var onFocus: (() -> Void)?
    var headerHeight: CGFloat = 0
    var isNativeControlPoint: ((CGPoint) -> Bool)?
    var handleNativeControlEvent: ((NSEvent) -> Bool)?

    func attach(owner: NSWindow, page: NSWindow) {
        guard self.owner !== owner || self.page !== page else { return }
        detach()
        self.owner = owner
        self.page = page
        loggedPointerEvents = 0
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: page, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onFocus?()
                    // Native activation is still unwinding. Do not fight it
                    // reentrantly or take the page's keyboard responder away.
                    DispatchQueue.main.async { [weak self] in self?.restoreDocumentMainWindow() }
                }
            })
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]) { [weak self] event in
            guard let self, let owner = self.owner, let page = self.page,
                  page.parent === owner, NSApp.isActive, owner.isVisible,
                  !owner.isMiniaturized, owner.attachedSheet == nil, page.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return event }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
               event.window === page || event.window === owner,
               self.loggedPointerEvents < 10,
               CommandLine.arguments.contains("--remote-debugging-port=9333") {
                self.loggedPointerEvents += 1
                let diagnostic = "KESTREL_LIFECYCLE windowGeometry pointerWindow=\(event.windowNumber) owner=\(owner.windowNumber) page=\(page.windowNumber) point=\(NSStringFromPoint(event.locationInWindow)) native=\(self.isNativeControlPoint?(event.locationInWindow) ?? false)"
                try? FileHandle.standardError.write(contentsOf: Data((diagnostic + "\n").utf8))
            }
            if event.window === page {
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                    if !page.isKeyWindow { page.makeKey() }
                    owner.makeMain()
                    if !(self.isNativeControlPoint?(event.locationInWindow)
                        ?? (event.locationInWindow.y >= page.frame.height - self.headerHeight)) {
                        self.onFocus?()
                    }
                }
                if self.handleNativeControlEvent?(event) == true { return nil }
            } else if event.window === owner,
                      [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                // Activate the target before AppKit makes its first-mouse
                // decision. Deliver the same event once, without replaying it.
                if !owner.isKeyWindow { owner.makeKey() }
                owner.makeMain()
            }
            return event
        }
        restoreDocumentMainWindow()
    }

    private func restoreDocumentMainWindow() {
        guard let owner, let page, page.parent === owner, page.isKeyWindow,
              NSApp.isActive, owner.isVisible, !owner.isMiniaturized,
              owner.attachedSheet == nil, page.attachedSheet == nil,
              NSApp.modalWindow == nil else { return }
        if !owner.isMainWindow { owner.makeMain() }
    }

    func detach() {
        if let owner, let page, page.isKeyWindow, page.parent === owner,
           NSApp.isActive, owner.isVisible, !owner.isMiniaturized,
           owner.attachedSheet == nil, page.attachedSheet == nil, NSApp.modalWindow == nil {
            owner.makeKey()
            owner.makeMain()
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        owner = nil
        page = nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }
}
#endif
