import XCTest

@testable import KestrelWebKit

final class JavaScriptStringLiteralTests: XCTestCase {
    func testQuotesPlainText() {
        XCTAssertEqual(JavaScriptStringLiteral.escape("Sign in"), "\"Sign in\"")
    }

    func testEscapesQuotesAndBackslashes() {
        XCTAssertEqual(
            JavaScriptStringLiteral.escape("say \"hi\" \\ now"),
            "\"say \\\"hi\\\" \\\\ now\""
        )
    }

    func testEscapesControlCharacters() {
        XCTAssertEqual(
            JavaScriptStringLiteral.escape("line\nbreak\ttab\rcarriage"),
            "\"line\\nbreak\\ttab\\rcarriage\""
        )
    }

    func testEscapesScriptLineSeparators() {
        XCTAssertEqual(
            JavaScriptStringLiteral.escape("a\u{2028}b\u{2029}c"),
            "\"a\\u2028b\\u2029c\""
        )
    }

    func testEmptyStringIsAnEmptyLiteral() {
        XCTAssertEqual(JavaScriptStringLiteral.escape(""), "\"\"")
    }
}
