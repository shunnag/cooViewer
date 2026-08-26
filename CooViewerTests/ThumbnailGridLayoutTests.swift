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

    // MARK: - 自動グリッド(セルサイズ基準。設計書 §2.4)

    func testDimensionsFitViewport() {
        // 幅 1000: (1000+8) / (160+8) = 6 列(6×160+5×8 = 1000 でちょうど収まる)。
        // 高さ 600: セル高 160×1.45 = 232 → (600+8) / (232+8) = 2.53 → 2 行
        let dims = ThumbnailGridLayout.dimensions(
            for: CGSize(width: 1000, height: 600), cellSize: 160)
        XCTAssertEqual(dims.columns, 6)
        XCTAssertEqual(dims.rows, 2)
    }

    func testDimensionsNeverBelowOneByOne() {
        // ビューポートより大きいセル・ゼロ寸法でも最低 1×1
        let small = ThumbnailGridLayout.dimensions(
            for: CGSize(width: 50, height: 40), cellSize: 400)
        XCTAssertEqual(small.rows, 1)
        XCTAssertEqual(small.columns, 1)
        let zero = ThumbnailGridLayout.dimensions(for: .zero, cellSize: 160)
        XCTAssertEqual(zero.rows, 1)
        XCTAssertEqual(zero.columns, 1)
    }

    func testDimensionsClampCellSize() {
        // 可動域外のセルサイズは丸めてから計算する(極小値で列数が爆発しない)
        let viewport = CGSize(width: 1000, height: 600)
        let tiny = ThumbnailGridLayout.dimensions(for: viewport, cellSize: 1)
        let atMin = ThumbnailGridLayout.dimensions(
            for: viewport, cellSize: ThumbnailZoomSetting.range.lowerBound)
        XCTAssertEqual(tiny.columns, atMin.columns)
        XCTAssertEqual(tiny.rows, atMin.rows)
    }

    func testZoomSettingReadWriteClamp() {
        let suite = "ThumbnailZoomSettingTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // 未保存なら既定サイズ
        XCTAssertEqual(ThumbnailZoomSetting.read(from: defaults),
                       ThumbnailZoomSetting.defaultSize)
        // 可動域の外は書き込み時に丸める
        ThumbnailZoomSetting.write(9999, to: defaults)
        XCTAssertEqual(ThumbnailZoomSetting.read(from: defaults),
                       ThumbnailZoomSetting.range.upperBound)
        ThumbnailZoomSetting.write(200, to: defaults)
        XCTAssertEqual(ThumbnailZoomSetting.read(from: defaults), 200)
    }
}
