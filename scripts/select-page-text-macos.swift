import AppKit
import CoreGraphics
import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
    fputs("usage: select-page-text-macos.swift page-screenshot.png\n", stderr)
    exit(2)
}

let screenshotURL = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(url: screenshotURL).perform([request])

guard let observation = request.results?.first(where: {
    $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(
        "This domain is for use in documentation examples"
    ) == true
}),
let image = NSImage(contentsOf: screenshotURL),
let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("could not locate selectable text in the page screenshot\n", stderr)
    exit(1)
}

// Vision boxes are normalized from the lower left; Quartz mouse coordinates
// use the primary display's upper-left origin.
let box = observation.boundingBox
let width = CGFloat(cgImage.width)
let height = CGFloat(cgImage.height)
let textWidth = box.width * width
let start = CGPoint(
    x: box.minX * width + min(3, textWidth * 0.01),
    y: (1 - box.midY) * height
)
let end = CGPoint(
    x: box.maxX * width - min(3, textWidth * 0.01),
    y: start.y
)
let source = CGEventSource(stateID: .combinedSessionState)

func post(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

post(.mouseMoved, at: start)
Thread.sleep(forTimeInterval: 0.15)
post(.leftMouseDown, at: start)
for step in 1...12 {
    let fraction = CGFloat(step) / 12
    post(.leftMouseDragged, at: CGPoint(
        x: start.x + (end.x - start.x) * fraction,
        y: start.y
    ))
    Thread.sleep(forTimeInterval: 0.025)
}
post(.leftMouseUp, at: end)
Thread.sleep(forTimeInterval: 0.4)
print("Dragged across visible example.com text at \(Int(start.x)),\(Int(start.y))–\(Int(end.x)),\(Int(end.y)).")
