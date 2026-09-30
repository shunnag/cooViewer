import CoreGraphics
import Washi
import XCTest

@testable import cooViewer

/// 合本の構築要求と失敗マーカーは、個別 EPUB の寿命をまたいで保持する。
@MainActor
final class CollectionReadingStateTests: XCTestCase {
    private let key = CollectionPageMapState.Key(folderPath: "/collection", metricsKey: "A")

    func testSameBuildCoalescesButReorderingSupersedesIt() throws {
        let state = CollectionPageMapState()
        let entries = [entry(0), entry(1)]
        let first = try XCTUnwrap(state.begin(key: key, entries: entries))
        let task = Task<Void, Never> { await Task.yield() }
        first.task = task
        XCTAssertNil(state.begin(key: key, entries: entries))

        let reordered = Array(entries.reversed())
        let next = try XCTUnwrap(state.begin(key: key, entries: reordered))

        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(state.publish(map(entries), for: first))
        state.abandon(first)
        XCTAssertTrue(state.owns(next))
        XCTAssertTrue(state.publish(map(reordered), for: next))
        XCTAssertEqual(state.current?.entries, reordered)
    }

    func testOldCompletionCannotPublishAfterSameKeyRestart() throws {
        let state = CollectionPageMapState()
        let entries = [entry(0)]
        let first = try XCTUnwrap(state.begin(key: key, entries: entries))
        state.cancel()
        let next = try XCTUnwrap(state.begin(key: key, entries: entries))

        XCTAssertFalse(state.publish(map(entries), for: first))
        state.abandon(first)
        XCTAssertTrue(state.owns(next))
        XCTAssertTrue(state.publish(map(entries, counts: [0: [5]]), for: next))
        XCTAssertEqual(state.current?.total, 5)
    }

    func testRetryBudgetCountsOnlyPublishedPartialMapsForSameEntries() throws {
        let state = CollectionPageMapState()
        let entries = [entry(0)]
        for expected in 1...CollectionPageMapState.maximumAttempts {
            let request = try XCTUnwrap(state.begin(key: key, entries: entries))
            XCTAssertTrue(state.publish(map(entries), for: request))
            XCTAssertEqual(state.attemptCount(for: key, entries: entries), expected)
        }
        let abandoned = try XCTUnwrap(state.begin(key: key, entries: entries))
        state.abandon(abandoned)
        XCTAssertEqual(state.attemptCount(for: key, entries: entries), 3)

        let changed = [entry(1)]
        XCTAssertEqual(state.attemptCount(for: key, entries: changed), 0)
        let request = try XCTUnwrap(state.begin(key: key, entries: changed))
        XCTAssertTrue(state.publish(map(changed), for: request))
        XCTAssertEqual(state.attemptCount(for: key, entries: changed), 1)
        let complete = try XCTUnwrap(state.begin(key: key, entries: changed))
        XCTAssertTrue(state.publish(map(changed, counts: [0: [2]]), for: complete))
        XCTAssertEqual(state.attemptCount(for: key, entries: changed), 0)
    }

    func testCloseRetainsPublishedMapAndAllowsSameKeyRebuild() throws {
        let state = CollectionPageMapState()
        let entries = [entry(0)]
        let first = try XCTUnwrap(state.begin(key: key, entries: entries))
        XCTAssertTrue(state.publish(map(entries), for: first))
        let pending = try XCTUnwrap(state.begin(key: key, entries: entries))

        state.cancel(resetAttempts: true)

        XCTAssertNil(state.request)
        XCTAssertEqual(state.current?.entries, entries)
        XCTAssertEqual(state.attemptCount(for: key, entries: entries), 0)
        XCTAssertFalse(state.publish(map(entries), for: pending))
        XCTAssertNotNil(state.begin(key: key, entries: entries))
    }

    func testTransientFailuresSurviveArrivalConsumptionAndOnlySkipOneLanding() {
        let state = CollectionNavigationState()
        let first = URL(fileURLWithPath: "/collection/first.epub")
        let second = URL(fileURLWithPath: "/collection/second.epub")
        state.recordTransientFailure(for: first)
        state.recordTransientFailure(for: second)
        state.arrivalForward = false
        state.arrivalAtFirst = true

        let arrival = state.takeArrival()

        XCTAssertEqual(arrival.forward, false)
        XCTAssertTrue(arrival.atFirst)
        XCTAssertNil(state.arrivalForward)
        XCTAssertFalse(state.arrivalAtFirst)
        XCTAssertTrue(state.consumeTransientFailure(for: first))
        XCTAssertFalse(state.consumeTransientFailure(for: first))
        XCTAssertTrue(state.consumeTransientFailure(for: second))
        XCTAssertFalse(state.hasPermanentFailure(for: first))
    }

    func testPermanentFailureRegistrationOnlyAnnouncesFirstTime() {
        let state = CollectionNavigationState()
        let url = URL(fileURLWithPath: "/collection/drm.epub")
        XCTAssertTrue(state.recordPermanentFailure(for: url))
        XCTAssertFalse(state.recordPermanentFailure(for: url))
        _ = state.takeArrival()
        XCTAssertFalse(state.consumeTransientFailure(for: url))
        XCTAssertTrue(state.hasPermanentFailure(for: url))
    }

    func testLateFailedEntryCannotUndoLaterCollectionLanding() async throws {
        let source = PausedCollectionSource()
        let book = try await Book.open(source: source)
        book.readMode = .leftToRightSingle
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        defer { book.cancelPrefetch() }
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        let locator = EPUBLocator(spineIndex: 0, progression: 0)
        let first = try XCTUnwrap(controller.enterCollectionReflowEPUB(
            url: source.firstURL, entryIndex: 0, forward: true, at: locator))
        await fulfillment(of: [source.paused], timeout: 2)
        let next = try XCTUnwrap(controller.enterCollectionReflowEPUB(
            url: source.secondURL, entryIndex: 1, forward: true, at: locator))
        await next.value
        XCTAssertEqual(book.currentIndex, 1)

        await source.resume()
        await first.value

        XCTAssertEqual(book.currentIndex, 1, "古い解析失敗の表紙降格で最新着地を戻さない")
        XCTAssertFalse(controller.collectionNavigation.consumeTransientFailure(for: source.firstURL))
    }

    private func entry(_ index: Int) -> PageEntry {
        PageEntry(id: index, name: "book\(index).epub", pathInBook: "book\(index).epub",
                  fileURL: nil, creationDate: nil, modificationDate: nil,
                  reflowEPUBURL: URL(fileURLWithPath: "/collection/book\(index).epub"))
    }

    private func map(_ entries: [PageEntry], counts: [Int: [Int]] = [:]) -> CollectionPageMap {
        CollectionPageMap.make(folderPath: key.folderPath, metricsKey: key.metricsKey,
                               entries: entries, counts: counts)
    }
}

private actor PausedCollectionSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/collection")
    nonisolated let firstURL = URL(fileURLWithPath: "/stub/collection/first.epub")
    nonisolated let secondURL = URL(fileURLWithPath: "/stub/collection/second.epub")
    nonisolated let paused = XCTestExpectation(description: "最初の巻の準備を停止")
    nonisolated var supportsDateSort: Bool { false }
    private var continuation: CheckedContinuation<Void, Never>?

    func entries() async throws -> [PageEntry] {
        [firstURL, secondURL].enumerated().map { index, url in
            PageEntry(id: index, name: url.lastPathComponent, pathInBook: url.lastPathComponent,
                      fileURL: nil, creationDate: nil, modificationDate: nil, reflowEPUBURL: url)
        }
    }

    func preparsedReflowPublication(for url: URL) async -> EPUBPublication? {
        if url == firstURL {
            await withCheckedContinuation {
                continuation = $0
                paused.fulfill()
            }
        }
        return nil
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try ImageDecoding.decode(TestFixtures.pngData(width: 70, height: 100),
                                 maxPixelSize: maxPixelSize)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
