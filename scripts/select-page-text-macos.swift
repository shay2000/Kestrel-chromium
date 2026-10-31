import AppKit
import CoreGraphics
import Foundation
import Vision

guard CommandLine.arguments.count == 3 else {
    fputs("usage: select-page-text-macos.swift page-screenshot.png selection-screenshot.png\n", stderr)
    exit(2)
}

let sourceScreenshot = URL(fileURLWithPath: CommandLine.arguments[1])
let selectionScreenshot = URL(fileURLWithPath: CommandLine.arguments[2])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(url: sourceScreenshot).perform([request])

guard let observation = request.results?.first(where: {
    $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(
        "This domain is for use in documentation examples"
    ) == true
}),
let image = NSImage(contentsOf: sourceScreenshot),
let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("could not locate selectable text in the page screenshot\n", stderr)
    exit(1)
}

let displayID = CGMainDisplayID()
let displayBounds = CGDisplayBounds(displayID)
let imageWidth = CGFloat(cgImage.width)
let imageHeight = CGFloat(cgImage.height)
let pixelsPerPointX = imageWidth / max(1, displayBounds.width)
let pixelsPerPointY = imageHeight / max(1, displayBounds.height)
let box = observation.boundingBox
let startXInImage = box.minX * imageWidth + 3
let endXInImage = box.maxX * imageWidth - 3
let yInImage = (1 - box.midY) * imageHeight

let source = CGEventSource(stateID: .combinedSessionState)
guard source != nil else {
    fputs("could not create a mouse event source\n", stderr)
    exit(1)
}

func post(_ type: CGEventType, at point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else {
        fatalError("could not create \(type) mouse event")
    }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}

func dragAcrossText(usingQuartzBottomOrigin: Bool) {
    let startY: CGFloat
    let endY: CGFloat
    if usingQuartzBottomOrigin {
        startY = displayBounds.maxY - yInImage / pixelsPerPointY
        endY = startY
    } else {
        startY = displayBounds.minY + yInImage / pixelsPerPointY
        endY = startY
    }
    let start = CGPoint(x: displayBounds.minX + startXInImage / pixelsPerPointX, y: startY)
    let end = CGPoint(x: displayBounds.minX + endXInImage / pixelsPerPointX, y: endY)

    post(.mouseMoved, at: start)
    Thread.sleep(forTimeInterval: 0.15)
    post(.leftMouseDown, at: start)
    for step in 1...16 {
        let fraction = CGFloat(step) / 16
        post(.leftMouseDragged, at: CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        ))
        Thread.sleep(forTimeInterval: 0.035)
    }
    post(.leftMouseUp, at: end)
    Thread.sleep(forTimeInterval: 0.5)
}

func captureSelectionScreenshot() throws {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", selectionScreenshot.path]
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationStatus == 0 else {
        throw NSError(domain: "KestrelScreenshot", code: Int(capture.terminationStatus))
    }
}

func selectedBluePixelCount(in screenshot: URL) -> Int {
    guard let selectedImage = NSImage(contentsOf: screenshot),
          let selectedCGImage = selectedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
    let bitmap = NSBitmapImageRep(cgImage: selectedCGImage)
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    let left = max(0, Int(box.minX * CGFloat(width)))
    let right = min(width, Int(box.maxX * CGFloat(width)))
    let top = max(0, Int((1 - box.maxY) * CGFloat(height)))
    let bottom = min(height, Int((1 - box.minY) * CGFloat(height)))
    var count = 0

    // NSBitmapImageRep can expose either pixel-row orientation depending on
    // the image source, so scan the Vision box and its vertical mirror.
    for yRange in [top..<max(top + 1, bottom), max(0, height - bottom)..<min(height, height - top)] {
        for y in yRange {
            for x in left..<max(left + 1, right) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent > 0.42,
                   color.blueComponent > color.redComponent + 0.14,
                   color.blueComponent > color.greenComponent + 0.03 {
                    count += 1
                }
            }
        }
    }
    return count
}

print("Display bounds: \(displayBounds); screenshot: \(cgImage.width)x\(cgImage.height); pixels per point: \(pixelsPerPointX)x\(pixelsPerPointY).")
for (label, usesBottomOrigin) in [("Quartz top origin", false), ("Quartz bottom origin", true)] {
    dragAcrossText(usingQuartzBottomOrigin: usesBottomOrigin)
    try captureSelectionScreenshot()
    let highlightedPixels = selectedBluePixelCount(in: selectionScreenshot)
    print("\(label) drag produced \(highlightedPixels) blue selection pixels in the target line.")
    if highlightedPixels >= 40 {
        print("Visible text selection confirmed in \(selectionScreenshot.path).")
        exit(0)
    }
}

fputs("The page text remained unselected after both Quartz coordinate mappings.\n", stderr)
exit(1)
