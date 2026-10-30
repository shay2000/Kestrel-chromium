import XCTest

@testable import KestrelWebKit

final class URLNormalisationTests: XCTestCase {
    func testEmptyInputIsNotNavigable() {
        XCTAssertNil(URLNormalisation.destinationURL(from: "   "))
    }

    func testExplicitHTTPSAddressIsPreserved() {
        let url = URLNormalisation.destinationURL(from: "https://example.com/path?q=1")
        XCTAssertEqual(url?.absoluteString, "https://example.com/path?q=1")
    }

    func testProviderEndpointRequiresHTTPSWithoutURLCredentials() {
        XCTAssertTrue(URLNormalisation.isHTTPSURL("https://api.example.com/v1"))
        XCTAssertFalse(URLNormalisation.isHTTPSURL("http://api.example.com/v1"))
        XCTAssertFalse(URLNormalisation.isHTTPSURL("https://user:password@api.example.com/v1"))
    }

    func testBareHostPortsAndLocalPathsAreAddresses() {
        for address in ["example.com:8443/path", "127.0.0.1:8080/test", "localhost:3000", "localhost/path", "[::1]:8080/path", "localhost?query=a%20b", "example.com:65535/#section", "example.com/path?next=https://example.org/", "example.com:8443/?next=https://example.org/"] {
            XCTAssertEqual(URLNormalisation.destinationURL(from: address)?.absoluteString, "https://" + address, address)
            XCTAssertTrue(URLNormalisation.isOpenableAddress(address), address)
        }
    }

    func testHostPortParsingPreservesSchemeAndInvalidAddressRejection() {
        for address in ["example.com:65536/path", "localhost:-1", "localhost:abc", "example.com:", "[::1]:99999/",
                        "javascript:123", "mailto:me@example.com", "file:///tmp/example.com", "data:text/plain,hello", "localhost/a b"] {
            XCTAssertFalse(URLNormalisation.isOpenableAddress(address), address)
            XCTAssertEqual(URLNormalisation.destinationURL(from: address)?.host, "www.google.com", address)
        }
        XCTAssertEqual(URLNormalisation.destinationURL(from: "localhost:3000", searchEngine: .bing)?.host, "localhost")
    }

    func testBareHostBecomesHTTPS() {
        let url = URLNormalisation.destinationURL(from: "example.com")
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testSingleWordBecomesGoogleSearch() throws {
        let url = try XCTUnwrap(URLNormalisation.destinationURL(from: "swift"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "swift")
    }

    func testSpacedInputBecomesSearch() {
        let url = URLNormalisation.destinationURL(from: "swift webkit")
        XCTAssertEqual(url?.host, "www.google.com")
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(components?.queryItems?.first?.name, "q")
        XCTAssertEqual(components?.queryItems?.first?.value, "swift webkit")
    }

    func testNonBrowsableSchemeFallsBackToSearch() {
        let url = URLNormalisation.destinationURL(from: "javascript:alert(1)")
        XCTAssertEqual(url?.host, "www.google.com")
    }

    func testSearchEngineHostIsConfigurable() {
        let url = URLNormalisation.destinationURL(from: "one two", searchEngineHost: "example.org")
        XCTAssertEqual(url?.host, "example.org")
    }

    func testSelectedSearchEngineIsUsedForSearchQueries() throws {
        let duckDuckGo = try XCTUnwrap(URLNormalisation.destinationURL(from: "webkit tabs", searchEngine: .duckDuckGo))
        XCTAssertEqual(duckDuckGo.host, "duckduckgo.com")
        XCTAssertEqual(URLComponents(url: duckDuckGo, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "webkit tabs")

        let bing = try XCTUnwrap(URLNormalisation.searchURL(for: "swift", searchEngine: .bing))
        XCTAssertEqual(bing.host, "www.bing.com")
    }

    func testBangShortcutsOpenOnlyAllowListedSearchDestinations() throws {
        let maps = try XCTUnwrap(URLNormalisation.destinationURL(from: "!maps Brooklyn", searchEngine: .google))
        XCTAssertEqual(maps.host, "www.google.com")
        XCTAssertEqual(maps.path, "/maps/search")
        XCTAssertTrue(maps.absoluteString.contains("query=Brooklyn"))

        let wiki = try XCTUnwrap(URLNormalisation.destinationURL(from: "!w swift", searchEngine: .bing))
        XCTAssertEqual(wiki.host, "en.wikipedia.org")
        XCTAssertEqual(URLComponents(url: wiki, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "swift")
        XCTAssertEqual(URLNormalisation.destinationURL(from: "!unknown search")?.host, "www.google.com")
        XCTAssertEqual(URLNormalisation.destinationURL(from: "!maps")?.host, "www.google.com")
    }

    func testTabShortcutKeepsRemainingQueryForMapsMode() throws {
        let completion = try XCTUnwrap(SearchShortcut.tabCompletion(in: "maps Central Park"))
        XCTAssertEqual(completion.shortcut, .maps)
        XCTAssertEqual(completion.remainingQuery, "Central Park")

        let maps = try XCTUnwrap(completion.shortcut.destinationURL(for: completion.remainingQuery, using: .google))
        XCTAssertEqual(maps.host, "www.google.com")
        XCTAssertTrue(maps.absoluteString.contains("maps/search"))
        XCTAssertNil(SearchShortcut.tabCompletion(in: "maple tree"))
    }

    func testOpenableAddressAllowList() {
        XCTAssertTrue(URLNormalisation.isOpenableAddress("https://example.com"))
        XCTAssertTrue(URLNormalisation.isOpenableAddress("example.com"))
        XCTAssertFalse(URLNormalisation.isOpenableAddress("file:///etc/passwd"))
        XCTAssertFalse(URLNormalisation.isOpenableAddress("javascript:alert(1)"))
        XCTAssertFalse(URLNormalisation.isOpenableAddress(""))
    }

    func testSchemePrefixDetection() {
        XCTAssertEqual(URLNormalisation.schemePrefix(in: "https://example.com"), "https")
        XCTAssertEqual(URLNormalisation.schemePrefix(in: "mailto:me@example.com"), "mailto")
        XCTAssertNil(URLNormalisation.schemePrefix(in: "example.com"))
        XCTAssertNil(URLNormalisation.schemePrefix(in: "://nonsense"))
    }

    func testGoogleSuggestionEndpointOnlyAcceptsSearchText() throws {
        let url = try XCTUnwrap(SearchSuggestions.endpoint(for: "swift webkit"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "suggestqueries.google.com")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "client" })?.value, "firefox")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "swift webkit")
        XCTAssertNil(SearchSuggestions.endpoint(for: "https://example.com/private"))
        XCTAssertNil(SearchSuggestions.endpoint(for: "example.com"))
    }

    func testGoogleSuggestionsParseAndDeduplicateResults() {
        let data = Data(#"["swift",["swift concurrency","SwiftUI","swift concurrency"],[],[]]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(data), ["swift concurrency", "SwiftUI"])
        XCTAssertTrue(SearchSuggestions.parse(Data("{}".utf8)).isEmpty)
    }

    func testSuggestionsFollowSelectedEngineAndParseDuckDuckGoShape() throws {
        let endpoint = try XCTUnwrap(SearchSuggestions.endpoint(for: "swift ui", engine: .duckDuckGo))
        XCTAssertEqual(endpoint.host, "ac.duckduckgo.com")
        let suggestions = Data(#"[{"phrase":"swift ui"},{"phrase":"Swift UI"},{"phrase":"swift concurrency"}]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(suggestions, engine: .duckDuckGo), ["swift ui", "swift concurrency"])
        let listSuggestions = Data(#"["swift",["swift ui","swift concurrency"]]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(listSuggestions, engine: .duckDuckGo), ["swift ui", "swift concurrency"])

        let bing = try XCTUnwrap(SearchSuggestions.endpoint(for: "swift ui", engine: .bing))
        XCTAssertEqual(bing.host, "api.bing.com")
    }

    func testAssistantImageSearchUsesTheSelectedEngineImageResults() throws {
        let google = try XCTUnwrap(SearchEngine.google.searchURL(for: "Falcon Heavy", mode: .images))
        let googleComponents = try XCTUnwrap(URLComponents(url: google, resolvingAgainstBaseURL: false))
        XCTAssertEqual(googleComponents.host, "www.google.com")
        XCTAssertEqual(googleComponents.queryItems?.first(where: { $0.name == "tbm" })?.value, "isch")
        XCTAssertEqual(googleComponents.queryItems?.first(where: { $0.name == "q" })?.value, "Falcon Heavy")

        let duckDuckGo = try XCTUnwrap(SearchEngine.duckDuckGo.searchURL(for: "Falcon Heavy", mode: .images))
        let duckDuckGoComponents = try XCTUnwrap(URLComponents(url: duckDuckGo, resolvingAgainstBaseURL: false))
        XCTAssertEqual(duckDuckGoComponents.queryItems?.first(where: { $0.name == "ia" })?.value, "images")

        let bing = try XCTUnwrap(SearchEngine.bing.searchURL(for: "Falcon Heavy", mode: .images))
        XCTAssertEqual(URLComponents(url: bing, resolvingAgainstBaseURL: false)?.path, "/images/search")
    }

    func testAddressBarUsesShortSearchBreadcrumbsAndSitePaths() throws {
        let google = try XCTUnwrap(AddressBarPresentation.label(
            for: "https://www.google.com/search?tbm=isch&q=Falcon%20Heavy"
        ))
        XCTAssertEqual(google, AddressBarLabel(primary: "Google", detail: "Falcon Heavy"))

        let site = try XCTUnwrap(AddressBarPresentation.label(
            for: "https://www.example.com/guides/deep/topic?private=value"
        ))
        XCTAssertEqual(site, AddressBarLabel(primary: "example.com", detail: "guides / deep"))
    }
}
