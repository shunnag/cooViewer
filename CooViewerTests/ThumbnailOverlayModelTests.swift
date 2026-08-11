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
}
