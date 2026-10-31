// Actual packaged-app lifecycle UI checks. Reuses the bounded runner/CDP helpers.
import AppKit
import ApplicationServices
import Foundation
import Vision

typealias Probe = ChromeWebStoreAcceptance

@main @MainActor
struct ChromiumLifecycleAcceptance {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreProbeError(message: message) }
    }
    static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw StoreProbeError(message: "usage: lifecycle-test Kestrel.app evidence-directory localhost-fixture-url") }
            Probe.app = URL(fileURLWithPath: CommandLine.arguments[1])
            Probe.output = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: Probe.output, withIntermediateDirectories: true)
            try await Probe.launch(reuse: true)
            await Probe.widenRunnerWindow()
            let fixture = CommandLine.arguments[3]
            let page = try await Probe.open(fixture)
            await Probe.pause(2)
            _ = try await Probe.cdp(page, "Page.bringToFront")
            try require(try await Probe.clickPageButton(page, label: "Edit test draft"), "Could not edit the local test form")
            key(13, flags: .maskCommand) // The actual Close Tab shortcut.
            try await chooseStay(stage: "close-tab")
            try await verifyDraft(page)
            Probe.record("cancelled_tab_close_preserved_draft")
            // Exercise the ordinary app quit path while a form can cancel it.
            NSRunningApplication(processIdentifier: Probe.testedPID!)?.terminate()
            try await chooseStay(stage: "quit")
            try await verifyDraft(page)
            try require(NSRunningApplication(processIdentifier: Probe.testedPID!)?.isTerminated == false, "Stay did not cancel app quit")
            Probe.record("cancelled_quit_preserved_draft")
            try require(try await Probe.clickPageButton(page, label: "Save test draft"), "Could not save test form")
            // Capture the engine's own hybrid UI without a synthetic authenticator.
            try require(try await Probe.clickPageButton(page, label: "Try phone passkey"), "No phone passkey probe button")
            await Probe.pause(4)
            let lines = try Probe.capture("native-hybrid")
            try Probe.dumpAX("native-hybrid-ax.json")
            let barcode = VNDetectBarcodesRequest(); barcode.symbologies = [.qr]
            try VNImageRequestHandler(url: Probe.output.appendingPathComponent("native-hybrid.png")).perform([barcode])
            let hasFidoQR = (barcode.results ?? []).contains { $0.payloadStringValue?.hasPrefix("FIDO:/") == true }
            Probe.record("native_hybrid_ui", ["fidoQRVisible": hasFidoQR, "text": lines.map(\.text).joined(separator: "\n"), "physicalCeremonyPassed": false])
            emitPreview("native-hybrid")
            _ = try await Probe.evaluate(page, "controller?.abort(); true")
            key(53) // Dismiss any remaining native picker.
            await Probe.pause(1)
            // This is deliberately separate evidence from native phone/Touch ID acceptance.
            _ = try await Probe.cdp(page, "WebAuthn.enable", ["enableUI": false])
            let device = try await Probe.cdp(page, "WebAuthn.addVirtualAuthenticator", ["options": [
                "protocol":"ctap2", "transport":"usb", "hasResidentKey":true,
                "hasUserVerification":true, "isUserVerified":true, "automaticPresenceSimulation":true
            ]])
            let reply = try await Probe.cdp(page, "Runtime.evaluate", ["expression":"virtualWebAuthnRoundTrip()", "awaitPromise":true, "returnByValue":true, "userGesture":true])
            guard let result = (reply["result"] as? [String: Any])?["value"] as? [String: Any] else { throw StoreProbeError(message: "Synthetic WebAuthn round trip failed: \(reply)") }
            for field in ["signatureVerified", "registrationBound", "assertionBound", "credentialMatched", "rpHashMatched", "userPresenceAndVerification"] {
                try require(result[field] as? Bool == true, "Synthetic WebAuthn validation failed: \(field)")
            }
            Probe.record("synthetic_webauthn_round_trip", result)
            if let id = device["authenticatorId"] as? String { _ = try await Probe.cdp(page, "WebAuthn.removeVirtualAuthenticator", ["authenticatorId":id]) }
            _ = try await Probe.cdp(page, "WebAuthn.disable")
            // Opening then closing real targets exercises native browser callbacks.
            for index in 0..<5 {
                let rapid = try await Probe.open(fixture + "?rapid=\(index)")
                if let id = rapid["id"] as? String { _ = try await Probe.cdp(rapid, "Target.closeTarget", ["targetId":id]) }
                await Probe.pause(0.3)
            }
            try await verifyDraft(page, expected: "Unsaved draft survives Stay")
            Probe.record("rapid_tab_close_parent_survived", ["cycles":5])
            // Deliver a new URL and quit immediately, without waiting for its target.
            try Probe.command("/usr/bin/open", ["-a", Probe.app.path, fixture + "?quit-during-create=1"])
            try await Probe.launch()
            await Probe.pause(15)
            try require(!Probe.collectCrashReports(), "A tested app process crashed")
            Probe.collectLifecycleLog()
            try Probe.save("result.json", ["passed":true, "nativeHybridQRVisible":hasFidoQR, "physicalPasskeyCeremonyPassed":false, "syntheticWebAuthnPassed":true])
            print("Kestrel lifecycle and synthetic WebAuthn acceptance passed; native FIDO QR visible: \(hasFidoQR). Physical phone ceremony unverified.")
        } catch {
            try? Probe.capture("failure"); try? Probe.dumpAX("failure-ax.json")
            Probe.collectCrashReports(); Probe.collectLifecycleLog()
            fputs("Kestrel lifecycle acceptance failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] { let event = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down); event?.flags=flags; event?.post(tap:.cghidEventTap) }
    }
    static func chooseStay(stage: String) async throws {
        for attempt in 0..<15 {
            await Probe.pause(0.4)
            let lines = try Probe.capture("\(stage)-dialogue-\(attempt)")
            let matches = lines.filter { $0.text == "Stay" }
            if matches.count == 1, let match = matches.first { Probe.clickScreen(match.box); await Probe.pause(0.6); return }
        }
        throw StoreProbeError(message: "No native Stay choice for \(stage)")
    }
    static func verifyDraft(_ page: [String: Any], expected: String = "Unsaved draft survives Stay") async throws {
        let draft = try await Probe.evaluate(page, "document.querySelector('#draft')?.value") as? String
        try require(draft == expected, "The original form or its draft disappeared")
    }
    static func emitPreview(_ name: String) {
        guard let tiff = NSImage(contentsOf: Probe.output.appendingPathComponent(name + ".png"))?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using:.jpeg,properties:[.compressionFactor:0.45]) else { return }
        print("KESTREL_PROBE_IMAGE \(name) \(jpeg.base64EncodedString())"); fflush(stdout)
    }
}
