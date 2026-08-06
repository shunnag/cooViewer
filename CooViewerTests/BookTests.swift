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
            TestFixtures.pngData(width: Int(size.width), height: Int(size.height)))
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
