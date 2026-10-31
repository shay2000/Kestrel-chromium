// Disposable-runner acceptance of the real Chrome Web Store install flow.
// CDP reads page state and sends pointer input; it never calls an install API.
// Native confirmation is activated through AX or a visible OCR target.
import AppKit
import ApplicationServices
import Foundation
import Vision

struct StoreProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

#if !KESTREL_LIFECYCLE_HARNESS
@main
#endif
@MainActor
struct ChromeWebStoreAcceptance {
    static var app = URL(fileURLWithPath: "/")
    static var output = URL(fileURLWithPath: "/")
    static var testedPID: pid_t?
    static var testedPIDs = Set<Int>()
    static var sockets: [String: URLSessionWebSocketTask] = [:]
    static var nextCommandID = 0
    static let port = 9333
    static var uaProbe = false
    static let items = [
        (id: "aapbdbdomjkkjkaonfhkkikfgjllcleb", slug: "google-translate", name: "Google Translate"),
        (id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", slug: "dark-reader", name: "Dark Reader")
    ]

    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw StoreProbeError(message: "usage: chrome-web-store-test Kestrel.app evidence-directory")
            }
            app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await launch(reuse: true)
            await widenRunnerWindow()
            try await inspectWindowSurfaces(stage: "before-install")
            var installed = Set<String>()
            var failures: [String] = []
            for item in items {
                do {
                    try await install(id: item.id, slug: item.slug, name: item.name); installed.insert(item.id)
                    await pause(5)
                    try await inspectWindowSurfaces(stage: "after-\(item.slug)")
                }
                catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                    record("item_failed", ["name": item.name, "error": error.localizedDescription])
                    try? capture("\(item.slug)-failure")
                }
            }
            if installed.contains(items[1].id) { try await verifyDarkReader(stage: "before-restart") }
            if ProcessInfo.processInfo.environment["KESTREL_REQUIRE_EXTENSION_WINDOW_FIXTURE"] == "1" {
                try await verifyFixtureOptions()
            }
            if !installed.isEmpty { try await launch(); await widenRunnerWindow() }
            for item in items where installed.contains(item.id) {
                guard let manifest = try installedManifest(id: item.id) else {
                    throw StoreProbeError(message: "Installed extension disappeared after restart: \(item.name)")
                }
                record("persisted", ["name": item.name, "manifest": manifest.path])
            }
            if installed.contains(items[1].id) { try await verifyDarkReader(stage: "after-restart") }
            try await inspectWindowSurfaces(stage: "after-restart")
            if !failures.isEmpty { throw StoreProbeError(message: failures.joined(separator: "; ")) }
            await pause(15)
            guard !collectCrashReports() else { throw StoreProbeError(message: "A tested Kestrel process crashed during quit/restart") }
            collectLifecycleLog()
            try save("result.json", ["passed": true, "runtimeUserAgentProbe": uaProbe,
                                     "installedIDs": items.map(\.id), "restartRuntimePassed": true])
            print("Chrome Web Store native install and restart acceptance passed. User-agent probe: \(uaProbe)")
        } catch {
            try? capture("failure")
            try? dumpAX("failure-ax.json")
            collectLifecycleLog()
            collectCrashReports()
            try? save("result.json", ["passed": false, "runtimeUserAgentProbe": uaProbe,
                                     "error": error.localizedDescription])
            fputs("Chrome Web Store acceptance failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func widenRunnerWindow() async {
        let display = CGMainDisplayID()
        if CGDisplayBounds(display).width < 1600,
           let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode],
           let mode = modes.filter({ $0.width >= 1600 && $0.width <= 2560 && $0.height >= 900 && $0.height <= 1600 })
                .sorted(by: { $0.width * $0.height < $1.width * $1.height }).first {
            let status = CGDisplaySetDisplayMode(display, mode, nil)
            record("display_mode", ["width": mode.width, "height": mode.height, "status": status.rawValue])
            await pause(2)
        }
        guard let pid = testedPID else { return }
        let root = AXUIElementCreateApplication(pid)
        let windows = ax(root, "AXWindows") as? [AXUIElement] ?? []
        guard let window = windows.first(where: { String(describing: ax($0, "AXTitle") ?? "" as CFString) == "Kestrel" }) else {
            record("window_resize", ["availableTitles": windows.map { String(describing: ax($0, "AXTitle") ?? "" as CFString) }]); return
        }
        let bounds = CGDisplayBounds(display)
        var size = CGSize(width: min(1680, bounds.width - 40), height: min(980, bounds.height - 80))
        var point = CGPoint(x: bounds.minX + 20, y: bounds.minY + 40)
        if let value = AXValueCreate(.cgSize, &size) { _ = AXUIElementSetAttributeValue(window, "AXSize" as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &point) { _ = AXUIElementSetAttributeValue(window, "AXPosition" as CFString, value) }
        record("window_resize", ["width": size.width, "height": size.height]); await pause(2)
    }

    @discardableResult static func collectCrashReports() -> Bool {
        let reports = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey]) else { return false }
        var found = false
        let destination = output.appendingPathComponent("crash-reports")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files where file.lastPathComponent.hasPrefix("Kestrel") {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) < 3600 else { continue }
            try? FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                let body = text.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? text
                if let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let pid = object["pid"] as? Int, testedPIDs.contains(pid) { found = true }
                record("crash_report", ["file": file.lastPathComponent, "text": String(text.prefix(20000))])
            }
        }
        return found
    }

    static func record(_ event: String, _ details: [String: Any] = [:]) {
        let value = ["event": event, "details": details, "time": ISO8601DateFormatter().string(from: Date())] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
        let url = output.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: url) {
            _ = try? file.seekToEnd(); try? file.write(contentsOf: data + Data([10])); try? file.close()
        }
    }

    static func save(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name))
    }

    static func command(_ executable: String, _ arguments: [String]) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        try child.run(); child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw StoreProbeError(message: "Failed command: \(executable)") }
    }

    static func pause(_ seconds: Double = 1) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    static func collectLifecycleLog() {
        let destination = output.appendingPathComponent("native-lifecycle.log")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let file = try? FileHandle(forWritingTo: destination) else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "15m", "--style", "compact", "--predicate", "eventMessage BEGINSWITH 'KESTREL_LIFECYCLE'"]
        process.standardOutput = file; process.standardError = file
        try? process.run(); process.waitUntilExit(); try? file.close()
        if let value = try? String(contentsOf: destination, encoding: .utf8) { print(String(value.suffix(24000))) }
    }

    static func launch(reuse: Bool = false) async throws {
        if reuse, let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.shayprasad.Kestrel").first(where: { $0.bundleURL?.standardizedFileURL.path == app.path }),
           (try? await targets()) != nil {
            testedPID = running.processIdentifier; testedPIDs.insert(Int(running.processIdentifier))
            running.activate(options: [.activateIgnoringOtherApps])
            record("reused_running_app", ["pid": running.processIdentifier, "bundle": app.path])
            return
        }
        for socket in sockets.values { socket.cancel(with: .normalClosure, reason: nil) }
        sockets = [:]
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: "com.shayprasad.Kestrel")
            where running.bundleURL?.standardizedFileURL.path == app.path { running.terminate() }
        for _ in 0..<15 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.shayprasad.Kestrel")
                .allSatisfy({ $0.bundleURL?.standardizedFileURL.path != app.path }) { break }
            await pause()
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.shayprasad.Kestrel")
            .allSatisfy({ $0.bundleURL?.standardizedFileURL.path != app.path }) else {
            throw StoreProbeError(message: "Kestrel did not finish quitting before restart")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--remote-debugging-port=\(port)", "--force-renderer-accessibility"]
        let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { application, error in
                if let application { continuation.resume(returning: application) }
                else { continuation.resume(throwing: error ?? StoreProbeError(message: "LaunchServices could not relaunch Kestrel")) }
            }
        }
        testedPID = running.processIdentifier; testedPIDs.insert(Int(running.processIdentifier))
        for _ in 0..<30 {
            if !running.isTerminated {
                running.activate(options: [.activateIgnoringOtherApps])
                if (try? await targets()) != nil {
                    record("launched", ["pid": running.processIdentifier, "bundle": running.bundleURL?.path ?? "unknown"])
                    return
                }
            }
            await pause()
        }
        throw StoreProbeError(message: "Kestrel did not expose its loopback test endpoint or remain running.")
    }

    static func targets() async throws -> [[String: Any]] {
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        var request = URLRequest(url: url); request.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    static func target(matching url: String) async throws -> [String: Any] {
        for _ in 0..<40 {
            if let page = try await targets().first(where: { ($0["type"] as? String) == "page" && ($0["url"] as? String)?.hasPrefix(url) == true }) { return page }
            await pause()
        }
        throw StoreProbeError(message: "No Kestrel page target for \(url)")
    }

    static func cdp(_ page: [String: Any], _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let rawURL = page["webSocketDebuggerUrl"] as? String, let url = URL(string: rawURL),
              url.host == "127.0.0.1" || url.host == "localhost" else { throw StoreProbeError(message: "No loopback page endpoint") }
        let socket: URLSessionWebSocketTask
        if let existing = sockets[rawURL] { socket = existing }
        else { socket = URLSession.shared.webSocketTask(with: url); socket.resume(); sockets[rawURL] = socket }
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 12_000_000_000); socket.cancel(with: .goingAway, reason: nil) }
            catch { }
        }
        defer { timeout.cancel() }
        nextCommandID += 1
        let commandID = nextCommandID
        let data = try JSONSerialization.data(withJSONObject: ["id": commandID, "method": method, "params": params])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let bytes: Data
            switch message { case .data(let value): bytes = value; case .string(let value): bytes = Data(value.utf8); @unknown default: continue }
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["id"] as? Int == commandID else { continue }
            if let error = object["error"] { throw StoreProbeError(message: "CDP \(method): \(error)") }
            return object["result"] as? [String: Any] ?? [:]
        }
    }

    static func evaluate(_ page: [String: Any], _ expression: String) async throws -> Any {
        let result = try await cdp(page, "Runtime.evaluate", ["expression": expression, "returnByValue": true])
        if result["exceptionDetails"] != nil { throw StoreProbeError(message: "Page diagnostic expression failed") }
        return (result["result"] as? [String: Any])?["value"] ?? NSNull()
    }

    static func open(_ url: String) async throws -> [String: Any] {
        try command("/usr/bin/open", ["-a", app.path, url])
        return try await target(matching: url)
    }

    static let storeState = """
    (() => ({url:location.href, title:document.title, userAgent:navigator.userAgent,
      privateAPI:typeof window.chrome?.webstorePrivate,
      beginInstall:typeof window.chrome?.webstorePrivate?.beginInstallWithManifest3,
      completeInstall:typeof window.chrome?.webstorePrivate?.completeInstall,
      text:(document.body?.innerText||'').slice(0,14000),
      viewport:{width:innerWidth,height:innerHeight,devicePixelRatio,scrollX,scrollY},
      buttons:Array.from(document.querySelectorAll('button')).map(e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return {text:(e.innerText||e.getAttribute('aria-label')||'').trim(),disabled:e.disabled,display:s.display,visibility:s.visibility,rect:{x:r.x,y:r.y,width:r.width,height:r.height}}}).slice(0,100)}))()
    """

    static func install(id: String, slug: String, name: String) async throws {
        let url = "https://chromewebstore.google.com/detail/\(slug)/\(id)"
        let page = try await open(url); await pause(12)
        let baseline = try await evaluate(page, storeState)
        try save("\(slug)-baseline.json", baseline); record("store_baseline", ["name": name, "state": baseline])
        try capture("\(slug)-baseline")
        var state = baseline as? [String: Any] ?? [:]
        await clearRunnerDialogues()
        if try await clickPageButton(page, label: "No thanks") { await pause(2) }
        if try await buttonLocation(page, label: "Add to Chrome") == nil,
           (state["text"] as? String)?.localizedCaseInsensitiveContains("Switch to Chrome") == true,
           (state["userAgent"] as? String)?.contains("KestrelChromium/1.0") == true {
            let version = try await cdp(page, "Browser.getVersion")
            let product = version["product"] as? String ?? ""
            let original = state["userAgent"] as? String ?? ""
            guard product.range(of: #"^(?:Chrome|Chromium)/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                  original.contains("KestrelChromium/1.0") else {
                throw StoreProbeError(message: "The native install button is unavailable; a measured engine identity was not available for the diagnostic UA probe. \(version)")
            }
            let engineUA = original.replacingOccurrences(of: "KestrelChromium/1.0", with: product)
            _ = try await cdp(page, "Emulation.setUserAgentOverride", ["userAgent": engineUA])
            _ = try await cdp(page, "Page.reload", ["ignoreCache": true]); await pause(10)
            uaProbe = true
            state = try await evaluate(page, storeState) as? [String: Any] ?? [:]
            try save("\(slug)-engine-ua.json", state)
            record("engine_ua_probe", ["name": name, "product": product, "state": state])
            try capture("\(slug)-engine-ua")
            if try await clickPageButton(page, label: "No thanks") { await pause(2) }
        }
        try capture("\(slug)-before-install")
        guard try await clickPageButton(page, label: "Add to Chrome") else {
            throw StoreProbeError(message: "No unique enabled visible Add to Chrome button for \(name)")
        }
        record("clicked_store_install", ["name": name])
        try await confirmNativeInstall(name: name, slug: slug)
        for _ in 0..<40 {
            if let manifest = try installedManifest(id: id) {
                try save("\(slug)-installed.json", ["id": id, "manifestPath": manifest.path,
                        "manifest": try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))])
                record("installed", ["name": name, "id": id, "manifest": manifest.path])
                try capture("\(slug)-installed"); return
            }
            await pause()
        }
        throw StoreProbeError(message: "Native approval did not create the installed extension: \(name)")
    }

    static func buttonLocation(_ page: [String: Any], label: String) async throws -> [String: Any]? {
        let text = String(decoding: try JSONEncoder().encode(label), as: UTF8.self)
        _ = try await evaluate(page, """
        (()=>{const a=Array.from(document.querySelectorAll('button')).filter(e=>e.innerText.trim()===\(text)&&!e.disabled);if(a.length===1)a[0].scrollIntoView({block:'center',inline:'center',behavior:'instant'});return true;})()
        """)
        await pause(0.2)
        return try await evaluate(page, """
        (()=>{const a=Array.from(document.querySelectorAll('button')).filter(e=>e.innerText.trim()===\(text)&&!e.disabled).map(e=>({e,r:e.getBoundingClientRect()})).filter(({e,r})=>r.width>0&&r.height>0&&r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight&&e.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)));return a.length===1?{x:a[0].r.x+a[0].r.width/2,y:a[0].r.y+a[0].r.height/2}:null;})()
        """) as? [String: Any]
    }
    static func clickPageButton(_ page: [String: Any], label: String) async throws -> Bool {
        guard let point = try await buttonLocation(page, label: label), let x = point["x"] as? Double, let y = point["y"] as? Double else { return false }
        _ = try await cdp(page, "Input.dispatchMouseEvent", ["type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1])
        _ = try await cdp(page, "Input.dispatchMouseEvent", ["type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1])
        record("page_button", ["label": label, "x": x, "y": y]); return true
    }

    static func clearRunnerDialogues() async {
        guard let lines = try? capture("runner-dialogues") else { return }
        let text = lines.map(\.text).joined(separator: " ").lowercased()
        let label: String?
        if text.contains("find") && text.contains("devices on local networks") && text.contains("hosted-compute") { label = "Allow" }
        else if text.contains("kestrel chromium quit unexpectedly") { label = "Ignore" }
        else { label = nil }
        if let label, let target = lines.first(where: { $0.text == label }) {
            clickScreen(target.box)
            record("runner_dialogue", ["choice": label, "mainProcessAlive": testedPID.flatMap(NSRunningApplication.init(processIdentifier:))?.isTerminated == false])
            await pause(2)
        }
    }
    static func clickScreen(_ box: CGRect) {
        let display = CGDisplayBounds(CGMainDisplayID())
        let point = CGPoint(x: display.minX + box.midX * display.width, y: display.minY + (1 - box.midY) * display.height)
        for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    static func installedManifest(id: String) throws -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("com.shayprasad.Kestrel/CefSwift/Default/Extensions/\(id)")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("manifest.json") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func axNodes() -> [AXUIElement] {
        guard let pid = testedPID else { return [] }
        let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root, 1)
        var nodes: [AXUIElement] = []
        func visit(_ node: AXUIElement, _ depth: Int) {
            guard nodes.count < 5000, depth < 40 else { return }; nodes.append(node)
            for child in ax(node, "AXChildren") as? [AXUIElement] ?? [] { visit(child, depth + 1) }
        }
        for window in ax(root, "AXWindows") as? [AXUIElement] ?? [] { visit(window, 0) }
        return nodes
    }
    static func ax(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func inspectWindowSurfaces(stage: String) async throws {
        guard let pid = testedPID else { throw StoreProbeError(message: "No tested process for window census") }
        let root = AXUIElementCreateApplication(pid)
        var windows: [[String: Any]] = []
        var chromeToolbars = 0
        for window in ax(root, "AXWindows") as? [AXUIElement] ?? [] {
            var controls: [[String: String]] = []
            var visited = 0
            func visit(_ node: AXUIElement, _ depth: Int) {
                guard depth < 35, visited < 5000 else { return }; visited += 1
                let role = String(describing: ax(node, "AXRole") ?? "" as CFString)
                let description = String(describing: ax(node, "AXDescription") ?? "" as CFString)
                let title = String(describing: ax(node, "AXTitle") ?? "" as CFString)
                if role == "AXToolbar" || role == "AXTabGroup" || role == "AXTextField" ||
                    description.localizedCaseInsensitiveContains("address and search bar") {
                    controls.append(["role": role, "description": description, "title": title])
                }
                if description.localizedCaseInsensitiveContains("address and search bar") { chromeToolbars += 1 }
                for child in ax(node, "AXChildren") as? [AXUIElement] ?? [] { visit(child, depth + 1) }
            }
            visit(window, 0)
            windows.append(["title": String(describing: ax(window, "AXTitle") ?? "" as CFString),
                            "subrole": String(describing: ax(window, "AXSubrole") ?? "" as CFString), "controls": controls])
        }
        let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
        let pages = try await targets().map { target in
            Dictionary(uniqueKeysWithValues: ["id", "type", "url", "title"].map { ($0, target[$0] ?? "") })
        }
        let value: [String: Any] = ["stage": stage, "windows": windows, "visible": visible,
                                  "targets": pages, "chromeToolbarCount": chromeToolbars]
        record("window_census", value)
        try save("window-census-\(stage).json", value)
        try capture("window-census-\(stage)")
        if chromeToolbars > 0 {
            throw StoreProbeError(message: "A separate Chromium toolbar/window escaped Kestrel after \(stage)")
        }
        if stage == "after-dark-reader", !pages.contains(where: { ($0["url"] as? String)?.hasPrefix("https://darkreader.org/help/") == true }) {
            throw StoreProbeError(message: "Dark Reader's welcome page was lost instead of opening as a Kestrel tab")
        }
    }

    static func verifyFixtureOptions() async throws {
        var worker: [String: Any]?
        for _ in 0..<10 {
            for target in try await targets() where target["type"] as? String == "service_worker" {
                guard let text = target["url"] as? String, URL(string: text)?.path == "/background.js" else { continue }
                if try await evaluate(target, "chrome.runtime.getManifest().name") as? String == "Kestrel Chromium Extension Smoke" {
                    worker = target; break
                }
            }
            if worker != nil { break }; await pause()
        }
        guard let worker, let text = worker["url"] as? String, let host = URL(string: text)?.host else {
            throw StoreProbeError(message: "No disposable extension worker for native options-page acceptance")
        }
        let result = try await cdp(worker, "Runtime.evaluate", ["expression": "chrome.runtime.openOptionsPage().then(()=>true)", "awaitPromise": true, "returnByValue": true])
        guard result["exceptionDetails"] == nil, (result["result"] as? [String: Any])?["value"] as? Bool == true else {
            throw StoreProbeError(message: "The actual extension options API failed: \(result)")
        }
        let address = "chrome-extension://\(host)/options.html"
        var loaded = false
        await pause(0.3)
        for _ in 0..<30 {
            // The native provisional target is deliberately retired. Resolve
            // the final Kestrel target afresh instead of keeping that socket.
            let candidates = try await targets().filter { ($0["type"] as? String) == "page" && ($0["url"] as? String) == address }
            for page in candidates {
                do {
                    let state = try await evaluate(page, "({url:location.href,ready:document.readyState,text:(document.body?.innerText||'').slice(0,500)})") as? [String: Any] ?? [:]
                    record("options_target_probe", ["id": page["id"] ?? "", "state": state])
                    if state["url"] as? String == address, state["ready"] as? String == "complete",
                       (state["text"] as? String)?.contains("Kestrel extension options fixture") == true {
                        loaded = true; break
                    }
                } catch { record("retired_options_target", ["id": page["id"] ?? "", "error": error.localizedDescription]) }
            }
            if loaded { break }
            await pause(0.2)
        }
        guard loaded else {
            throw StoreProbeError(message: "The extension options document did not load in Kestrel")
        }
        await pause(0.5) // Allow the host's title/loading observations to settle.
        try await inspectWindowSurfaces(stage: "extension-options")
        record("extension_options_hosted", ["extensionID": host, "apiSucceeded": true])
    }
    static func dumpAX(_ name: String) throws {
        try save(name, axNodes().map { node in Dictionary(uniqueKeysWithValues: ["AXRole", "AXTitle", "AXDescription", "AXValue"].map { ($0, String(describing: ax(node, $0) ?? "" as CFString).prefix(400).description) }) })
    }

    static func confirmNativeInstall(name: String, slug: String) async throws {
        for attempt in 0..<12 {
            await pause()
            let screenshot = try capture("\(slug)-prompt-\(attempt)")
            let nodes = axNodes().filter { node in
                String(describing: ax(node, "AXRole") ?? "" as CFString) == "AXButton" &&
                ["AXTitle", "AXDescription"].contains { String(describing: ax(node, $0) ?? "" as CFString).lowercased() == "add extension" }
            }
            let text = screenshot.map(\.text).joined(separator: " ").lowercased()
            guard text.contains(name.lowercased()) else { continue }
            try dumpAX("\(slug)-prompt-ax.json")
            if nodes.count == 1, let button = nodes.first,
               let raw = ax(button, "AXPosition"), CFGetTypeID(raw) == AXValueGetTypeID() {
                var point = CGPoint.zero
                if AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point),
                   CGDisplayBounds(CGMainDisplayID()).contains(point), AXUIElementPerformAction(button, "AXPress" as CFString) == .success {
                    record("confirmed_native_install", ["name": name, "method": "AXPress"]); return
                }
            }
            let matches = screenshot.filter { $0.text.lowercased().trimmingCharacters(in: .whitespaces) == "add extension" }
            if matches.count == 1, let match = matches.first {
                let display = CGDisplayBounds(CGMainDisplayID())
                let point = CGPoint(x: display.minX + match.box.midX * display.width,
                                    y: display.minY + (1 - match.box.midY) * display.height)
                for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                record("confirmed_native_install", ["name": name, "method": "visible Quartz target", "x": point.x, "y": point.y]); return
            }
        }
        throw StoreProbeError(message: "No visible native Add extension confirmation for \(name)")
    }

    struct Recognised { let text: String; let box: CGRect }
    @discardableResult static func capture(_ name: String) throws -> [Recognised] {
        let url = output.appendingPathComponent(name + ".png")
        // A hosted display can briefly have no capture surface during a native
        // window transition. Require a real capture, with a bounded retry.
        for attempt in 0..<3 {
            do { try command("/usr/sbin/screencapture", ["-x", url.path]); break }
            catch {
                if attempt == 2 { throw error }
                record("capture_retry", ["name": name, "attempt": attempt + 1])
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        try VNImageRequestHandler(url: url).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Recognised? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return Recognised(text: text, box: observation.boundingBox)
        }
        try lines.map(\.text).joined(separator: "\n").write(to: output.appendingPathComponent(name + ".ocr.txt"), atomically: true, encoding: .utf8)
        record("capture", ["name": name, "text": String(lines.map(\.text).joined(separator: "\n").prefix(8000))])
        if name == "google-translate-before-install" || name == "google-translate-prompt-0" || name == "dark-reader-after-restart" || name.hasPrefix("window-census-") || name == "failure",
           let source = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let width = min(source.width, 1280), height = source.height * width / source.width
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let preview = context.makeImage(), let jpeg = NSBitmapImageRep(cgImage: preview).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
                    print("KESTREL_CWS_IMAGE \(name) \(jpeg.base64EncodedString())")
                    fflush(stdout)
                }
            }
        }
        return lines
    }

    static func verifyDarkReader(stage: String) async throws {
        let page = try await open("https://example.com/")
        for _ in 0..<30 {
            let value = try await evaluate(page, "({styles:document.querySelectorAll('style.darkreader').length,meta:!!document.querySelector('meta[name=darkreader]'),background:getComputedStyle(document.documentElement).backgroundColor,url:location.href})") as? [String: Any] ?? [:]
            if (value["styles"] as? Int ?? 0) > 0 || value["meta"] as? Bool == true {
                record("dark_reader_runtime", ["stage": stage, "state": value]); try capture("dark-reader-\(stage)"); return
            }
            await pause()
        }
        throw StoreProbeError(message: "Dark Reader did not inject its page styles \(stage)")
    }
}
