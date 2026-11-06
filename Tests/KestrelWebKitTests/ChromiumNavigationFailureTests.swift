import XCTest
@testable import KestrelWebKit

final class ChromiumNavigationFailureTests: XCTestCase {
    func testOrdinaryConnectionFailuresDoNotConstructAnInvalidRange() {
        for code in [-10, -102, -105, -130, -199, -300, -501] {
            XCTAssertEqual(BrowserNavigationFailure.chromium(code: code), .unavailable)
        }
    }
    func testCertificateRangeIncludesBothBoundariesAndTLSFailure() {
        for code in [-107, -200, -201, -250, -299] {
            XCTAssertEqual(BrowserNavigationFailure.chromium(code: code), .secureConnection)
        }
    }
    func testTimeoutOfflineAndIntentionalCancellationRemainDistinct() {
        XCTAssertNil(BrowserNavigationFailure.chromium(code: -3))
        XCTAssertEqual(BrowserNavigationFailure.chromium(code: -7), .timedOut)
        for code in [-106, -109, -118] { XCTAssertEqual(BrowserNavigationFailure.chromium(code: code), .offline) }
    }
}
