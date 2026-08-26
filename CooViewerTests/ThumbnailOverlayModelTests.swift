import XCTest

@testable import cooViewer

/// サムネイルオーバーレイモデルのスナップショット同期のテスト。
/// 表示中にソート変更等で本のエントリ列が変わった場合、follow がスナップショットを
/// 組み直し、一覧の表示とクリックのジャンプ先が実際の本とずれないことを確認する。
@MainActor
final class ThumbnailOverlayModelTests: XCTestCase {
    /// 名前(自然順)と名前(単純)で並びが変わるエントリ名を持つスタブソース
    private final class NamedStubSource: BookSource, @unchecked Sendable {
        let url = URL(fileURLWithPath: "/stub/named-book")
        let names: [String]
        let sizes: [CGSize]?
        var supportsDateSort: Bool { false }

        init(names: [String], sizes: [CGSize]? = nil) {
            self.names = names
            self.sizes = sizes
        }

        func entries() async throws -> [PageEntry] {
            names.enumerated().map { index, name in
                PageEntry(id: index, name: name, pathInBook: name,
                          fileURL: nil, creationDate: nil, modificationDate: nil)
            }
        }

        func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
            let size = sizes?[entry.id] ?? CGSize(width: 70, height: 100)
            return try ImageDecoding.decode(
                TestFixtures.pngData(width: Int(size.width), height: Int(size.height)),
                maxPixelSize: maxPixelSize)
        }
    }

    private func makeModel() -> ThumbnailOverlayModel {
        let defaults = UserDefaults(suiteName: "ThumbnailOverlayModelTests")!
        defaults.removePersistentDomain(forName: "ThumbnailOverlayModelTests")
        let model = ThumbnailOverlayModel(defaults: defaults)
        // しおりのみ表示にして先読みを空にする(テストからの実 I/O を避ける)
        model.onlyBookmarks = true
        return model
    }

    /// ソート変更でエントリ列が変わったら follow がスナップショットを組み直す
    func testFollowRebuildsSnapshotAfterSortChange() async throws {
        // 自然順: a1 < a2 < a10 / 単純順: a1 < a10 < a2 と並びが必ず変わる
        let book = try await Book.open(
            source: NamedStubSource(names: ["a2.png", "a10.png", "a1.png"]))
        let model = makeModel()
        model.present(book: book)
        XCTAssertEqual(model.snapshot.entries, book.entries)

        book.setSortMode(.literalName)
        // 前提の確認: 並びが実際に変わっている(変わらなければテスト自体が無効)
        XCTAssertNotEqual(model.snapshot.entries, book.entries)

        model.follow(book: book, displayedIndices: [book.currentIndex])
        XCTAssertEqual(model.snapshot.entries, book.entries)
        XCTAssertEqual(model.snapshot.currentIndex, book.currentIndex)
        XCTAssertEqual(model.snapshot.displayedIndices, [book.currentIndex])
        await model.waitForPrefetch()
    }

    /// 見開きモード: サムネイル生成で横長と判明したページはペアから外れること
    /// (旧 mangaMode の isSmallImage 規則への漸進的収束)
    func testComicModePairingLearnsLandscapePages() async throws {
        let portrait = CGSize(width: 70, height: 100)
        let landscape = CGSize(width: 150, height: 100)
        let book = try await Book.open(source: NamedStubSource(
            names: ["a.png", "b.png", "c.png", "d.png"],
            sizes: [portrait, landscape, portrait, portrait]))
        let model = makeModel()
        model.onlyBookmarks = false
        model.comicMode = true
        // 先読み(縦横比の計測)はビューポート確定後のみ走る
        model.updateViewport(CGSize(width: 1000, height: 600))
        model.present(book: book)
        await model.waitForPrefetch()
        XCTAssertEqual(model.knownLargePages, [1])
        XCTAssertEqual(model.layout.cellGroups, [[0], [1], [2, 3]])
    }

    /// marks の強制ペア指定は縦横比に優先し、強制単ページは計測前でも単独になる
    /// (マーク変更はスナップショット追従で即反映される。§4.2.1)
    func testMarksOverrideMeasuredAspectInPairing() async throws {
        let portrait = CGSize(width: 70, height: 100)
        let landscape = CGSize(width: 150, height: 100)
        let book = try await Book.open(source: NamedStubSource(
            names: ["a.png", "b.png", "c.png", "d.png"],
            sizes: [portrait, landscape, portrait, portrait]))
        // 横長の 1 を強制ペア(1-2)に、縦長の 2(index)を強制単ページに
        book.marks.setForcedPair(firstIndex: 0)
        book.marks.setForcedSingle(2)
        let model = makeModel()
        model.onlyBookmarks = false
        model.comicMode = true
        // 先読み(縦横比の計測)はビューポート確定後のみ走る
        model.updateViewport(CGSize(width: 1000, height: 600))
        model.present(book: book)
        await model.waitForPrefetch()
        // 横長 1 は強制ペアで許容、2 は強制単ページで分離
        XCTAssertEqual(model.knownLargePages, [2])
        XCTAssertEqual(model.layout.cellGroups, [[0, 1], [2], [3]])
    }

    /// 表紙単ページ設定: サムネイル一覧でも先頭ページは単独セルになること
    /// (強制ペア指定 1-2 がある場合はそちらが優先)
    func testCoverSingleSeparatesFirstCell() async throws {
        let portrait = CGSize(width: 70, height: 100)
        let book = try await Book.open(source: NamedStubSource(
            names: ["a.png", "b.png", "c.png", "d.png", "e.png"],
            sizes: [portrait, portrait, portrait, portrait, portrait]))
        book.coverSingleFirst = true
        let model = makeModel()
        model.onlyBookmarks = false
        model.comicMode = true
        // 先読み(縦横比の計測)はビューポート確定後のみ走る
        model.updateViewport(CGSize(width: 1000, height: 600))
        model.present(book: book)
        await model.waitForPrefetch()
        XCTAssertEqual(model.layout.cellGroups, [[0], [1, 2], [3, 4]])

        // 強制ペア(1-2)を付けると表紙もペアに戻る
        book.marks.setForcedPair(firstIndex: 0)
        model.follow(book: book, displayedIndices: [0])
        XCTAssertEqual(model.layout.cellGroups, [[0, 1], [2, 3], [4]])
    }

    /// clear がスナップショット(ソースへの強参照)を解放すること。
    /// 非表示のまま本を切り替えたときの旧書庫の一時ファイル保持を防ぐ
    func testClearReleasesSnapshot() async throws {
        let book = try await Book.open(
            source: NamedStubSource(names: ["a1.png", "a2.png"]))
        let model = makeModel()
        model.present(book: book)
        XCTAssertFalse(model.snapshot.entries.isEmpty)
        XCTAssertNotNil(model.snapshot.source)

        model.clear()
        XCTAssertTrue(model.snapshot.entries.isEmpty)
        XCTAssertNil(model.snapshot.source)
        XCTAssertEqual(model.screen, 0)
    }

    /// 並びが変わっていなければ follow は強調表示の更新だけを行う
    func testFollowKeepsSnapshotWhenOrderUnchanged() async throws {
        let book = try await Book.open(
            source: NamedStubSource(names: ["a1.png", "a2.png", "a3.png"]))
        let model = makeModel()
        model.present(book: book)

        book.goTo(index: 2)
        model.follow(book: book, displayedIndices: [2])
        XCTAssertEqual(model.snapshot.entries, book.entries)
        XCTAssertEqual(model.snapshot.currentIndex, 2)
        XCTAssertEqual(model.snapshot.displayedIndices, [2])
        await model.waitForPrefetch()
    }

    // MARK: - 自動グリッドとズーム(設計書 §2.4)

    /// ソース無しの大きなスナップショット(先読みは source ガードで走らない)
    private func presentPages(_ count: Int, currentIndex: Int = 0,
                              on model: ThumbnailOverlayModel) {
        var snapshot = ThumbnailOverlayModel.Snapshot()
        snapshot.entries = (0..<count).map {
            PageEntry(id: $0, name: "\($0).png", pathInBook: "\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
        snapshot.currentIndex = currentIndex
        snapshot.displayedIndices = [currentIndex]
        model.present(snapshot: snapshot)
    }

    /// ズーム(セルサイズ変更)を何度繰り返しても表示位置がドリフトしないこと。
    /// screen×旧セル数→新セル数の逐次換算だと床関数の丸めが累積して先頭方向へ
    /// 這うため、先頭セル組アンカーからの導出を検証する
    func testZoomKeepsAnchorStable() {
        let model = makeModel()
        model.onlyBookmarks = false
        presentPages(100, on: model)
        model.updateViewport(CGSize(width: 1000, height: 600))  // 6×2 = 12 セル/画面
        model.moveScreen(by: 3)  // 先頭セル組 36
        let anchorEntry = model.layout.groups(onScreen: model.screen).first?.first
        XCTAssertNotNil(anchorEntry)
        // 60Hz のピンチを模して細かく往復させる
        for step in 0..<120 {
            model.setCellSize(160 + CGFloat(step % 40), commit: false)
        }
        model.setCellSize(160, commit: false)
        XCTAssertEqual(model.layout.groups(onScreen: model.screen).first?.first,
                       anchorEntry)
    }

    /// セルサイズはジェスチャ確定(commit)時のみ保存され、
    /// defaults 側の変更は sync で反映されること
    func testCellSizePersistsOnCommitOnly() {
        let suite = "ThumbnailOverlayModelZoomTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = ThumbnailOverlayModel(defaults: defaults)
        XCTAssertEqual(model.cellSize, ThumbnailZoomSetting.defaultSize)

        model.setCellSize(240, commit: false)  // ジェスチャ中
        XCTAssertEqual(model.cellSize, 240)
        XCTAssertEqual(defaults.double(forKey: ThumbnailZoomSetting.defaultsKey), 0)

        model.setCellSize(240, commit: true)  // 指を離した
        XCTAssertEqual(defaults.double(forKey: ThumbnailZoomSetting.defaultsKey), 240)

        // 設定スライダ → applySettings 経由の同期
        ThumbnailZoomSetting.write(120, to: defaults)
        model.syncCellSizeFromDefaults()
        XCTAssertEqual(model.cellSize, 120)
    }

    /// 最初のジオメトリ到着ではフォールバック 3×4 のアンカー換算ではなく、
    /// 現在ページを含む画面を取り直すこと
    func testFirstViewportShowsCurrentPage() {
        let model = makeModel()
        model.onlyBookmarks = false
        presentPages(100, currentIndex: 50, on: model)
        // 400×400 @ セル 160: 列 (408/168)=2・行 (408/240)=1 → 2 セル/画面
        model.updateViewport(CGSize(width: 400, height: 400))
        XCTAssertEqual(model.screen, 25)  // 50 を含む画面
        XCTAssertEqual(model.layout.groups(onScreen: model.screen).first?.first, 50)
    }
}
