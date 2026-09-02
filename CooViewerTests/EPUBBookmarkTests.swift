import XCTest
import Washi

@testable import cooViewer

/// リフローしおりの画面一致・整列・境界(仕様書 §4.7、設計書 §2.4)
@MainActor
final class EPUBBookmarkTests: XCTestCase {
    private func bookmark(_ page: Int, progression: Double = 0)
        -> (name: String, locator: EPUBLocator) {
        ("p\(page)", EPUBLocator(spineIndex: page, progression: progression))
    }

    func testMatchingUsesOneBasedVisibleRangeForZeroBasedCensusPage() {
        let bookmarks = [bookmark(1), bookmark(3)]
        let match = EPUBBookmarkLogic.matchingIndex(
            in: bookmarks,
            current: EPUBLocator(spineIndex: 0),
            currentPageRange: 1...2,
            globalPage: { $0.spineIndex })
        XCTAssertEqual(match, 0, "0 始まり page 1 は表示上の 2 ページ目")
    }

    func testMatchingFallbackHonorsSpineAndFixedEpsilonBoundary() {
        let bookmarks = [
            bookmark(2, progression: 0.481),
            bookmark(1, progression: 0.50),
        ]
        XCTAssertEqual(EPUBBookmarkLogic.matchingIndex(
            in: bookmarks,
            current: EPUBLocator(spineIndex: 2, progression: 0.50),
            currentPageRange: nil,
            globalPage: { _ in nil }), 0)
        XCTAssertNil(EPUBBookmarkLogic.matchingIndex(
            in: bookmarks,
            current: EPUBLocator(spineIndex: 2, progression: 0.502),
            currentPageRange: nil,
            globalPage: { _ in nil }))
    }

    func testNextAndPreviousChooseNearestPageFromUnsortedBookmarks() {
        let bookmarks = [bookmark(7), bookmark(2), bookmark(5), bookmark(3)]
        let current = EPUBLocator(spineIndex: 4)
        XCTAssertEqual(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: current, currentPageRange: 4...5,
            next: true, globalPage: { $0.spineIndex }), 2)
        XCTAssertEqual(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: current, currentPageRange: 4...5,
            next: false, globalPage: { $0.spineIndex }), 1)
    }

    func testNavigationExcludesBookmarksInsideCurrentSpreadAndBookEdges() {
        let bookmarks = [bookmark(0), bookmark(1), bookmark(3)]
        let current = EPUBLocator(spineIndex: 0)
        XCTAssertNil(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: current, currentPageRange: 1...2,
            next: false, globalPage: { $0.spineIndex }))
        XCTAssertEqual(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: current, currentPageRange: 1...2,
            next: true, globalPage: { $0.spineIndex }), 2)
        XCTAssertNil(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: EPUBLocator(spineIndex: 3),
            currentPageRange: 4...4, next: true,
            globalPage: { $0.spineIndex }))
    }
}
