import XCTest
@testable import KestrelWebKit

#if canImport(SwiftUI) && canImport(WebKit)

/// The markdown the sidebar renders.
///
/// These tests exist because the parser was doing two jobs at once — repairing
/// the run-on prose models emit *and* recognising structure — and the repairs
/// ran over the whole document before anything was parsed. That silently
/// rewrote code. The tests below pin the boundary: repairs apply to prose, and
/// to prose only.
final class AssistantMarkdownParserTests: XCTestCase {

    func testAccessibilityTextDescribesMarkdownWithoutLiteralMarkers() {
        let label = AssistantMarkdownParser.accessibilityText(
            """
            # Summary

            - **Ready** now.

            > Keep the label readable.

            ```
            print("ready")
            ```

            | Model | Files |
            | --- | --- |
            | Local | 1 |
            """
        )

        XCTAssertEqual(
            label,
            "Heading: Summary\nList item: Ready now.\nQuote: Keep the label readable.\nCode block: print(\"ready\")\nTable with columns: Model, Files. Row 1: Model: Local, Files: 1"
        )
        XCTAssertFalse(label.contains("**"))
    }

    // MARK: - Repairs

    func testRepairsAHeadingRunIntoTheNextSentence() {
        let blocks = AssistantMarkdownParser.parse("**Summary**On 18 September the deal closed.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("**Summary**"),
            .paragraph("On 18 September the deal closed.")
        ])
    }

    func testRepairsAMissingSpaceAfterASentence() {
        let blocks = AssistantMarkdownParser.parse("It ended.The response arrived.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("It ended. The response arrived.")
        ])
    }

    func testRepairsAMissingSpaceAfterAColon() {
        let blocks = AssistantMarkdownParser.parse("Here is the list:First item")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Here is the list: First item")
        ])
    }

    /// The colon repair only fires before a capital, and that is deliberate.
    /// A colon before a lowercase letter is how prose writes an address or a
    /// URL, and rewriting `mailto:someone@example.com` into
    /// `mailto: someone@example.com` would be the same mistake the code-fence
    /// rule exists to prevent.
    func testAColonBeforeALowercaseLetterIsLeftAlone() {
        let blocks = AssistantMarkdownParser.parse("Write to mailto:someone@example.com today.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Write to mailto:someone@example.com today.")
        ])
    }

    func testRepairsLeaveFencedCodeAlone() {
        let blocks = AssistantMarkdownParser.parse(
            """
            Call it like this:

            ```
            obj.Method().Another()
            init(frame:CGRect)
            ```
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Call it like this:"),
            .code("obj.Method().Another()\ninit(frame:CGRect)")
        ])
    }

    func testRepairsLeaveBacktickSpansAlone() {
        let blocks = AssistantMarkdownParser.parse("Use `init(frame:CGRect)` and `obj.Method()` here.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Use `init(frame:CGRect)` and `obj.Method()` here.")
        ])
    }

    func testRepairsStillApplyToTheProseAroundABacktickSpan() {
        let blocks = AssistantMarkdownParser.parse("Call `init(frame:CGRect)`.Then stop.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Call `init(frame:CGRect)`. Then stop.")
        ])
    }

    func testABoldRunGluedToACapitalSplits() {
        let blocks = AssistantMarkdownParser.parse("Use **bold**Words here.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Use **bold**"),
            .paragraph("Words here.")
        ])
    }

    /// A closing `**` must not be mistaken for an opening one.
    ///
    /// The rule that splits a bold run from a sentence glued to it used to match
    /// across two bold runs. In "planets **Mars**, **Earth**" it paired the
    /// closing `**` of Mars with the opening `**` of Earth, broke the line
    /// between them, and left the rest of the asterisks on screen as literal
    /// text — so a perfectly good sentence rendered as three broken lines with
    /// stray `**` in it.
    func testSeveralBoldRunsInOneSentenceAreLeftAlone() {
        let blocks = AssistantMarkdownParser.parse(
            "Here is a comparison of the planets **Mars**, **Earth**, and **Jupiter** based on their known moons:"
        )

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph(
                "Here is a comparison of the planets **Mars**, **Earth**, and **Jupiter** based on their known moons:"
            )
        ])
    }

    // MARK: - Repairs must not damage what is already correct

    /// The spacing rule looks for a capital after a dot, and a URL is full of
    /// both. `https://example.com/a.B` came out as `.../a. B`, which breaks the
    /// address. Requiring two lowercase letters in front of the dot is what
    /// keeps the rule on sentence endings.
    func testAURLIsLeftAlone() {
        let blocks = AssistantMarkdownParser.parse("See https://example.com/a.B for details.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("See https://example.com/a.B for details.")
        ])
    }

    func testAnUppercaseFilenameIsLeftAlone() {
        let blocks = AssistantMarkdownParser.parse("Open README.MD and INDEX.HTML next.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Open README.MD and INDEX.HTML next.")
        ])
    }

    func testASentenceAfterACodeSpanStillGetsItsSpace() {
        let blocks = AssistantMarkdownParser.parse("Use `foo()`.Then call `bar()`.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Use `foo()`. Then call `bar()`.")
        ])
    }

    func testAnUnbalancedBacktickIsNotTurnedIntoASpan() {
        let blocks = AssistantMarkdownParser.parse("The value is 5 ` 3 here.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("The value is 5 ` 3 here.")
        ])
    }

    // MARK: - Lists and rules

    /// Markdown reads "2026. That was the year" as an ordered list starting at
    /// 2026, so the sidebar drew a sentence as a list item numbered 2026.
    func testASentenceStartingWithAYearIsNotAList() {
        let blocks = AssistantMarkdownParser.parse("2026. That was the year it changed.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("2026. That was the year it changed.")
        ])
    }

    func testThreeDigitNumbersStillStartAList() {
        let blocks = AssistantMarkdownParser.parse("999. The last one.")

        XCTAssertEqual(blocks.map(\.content), [
            .numbered(depth: 0, number: 999, text: "The last one.")
        ])
    }

    func testDashesBetweenSectionsBecomeARule() {
        let blocks = AssistantMarkdownParser.parse("Before\n\n---\n\nAfter")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Before"),
            .rule,
            .paragraph("After")
        ])
    }

    func testSpacedAndUnderscoreBreaksAreRulesToo() {
        XCTAssertEqual(AssistantMarkdownParser.parse("* * *").map(\.content), [.rule])
        XCTAssertEqual(AssistantMarkdownParser.parse("___").map(\.content), [.rule])
    }

    /// `* * *` must be read as a break, not as a bullet whose text is "* *".
    func testASpacedBreakIsNotABullet() {
        XCTAssertFalse(
            AssistantMarkdownParser.parse("* * *").contains { block in
                if case .bullet = block.content { return true }
                return false
            }
        )
    }

    func testTwoDashesAreNotARule() {
        XCTAssertEqual(AssistantMarkdownParser.parse("--").map(\.content), [.paragraph("--")])
    }

    func testABreakInsideATableDelimiterIsNotReadAsARule() {
        let blocks = AssistantMarkdownParser.parse(
            """
            | A | B |
            | --- | --- |
            | 1 | 2 |
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .table(headers: ["A", "B"], rows: [["1", "2"]])
        ])
    }

    // MARK: - List nesting

    func testListDepthIsBucketedEveryTwoColumns() {
        XCTAssertEqual(AssistantMarkdownParser.listDepth(of: "- top"), 0)
        XCTAssertEqual(AssistantMarkdownParser.listDepth(of: "  - one level in"), 1)
        XCTAssertEqual(AssistantMarkdownParser.listDepth(of: "    - two levels in"), 2)
        XCTAssertEqual(AssistantMarkdownParser.listDepth(of: "      - three levels in"), 3)
    }

    func testListDepthIsCappedSoADeepListCannotMarchOffTheSidebar() {
        XCTAssertEqual(AssistantMarkdownParser.listDepth(of: "            - very deep"), 3)
    }

    func testATabCountsAsThreeColumns() {
        XCTAssertEqual(AssistantMarkdownParser.listDepth(of: "\t- tabbed"), 1)
    }

    func testNestedListItemsKeepTheirDepth() {
        let blocks = AssistantMarkdownParser.parse(
            """
            - Top level
              - Nested once
                - Nested twice
            1. Numbered top
              1. Numbered nested
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .bullet(depth: 0, text: "Top level"),
            .bullet(depth: 1, text: "Nested once"),
            .bullet(depth: 2, text: "Nested twice"),
            .numbered(depth: 0, number: 1, text: "Numbered top"),
            .numbered(depth: 1, number: 1, text: "Numbered nested")
        ])
    }

    // MARK: - Tables

    func testParsesAPipeTable() {
        let blocks = AssistantMarkdownParser.parse(
            """
            | Feature | Status |
            | --- | --- |
            | Search | Shipped |
            | Tabs | Planned |
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .table(
                headers: ["Feature", "Status"],
                rows: [["Search", "Shipped"], ["Tabs", "Planned"]]
            )
        ])
    }

    func testParsesATableWithoutOuterPipes() {
        let blocks = AssistantMarkdownParser.parse(
            """
            Feature | Status
            --- | ---
            Search | Shipped
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .table(headers: ["Feature", "Status"], rows: [["Search", "Shipped"]])
        ])
    }

    func testParsesAlignmentMarkersInTheDelimiterRow() {
        let blocks = AssistantMarkdownParser.parse(
            """
            | Left | Centre | Right |
            | :--- | :---: | ---: |
            | a | b | c |
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .table(headers: ["Left", "Centre", "Right"], rows: [["a", "b", "c"]])
        ])
    }

    /// The delimiter row can begin with a dash, so the table check has to run
    /// before the bullet check or the table is eaten by the list rule.
    func testADashDelimiterIsNotReadAsABullet() {
        let blocks = AssistantMarkdownParser.parse(
            """
            Name | Value
            --- | ---
            alpha | 1
            """
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.content, .table(
            headers: ["Name", "Value"],
            rows: [["alpha", "1"]]
        ))
    }

    /// A sentence that happens to contain a pipe is a sentence. Markdown needs
    /// a delimiter row, and insisting on one is what keeps prose out of tables.
    func testAPipeInASentenceIsNotATable() {
        let blocks = AssistantMarkdownParser.parse("The flag is red | blue and green.")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("The flag is red | blue and green.")
        ])
    }

    func testASingleColumnIsNotATable() {
        let blocks = AssistantMarkdownParser.parse(
            """
            | Heading |
            | --- |
            | value |
            """
        )

        // One column is not worth a grid; the lines fall through to prose.
        let hasTable = blocks.contains { block in
            if case .table = block.content { return true }
            return false
        }
        XCTAssertFalse(hasTable)
    }

    func testRaggedRowsArePaddedAndOverlongRowsAreTruncated() {
        let blocks = AssistantMarkdownParser.parse(
            """
            | A | B | C |
            | --- | --- | --- |
            | 1 |
            | 1 | 2 | 3 | 4 |
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .table(
                headers: ["A", "B", "C"],
                rows: [["1", "", ""], ["1", "2", "3"]]
            )
        ])
    }

    func testATableEndsAtTheFirstLineWithoutPipes() {
        let blocks = AssistantMarkdownParser.parse(
            """
            | A | B |
            | --- | --- |
            | 1 | 2 |
            That was the table.
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .table(headers: ["A", "B"], rows: [["1", "2"]]),
            .paragraph("That was the table.")
        ])
    }

    func testATableIsNotReadInsideAFencedCodeBlock() {
        let blocks = AssistantMarkdownParser.parse(
            """
            ```
            | A | B |
            | --- | --- |
            | 1 | 2 |
            ```
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .code("| A | B |\n| --- | --- |\n| 1 | 2 |")
        ])
    }

    func testATableHeaderWithNoRowsStillParses() {
        let blocks = AssistantMarkdownParser.parse(
            """
            | A | B |
            | --- | --- |
            """
        )

        XCTAssertEqual(blocks.map(\.content), [
            .table(headers: ["A", "B"], rows: [])
        ])
    }

    // MARK: - Structure

    func testParagraphsAreJoinedAcrossSoftLineBreaks() {
        let blocks = AssistantMarkdownParser.parse("First half\nsecond half")

        XCTAssertEqual(blocks.map(\.content), [.paragraph("First half second half")])
    }

    func testHeadingsOfEveryLevelAreRecognised() {
        let blocks = AssistantMarkdownParser.parse("# One\n## Two\n### Three")

        XCTAssertEqual(blocks.map(\.content), [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 3, text: "Three")
        ])
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        let blocks = AssistantMarkdownParser.parse("#NotAHeading")

        XCTAssertEqual(blocks.map(\.content), [.paragraph("#NotAHeading")])
    }

    func testQuotesAreRecognised() {
        let blocks = AssistantMarkdownParser.parse("> A quotation.")

        XCTAssertEqual(blocks.map(\.content), [.quote("A quotation.")])
    }

    func testAnUnclosedCodeFenceStillEmitsTheCode() {
        let blocks = AssistantMarkdownParser.parse("Text before.\n\n```\nlet x = 1")

        XCTAssertEqual(blocks.map(\.content), [
            .paragraph("Text before."),
            .code("let x = 1")
        ])
    }

    func testBlockIdentifiersAreUniqueSoSwiftUIReusesRowsCorrectly() {
        let blocks = AssistantMarkdownParser.parse("# A\n\ntext\n\n- one\n- two")

        XCTAssertEqual(blocks.map(\.id), Array(0..<blocks.count))
    }
}

#endif
