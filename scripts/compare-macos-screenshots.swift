import AppKit
import Foundation

guard CommandLine.arguments.count == 4,
      let chromium = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let webKit = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
    fputs("usage: compare-macos-screenshots.swift chromium.png webkit.png output.png\n", stderr)
    exit(2)
}

let labelHeight: CGFloat = 36
let imageHeight = max(chromium.size.height, webKit.size.height)
let canvas = NSImage(size: NSSize(
    width: chromium.size.width + webKit.size.width,
    height: imageHeight + labelHeight
))

canvas.lockFocus()
NSColor.windowBackgroundColor.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvas.size)).fill()

let labelAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.boldSystemFont(ofSize: 14),
    .foregroundColor: NSColor.labelColor
]
NSAttributedString(string: "Chromium", attributes: labelAttributes)
    .draw(at: NSPoint(x: 14, y: imageHeight + 10))
NSAttributedString(string: "WebKit 1.0.0", attributes: labelAttributes)
    .draw(at: NSPoint(x: chromium.size.width + 14, y: imageHeight + 10))

chromium.draw(in: NSRect(origin: .zero, size: chromium.size))
webKit.draw(in: NSRect(
    x: chromium.size.width,
    y: 0,
    width: webKit.size.width,
    height: webKit.size.height
))
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not render comparison image\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
// Keep a small inspectable preview in the runner log as well as the full PNG artefact.
let preview = NSImage(size: NSSize(width: 1600, height: canvas.size.height * 1600 / canvas.size.width))
preview.lockFocus()
canvas.draw(in: NSRect(origin: .zero, size: preview.size))
preview.unlockFocus()
if let tiff = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
   let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
    print("KESTREL_VISUAL_IMAGE webkit-vs-chromium \(jpeg.base64EncodedString())")
}
