import Darwin
import Foundation
import Vision

guard CommandLine.arguments.count >= 3 else {
    fputs("usage: verify-macos-screenshot.swift image expected-text [expected-text ...]\n", stderr)
    exit(2)
}

func normalisedText(_ text: String) -> String {
    text.localizedLowercase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
let expected = Array(CommandLine.arguments.dropFirst(2)).map(normalisedText)
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
try VNImageRequestHandler(url: imageURL).perform([request])

let recognizedText = (request.results ?? [])
    .compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
let normalisedRecognition = normalisedText(recognizedText)
let missing = expected.filter { !normalisedRecognition.contains($0) }
guard missing.isEmpty else {
    fputs("Screenshot did not contain expected text: \(missing.joined(separator: ", "))\n", stderr)
    fputs("Recognised screenshot text (bounded):\n\(recognizedText.prefix(8_000))\n", stderr)
    exit(1)
}

print("Screenshot text verified: \(expected.joined(separator: ", "))")
