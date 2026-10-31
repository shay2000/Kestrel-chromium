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

@main
@MainActor
struct ChromeWebStoreAcceptance {
    static var app = URL(fileURLWithPath: "/")
    static var output = URL(fileURLWithPath: "/")
    static var process: Process?
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
            try await launch()
            for item in items { try await install(id: item.id, slug: item.slug, name: item.name) }
            try await verifyDarkReader(stage: "before-restart")
            try await launch()
            for item in items {
                guard let manifest = try installedManifest(id: item.id) else {
                    throw StoreProbeError(message: "Installed extension disappeared after restart: \(item.name)")
                }
                record("persisted", ["name": item.name, "manifest": manifest.path])
            }
            try await verifyDarkReader(stage: "after-restart")
            try save("result.json", ["passed": true, "runtimeUserAgentProbe": uaProbe,
                                     "installedIDs": items.map(\.id), "restartRuntimePassed": true])
            print("Chrome Web Store native install and restart acceptance passed. User-agent probe: \(uaProbe)")
        } catch {
            try? capture("failure")
            try? dumpAX("failure-ax.json")
            try? save("result.json", ["passed": false, "runtimeUserAgentProbe": uaProbe,
                                     "error": error.localizedDescription])
            fputs("Chrome Web Store acceptance failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func record(_ event: String, _ details: [String: Any] = [:]) {
        let value = ["event": event, "details": details] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
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

    static func launch() async throws {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: "com.shayprasad.Kestrel")
            where running.bundleURL?.standardizedFileURL == app { running.terminate() }
        for _ in 0..<15 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.shayprasad.Kestrel")
                .allSatisfy({ $0.bundleURL?.standardizedFileURL != app }) { break }
            await pause()
        }
        let child = Process()
        child.executableURL = app.appendingPathComponent("Contents/MacOS/Kestrel")
        child.arguments = ["--remote-debugging-port=\(port)", "--force-renderer-accessibility"]
        let log = output.appendingPathComponent("app-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        child.standardOutput = try FileHandle(forWritingTo: log)
        child.standardError = child.standardOutput
        try child.run(); process = child
        for _ in 0..<30 {
            if child.isRunning, let running = NSRunningApplication(processIdentifier: child.processIdentifier) {
                running.activate(options: [.activateIgnoringOtherApps])
                if (try? await targets()) != nil {
                    record("launched", ["pid": child.processIdentifier, "bundle": running.bundleURL?.path ?? "unknown"])
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
        let socket = URLSession.shared.webSocketTask(with: url); socket.resume()
        let timeout = Task { await pause(12); socket.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let bytes: Data
            switch message { case .data(let value): bytes = value; case .string(let value): bytes = Data(value.utf8); @unknown default: continue }
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["id"] as? Int == 1 else { continue }
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
      buttons:Array.from(document.querySelectorAll('button')).map(e=>({text:(e.innerText||e.getAttribute('aria-label')||'').trim(),disabled:e.disabled})).slice(0,100)}))()
    """

    static func install(id: String, slug: String, name: String) async throws {
        let url = "https://chromewebstore.google.com/detail/\(slug)/\(id)"
        let page = try await open(url); await pause(12)
        let baseline = try await evaluate(page, storeState)
        try save("\(slug)-baseline.json", baseline); record("store_baseline", ["name": name, "state": baseline])
        try capture("\(slug)-baseline")
        var state = baseline as? [String: Any] ?? [:]
        if (state["text"] as? String)?.localizedCaseInsensitiveContains("Switch to Chrome") == true {
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
        }
        let location = try await evaluate(page, """
        (()=>{const a=Array.from(document.querySelectorAll('button')).filter(e=>e.innerText.trim()==='Add to Chrome'&&!e.disabled).map(e=>e.getBoundingClientRect()).filter(r=>r.width>0&&r.height>0&&r.top>=0&&r.bottom<=innerHeight);return a.length===1?{x:a[0].x+a[0].width/2,y:a[0].y+a[0].height/2}:null;})()
        """)
        guard let point = location as? [String: Any], let x = point["x"] as? Double, let y = point["y"] as? Double else {
            throw StoreProbeError(message: "No unique enabled visible Add to Chrome button for \(name)")
        }
        _ = try await cdp(page, "Input.dispatchMouseEvent", ["type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1])
        _ = try await cdp(page, "Input.dispatchMouseEvent", ["type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1])
        record("clicked_store_install", ["name": name, "x": x, "y": y])
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

    static func installedManifest(id: String) throws -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("com.shayprasad.Kestrel/CefSwift/Default/Extensions/\(id)")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("manifest.json") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func axNodes() -> [AXUIElement] {
        guard let pid = process?.processIdentifier else { return [] }
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
        try command("/usr/sbin/screencapture", ["-x", url.path])
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        try VNImageRequestHandler(url: url).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Recognised? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return Recognised(text: text, box: observation.boundingBox)
        }
        try lines.map(\.text).joined(separator: "\n").write(to: output.appendingPathComponent(name + ".ocr.txt"), atomically: true, encoding: .utf8)
        record("capture", ["name": name, "text": String(lines.map(\.text).joined(separator: "\n").prefix(8000))])
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
