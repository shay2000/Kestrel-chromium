import XCTest

@testable import KestrelWebKit

final class RedactionTests: XCTestCase {
    func testBearerTokenIsRedacted() {
        let redacted = Redaction.redacted("Authorization: Bearer abcdefghijklmnopqrstuvwxyz")
        XCTAssertFalse(redacted.contains("abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(redacted.contains(Redaction.placeholder))
    }

    func testProviderKeyIsRedacted() {
        let redacted = Redaction.redacted("using sk-abcdefghijklmnop next")
        XCTAssertFalse(redacted.contains("sk-abcdefghijklmnop"))
    }

    func testKeyValuePairIsRedacted() {
        let redacted = Redaction.redacted(#"{"api_key":"super-secret-value"}"#)
        XCTAssertFalse(redacted.contains("super-secret-value"))
    }

    func testOrdinaryTextIsUnchanged() {
        let text = "The quick brown fox"
        XCTAssertEqual(Redaction.redacted(text), text)
    }

    func testPresenceDescriptionNeverContainsValue() {
        XCTAssertEqual(Redaction.describePresence(nil), "not configured")
        let description = Redaction.describePresence("secret-value")
        XCTAssertFalse(description.contains("secret-value"))
        XCTAssertTrue(description.contains("hidden"))
    }

    func testEnvironmentNamesAreJoined() {
        XCTAssertEqual(Redaction.describeEnvironmentNames(["A", "", "B"]), "A, B")
    }
}
