import XCTest

@testable import KestrelWebKit

final class PasskeyHandoffTests: XCTestCase {
    func testSuccessfulCeremonyPayloadIsRecognised() {
        XCTAssertEqual(
            PasskeyHandoffSignal(messageBody: ["reason": "succeeded"]),
            .succeeded
        )
    }

    func testRejectedPayloadIsRecognised() {
        XCTAssertEqual(
            PasskeyHandoffSignal(messageBody: ["reason": "rejected"]),
            .rejected
        )
    }

    func testUnknownAndMalformedPayloadsAreIgnored() {
        XCTAssertNil(PasskeyHandoffSignal(messageBody: ["reason": "something-else"]))
        XCTAssertNil(PasskeyHandoffSignal(messageBody: ["reason": "platform-unavailable"]))
        XCTAssertNil(PasskeyHandoffSignal(messageBody: ["reason": 42]))
        XCTAssertNil(PasskeyHandoffSignal(messageBody: [String: Any]()))
        XCTAssertNil(PasskeyHandoffSignal(messageBody: "not a dictionary"))
    }

    /// The watcher must hook both ceremonies and report through the app's own
    /// channel, or the banner can never appear.
    func testScriptWatchesBothCeremoniesAndReportsThroughTheBridge() {
        let source = PasskeyHandoffBridge.scriptSource
        XCTAssertTrue(source.contains("navigator.credentials"))
        XCTAssertTrue(source.contains("watch(\"get\")"))
        XCTAssertTrue(source.contains("watch(\"create\")"))
        XCTAssertTrue(source.contains(PasskeyHandoffBridge.messageName))
        XCTAssertTrue(source.contains("postMessage"))
    }

    /// The script is app-owned: it must not read the page or interpolate
    /// anything a page or model could supply.
    func testScriptNeverReadsPageContent() {
        let source = PasskeyHandoffBridge.scriptSource
        XCTAssertFalse(source.contains("document."))
        XCTAssertFalse(source.contains("location"))
        XCTAssertFalse(source.contains("\\("))
    }

    /// The reasons the parser accepts are exactly the ones the script sends.
    func testScriptReasonStringsMatchTheParsedSignals() {
        let source = PasskeyHandoffBridge.scriptSource
        XCTAssertFalse(source.contains("platform-unavailable"))
        XCTAssertTrue(source.contains("succeeded"))
        XCTAssertTrue(source.contains("rejected"))
        XCTAssertNotNil(PasskeyHandoffSignal(messageBody: ["reason": "succeeded"]))
        XCTAssertNotNil(PasskeyHandoffSignal(messageBody: ["reason": "rejected"]))
    }
}
