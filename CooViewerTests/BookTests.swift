import CoreGraphics
import XCTest
@testable import cooViewer

/// サイズ指定だけでページを供給するテスト用ソース。
final class StubSource: BookSource, @unchecked Sendable {
    let url = URL(fileURLWithPath: "/stub/book")
    let sizes: [CGSize]

    var supportsDateSort: Bool { false }

    init(sizes: [CGSize]) {
        self.sizes = sizes
    }

    func entries() async throws -> [PageEntry] {
        sizes.indices.map { index in
            PageEntry(id: index, name: String(format: "p%03d.png", index),
                      pathInBook: String(format: "p%03d.png", index),
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let size = sizes[entry.id]
        return try ImageDecoding.decode(
            TestFixtures.pngData(width: Int(size.width), height: Int(size.height)),
            maxPixelSize: maxPixelSize)
    }
}

@MainActor
final class BookTests: XCTestCase {
    private let portrait = CGSize(width: 70, height: 100)   // 0.7 <= 0.74 → 見開き候補
    private let landscape = CGSize(width: 150, height: 100) // 1.5 > 0.74 → 単ページ

    private func makeBook(_ sizes: [CGSize], readMode: ReadMode = .rightToLeftSpread) async throws -> Book {
        let book = try await Book.open(source: StubSource(sizes: sizes))
        book.readMode = readMode
        return book
    }

    func testSpreadPairsTwoPortraitPages() async throws {
        let book = try await makeBook([portrait, portrait, portrait])
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0, 1])
    }

    func testLandscapePageStaysSingle() async throws {
        let book = try await makeBook([landscape, portrait, portrait])
        var spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])
        XCTAssertEqual(book.moveNext(), .moved)
        spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [1, 2])
    }

    func testPortraitBeforeLandscapeStaysSingle() async throws {
        let book = try await makeBook([portrait, landscape, portrait])
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])
    }

    func testSingleReadModeNeverPairs() async throws {
        let book = try await makeBook([portrait, portrait], readMode: .rightToLeftSingle)
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])
    }

    func testMarksForceSingle() async throws {
        let book = try await makeBook([portrait, portrait])
        book.marks = PageMarks(legacyArray: ["1"])  // 1 始まり(仕様書 §7.1)
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])
    }

    func testMarksForcePairOfLandscapePages() async throws {
        let book = try await makeBook([landscape, landscape])
        book.marks = PageMarks(legacyArray: ["1-2"])
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0, 1])
    }

    /// 表紙単ページ設定: 先頭は単ページ、以降は (1,2)(3,4)… で見開き
    func testCoverSingleKeepsFirstPageAlone() async throws {
        let book = try await makeBook([portrait, portrait, portrait])
        book.coverSingleFirst = true
        var spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])
        XCTAssertEqual(book.moveNext(), .moved)
        spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [1, 2])
    }

    /// 表紙単ページ設定でも marks の強制ペア(1-2)が優先されること
    func testCoverSingleYieldsToForcedPairMark() async throws {
        let book = try await makeBook([portrait, portrait])
        book.coverSingleFirst = true
        book.marks = PageMarks(legacyArray: ["1-2"])
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0, 1])
    }

    /// 表紙単ページ設定の後方めくり: (3,4)→(1,2)→(0) と揃って戻ること
    func testCoverSingleBackwardNavigation() async throws {
        let book = try await makeBook(
            [portrait, portrait, portrait, portrait, portrait])
        book.coverSingleFirst = true
        book.goTo(index: 3)
        var result = await book.movePrevious()
        XCTAssertEqual(result, .moved)
        XCTAssertEqual(book.currentIndex, 1)     // (1,2) ペアへ
        result = await book.movePrevious()
        XCTAssertEqual(result, .moved)
        XCTAssertEqual(book.currentIndex, 0)     // 表紙は単ページ
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])
    }

    /// 表紙単ページの途中切替: 先頭起点の区分へ整列してから再表示する
    /// (OFF で (2,3) 表示中 → ON → (1,2) になる)
    func testReanchorAfterCoverSingleToggleOn() async throws {
        let book = try await makeBook(
            [portrait, portrait, portrait, portrait, portrait, portrait])
        book.goTo(index: 2)
        var spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [2, 3])       // OFF: (2,3) を表示中
        book.coverSingleFirst = true
        await book.reanchorToLeadingPartition()
        spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [1, 2])       // ON: (0)(1,2)(3,4)… に整列
    }

    /// 表紙単ページの途中切替(逆方向): ON で (1,2) → OFF → (0,1)
    func testReanchorAfterCoverSingleToggleOff() async throws {
        let book = try await makeBook(
            [portrait, portrait, portrait, portrait, portrait, portrait])
        book.coverSingleFirst = true
        book.goTo(index: 1)
        var spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [1, 2])
        book.coverSingleFirst = false
        await book.reanchorToLeadingPartition()
        spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0, 1])
    }

    /// 整列は強制ペア(1-2)を保つ: 表紙単ページを ON にしても区分が動かない
    func testReanchorKeepsForcedPairPartition() async throws {
        let book = try await makeBook(
            [portrait, portrait, portrait, portrait])
        book.marks = PageMarks(legacyArray: ["1-2"])
        book.goTo(index: 2)
        var spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [2, 3])
        book.coverSingleFirst = true
        await book.reanchorToLeadingPartition()
        spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [2, 3])       // (0,1) 強制ペアのまま
    }

    /// 整列は先頭・単ページモードでは何もしない
    func testReanchorNoOpAtCoverAndInSingleMode() async throws {
        let book = try await makeBook([portrait, portrait, portrait])
        book.coverSingleFirst = true
        await book.reanchorToLeadingPartition()
        XCTAssertEqual(book.currentIndex, 0)

        let single = try await makeBook(
            [portrait, portrait, portrait], readMode: .rightToLeftSingle)
        single.goTo(index: 2)
        single.coverSingleFirst = true
        await single.reanchorToLeadingPartition()
        XCTAssertEqual(single.currentIndex, 2)
    }

    /// 次方向のスプレッド列予測: サイズ判明済みならペア、端では空
    func testPredictedAdjacentSpreadsForward() async throws {
        let book = try await makeBook(
            [portrait, portrait, portrait, portrait, portrait, portrait])
        _ = await book.currentSpread()               // (0,1) 表示
        // サイズ未取得のうちは単ページと保守的に予測する
        var predicted = await book.predictedAdjacentSpreads(forward: true, maxPages: 5)
        XCTAssertEqual(predicted, [[2], [3], [4], [5]])
        // デコードでサイズ索引が埋まればペアと予測する
        for index in 2...5 {
            _ = await book.image(at: index)
        }
        predicted = await book.predictedAdjacentSpreads(forward: true, maxPages: 5)
        XCTAssertEqual(predicted, [[2, 3], [4, 5]])
        // ペアを分割してまで maxPages に詰めない
        predicted = await book.predictedAdjacentSpreads(forward: true, maxPages: 3)
        XCTAssertEqual(predicted, [[2, 3]])
        // 末尾のスプレッド表示中は次が無い
        book.goTo(index: 4)
        _ = await book.currentSpread()
        predicted = await book.predictedAdjacentSpreads(forward: true, maxPages: 5)
        XCTAssertEqual(predicted, [])
    }

    /// 前方向のスプレッド列予測: ペア判定は movePrevious と同じ規則、先頭では空
    func testPredictedAdjacentSpreadsBackward() async throws {
        let book = try await makeBook(
            [portrait, portrait, portrait, portrait, portrait, portrait])
        for index in 0...3 {
            _ = await book.image(at: index)
        }
        book.goTo(index: 4)
        _ = await book.currentSpread()
        let predicted = await book.predictedAdjacentSpreads(forward: false, maxPages: 5)
        XCTAssertEqual(predicted, [[2, 3], [0, 1]])
        book.goTo(index: 0)
        let atStart = await book.predictedAdjacentSpreads(forward: false, maxPages: 5)
        XCTAssertEqual(atStart, [])
    }

    /// 単ページモードの予測は常に 1 ページずつ
    func testPredictedAdjacentSpreadsInSingleMode() async throws {
        let book = try await makeBook(
            [portrait, portrait, portrait], readMode: .rightToLeftSingle)
        _ = await book.currentSpread()
        _ = await book.image(at: 1)
        _ = await book.image(at: 2)
        let predicted = await book.predictedAdjacentSpreads(forward: true, maxPages: 5)
        XCTAssertEqual(predicted, [[1], [2]])
    }

    func testMoveNextAdvancesBySpreadWidthAndDetectsEnd() async throws {
        let book = try await makeBook([portrait, portrait, portrait])
        _ = await book.currentSpread()               // [0,1]
        XCTAssertEqual(book.moveNext(), .moved)      // → 2
        _ = await book.currentSpread()               // [2]
        XCTAssertEqual(book.moveNext(), .hitEnd)
        XCTAssertEqual(book.currentIndex, 2)         // 位置は維持
    }

    func testMovePreviousPairsWhenPossible() async throws {
        let book = try await makeBook([portrait, portrait, portrait, portrait, portrait])
        book.goTo(index: 4)
        let result = await book.movePrevious()
        XCTAssertEqual(result, .moved)
        XCTAssertEqual(book.currentIndex, 2)         // 2 枚ペアで戻る
    }

    func testMovePreviousSinglesOverLandscape() async throws {
        let book = try await makeBook([portrait, landscape, portrait])
        book.goTo(index: 2)
        _ = await book.movePrevious()
        XCTAssertEqual(book.currentIndex, 1)         // 横長は単独
        let second = await book.movePrevious()
        XCTAssertEqual(second, .moved)
        XCTAssertEqual(book.currentIndex, 0)
        let atStart = await book.movePrevious()
        XCTAssertEqual(atStart, .hitStart)
    }

    func testGoToLastLandsOnFinalSpread() async throws {
        let book = try await makeBook([portrait, portrait, portrait, portrait])
        await book.goToLast()
        XCTAssertEqual(book.currentIndex, 2)
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [2, 3])
    }

    func testGoToLastLandsOnFinalSingleWhenLandscape() async throws {
        let book = try await makeBook([portrait, portrait, landscape])
        await book.goToLast()
        XCTAssertEqual(book.currentIndex, 2)
    }

    func testHalfMoves() async throws {
        let book = try await makeBook([portrait, portrait, portrait])
        _ = await book.currentSpread()
        XCTAssertEqual(book.moveHalfNext(), .moved)
        XCTAssertEqual(book.currentIndex, 1)
        XCTAssertEqual(book.moveHalfPrevious(), .moved)
        XCTAssertEqual(book.currentIndex, 0)
        XCTAssertEqual(book.moveHalfPrevious(), .hitStart)
    }

    func testGoToPercentWithoutUpperClamp() async throws {
        let book = try await makeBook(Array(repeating: portrait, count: 10))
        XCTAssertEqual(book.goToPercent(0.5), .moved)
        XCTAssertEqual(book.currentIndex, 5)
        XCTAssertEqual(book.goToPercent(1.0), .hitEnd)   // 旧 goToPar の巻末挙動(§13.3)
        XCTAssertEqual(book.currentIndex, 5)
    }

    func testSortChangeResetsToFirstPage() async throws {
        let book = try await makeBook(Array(repeating: portrait, count: 5))
        book.goTo(index: 3)
        book.setSortMode(.shuffle)
        XCTAssertEqual(book.currentIndex, 0)             // 旧仕様維持(§13.3)
        XCTAssertEqual(book.pageCount, 5)
    }

    func testDisplayPixelCapDownsamplesButFullResolutionBypasses() async throws {
        let book = try await makeBook([CGSize(width: 70, height: 100)])
        book.displayPixelCap = 50
        let display = await book.image(at: 0)
        XCTAssertEqual(display?.height, 50)   // 長辺 100 → 50
        XCTAssertEqual(display?.width, 35)
        let full = await book.fullResolutionImage(at: 0)
        XCTAssertEqual(full?.width, 70)       // 原寸はキャップを介さない
        XCTAssertEqual(full?.height, 100)
    }

    func testBrokenPageReportsNilImageAndStaysSingle() async throws {
        // 2 ページ目が壊れているソース
        final class BrokenStub: BookSource, @unchecked Sendable {
            let url = URL(fileURLWithPath: "/stub/broken")
            var supportsDateSort: Bool { false }
            func entries() async throws -> [PageEntry] {
                (0..<2).map {
                    PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                              fileURL: nil, creationDate: nil, modificationDate: nil)
                }
            }
            func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
                if entry.id == 1 { throw BookSourceError.pageLoadFailed(entry.name) }
                return try ImageDecoding.decode(TestFixtures.pngData(width: 70, height: 100))
            }
        }
        let book = try await Book.open(source: BrokenStub())
        book.readMode = .rightToLeftSpread
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])              // 壊れページとはペアにしない
        book.goTo(index: 1)
        let broken = await book.currentSpread()
        XCTAssertEqual(broken.indices, [1])
        XCTAssertNil(broken.images[0])                   // UI 側でプレースホルダ表示
    }
}

/// cacheKey: エントリ一覧ダイジェスト(フォルダの本の古いサムネイル防止)
@MainActor
final class BookCacheKeyTests: XCTestCase {
    private func makeFolderBook(at root: URL, sortMode: SortMode = .name)
        async throws -> Book {
        let source = try FolderSource(url: root, readSubFolders: true)
        return try await Book.open(source: source, sortMode: sortMode)
    }

    func testCacheKeyIgnoresSortOrder() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.png", "b.png", "c.png"] {
            try TestFixtures.pngData(width: 10, height: 10)
                .write(to: root.appendingPathComponent(name))
        }
        let byName = try await makeFolderBook(at: root, sortMode: .name)
        let shuffled = try await makeFolderBook(at: root, sortMode: .shuffle)
        XCTAssertEqual(byName.cacheKey, shuffled.cacheKey,
                       "並び順が違っても同じ本なら同じキー")
    }

    func testCacheKeyChangesWhenSubfolderFileChanges() async throws {
        // 親フォルダの更新日時が動かない「サブフォルダ内だけの変更」でも
        // キーが変わること(旧実装の弱点の回帰テスト)
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("page.png")
        try TestFixtures.pngData(width: 10, height: 10).write(to: file)

        let before = try await makeFolderBook(at: root).cacheKey
        // 親フォルダの mtime を固定したままサブフォルダ内のファイルだけ更新する
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: file.path)
        try FileManager.default.setAttributes(
            [.modificationDate: parentAttributes[.modificationDate]!],
            ofItemAtPath: root.path)
        let after = try await makeFolderBook(at: root).cacheKey
        XCTAssertNotEqual(before, after, "サブフォルダ内の変更でキーが変わること")
    }
}
