#if canImport(AppKit) && canImport(CefKit)
import AppKit

/// Positions only Chromium's existing transient extension surfaces. Their
/// delegates, renderer, native controls and lifetime remain owned by Chromium.
@MainActor
final class ChromiumExtensionPopover {
    private static var active: ChromiumExtensionPopover?
    private weak var page: NSWindow?
    private weak var owner: NSWindow?
    private let anchorLabel: String?
    private let isCurrent: @MainActor () -> Bool
    private let baseline: Set<Int>
    private var observers: [NSObjectProtocol] = []
    private var discovery: Task<Void, Never>?
    private var idleClose: Task<Void, Never>?
    private var adjusting = false
    private var hadVisibleWindow = false
    private var inputMonitor: Any?
    private var windows: [Int: WeakWindow] = [:]
    private final class WeakWindow { weak var value: NSWindow?; init(_ value: NSWindow) { self.value = value } }

    static func begin(page: NSWindow, owner: NSWindow, anchorLabel: String?, isCurrent: @escaping @MainActor () -> Bool) {
        active?.stop()
        let session = ChromiumExtensionPopover(page: page, owner: owner, anchorLabel: anchorLabel, isCurrent: isCurrent)
        active = session
        session.start()
    }

    private init(page: NSWindow, owner: NSWindow, anchorLabel: String?, isCurrent: @escaping @MainActor () -> Bool) {
        self.page = page; self.owner = owner; self.anchorLabel = anchorLabel; self.isCurrent = isCurrent
        baseline = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
    }

    private func start() {
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown ? event.keyCode == 53 : (event.window === self.page || event.window === self.owner) {
                self.stop()
            }
            return event
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIdleClose() }
        })
        discovery = Task { [weak self] in
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                self?.update()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        scheduleIdleClose()
    }

    private func update() {
        guard !adjusting else { return }
        guard isCurrent(), let page, let owner, page.parent === owner, page.isVisible else { stop(); return }
        guard owner.attachedSheet == nil, page.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let roots: [Any] = [page.contentView?.subviews.last, owner.contentView].compactMap { $0 }
        let preferred = anchorLabel.flatMap { ChromiumExtensionActions.controlFrame(named: $0, in: roots) }
        guard let anchor = preferred ?? ChromiumExtensionActions.controlFrame(named: "Show extensions", in: roots) else { return }
        for window in NSApp.windows where window.isVisible && window !== page && window !== owner
            && !baseline.contains(window.windowNumber) && window.parent !== owner
            && window.canBecomeKey && !window.styleMask.contains(.titled)
            && window.frame.height >= 40 && window.frame.width >= 80 {
            windows[window.windowNumber] = WeakWindow(window)
        }
        let visible = windows.values.contains { $0.value?.isVisible == true }
        if hadVisibleWindow && !visible { scheduleIdleClose() }
        hadVisibleWindow = visible
        guard !windows.values.contains(where: { $0.value?.attachedSheet != nil }) else { return }
        adjusting = true
        defer { adjusting = false }
        for value in windows.values {
            guard let window = value.value, window.isVisible else { continue }
            let screen = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? owner.frame
            let sidebar = anchorLabel?.hasSuffix(" extension") == true && preferred != nil
            var x = sidebar ? anchor.maxX + 8 : anchor.maxX - window.frame.width
            var y = anchor.minY - window.frame.height - 4
            if y < screen.minY { y = anchor.maxY + 4 }
            x = max(screen.minX, min(x, screen.maxX - window.frame.width))
            y = max(screen.minY, min(y, screen.maxY - window.frame.height))
            let origin = CGPoint(x: x.rounded(), y: y.rounded())
            if abs(window.frame.minX - origin.x) > 0.5 || abs(window.frame.minY - origin.y) > 0.5 {
                window.setFrameOrigin(origin)
            }
        }
    }

    private func scheduleIdleClose() {
        idleClose?.cancel()
        idleClose = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.windows.values.contains(where: { $0.value?.isVisible == true }) { self.stop() }
        }
    }

    private func stop() {
        discovery?.cancel(); idleClose?.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []; windows = [:]
        if Self.active === self { Self.active = nil }
    }
}
#endif
