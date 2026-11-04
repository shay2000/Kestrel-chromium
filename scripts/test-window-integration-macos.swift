import AppKit
import ApplicationServices
import Foundation

typealias FocusProbe = ChromeWebStoreAcceptance

@main @MainActor
struct WindowIntegrationAcceptance {
    static var failures: [String] = []
    static func check(_ result: Bool, _ label: String) {
        FocusProbe.record("focus_check", ["check": label, "passed": result])
        if !result { failures.append(label) }
    }
    static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags; event?.post(tap: .cghidEventTap)
        }
    }
    static func type(_ value: String) {
        let characters = Array(value.utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            characters.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            event?.post(tap: .cghidEventTap)
        }
    }
    static func text(_ element: AXUIElement?, _ attribute: String) -> String {
        guard let element else { return "" }
        return String(describing: FocusProbe.ax(element, attribute) ?? "" as CFString)
    }
    static func rootWindow() throws -> AXUIElement {
        let app = AXUIElementCreateApplication(FocusProbe.testedPID!)
        guard let root = (FocusProbe.ax(app, "AXWindows") as? [AXUIElement])?.first(where: { text($0, "AXTitle") == "Kestrel focus fixture" }) else { throw StoreProbeError(message: "No Kestrel fixture window") }
        return root
    }
    static func clickAXControl(_ label: String) throws {
        // Avoid AXPress, which bypasses first-click behaviour.
        guard let node = FocusProbe.axNodes().first(where: { text($0, "AXRole") == "AXButton" && (text($0, "AXTitle") == label || text($0, "AXDescription") == label) }),
              let position = FocusProbe.ax(node, "AXPosition"), let size = FocusProbe.ax(node, "AXSize") else { throw StoreProbeError(message: "No native control: \(label)") }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin), AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { throw StoreProbeError(message: "No control bounds") }
        let point = CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
        for event in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: event, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap) }
    }
    static func clickElement(_ page: [String: Any], _ id: String) async throws {
        let literal = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        let point = try await FocusProbe.evaluate(page, "(()=>{let r=document.getElementById(\(literal)).getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()") as? [String: Any] ?? [:]
        guard let x = point["x"] as? Double, let y = point["y"] as? Double else { throw StoreProbeError(message: "No fixture control bounds") }
        try await FocusProbe.nativePageClick(page, x: x, y: y)
        await FocusProbe.pause(0.3)
    }
    static func preview(_ label: String) throws {
        _ = try FocusProbe.capture(label)
        if let bitmap = NSBitmapImageRep(data: try Data(contentsOf: FocusProbe.output.appendingPathComponent(label + ".png"))), let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) {
            print("KESTREL_FOCUS_IMAGE \(label) \(data.base64EncodedString())")
        }
    }
    static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw StoreProbeError(message: "usage: window-integration-test Kestrel.app evidence-dir fixture-url") }
            FocusProbe.app = URL(fileURLWithPath: CommandLine.arguments[1]); FocusProbe.output = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: FocusProbe.output, withIntermediateDirectories: true)
            try await FocusProbe.launch(reuse: true)
            let page = try await FocusProbe.open(CommandLine.arguments[3])
            await FocusProbe.pause(2)
            let owner = try rootWindow()
            var origin = CGPoint(x: 30, y: 55), size = CGSize(width: 1180, height: 780)
            if let value = AXValueCreate(.cgPoint, &origin) { _ = AXUIElementSetAttributeValue(owner, "AXPosition" as CFString, value) }
            if let value = AXValueCreate(.cgSize, &size) { _ = AXUIElementSetAttributeValue(owner, "AXSize" as CFString, value) }
            await FocusProbe.pause(1)
            try await clickElement(page, "entry"); type("one click")
            await FocusProbe.pause(0.3)
            check(try await FocusProbe.evaluate(page, "document.getElementById('entry').value") as? String == "one click", "page receives typing after one native click")
            let main = FocusProbe.ax(owner, "AXMain") as? Bool ?? false
            check(main, "Kestrel frame remains the main window while page has keyboard focus")
            let app = AXUIElementCreateApplication(FocusProbe.testedPID!)
            FocusProbe.record("native_window_focus", ["ownerMain": main, "mainTitle": text(FocusProbe.ax(app, "AXMainWindow") as! AXUIElement?, "AXTitle"), "pageBounds": NSStringFromRect(try await FocusProbe.nativePageBounds(page))])
            try preview("page-focused")
            try clickAXControl("Add bookmark"); await FocusProbe.pause(0.5)
            check(FocusProbe.axNodes().contains { text($0, "AXDescription") == "Remove bookmark" || text($0, "AXTitle") == "Remove bookmark" }, "toolbar acts on the first click after using the page")
            try await clickElement(page, "count")
            check(try await FocusProbe.evaluate(page, "window.clickCount") as? Int == 1, "page button acts exactly once on the first return click")
            key(37, [.maskCommand, .maskControl]); await FocusProbe.pause(0.5)
            let focused = FocusProbe.ax(app, "AXFocusedUIElement") as! AXUIElement?
            check(text(focused, "AXValue").contains("window-focus.html"), "configured address shortcut reaches the actual search field from the page")
            try preview("toolbar-focused")
            try FocusProbe.save("result.json", ["passed": failures.isEmpty, "failures": failures, "nativeMouseInput": true])
            if !failures.isEmpty { throw StoreProbeError(message: failures.joined(separator: "; ")) }
            print("Native Kestrel window focus and first-click acceptance passed")
        } catch {
            try? preview("failure"); try? FocusProbe.dumpAX("failure-ax.json")
            fputs("Window integration acceptance failed: \(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}
