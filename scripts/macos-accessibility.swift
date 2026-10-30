// Native AX client for the disposable-runner user stress harness.
// Avoids System Events' unstable object specifiers for SwiftUI virtual controls.
import ApplicationServices
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = Int32(arguments[1]) else {
    fail("Usage: macos-accessibility PID dump|fields|count|click [label]")
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)
func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
    return value
}
func text(_ node: AXUIElement, _ name: String) -> String {
    guard let value = attribute(node, name) else { return "" }
    return String(describing: value)
}
guard let windows = attribute(app, "AXWindows") as? [AXUIElement], let window = windows.first else {
    fail("No accessible app window")
}
var nodes: [AXUIElement] = []
func visit(_ node: AXUIElement, depth: Int) {
    guard depth < 60, nodes.count < 10000 else { return }
    nodes.append(node)
    for child in attribute(node, "AXChildren") as? [AXUIElement] ?? [] {
        visit(child, depth: depth + 1)
    }
}
visit(window, depth: 0)
let label = arguments.count > 3 ? arguments[3] : ""
func labels(_ node: AXUIElement) -> [String] {
    [text(node, "AXDescription"), text(node, "AXTitle")]
}
func frame(_ node: AXUIElement) -> CGRect? {
    guard let rawPoint = attribute(node, "AXPosition"), let rawSize = attribute(node, "AXSize"),
          CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(rawPoint, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
let matches = nodes.filter { node in
    labels(node).contains { $0 == label || (label == "Address bar" && $0.hasPrefix("Address bar, ")) }
}
let output: Any
switch arguments[2] {
case "dump":
    output = nodes.map { node in
        Dictionary(uniqueKeysWithValues: ["AXRole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier", "AXFocused", "AXSelected"].map {
            ($0, text(node, $0))
        })
    }
case "fields":
    output = matches.map { node in
        if let address = labels(node).first(where: { $0.hasPrefix("Address bar, ") }) {
            return String(address.dropFirst("Address bar, ".count))
        }
        return text(node, "AXValue")
    }
case "count":
    output = ["count": matches.count]
case "focused":
    output = ["focused": matches.contains { text($0, "AXFocused") == "1" }]
case "selected":
    output = ["selected": matches.contains { text($0, "AXSelected") == "1" }]
case "enabled":
    output = ["enabled": matches.count == 1 && text(matches[0], "AXEnabled") == "1"]
case "focused_text":
    output = ["count": nodes.filter { ["AXTextField", "AXTextArea", "AXComboBox"].contains(text($0, "AXRole")) && text($0, "AXFocused") == "1" }.count]
case "pointer":
    guard matches.count == 1, let node = matches.first, text(node, "AXEnabled") == "1",
          let rect = frame(node), let windowRect = frame(window), rect.width > 0, rect.height > 0 else { fail("No enabled visible pointer target: \(label)") }
    let point = CGPoint(x: rect.midX, y: rect.midY)
    guard point.x.isFinite, point.y.isFinite, windowRect.contains(point) else { fail("Pointer target outside window") }
    for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left) else { fail("Cannot create pointer event") }
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
    output = ["control": label, "x": point.x, "y": point.y]
case "click":
    guard matches.count == 1, let node = matches.first else { fail("Expected one control: \(label); found \(matches.count)") }
    let role = text(node, "AXRole")
    let status: AXError
    if role == "AXTextField" || role == "AXTextArea" {
        status = AXUIElementSetAttributeValue(node, "AXFocused" as CFString, kCFBooleanTrue)
    } else {
        status = AXUIElementPerformAction(node, "AXPress" as CFString)
    }
    guard status == .success else { fail("Cannot activate \(label): \(status.rawValue)") }
    output = ["activated": label]
default:
    fail("Unknown AX operation")
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
