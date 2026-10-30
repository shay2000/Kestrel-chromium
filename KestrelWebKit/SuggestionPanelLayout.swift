import Foundation

/// Decides how many suggestion rows the address field's dropdown can show.
///
/// The panel opens downwards from the field, so what it can show is bounded by
/// the room between the field and the bottom of the display. A fixed row count
/// gets this wrong in both directions: too many and the last rows fall off the
/// bottom of a laptop screen, too few and a large display leaves half the panel
/// empty. The row budget is derived from the screen and then shared out between
/// the sections.
///
/// The numbers here are deliberately conservative. `fixedChrome` is an upper
/// bound on everything in the panel that is not a suggestion row, so a panel
/// sized from it can never overrun the display even when every section has
/// matches to show.
enum SuggestionPanelLayout {
    /// One suggestion row.
    static let rowHeight: CGFloat = 46
    /// The gap between two rows inside one section.
    static let rowSpacing: CGFloat = 2

    /// Everything in the panel that is not a suggestion row: its padding, the
    /// two route rows, the section headings, the dividers and the footer
    /// button.
    static let fixedChrome: CGFloat = 310

    /// Below this the panel stops being useful. Sections clip instead.
    static let minimumRows = 4
    /// Above this it stops being a dropdown and becomes a list.
    static let maximumRows = 14

    /// Kept clear below the panel so it never touches the window edge.
    static let bottomMargin: CGFloat = 18

    /// Distance from the top of the visible screen to the bottom of a field
    /// sitting in the toolbar.
    static let toolbarTopAllowance: CGFloat = 120
    /// The same for the new tab page's floating field, which sits well down the
    /// page with a caption above it.
    static let newTabTopAllowance: CGFloat = 270

    /// Used when there is no screen to measure, so the arithmetic still lands
    /// somewhere sensible.
    static let fallbackScreenHeight: CGFloat = 900

    /// Most rows one local section may show.
    static let localSectionLimit = 4
    /// Most rows the network suggestions may show.
    static let remoteSectionLimit = 7

    /// How many suggestion rows fit on a display of this height.
    ///
    /// `offsetFromTop` is the distance from the top of the visible screen to
    /// the bottom of the field, which is where the panel starts.
    static func rowCapacity(screenHeight: CGFloat, offsetFromTop: CGFloat) -> Int {
        let available = screenHeight - offsetFromTop - bottomMargin
        let rows = Int(((available - fixedChrome) / (rowHeight + rowSpacing)).rounded(.down))
        return min(max(rows, minimumRows), maximumRows)
    }

    /// The panel's height when it is showing this many rows.
    static func panelHeight(rowCapacity: Int) -> CGFloat {
        fixedChrome + CGFloat(max(0, rowCapacity)) * (rowHeight + rowSpacing)
    }
}

/// How a row budget was shared out between the panel's sections.
struct SuggestionCapacity: Equatable {
    var bookmarks = 0
    var recentSearches = 0
    var openTabs = 0
    var remote = 0

    var total: Int { bookmarks + recentSearches + openTabs + remote }
}

extension SuggestionPanelLayout {
    /// Shares `capacity` rows between the four sections.
    ///
    /// The rows are handed out one at a time, in a loop, so every section with
    /// matches gets a look in before any section gets its second row. Filling
    /// one section to its cap before moving on would let four matching
    /// bookmarks hide the search suggestions completely, which reads as the
    /// panel being broken rather than as a budget being spent.
    static func allocate(
        capacity: Int,
        bookmarkMatches: Int,
        recentMatches: Int,
        tabMatches: Int,
        remoteMatches: Int
    ) -> SuggestionCapacity {
        let wants = [
            max(0, bookmarkMatches),
            max(0, recentMatches),
            max(0, tabMatches),
            max(0, remoteMatches)
        ]
        let limits = [localSectionLimit, localSectionLimit, localSectionLimit, remoteSectionLimit]
        var given = [0, 0, 0, 0]
        var remaining = max(0, capacity)

        while remaining > 0 {
            var placedARow = false
            for index in wants.indices where remaining > 0 {
                guard given[index] < min(wants[index], limits[index]) else { continue }
                given[index] += 1
                remaining -= 1
                placedARow = true
            }
            guard placedARow else { break }
        }

        return SuggestionCapacity(
            bookmarks: given[0],
            recentSearches: given[1],
            openTabs: given[2],
            remote: given[3]
        )
    }
}
