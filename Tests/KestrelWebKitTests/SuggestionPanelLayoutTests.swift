import XCTest
@testable import KestrelWebKit

/// The address field's dropdown sizes itself to the display. These cover the
/// two rules that decide what the user actually sees: how many rows fit, and
/// how those rows are shared between the sections.
final class SuggestionPanelLayoutTests: XCTestCase {

    // MARK: - Row capacity

    func testTallerScreenShowsMoreRows() {
        let short = SuggestionPanelLayout.rowCapacity(
            screenHeight: 800,
            offsetFromTop: SuggestionPanelLayout.newTabTopAllowance
        )
        let tall = SuggestionPanelLayout.rowCapacity(
            screenHeight: 1_400,
            offsetFromTop: SuggestionPanelLayout.newTabTopAllowance
        )
        XCTAssertLessThan(short, tall)
    }

    func testRowCapacityNeverFallsBelowTheMinimum() {
        let capacity = SuggestionPanelLayout.rowCapacity(screenHeight: 320, offsetFromTop: 270)
        XCTAssertEqual(capacity, SuggestionPanelLayout.minimumRows)
    }

    func testRowCapacityIsClampedOnAVeryLargeDisplay() {
        let capacity = SuggestionPanelLayout.rowCapacity(screenHeight: 5_000, offsetFromTop: 120)
        XCTAssertEqual(capacity, SuggestionPanelLayout.maximumRows)
    }

    /// The guarantee this whole type exists for: whenever the display has room
    /// for the minimum number of rows, a panel sized from this budget stays on
    /// screen instead of running off the bottom.
    ///
    /// Below that the floor is kept deliberately — a two-row dropdown is not
    /// worth opening, so the panel is allowed to reach the bottom edge rather
    /// than shrink to nothing.
    func testPanelStaysOnScreenWheneverTheMinimumFits() {
        for screenHeight in stride(from: CGFloat(600), through: 1_800, by: 20) {
            for allowance in [
                SuggestionPanelLayout.toolbarTopAllowance,
                SuggestionPanelLayout.newTabTopAllowance
            ] {
                let capacity = SuggestionPanelLayout.rowCapacity(
                    screenHeight: screenHeight,
                    offsetFromTop: allowance
                )
                let bottom = allowance + SuggestionPanelLayout.panelHeight(rowCapacity: capacity)
                let minimumBottom = allowance
                    + SuggestionPanelLayout.panelHeight(rowCapacity: SuggestionPanelLayout.minimumRows)

                guard minimumBottom <= screenHeight else {
                    XCTAssertEqual(
                        capacity,
                        SuggestionPanelLayout.minimumRows,
                        "A screen too short for the floor should still get the floor"
                    )
                    continue
                }
                XCTAssertLessThanOrEqual(
                    bottom,
                    screenHeight,
                    "A \(capacity)-row panel starting at \(allowance) runs past \(screenHeight)"
                )
            }
        }
    }

    func testPanelHeightGrowsWithEachRow() {
        let small = SuggestionPanelLayout.panelHeight(rowCapacity: 4)
        let large = SuggestionPanelLayout.panelHeight(rowCapacity: 9)
        XCTAssertGreaterThan(large, small)
        XCTAssertEqual(
            large - small,
            5 * (SuggestionPanelLayout.rowHeight + SuggestionPanelLayout.rowSpacing),
            accuracy: 0.001
        )
    }

    // MARK: - Sharing the budget out

    func testEverySectionWithMatchesGetsARowBeforeAnySectionGetsASecond() {
        let capacity = SuggestionPanelLayout.allocate(
            capacity: 4,
            bookmarkMatches: 9,
            recentMatches: 9,
            tabMatches: 9,
            remoteMatches: 9
        )
        XCTAssertEqual(capacity, SuggestionCapacity(
            bookmarks: 1,
            recentSearches: 1,
            openTabs: 1,
            remote: 1
        ))
    }

    func testAnEmptySectionHandsItsRowsToTheOthers() {
        let capacity = SuggestionPanelLayout.allocate(
            capacity: 8,
            bookmarkMatches: 0,
            recentMatches: 0,
            tabMatches: 0,
            remoteMatches: 20
        )
        XCTAssertEqual(capacity.bookmarks, 0)
        XCTAssertEqual(capacity.recentSearches, 0)
        XCTAssertEqual(capacity.openTabs, 0)
        XCTAssertEqual(capacity.remote, SuggestionPanelLayout.remoteSectionLimit)
        XCTAssertLessThanOrEqual(capacity.total, 8)
    }

    /// Whatever is left over when one section cannot fill its share goes to the
    /// others rather than being wasted.
    func testLeftoverRowsAreRedistributed() {
        let capacity = SuggestionPanelLayout.allocate(
            capacity: 9,
            bookmarkMatches: 1,
            recentMatches: 0,
            tabMatches: 1,
            remoteMatches: 40
        )
        XCTAssertEqual(capacity.bookmarks, 1)
        XCTAssertEqual(capacity.recentSearches, 0)
        XCTAssertEqual(capacity.openTabs, 1)
        XCTAssertEqual(capacity.remote, SuggestionPanelLayout.remoteSectionLimit)
        XCTAssertEqual(capacity.total, 9)
    }

    func testNoSectionExceedsItsOwnLimit() {
        let capacity = SuggestionPanelLayout.allocate(
            capacity: 100,
            bookmarkMatches: 100,
            recentMatches: 100,
            tabMatches: 100,
            remoteMatches: 100
        )
        XCTAssertEqual(capacity.bookmarks, SuggestionPanelLayout.localSectionLimit)
        XCTAssertEqual(capacity.recentSearches, SuggestionPanelLayout.localSectionLimit)
        XCTAssertEqual(capacity.openTabs, SuggestionPanelLayout.localSectionLimit)
        XCTAssertEqual(capacity.remote, SuggestionPanelLayout.remoteSectionLimit)
    }

    func testTheTotalNeverExceedsTheBudget() {
        for budget in 0...20 {
            for matches in [0, 1, 3, 7, 40] {
                let capacity = SuggestionPanelLayout.allocate(
                    capacity: budget,
                    bookmarkMatches: matches,
                    recentMatches: matches,
                    tabMatches: matches,
                    remoteMatches: matches
                )
                XCTAssertLessThanOrEqual(
                    capacity.total,
                    budget,
                    "Budget \(budget) with \(matches) matches each overspent"
                )
                XCTAssertGreaterThanOrEqual(capacity.bookmarks, 0)
                XCTAssertGreaterThanOrEqual(capacity.remote, 0)
            }
        }
    }

    func testNoMatchesMeansNoRows() {
        let capacity = SuggestionPanelLayout.allocate(
            capacity: 8,
            bookmarkMatches: 0,
            recentMatches: 0,
            tabMatches: 0,
            remoteMatches: 0
        )
        XCTAssertEqual(capacity.total, 0)
    }

    /// A negative budget should behave like an empty one rather than trapping.
    func testANegativeBudgetIsTreatedAsEmpty() {
        let capacity = SuggestionPanelLayout.allocate(
            capacity: -5,
            bookmarkMatches: 3,
            recentMatches: 3,
            tabMatches: 3,
            remoteMatches: 3
        )
        XCTAssertEqual(capacity.total, 0)
    }
}

/// The shortcut prefix has to be recognised in the bang form only, or a search
/// for the word "maps" would be rewritten.
final class SearchShortcutBangTests: XCTestCase {

    func testRecognisesTheBangFormOfEachShortcut() {
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!maps eiffel tower"), .maps)
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!map eiffel tower"), .maps)
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!i aurora"), .images)
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!n election"), .news)
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!videos storm"), .videos)
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!shop desk"), .shopping)
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!yt lo-fi"), .youtube)
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!w Rosetta"), .wikipedia)
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "!a keyboard"), .amazon)
    }

    func testIsCaseInsensitiveAndTolerantOfSurroundingSpace() {
        XCTAssertEqual(SearchShortcut.leadingShortcut(in: "  !MAPS eiffel  "), .maps)
        XCTAssertEqual(
            SearchShortcut.strippingLeadingShortcut(from: "  !MAPS eiffel tower  "),
            "eiffel tower"
        )
    }

    func testDoesNotTreatABareTriggerWordAsAShortcut() {
        XCTAssertNil(SearchShortcut.leadingShortcut(in: "maps of Iceland"))
        XCTAssertNil(SearchShortcut.leadingShortcut(in: "news today"))
        XCTAssertEqual(
            SearchShortcut.strippingLeadingShortcut(from: "maps of Iceland"),
            "maps of Iceland"
        )
    }

    func testDoesNotTreatAnUnknownBangAsAShortcut() {
        XCTAssertNil(SearchShortcut.leadingShortcut(in: "!notashortcut something"))
        XCTAssertEqual(
            SearchShortcut.strippingLeadingShortcut(from: "!notashortcut something"),
            "!notashortcut something"
        )
    }

    func testLeavesABangThatIsNotAtTheStart() {
        XCTAssertEqual(
            SearchShortcut.strippingLeadingShortcut(from: "weather !maps"),
            "weather !maps"
        )
    }

    func testABangWithNoQueryStripsToNothing() {
        XCTAssertEqual(SearchShortcut.strippingLeadingShortcut(from: "!maps"), "")
        XCTAssertEqual(SearchShortcut.strippingLeadingShortcut(from: "!maps   "), "")
    }

    func testPlainQueriesAreOnlyTrimmed() {
        XCTAssertEqual(
            SearchShortcut.strippingLeadingShortcut(from: "  falcon heavy  "),
            "falcon heavy"
        )
    }
}
