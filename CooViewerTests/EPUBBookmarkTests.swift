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

    func testCollectionPageNumberClampsToSegmentEnd() {
        XCTAssertEqual(EPUBBookmarkLogic.collectionPageNumber(
            globalStart: 10, localPage: 99, segmentPageCount: 5), 15)
        XCTAssertEqual(EPUBBookmarkLogic.collectionPageNumber(
            globalStart: 10, localPage: 2, segmentPageCount: 5), 13)
    }

    func testResolvedLocatorKeepsOriginalWhenPageIsUnchanged() {
        let original = EPUBLocator(spineIndex: 2, progression: 0.37)
        var conversionCalled = false

        let resolved = EPUBBookmarkLogic.resolvedLocator(
            original: original, editedPage: 13, originalPage: 13,
            range: 11...15, base: 10,
            locatorForLocalPage: { _ in
                conversionCalled = true
                return EPUBLocator(spineIndex: 9)
            })

        XCTAssertEqual(resolved, original)
        XCTAssertFalse(conversionCalled)
    }

    func testResolvedLocatorUsesConvertedLocatorForEditedPage() {
        let original = EPUBLocator(spineIndex: 2, progression: 0.37)
        let converted = EPUBLocator(spineIndex: 4, progression: 0.25)

        let resolved = EPUBBookmarkLogic.resolvedLocator(
            original: original, editedPage: 4, originalPage: 2,
            range: 1...5, base: 0,
            locatorForLocalPage: { page in
                XCTAssertEqual(page, 3)
                return converted
            })

        XCTAssertEqual(resolved, converted)
    }

    func testResolvedLocatorKeepsOriginalForOutOfRangePage() {
        let original = EPUBLocator(spineIndex: 2, progression: 0.37)

        let resolved = EPUBBookmarkLogic.resolvedLocator(
            original: original, editedPage: 16, originalPage: 13,
            range: 11...15, base: 10,
            locatorForLocalPage: { _ in EPUBLocator(spineIndex: 9) })

        XCTAssertEqual(resolved, original)
    }

    func testResolvedLocatorKeepsOriginalWhenConversionFails() {
        let original = EPUBLocator(spineIndex: 2, progression: 0.37)

        let resolved = EPUBBookmarkLogic.resolvedLocator(
            original: original, editedPage: 4, originalPage: 2,
            range: 1...5, base: 0,
            locatorForLocalPage: { _ in nil })

        XCTAssertEqual(resolved, original)
    }

    func testResolvedBookmarksResolvesEditedPageWhenSameBook() {
        let edited: [(name: String, locator: EPUBLocator, pageNumber: Int?)] = [
            ("a", EPUBLocator(spineIndex: 2, progression: 0.37), 4),
        ]
        let converted = EPUBLocator(spineIndex: 4, progression: 0.25)
        let resolved = EPUBBookmarkLogic.resolvedBookmarks(
            edited, sameBook: true,
            originalPage: { _ in 2 },
            range: 1...5, base: 0,
            locatorForLocalPage: { _ in converted })
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].name, "a")
        XCTAssertEqual(resolved[0].locator, converted)
    }

    func testResolvedBookmarksKeepsOriginalLocatorWhenBookSwitched() {
        let original = EPUBLocator(spineIndex: 2, progression: 0.37)
        let edited: [(name: String, locator: EPUBLocator, pageNumber: Int?)] = [
            ("renamed", original, 4),  // ページ編集あり
        ]
        var conversionCalled = false
        var originalPageCalled = false
        let resolved = EPUBBookmarkLogic.resolvedBookmarks(
            edited, sameBook: false,
            originalPage: { _ in originalPageCalled = true; return 2 },
            range: 1...5, base: 0,
            locatorForLocalPage: { _ in
                conversionCalled = true; return EPUBLocator(spineIndex: 9) })
        // 名前は適用、locator は原本のまま、census 変換・originalPage は未評価
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].name, "renamed")
        XCTAssertEqual(resolved[0].locator, original)
        XCTAssertFalse(conversionCalled)
        XCTAssertFalse(originalPageCalled)
    }

    func testCollectionDisplayedPageRoundTripsThroughBaseOffset() {
        let displayed = EPUBBookmarkLogic.collectionPageNumber(
            globalStart: 10, localPage: 2, segmentPageCount: 5)
        XCTAssertEqual(displayed, 13)
        XCTAssertEqual(EPUBBookmarkLogic.localPage(
            forDisplayed: displayed, base: 10), 2)

        let converted = EPUBLocator(spineIndex: 7, progression: 0.5)
        XCTAssertEqual(EPUBBookmarkLogic.resolvedLocator(
            original: EPUBLocator(spineIndex: 1), editedPage: displayed,
            originalPage: 12, range: 11...15, base: 10,
            locatorForLocalPage: { $0 == 2 ? converted : nil }), converted)
    }

    func testResolvedLocatorKeepsOriginalWithoutCensusRange() {
        let original = EPUBLocator(spineIndex: 2, progression: 0.37)

        let resolved = EPUBBookmarkLogic.resolvedLocator(
            original: original, editedPage: 4, originalPage: 2,
            range: nil, base: 0,
            locatorForLocalPage: { _ in EPUBLocator(spineIndex: 9) })

        XCTAssertEqual(resolved, original)
    }

    func testEditorSaveItemsNormalizesNameAndReturnsOnlyEditedPage() {
        let locator = EPUBLocator(spineIndex: 2, progression: 0.37)
        let items = [
            EPUBBookmarkEditorView.Item(
                name: "", locator: locator, position: "2/5",
                pageNumber: 2, originalPageNumber: 2),
            EPUBBookmarkEditorView.Item(
                name: "moved", locator: locator, position: "2/5",
                pageNumber: 4, originalPageNumber: 2),
        ]

        let saved = EPUBBookmarkEditorView.saveItems(items)

        XCTAssertEqual(saved[0].name, "bookmark1")
        XCTAssertNil(saved[0].pageNumber)
        XCTAssertEqual(saved[0].locator, locator)
        XCTAssertEqual(saved[1].name, "moved")
        XCTAssertEqual(saved[1].pageNumber, 4)
    }

    func testMatchingUsesOneBasedVisibleRangeForZeroBasedCensusPage() {
        let bookmarks = [bookmark(1), bookmark(3)]
        let match = EPUBBookmarkLogic.matchingIndex(
            in: bookmarks,
            current: EPUBLocator(spineIndex: 0),
            currentPageRange: 1...2,
            pageCountInItem: 1,
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
            pageCountInItem: 1,
            globalPage: { _ in nil }), 0)
        XCTAssertNil(EPUBBookmarkLogic.matchingIndex(
            in: bookmarks,
            current: EPUBLocator(spineIndex: 2, progression: 0.502),
            currentPageRange: nil,
            pageCountInItem: 1,
            globalPage: { _ in nil }))
    }

    func testMatchingFallbackDistinguishesAdjacentPagesInLongSpine() {
        let pageCount = 200
        let page = 73
        let current = EPUBLocator(
            spineIndex: 2,
            progression: Double(page) / Double(pageCount - 1))
        let bookmarks = [
            ("same", current),
            ("next", EPUBLocator(
                spineIndex: 2,
                progression: Double(page + 1) / Double(pageCount - 1))),
        ]

        XCTAssertEqual(EPUBBookmarkLogic.matchingIndex(
            in: bookmarks, current: current, currentPageRange: nil,
            pageCountInItem: pageCount, globalPage: { _ in nil }), 0)
        XCTAssertNil(EPUBBookmarkLogic.matchingIndex(
            in: [bookmarks[1]], current: current, currentPageRange: nil,
            pageCountInItem: pageCount, globalPage: { _ in nil }))
    }

    func testNextAndPreviousChooseNearestPageFromUnsortedBookmarks() {
        let bookmarks = [bookmark(7), bookmark(2), bookmark(5), bookmark(3)]
        let current = EPUBLocator(spineIndex: 4)
        XCTAssertEqual(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: current, currentPageRange: 4...5,
            pageCountInItem: 1, next: true,
            globalPage: { $0.spineIndex }), 2)
        XCTAssertEqual(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: current, currentPageRange: 4...5,
            pageCountInItem: 1, next: false,
            globalPage: { $0.spineIndex }), 1)
    }

    func testNavigationExcludesBookmarksInsideCurrentSpreadAndBookEdges() {
        let bookmarks = [bookmark(0), bookmark(1), bookmark(3)]
        let current = EPUBLocator(spineIndex: 0)
        XCTAssertNil(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: current, currentPageRange: 1...2,
            pageCountInItem: 1, next: false,
            globalPage: { $0.spineIndex }))
        XCTAssertEqual(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: current, currentPageRange: 1...2,
            pageCountInItem: 1, next: true,
            globalPage: { $0.spineIndex }), 2)
        XCTAssertNil(EPUBBookmarkLogic.targetIndex(
            in: bookmarks, current: EPUBLocator(spineIndex: 3),
            currentPageRange: 4...4, pageCountInItem: 1, next: true,
            globalPage: { $0.spineIndex }))
    }
}
