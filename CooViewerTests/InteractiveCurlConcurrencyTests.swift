import AppKit
import XCTest
@testable import cooViewer

@MainActor
final class InteractiveCurlConcurrencyTests: XCTestCase {
    func testCancelDuringDecodeRestoresPositionBeforeNextInput() async throws {
        let source = CurlBookSource(pausingImage: 1)
        let book = try await makeBook(source)
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: true, progress: 0.1)
        let preparation = try XCTUnwrap(controller.interactiveCurlSession?.task)
        await fulfillment(of: [source.paused], timeout: 2)
        XCTAssertEqual(book.currentIndex, 1)

        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 0))
        XCTAssertEqual(book.currentIndex, 0, "取消は次の入力より前に元の位置へ戻す")
        book.goTo(index: 4)
        await source.resume()
        await preparation.value
        XCTAssertEqual(book.currentIndex, 4)
        XCTAssertNil(controller.interactiveCurlPhase)
    }

    func testOldBookDecodeCannotFinishNewBooksGesture() async throws {
        let source = CurlBookSource(pausingImage: 1)
        let book = try await makeBook(source)
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: true, progress: 0.1)
        let oldPreparation = try XCTUnwrap(controller.interactiveCurlSession?.task)
        await fulfillment(of: [source.paused], timeout: 2)

        let nextSource = CurlBookSource(pausingImage: 1)
        let nextBook = try await makeBook(nextSource)
        controller.replaceBook(nextBook)
        controller.beginInteractiveCurl(forward: true, progress: 0.2)
        let newPreparation = try XCTUnwrap(controller.interactiveCurlSession?.task)
        await fulfillment(of: [nextSource.paused], timeout: 2)
        await source.resume()
        await oldPreparation.value
        if case .starting = controller.interactiveCurlPhase {} else {
            XCTFail("旧本の準備完了が新本の starting を上書きした")
        }
        XCTAssertEqual(controller.interactiveCurlProgress, 0.2)
        await nextSource.resume()
        await newPreparation.value
        _ = controller.settleInteractiveCurlOnGestureEnd(finalDelta: 100)
    }

    func testActiveCancellationIsSynchronous() async throws {
        let book = try await makeBook(CurlBookSource())
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        let view = controller.readerViewForInput
        view.frame = NSRect(x: 0, y: 0, width: 160, height: 120)
        let image = await book.image(at: 0)
        view.setPages([try XCTUnwrap(image)], readsFromLeft: false)
        controller.beginInteractiveCurl(forward: true, progress: 0.1)
        await controller.interactiveCurlSession?.task?.value
        XCTAssertTrue(view.hasInteractiveCurl)
        XCTAssertEqual(book.currentIndex, 1)

        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 0))
        XCTAssertEqual(book.currentIndex, 0, "アニメーション終了や別 Task を待たない")
        book.goTo(index: 4)
        // 同じ MainActor 上で旧取消 Task が走り終わるまでイベントを進める。
        await Task.yield()
        XCTAssertEqual(book.currentIndex, 4, "取消後のジャンプに逆移動を適用しない")
        view.removeCurlOverlay()
    }

    private func makeBook(_ source: CurlBookSource) async throws -> Book {
        let book = try await Book.open(source: source)
        book.readMode = .rightToLeftSingle
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        return book
    }

    func testCancellationDoesNotUndoJumpBackToSamePageNumber() async throws {
        let book = try await makeBook(CurlBookSource())
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: true, progress: 0.1)
        await controller.interactiveCurlSession?.task?.value
        book.goTo(index: 4)
        book.goTo(index: 1)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 0))
        XCTAssertEqual(book.currentIndex, 1, "同じ番号でも後発のジャンプは別操作")
    }

    func testCancellationRestoresSpreadWidthForImmediateNextInput() async throws {
        let book = try await makeBook(CurlBookSource(wideImage: 2))
        book.readMode = .rightToLeftSpread
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0, 1])
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: true, progress: 0.1)
        await controller.interactiveCurlSession?.task?.value
        XCTAssertEqual(book.currentIndex, 2)
        XCTAssertEqual(book.displayedPageCount, 1)

        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 0))
        XCTAssertEqual(book.currentIndex, 0)
        XCTAssertEqual(book.displayedPageCount, 2)
        XCTAssertEqual(book.moveNext(), .moved)
        XCTAssertEqual(book.currentIndex, 2, "単ページだった取消先の送り幅を残さない")
    }

    func testCommittedBackwardGesturesBothApplyWhileHeaderIsPending() async throws {
        let source = CurlBookSource(pausingSize: 2)
        let book = try await makeBook(source)
        book.readMode = .rightToLeftSpread
        book.goTo(index: 4)
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: false, progress: 0.5)
        let first = try XCTUnwrap(controller.interactiveCurlSession?.task)
        await fulfillment(of: [source.paused], timeout: 2)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 100))
        controller.beginInteractiveCurl(forward: false, progress: 0.5)
        let second = try XCTUnwrap(controller.interactiveCurlSession?.task)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 100))

        await source.resume()
        await first.value
        await second.value
        XCTAssertEqual(book.currentIndex, 0, "4→2→0 と二回とも移動する")
        XCTAssertNil(controller.interactiveCurlPhase)
    }

    func testCancellingQueuedGestureKeepsEarlierCommittedBackwardMove() async throws {
        let source = CurlBookSource(pausingSize: 2)
        let book = try await makeBook(source)
        book.readMode = .rightToLeftSpread
        book.goTo(index: 4)
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: false, progress: 0.5)
        let first = try XCTUnwrap(controller.interactiveCurlSession?.task)
        await fulfillment(of: [source.paused], timeout: 2)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 100))
        controller.beginInteractiveCurl(forward: false, progress: 0.1)
        let second = try XCTUnwrap(controller.interactiveCurlSession?.task)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 0))

        await source.resume()
        await first.value
        await second.value
        XCTAssertEqual(book.currentIndex, 2, "後の取消は先の確定操作へ遡らない")
        XCTAssertNil(controller.interactiveCurlPhase)
    }

    func testCommittedForwardGesturesUseDestinationSpreadWidth() async throws {
        let source = CurlBookSource(pausingImage: 2, wideImage: 2)
        let book = try await makeBook(source)
        book.readMode = .rightToLeftSpread
        _ = await book.currentSpread()
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: true, progress: 0.5)
        let first = try XCTUnwrap(controller.interactiveCurlSession?.task)
        await fulfillment(of: [source.paused], timeout: 2)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 100))
        controller.beginInteractiveCurl(forward: true, progress: 0.5)
        let second = try XCTUnwrap(controller.interactiveCurlSession?.task)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 100))

        await source.resume()
        await first.value
        await second.value
        XCTAssertEqual(book.currentIndex, 3, "見開き0-1→単ページ2→3-4と進む")
        XCTAssertNil(controller.interactiveCurlPhase)
    }

    func testBookReplacementCancelsBackwardPreparation() async throws {
        let source = CurlBookSource(pausingSize: 2)
        let book = try await makeBook(source)
        book.readMode = .rightToLeftSpread
        book.goTo(index: 4)
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: false, progress: 0.5)
        let preparation = try XCTUnwrap(controller.interactiveCurlSession?.task)
        await fulfillment(of: [source.paused], timeout: 2)

        let nextBook = try await makeBook(CurlBookSource())
        controller.mouseCurlTracking = true
        controller.swipeTrackingActive = true
        controller.replaceBook(nextBook)
        await source.resume()
        await preparation.value
        XCTAssertEqual(book.currentIndex, 4)
        XCTAssertEqual(nextBook.currentIndex, 0)
        XCTAssertNil(controller.interactiveCurlPhase)
        XCTAssertFalse(controller.mouseCurlTracking)
        XCTAssertFalse(controller.swipeTrackingActive)
    }

    func testCancellingQueuedGestureStillDisplaysEarlierCommittedPage() async throws {
        let source = CurlBookSource(pausingImage: 1)
        let book = try await makeBook(source)
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        await controller.refreshDisplay()
        XCTAssertEqual(controller.lastSpreadIndices, [0])
        controller.beginInteractiveCurl(forward: true, progress: 0.5)
        let first = try XCTUnwrap(controller.interactiveCurlSession?.task)
        await fulfillment(of: [source.paused], timeout: 2)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 100))
        controller.beginInteractiveCurl(forward: true, progress: 0.1)
        let second = try XCTUnwrap(controller.interactiveCurlSession?.task)
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 0))

        await source.resume()
        await first.value
        await second.value
        XCTAssertEqual(book.currentIndex, 1)
        XCTAssertEqual(controller.lastSpreadIndices, [1], "確定済みの位置と画面を一致させる")
    }

    func testSystemCancellationIgnoresCompletionThreshold() async throws {
        let book = try await makeBook(CurlBookSource())
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: true, progress: 0.9)
        await controller.interactiveCurlSession?.task?.value
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 300, cancelled: true))
        XCTAssertEqual(book.currentIndex, 0)
    }

    func testResetWithoutReplacementRedrawsOriginalPage() async throws {
        let book = try await makeBook(CurlBookSource())
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        await controller.refreshDisplay()
        controller.beginInteractiveCurl(forward: true, progress: 0.1)
        await controller.interactiveCurlSession?.task?.value
        XCTAssertEqual(controller.lastSpreadIndices, [1])

        let redraw = controller.resetInteractiveCurl()
        XCTAssertEqual(book.currentIndex, 0)
        await redraw?.value
        XCTAssertEqual(controller.lastSpreadIndices, [0])
    }

    func testJumpBeforePreparationTaskStartsSupersedesGesture() async throws {
        let book = try await makeBook(CurlBookSource())
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        controller.beginInteractiveCurl(forward: true, progress: 0.5)
        book.goTo(index: 3)
        await controller.interactiveCurlSession?.task?.value
        XCTAssertTrue(controller.settleInteractiveCurlOnGestureEnd(finalDelta: 100))
        XCTAssertEqual(book.currentIndex, 3)
        XCTAssertNil(controller.interactiveCurlPhase)
    }
}

private actor CurlBookSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/curl-book")
    nonisolated var supportsDateSort: Bool { false }
    nonisolated let paused = XCTestExpectation(description: "カール用画像の読み込み待機")
    private let pausingImage: Int?
    private let pausingSize: Int?
    private let wideImage: Int?
    private var didPause = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(pausingImage: Int? = nil, pausingSize: Int? = nil, wideImage: Int? = nil) {
        self.pausingImage = pausingImage
        self.pausingSize = pausingSize
        self.wideImage = wideImage
    }

    func entries() async throws -> [PageEntry] {
        (0..<5).map {
            PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func imageSize(for entry: PageEntry) async -> CGSize? {
        if entry.id == pausingSize { await pauseOnce() }
        return CGSize(width: entry.id == wideImage ? 100 : 20, height: 40)
    }

    private func pauseOnce() async {
        guard !didPause else { return }
        didPause = true
        await withCheckedContinuation {
            continuation = $0
            paused.fulfill()
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        if entry.id == pausingImage { await pauseOnce() }
        let context = CGContext(data: nil, width: entry.id == wideImage ? 100 : 20, height: 40,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
