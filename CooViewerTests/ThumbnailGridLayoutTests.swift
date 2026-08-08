import XCTest
@testable import cooViewer

final class ThumbnailGridLayoutTests: XCTestCase {
    private func makeLayout(entryCount: Int = 10,
                            bookmarkedPages: Set<Int> = [],
                            onlyBookmarks: Bool = false,
                            comicMode: Bool = false,
                            rows: Int = 2, columns: Int = 3,
                            knownLargePages: Set<Int> = []) -> ThumbnailGridLayout {
        ThumbnailGridLayout(entryCount: entryCount,
                            bookmarkedPages: bookmarkedPages,
                            onlyBookmarks: onlyBookmarks,
                            comicMode: comicMode,
                            rows: rows, columns: columns,
                            knownLargePages: knownLargePages)
    }

    func testSinglePageMode() {
        let layout = makeLayout(entryCount: 10)
        XCTAssertEqual(layout.cellGroups, (0..<10).map { [$0] })
        XCTAssertEqual(layout.cellsPerScreen, 6)
        XCTAssertEqual(layout.screenCount, 2)  // ceil(10 / 6)
    }

    func testComicModePairsPagesAndHalvesColumns() {
        // 奇数エントリ: 末尾は単独セル
        let layout = makeLayout(entryCount: 5, comicMode: true, columns: 4)
        XCTAssertEqual(layout.cellGroups, [[0, 1], [2, 3], [4]])
        XCTAssertEqual(layout.columns, 2)
    }

    func testOnlyBookmarksFiltersBeforePairing() {
        let layout = makeLayout(entryCount: 10, bookmarkedPages: [1, 4, 7],
                                onlyBookmarks: true, comicMode: true)
        XCTAssertEqual(layout.cellGroups, [[1, 4], [7]])
    }

    func testComicModeKeepsLandscapePagesSingle() {
        // 旧 mangaMode の isSmallImage 規則: 横長ページはペアにしない。
        // 横長 1 を挟むと以降のペア境界もずれる(逐次ペアリング)
        let layout = makeLayout(entryCount: 5, comicMode: true, columns: 4,
                                knownLargePages: [1])
        XCTAssertEqual(layout.cellGroups, [[0], [1], [2, 3], [4]])
        // ペア相手側が横長でも同様に単独になる
        let second = makeLayout(entryCount: 4, comicMode: true, columns: 4,
                                knownLargePages: [0])
        XCTAssertEqual(second.cellGroups, [[0], [1, 2], [3]])
    }

    func testComicModeLandscapeRuleAppliesAfterBookmarkFilter() {
        let layout = makeLayout(entryCount: 10, bookmarkedPages: [1, 4, 7],
                                onlyBookmarks: true, comicMode: true,
                                knownLargePages: [4])
        XCTAssertEqual(layout.cellGroups, [[1], [4], [7]])
    }

    func testEmptyBookStillHasOneScreen() {
        let layout = makeLayout(entryCount: 0)
        XCTAssertEqual(layout.screenCount, 1)
        XCTAssertEqual(layout.groups(onScreen: 0), [])
    }

    func testGroupsOnScreenBounds() {
        let layout = makeLayout(entryCount: 10)  // 6 セル/画面
        XCTAssertEqual(layout.groups(onScreen: 0).count, 6)
        XCTAssertEqual(layout.groups(onScreen: 1), [[6], [7], [8], [9]])
        XCTAssertEqual(layout.groups(onScreen: -1), [])
        XCTAssertEqual(layout.groups(onScreen: 2), [])
    }

    func testScreenContainingEntry() {
        let layout = makeLayout(entryCount: 10)  // 6 セル/画面
        XCTAssertEqual(layout.screen(containing: 0), 0)
        XCTAssertEqual(layout.screen(containing: 6), 1)
        XCTAssertNil(layout.screen(containing: 99))
        // 絞り込みで非表示のページは nil
        let filtered = makeLayout(entryCount: 10, bookmarkedPages: [3],
                                  onlyBookmarks: true)
        XCTAssertNil(filtered.screen(containing: 0))
        XCTAssertEqual(filtered.screen(containing: 3), 0)
    }

    func testClampedScreen() {
        let layout = makeLayout(entryCount: 10)
        XCTAssertEqual(layout.clamped(screen: -5), 0)
        XCTAssertEqual(layout.clamped(screen: 5), 1)
    }
}
