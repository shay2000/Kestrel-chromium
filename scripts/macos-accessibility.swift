// Native AX client for the disposable-runner user stress harness.
// Avoids System Events' unstable object specifiers for SwiftUI virtual controls.
import ApplicationServices
import AppKit
import Foundation
import Vision

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
if ["native-key", "native-keycode"].contains(arguments[2]) {
    guard (4...5).contains(arguments.count), arguments[3].utf16.count <= 2048 else { fail("Invalid native key command") }
    let modifiers = arguments.count == 5 ? arguments[4].split(separator: ",").map(String.init) : []
    let masks: [String: CGEventFlags] = ["command": .maskCommand, "control": .maskControl, "option": .maskAlternate, "shift": .maskShift]
    guard modifiers.allSatisfy({ masks[$0] != nil }) else { fail("Invalid key modifiers") }
    let flags = modifiers.reduce(CGEventFlags()) { $0.union(masks[$1]!) }
    NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    Thread.sleep(forTimeInterval: 0.1)
    // System Events can leave modifier state behind after a shortcut. Each
    // native sequence explicitly releases it and supplies its own event flags.
    for code in [CGKeyCode(55), 59, 58, 56] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }
    func send(_ code: CGKeyCode, unicode: [UniChar] = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            if !unicode.isEmpty { unicode.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: $0.baseAddress!) } }
            event?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.003)
    }
    if arguments[2] == "native-keycode" {
        guard let code = UInt16(arguments[3]), code < 128 else { fail("Invalid native key code") }
        send(code)
    } else if !modifiers.isEmpty {
        let codes: [String: CGKeyCode] = ["a": 0, "s": 1, "g": 5, "q": 12, "w": 13, "e": 14, "t": 17, "0": 29, "]": 30, "[": 33, "p": 35, "l": 37, ",": 43]
        guard let code = codes[arguments[3].lowercased()] else { fail("Unsupported native shortcut") }
        send(code)
    } else {
        // Match the passing native focus probe: one Unicode insertion is a
        // normal paste event, without a synthetic 300-character/second burst.
        send(0, unicode: Array(arguments[3].utf16))
    }
    for code in [CGKeyCode(55), 59, 58, 56] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.15) // Drain posted events before this helper exits.
    FileHandle.standardOutput.write(Data("{\"native\":true}".utf8))
    exit(0)
}
if arguments[2] == "menu_select" {
    guard arguments.count == 4 else { fail("A menu and item title are required") }
    let titles = arguments[3].split(separator: "|", maxSplits: 1).map(String.init)
    guard titles.count == 2, let rawBar = attribute(app, "AXMenuBar") else { fail("No menu bar") }
    let bar = unsafeBitCast(rawBar, to: AXUIElement.self)
    let groups = (attribute(bar, "AXChildren") as? [AXUIElement] ?? []).filter { text($0, "AXTitle") == titles[0] }
    guard groups.count == 1 else { fail("Expected one menu: \(titles[0])") }
    NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    Thread.sleep(forTimeInterval: 0.15)
    for down in [true, false] {
        let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)
        escape?.flags = []
        escape?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.1)
    guard let groupBounds = frame(groups[0]) else { fail("No menu bar bounds") }
    // Start and finish native menu tracking with pointer events. AXPress can
    // expose a menu tree without committing the subsequent selected action.
    let barPoint = CGPoint(x: groupBounds.midX, y: groupBounds.midY)
    for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: barPoint, mouseButton: .left) else { fail("Cannot open the menu bar item") }
        event.flags = []
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
    Thread.sleep(forTimeInterval: 0.2)
    var pending = attribute(groups[0], "AXChildren") as? [AXUIElement] ?? []
    var items: [AXUIElement] = []
    var examined = 0
    while !pending.isEmpty, examined < 1000 {
        let node = pending.removeFirst()
        examined += 1
        if text(node, "AXRole") == "AXMenuItem", text(node, "AXTitle") == titles[1] { items.append(node) }
        pending += attribute(node, "AXChildren") as? [AXUIElement] ?? []
    }
    guard items.count == 1, text(items[0], "AXEnabled") == "1", let bounds = frame(items[0]) else { fail("Cannot select menu item: \(titles[1])") }
    let point = CGPoint(x: bounds.midX, y: bounds.midY)
    guard bounds.width > 0, bounds.height > 0, CGDisplayBounds(CGMainDisplayID()).contains(point) else { fail("Menu item is outside the runner display") }
    for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left) else { fail("Cannot create menu pointer event") }
        event.flags = []
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
    Thread.sleep(forTimeInterval: 0.35)
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["menu": titles[0], "item": titles[1], "method": "native pointer"]))
    exit(0)
}
// Handle only this known runner prompt, by a real pointer click. Denying LAN
// discovery keeps ordinary web/loopback testing independent of that permission.
if arguments[2] == "dismiss-local-network" {
    guard arguments.count == 4 else { fail("A prompt screenshot path is required") }
    let url = URL(fileURLWithPath: arguments[3])
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", url.path]
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationStatus == 0 else { fail("Cannot capture the runner prompt") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(url: url).perform([request])
    let lines = (request.results ?? []).compactMap { node -> (String, CGRect)? in
        guard let candidate = node.topCandidates(1).first else { return nil }
        return (candidate.string, node.boundingBox)
    }
    let words = lines.map { $0.0.lowercased() }.joined(separator: " ")
    let buttons = lines.filter { ["Don't Allow", "Don’t Allow"].contains($0.0) }
    var dismissed = false
    if words.contains("kestrel"), words.contains("find"), words.contains("devices"), words.contains("local networks"), buttons.count == 1 {
        let screen = CGDisplayBounds(CGMainDisplayID())
        let box = buttons[0].1
        let point = CGPoint(x: screen.minX + screen.width * box.midX, y: screen.minY + screen.height * (1 - box.midY))
        for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left) else { fail("Cannot click the runner prompt") }
            event.flags = []
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.04)
        }
        dismissed = true
    }
    let result: [String: Any] = ["dismissed": dismissed, "choice": dismissed ? "Don't Allow" : "none"]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    exit(0)
}
var nodes: [AXUIElement] = []
var visited: [CFHashCode: [AXUIElement]] = [:]
func visit(_ node: AXUIElement, depth: Int) {
    guard depth < 60, nodes.count < 10000 else { return }
    let hash = CFHash(node)
    guard !(visited[hash] ?? []).contains(where: { CFEqual($0, node) }) else { return }
    visited[hash, default: []].append(node)
    nodes.append(node)
    for child in attribute(node, "AXChildren") as? [AXUIElement] ?? [] {
        visit(child, depth: depth + 1)
    }
}
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
// CEF hosts each page in a native child window. A split has two sibling
// page windows; AXWindows.first is not necessarily the document or active page.
// Inspect the main document and its on-screen children, deduplicating AX nodes.
guard let windows = attribute(app, "AXWindows") as? [AXUIElement], !windows.isEmpty else {
    fail("No accessible app window")
}
let main = attribute(app, "AXMainWindow").map { unsafeBitCast($0, to: AXUIElement.self) }
let window = main ?? windows.max(by: { (frame($0)?.width ?? 0) * (frame($0)?.height ?? 0) < (frame($1)?.width ?? 0) * (frame($1)?.height ?? 0) })!
let onscreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { row -> CGRect? in
    guard (row[kCGWindowOwnerPID as String] as? Int) == Int(pid),
          let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
}
visit(window, depth: 0)
if let focused = attribute(app, "AXFocusedWindow") {
    visit(unsafeBitCast(focused, to: AXUIElement.self), depth: 0)
}
if let document = frame(window) {
    for child in windows where !CFEqual(child, window) {
        guard let rect = frame(child), document.contains(CGPoint(x: rect.midX, y: rect.midY)),
              onscreen.contains(where: { abs($0.minX - rect.minX) < 2 && abs($0.minY - rect.minY) < 2 && abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2 }) else { continue }
        visit(child, depth: 0)
    }
}
let matches = nodes.filter { node in
    labels(node).contains { $0 == label || (label == "Address bar" && $0.hasPrefix("Address bar, ")) }
}
let output: Any
switch arguments[2] {
case "resize":
    let dimensions = label.split(separator: ",").compactMap { Double($0) }
    guard dimensions.count == 2, dimensions.allSatisfy(\.isFinite),
          (700...1600).contains(dimensions[0]), (520...1000).contains(dimensions[1]) else { fail("Invalid document size") }
    let screen = CGDisplayBounds(CGMainDisplayID())
    var size = CGSize(width: min(CGFloat(dimensions[0]), screen.width - 80), height: min(CGFloat(dimensions[1]), screen.height - 100))
    guard let value = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success else { fail("Cannot resize the main document") }
    output = ["width": size.width, "height": size.height]
case "window_frame":
    guard let rect = frame(window) else { fail("No main document frame") }
    output = ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
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
        event.flags = []
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
