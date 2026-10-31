import XCTest
@testable import KestrelWebKit

final class ChromiumExtensionNavigationTests: XCTestCase {
    func testWelcomePageAndExactQueryAreKept() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/welcome?source=extension#setup"))
        XCTAssertEqual(ChromiumExtensionNavigation.destination(url, method: "GET", usesDefaultProfile: true), url)
    }

    func testInstallNewTabDoesNotCreateAKestrelTab() {
        for text in ["about:blank", "chrome://newtab/", "chrome://new-tab-page/", "chrome-untrusted://new-tab-page/"] {
            XCTAssertNil(ChromiumExtensionNavigation.destination(URL(string: text), method: "GET", usesDefaultProfile: true))
        }
    }

    func testPostAndOtherProfilesAreNeverReplayed() {
        let url = URL(string: "https://example.com/submit")!
        XCTAssertNil(ChromiumExtensionNavigation.destination(url, method: "POST", usesDefaultProfile: true))
        XCTAssertNil(ChromiumExtensionNavigation.destination(url, method: "GET", usesDefaultProfile: false))
    }

    func testExtensionOptionsKeepTheirOriginInsteadOfBecomingSearch() {
        let address = "chrome-extension://eimadpbcbfnmbkopoojfekhnkhdbieeh/ui/options/index.html?setup=1"
        let url = URL(string: address)!
        XCTAssertEqual(ChromiumExtensionNavigation.destination(url, method: "GET", usesDefaultProfile: true), url)
        XCTAssertEqual(URLNormalisation.destinationURL(from: address), url)
    }

    func testRejectsUnsafeSchemesCredentialsAndInvalidExtensionOrigins() {
        for text in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,test", "https://user:pass@example.com/",
                     "chrome-extension://eimadpbcbfnmbkopoojfekhnkhdbieeh:443/options.html",
                     "chrome-extension://user@eimadpbcbfnmbkopoojfekhnkhdbieeh/options.html", "chrome-extension://invalid/options.html"] {
            XCTAssertNil(ChromiumExtensionNavigation.destination(URL(string: text), method: "GET", usesDefaultProfile: true), text)
        }
    }
}
