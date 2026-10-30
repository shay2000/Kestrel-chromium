import XCTest

@testable import KestrelWebKit

final class PageContextTests: XCTestCase {
    func testNormaliseCollapsesWhitespace() {
        let value = PageContextBuilder.normalise("a\n\n  b\t c\u{00a0}d ")
        XCTAssertEqual(value, "a b c d")
    }

    func testBoundAppendsEllipsisAndFlagsTruncation() {
        let result = PageContextBuilder.bounded(String(repeating: "a", count: 210), limit: 200)
        XCTAssertEqual(result.text, String(repeating: "a", count: 199) + "…")
        XCTAssertEqual(result.text.count, 200)
        XCTAssertTrue(result.truncated)
    }

    func testBoundLeavesShortTextAlone() {
        let result = PageContextBuilder.bounded("short", limit: 100)
        XCTAssertEqual(result.text, "short")
        XCTAssertFalse(result.truncated)
    }

    func testBoundPreservesUnicodeAndNormalisedBoundarySemantics() {
        let samples = [
            "  " + String(repeating: "👩🏽‍💻e\u{301}\u{00a0}\n", count: 100),
            String(repeating: "a", count: 200) + " \n\t",
            String(repeating: "a", count: 199) + " \n b",
            " \t\n", ""
        ]
        for sample in samples {
            let normalised = PageContextBuilder.normalise(sample)
            let expected = normalised.count > 200 ? String(normalised.prefix(199)) + "…" : normalised
            let result = PageContextBuilder.bounded(sample, limit: 200)
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(result.truncated, normalised.count > 200)
        }
    }

    func testManySearchSourcesShareSmallBudgetWithoutDuplicatingEvidence() throws {
        let results = (0..<20).map {
            ExaSearchResult(title: "Result \($0)", url: "https://example.com/\($0)",
                            text: "Unique evidence \($0). " + String(repeating: "x", count: 500))
        }
        let search = ExaSearchProvider.pageContext(query: "q", results: results, limit: 200)
        let combined = try XCTUnwrap(PageContextBuilder.combining(currentPage: nil, searchResults: search, limit: 200))
        XCTAssertTrue(combined.textSnapshot.isEmpty, "Structured evidence must not also be sent as a merged current page")
        XCTAssertEqual(combined.additionalSources.count, results.count)
        XCTAssertLessThanOrEqual(combined.textSnapshot.count + combined.additionalSources.reduce(0) { $0 + $1.textSnapshot.count }, 200)
        XCTAssertTrue(combined.additionalSources.allSatisfy(\.wasTruncated))
    }

    func testCurrentPageAndStructuredSourcesRespectMinimumTotalBudget() throws {
        let page = PageContextBuilder.make(url: "https://page.example", title: "Page", text: String(repeating: "p", count: 500))
        let search = ExaSearchProvider.pageContext(query: "q", results: (0..<20).map {
            ExaSearchResult(title: "R\($0)", url: "https://example.com/\($0)", text: String(repeating: "r", count: 500))
        }, limit: 4_000)
        let combined = try XCTUnwrap(PageContextBuilder.combining(currentPage: page, searchResults: search, limit: 200))
        XCTAssertEqual(combined.textSnapshot.count, 100)
        XCTAssertLessThanOrEqual(combined.textSnapshot.count + combined.additionalSources.reduce(0) { $0 + $1.textSnapshot.count }, 200)
        XCTAssertEqual(combined.additionalSources.count, 20)
    }

    func testCurrentPageSecondaryEvidenceAlsoCountsTowardsSharedBudget() throws {
        let body = String(repeating: "a", count: 500)
        var page = PageContextBuilder.make(url: "https://page.example", title: "Page", text: body)
        page.additionalSources = [PageContextSource(label: "Earlier", context: page)]
        let search = PageContextBuilder.make(url: "https://search.example", title: "Search", text: body)
        let combined = try XCTUnwrap(PageContextBuilder.combining(currentPage: page, searchResults: search, limit: 400))
        XCTAssertLessThanOrEqual(combined.textSnapshot.count + combined.additionalSources.reduce(0) { $0 + $1.textSnapshot.count }, 400)
        XCTAssertEqual(combined.additionalSources.map(\.label), ["Earlier", "Search results"])
    }

    func testClampLimitEnforcesCeilingAndFloor() {
        XCTAssertEqual(PageContextBuilder.clampLimit(0), 200)
        XCTAssertEqual(PageContextBuilder.clampLimit(500_000), PageContextBuilder.maximumCharacterLimit)
        XCTAssertEqual(PageContextBuilder.clampLimit(1_000), 1_000)
    }

    func testAutomaticContextBudgetUsesProviderAndRecognisedModelWindow() {
        XCTAssertEqual(PageContextBuilder.automaticCharacterLimit(for: .appleLocalModel, model: "system-default"), 4_000)
        XCTAssertEqual(PageContextBuilder.automaticCharacterLimit(for: .codexCLI, model: ""), 16_000)
        XCTAssertEqual(PageContextBuilder.automaticCharacterLimit(for: .kiloCLI, model: ""), 12_000)
        XCTAssertEqual(PageContextBuilder.automaticCharacterLimit(for: .openRouter, model: "vendor/custom-16k"), 12_000)
        XCTAssertEqual(PageContextBuilder.automaticCharacterLimit(for: .mistral, model: "mistral-8K-instruct"), 6_000)
        XCTAssertEqual(PageContextBuilder.automaticCharacterLimit(for: .openRouter, model: "vendor/long-128k"), PageContextBuilder.maximumCharacterLimit)
        XCTAssertEqual(PageContextBuilder.automaticCharacterLimit(for: .mistral, model: "mistral-small-2506"), 12_000)
        XCTAssertEqual(PageContextBuilder.automaticCharacterLimit(for: .mistral, model: "vendor/999999999m"), 12_000)
    }

    func testMakeBuildsContext() {
        let context = PageContextBuilder.make(url: "https://example.com", title: "  Title ", text: "Body", limit: 100)
        XCTAssertEqual(context.url, "https://example.com")
        XCTAssertEqual(context.title, "Title")
        XCTAssertEqual(context.textSnapshot, "Body")
        XCTAssertFalse(context.wasTruncated)
    }

    func testSafeURLRemovesCredentialsQueryAndFragment() {
        let url = URL(string: "https://user:password@example.com/path?token=secret&view=full#section")

        XCTAssertEqual(PageContextBuilder.safeURLString(url), "https://example.com/path")
    }

    func testPromptDescriptionIsReadable() {
        let context = PageContextBuilder.make(url: "https://example.com", title: "Example", text: "Body", limit: 100)
        let description = PageContextBuilder.promptDescription(context)
        XCTAssertTrue(description.contains("URL: https://example.com"))
        XCTAssertTrue(description.contains("Title: Example"))
        XCTAssertTrue(description.contains("Body"))
    }

    func testCombiningPageAndSearchContextsStaysWithinOneBudget() throws {
        let current = PageContextBuilder.make(
            url: "https://example.com/current",
            title: "Current page",
            text: String(repeating: "c", count: 5_000),
            limit: 4_000
        )
        let results = PageContextBuilder.make(
            url: "https://duckduckgo.com/?q=example",
            title: "Search results",
            text: String(repeating: "r", count: 5_000),
            limit: 4_000
        )

        let combined = try XCTUnwrap(PageContextBuilder.combining(currentPage: current, searchResults: results, limit: 4_000))
        let includedTextCount = combined.textSnapshot.count + combined.additionalSources.reduce(0) { $0 + $1.textSnapshot.count }
        XCTAssertEqual(includedTextCount, 4_000)
        XCTAssertTrue(combined.wasTruncated)
        XCTAssertEqual(combined.additionalSources.first?.label, "Search results")

        let prompt = PageContextBuilder.promptDescription(combined)
        XCTAssertTrue(prompt.contains("Current page"))
        XCTAssertTrue(combined.textSnapshot.hasPrefix("c"))
        XCTAssertTrue(combined.additionalSources.first?.textSnapshot.hasPrefix("r") == true)
        XCTAssertTrue(prompt.contains("Search results"))
        XCTAssertTrue(prompt.contains("URL: https://duckduckgo.com/?q=example"))
    }

    func testSearchContextCanUseFullBudgetWhenCurrentPageIsUnavailable() throws {
        let results = PageContextBuilder.make(
            url: "https://duckduckgo.com/",
            title: "Search results",
            text: String(repeating: "r", count: 5_000),
            limit: 5_000
        )

        let combined = try XCTUnwrap(PageContextBuilder.combining(currentPage: nil, searchResults: results, limit: 4_000))
        XCTAssertTrue(combined.url.isEmpty)
        XCTAssertEqual(combined.additionalSources.first?.textSnapshot.count, 4_000)
        XCTAssertFalse(combined.isEmpty)
    }
}
