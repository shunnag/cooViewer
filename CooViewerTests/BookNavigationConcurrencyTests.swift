import CoreGraphics
import XCTest
@testable import cooViewer

/// ヘッダ/画像取得を止め、その間のジャンプが旧処理で巻き戻らないことを確認する。
@MainActor
final class BookNavigationConcurrencyTests: XCTestCase {
    func testPreviousDoesNotUndoJumpToFirstWhileReadingHeader() async throws {
        let source = PausingBookSource(pause: .size(2))
        let book = try await Book.open(source: source)
        book.goTo(index: 4)
        let previous = Task { await book.movePrevious() }
        await fulfillment(of: [source.paused], timeout: 2)

        book.goToFirst()
        await source.resume()
        let result = await previous.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(book.currentIndex, 0, "古い戻り判定が新しい位置から減算しない")
    }

    func testLastPageDoesNotUndoLaterJump() async throws {
        let source = PausingBookSource(pause: .size(3))
        let book = try await Book.open(source: source)
        let last = Task { await book.goToLast() }
        await fulfillment(of: [source.paused], timeout: 2)

        book.goTo(index: 1)
        await source.resume()
        let applied = await last.value
        XCTAssertFalse(applied)
        XCTAssertEqual(book.currentIndex, 1)
    }

    func testReanchorDoesNotMoveLaterJump() async throws {
        let source = PausingBookSource(pause: .size(0))
        let book = try await Book.open(source: source)
        book.goTo(index: 3)
        let reanchor = Task { await book.reanchorToLeadingPartition() }
        await fulfillment(of: [source.paused], timeout: 2)

        book.goTo(index: 1)
        await source.resume()
        let applied = await reanchor.value
        XCTAssertFalse(applied)
        XCTAssertEqual(book.currentIndex, 1)
    }

    func testSpreadDoesNotLabelOldImageWithNewPageIndex() async throws {
        let source = PausingBookSource(pause: .image(0))
        let book = try await Book.open(source: source)
        book.readMode = .rightToLeftSingle
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        let oldDisplay = Task { await book.currentSpread() }
        await fulfillment(of: [source.paused], timeout: 2)

        book.goTo(index: 2)
        let current = await book.currentSpread()
        await source.resume()
        let completed = await oldDisplay.value
        XCTAssertEqual(current.indices, [2])
        XCTAssertEqual(completed.indices, [2])
        XCTAssertEqual(completed.images.compactMap { $0?.width }, [12],
                       "現在の位置へ再計算し、ページ2の幅を返す")
    }

    func testOverlappingPreviousRequestsBothAdvanceBackward() async throws {
        let source = PausingBookSource(pause: .size(2))
        let book = try await Book.open(source: source)
        book.goTo(index: 4)
        let first = Task { await book.movePrevious() }
        await fulfillment(of: [source.paused], timeout: 2)

        let second = await book.movePrevious()
        XCTAssertEqual(second, .moved)
        XCTAssertEqual(book.currentIndex, 2)
        await source.resume()
        let result = await first.value
        XCTAssertEqual(result, .moved)
        XCTAssertEqual(book.currentIndex, 0, "同じ方向への二回の操作は二回とも反映する")
    }

    func testOldPairDoesNotChangeNewSinglePageTurnWidth() async throws {
        let source = PausingBookSource(pause: .image(0))
        let book = try await Book.open(source: source)
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        let oldDisplay = Task { await book.currentSpread() }
        await fulfillment(of: [source.paused], timeout: 2)

        book.goTo(index: 4)
        let current = await book.currentSpread()
        XCTAssertEqual(current.indices, [4])
        await source.resume()
        let completed = await oldDisplay.value
        XCTAssertEqual(completed.indices, [4])
        XCTAssertEqual(completed.images.compactMap { $0?.width }, [14])
        XCTAssertEqual(book.displayedPageCount, 1)
    }

    func testSpreadRechecksLayoutChangedDuringImageLoad() async throws {
        let source = PausingBookSource(pause: .image(0))
        let book = try await Book.open(source: source)
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        let display = Task { await book.currentSpread() }
        await fulfillment(of: [source.paused], timeout: 2)

        book.readMode = .rightToLeftSingle
        await source.resume()
        let completed = await display.value
        XCTAssertEqual(completed.indices, [0])
        XCTAssertEqual(book.displayedPageCount, 1)
    }

    func testSpreadRechecksSortChangedDuringImageLoad() async throws {
        let source = PausingBookSource(pause: .image(0))
        let book = try await Book.open(source: source)
        book.readMode = .rightToLeftSingle
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        let display = Task { await book.currentSpread() }
        await fulfillment(of: [source.paused], timeout: 2)

        book.setSortMode(.creationDate)
        await source.resume()
        let completed = await display.value
        XCTAssertEqual(completed.indices, [0])
        XCTAssertEqual(book.entries[0].id, 4)
        XCTAssertEqual(completed.images.compactMap { $0?.width }, [14])
    }
}

private actor PausingBookSource: BookSource {
    enum Pause: Equatable, Sendable {
        case size(Int)
        case image(Int)
    }

    nonisolated let url = URL(fileURLWithPath: "/stub/navigation-book")
    nonisolated var supportsDateSort: Bool { false }
    nonisolated let paused = XCTestExpectation(description: "ページ取得の待機点へ到達")
    private let pause: Pause
    private var didPause = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(pause: Pause) { self.pause = pause }

    func entries() async throws -> [PageEntry] {
        (0..<5).map {
            PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                      fileURL: nil, creationDate: Date(timeIntervalSince1970: Double(4 - $0)),
                      modificationDate: nil)
        }
    }

    private func waitIfNeeded(_ point: Pause) async {
        guard point == pause, !didPause else { return }
        didPause = true
        await withCheckedContinuation {
            continuation = $0
            paused.fulfill()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func imageSize(for entry: PageEntry) async -> CGSize? {
        await waitIfNeeded(.size(entry.id))
        return CGSize(width: 10 + entry.id, height: 30)
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        await waitIfNeeded(.image(entry.id))
        let context = CGContext(data: nil, width: 10 + entry.id, height: 30,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
