import Darwin
import Foundation
import Vision

guard CommandLine.arguments.count >= 3 else {
    fputs("usage: verify-macos-screenshot.swift image expected-text [expected-text ...]\n", stderr)
    exit(2)
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
let expected = Array(CommandLine.arguments.dropFirst(2)).map { $0.localizedLowercase }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
try VNImageRequestHandler(url: imageURL).perform([request])

let recognizedText = (request.results ?? [])
    .compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
    .localizedLowercase
let missing = expected.filter { !recognizedText.contains($0) }
guard missing.isEmpty else {
    fputs("Screenshot did not contain expected text: \(missing.joined(separator: ", "))\n", stderr)
    exit(1)
}

print("Screenshot text verified: \(expected.joined(separator: ", "))")
