import CoreGraphics
import os
import XCTest
@testable import cooViewer

/// 読み込みの完了順を制御し、待機中の設定変更と競合させる(設計書 §7.3)。
@MainActor
final class BookConcurrencyTests: XCTestCase {
    /// 設計書 §5: 他の本の先読みが二枠を占めても、合流した表示は FIFO を迂回する。
    func testDisplayPromotesQueuedPrefetchWithoutReleasingOtherBooksDecodes() async throws {
        let gate = SourceReadGate(limit: 2)
        let started = expectation(description: "先読み二件が処理本体へ入った")
        started.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        var released = false
        defer { if !released { release.signal(); release.signal() } }
        let image = try ImageDecoding.decode(TestFixtures.pngData(width: 16, height: 24))
        let blocking = GatedPrefetchSource(gate: gate, image: image, pageCount: 2,
            release: release, started: started)
        let otherBook = try await Book.open(source: blocking)
        let first = Task { await PageRequestIntent.$isPrefetch.withValue(true) { await otherBook.image(at: 0) } }
        let second = Task { await PageRequestIntent.$isPrefetch.withValue(true) { await otherBook.image(at: 1) } }
        await fulfillment(of: [started], timeout: 3)

        let source = GatedPrefetchSource(gate: gate, image: image)
        let book = try await Book.open(source: source)
        let prefetch = Task { await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 0) } }
        let queued = await waitForQueuedDecode(gate)
        XCTAssertTrue(queued)
        let completed = expectation(description: "表示は先読み二件の解放前に完了する")
        let display = Task {
            let result = await book.image(at: 0)
            completed.fulfill()
            return result
        }
        await fulfillment(of: [completed], timeout: 3)
        let during = await gate.debugCounts()
        XCTAssertEqual(during.active, 2)
        XCTAssertEqual(during.queued, 0)
        XCTAssertEqual(source.decodeCount, 1)
        XCTAssertEqual(source.decodePriorities, [.userInitiated])
        release.signal(); release.signal(); released = true
        let result = await display.value
        let prefetched = await prefetch.value
        XCTAssertTrue(result === image)
        XCTAssertTrue(prefetched === result)
        _ = await (first.value, second.value)
        let final = await gate.debugCounts()
        XCTAssertEqual(final.active, 0)
    }

    /// 設計書 §5: ジャンプ後の detached 先読みは待機中なら辞退し、次の表示へ失敗印を残さない。
    func testCancelPrefetchDropsQueuedDecodeAndAllowsDisplayRetry() async throws {
        let gate = SourceReadGate(limit: 2)
        let first = await gate.acquire(interactive: false)
        let second = await gate.acquire(interactive: false)
        XCTAssertTrue(first); XCTAssertTrue(second)
        let image = try ImageDecoding.decode(TestFixtures.pngData(width: 16, height: 24))
        let source = GatedPrefetchSource(gate: gate, image: image)
        let book = try await Book.open(source: source)
        let completed = expectation(description: "待機先読みの辞退")
        let prefetch = Task {
            let result = await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 0) }
            completed.fulfill()
            return result
        }
        let queued = await waitForQueuedDecode(gate)
        XCTAssertTrue(queued)
        book.cancelPrefetch()
        await fulfillment(of: [completed], timeout: 3)
        let during = await gate.debugCounts()
        XCTAssertEqual(during.queued, 0)
        XCTAssertEqual(source.decodeCount, 0)
        XCTAssertEqual(book.pageCacheStats().count, 0)
        await gate.release(); await gate.release()
        let discarded = await prefetch.value
        XCTAssertNil(discarded)
        let displayed = await book.image(at: 0)
        XCTAssertTrue(displayed === image)
        XCTAssertEqual(source.decodeCount, 1)
    }

    /// 設計書 §5、§7.3: 表示合流は CPU 優先度だけでなく、待機中の読み取りの順も引き上げる。
    func testDisplayJoinPromotesAlreadyQueuedSourceRead() async throws {
        let gate = SourceReadGate(limit: 1)
        let occupied = await gate.acquire(interactive: false)
        XCTAssertTrue(occupied)
        let order = ReadOrder()
        let background = Task(priority: .utility) {
            guard await gate.acquire() else { return }
            await order.note("background")
            await gate.release()
        }
        while await gate.debugCounts().queued < 1 { await Task.yield() }
        let source = OrderedReadSource(gate: gate, order: order,
            image: try ImageDecoding.decode(TestFixtures.pngData(width: 40, height: 60)))
        let book = try await Book.open(source: source)
        let prefetch = Task(priority: .utility) {
            await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 0) }
        }
        while await gate.debugCounts().queued < 2 { await Task.yield() }
        let handle = await source.promotion
        let promotion = try XCTUnwrap(handle)
        let display = Task(priority: .userInitiated) { await book.image(at: 0) }
        while !promotion.isPromoted { await Task.yield() }
        let interactive = Task(priority: .userInitiated) {
            guard await gate.acquire() else { return }
            await order.note("interactive")
            await gate.release()
        }
        while await gate.debugCounts().queued < 3 { await Task.yield() }
        await gate.release()
        _ = await (prefetch.value, display.value, background.value, interactive.value)
        let values = await order.values
        XCTAssertEqual(values, ["display", "interactive", "background"])
        let count = await source.requestCount
        XCTAssertEqual(count, 1)
        await book.close().value
    }

    /// 設計書 §5: 未準備の solid 書庫相当では、二枚目を一枚目の完了後に表示として取得する。
    func testUnknownSpreadPreservesSerialSourceOrdering() async throws {
        let source = ControlledPageSource(pageSizes: [.init(width: 40, height: 60), .init(width: 40, height: 60)], parallel: false)
        let book = try await Book.open(source: source)
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        _ = book.updateDisplayPixelCap(60)
        let display = Task { await book.currentSpread() }
        let first = await source.nextRequest()
        let windows = await source.parallelWindows
        XCTAssertEqual(windows, [[0, 1]])
        XCTAssertEqual(first.entryID, 0)
        await source.finish(first)
        let second = await source.nextRequest()
        XCTAssertEqual(second.entryID, 1)
        XCTAssertFalse(second.prefetch)
        XCTAssertTrue(second.display)
        await source.finish(second)
        let result = await display.value
        XCTAssertEqual(result.indices, [0, 1])
        let peak = await source.peakPendingRequests
        XCTAssertEqual(peak, 1)
        await book.close().value
    }

    /// 設計書 §5、§7.3: 寸法不明の二枚を先に登録し、表示は同じ単一飛行へ合流する。
    func testUnknownSpreadStartsBothPagesBeforeEitherCompletes() async throws {
        let started = expectation(description: "寸法不明の二枚へ同時着手")
        started.expectedFulfillmentCount = 2
        let source = ControlledPageSource(pageSizes: [.init(width: 40, height: 60), .init(width: 40, height: 60)], started: started)
        let book = try await Book.open(source: source)
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        _ = book.updateDisplayPixelCap(60)
        defer { book.close() }
        let display = Task(priority: .userInitiated) { await book.currentSpread() }
        await fulfillment(of: [started], timeout: 3)
        guard await source.requestCount == 2 else { return }
        let requests = [await source.nextRequest(), await source.nextRequest()]
        let first = try XCTUnwrap(requests.first { $0.entryID == 0 })
        let second = try XCTUnwrap(requests.first { $0.entryID == 1 })
        XCTAssertTrue(first.display)
        XCTAssertTrue(second.prefetch)
        XCTAssertFalse(second.display)
        XCTAssertEqual(second.priority, .utility)
        await source.finish(second)
        await source.finish(first)
        let spread = await display.value
        XCTAssertEqual(spread.indices, [0, 1])
        XCTAssertEqual(spread.images.compactMap { $0?.height }, [60, 60])
        let count = await source.requestCount
        XCTAssertEqual(count, 2)
    }

    /// 設計書 §5: 予測が外れた二枚目は表示へ昇格せず、通常の先読み結果として再利用する。
    func testUnpairedPredictionRemainsUtilityPrefetch() async throws {
        let started = expectation(description: "横長の先頭と予測した隣ページ")
        started.expectedFulfillmentCount = 2
        let source = ControlledPageSource(pageSizes: [.init(width: 80, height: 40), .init(width: 40, height: 60)], started: started)
        let book = try await Book.open(source: source)
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        _ = book.updateDisplayPixelCap(60)
        defer { book.close() }
        let display = Task { await book.currentSpread() }
        await fulfillment(of: [started], timeout: 3)
        guard await source.requestCount == 2 else { return }
        let requests = [await source.nextRequest(), await source.nextRequest()]
        for request in requests where request.entryID == 1 { await source.finish(request) }
        // 二枚目の公開まで待つが、表示優先度を継承させない(設計書 §5)。
        let prefetched = expectation(description: "先読み完了")
        Task(priority: .utility) { await book.waitForPrefetch(); prefetched.fulfill() }
        for request in requests where request.entryID == 0 { await source.finish(request) }
        await fulfillment(of: [prefetched], timeout: 3)
        let spread = await display.value
        XCTAssertEqual(spread.indices, [0])
        let priority = await source.decodePriority(for: 1)
        XCTAssertEqual(priority, .utility)
        let cached = await book.image(at: 1)
        XCTAssertNotNil(cached)
        let count = await source.requestCount
        XCTAssertEqual(count, 2)
    }

    /// 設計書 §5: 復号後の横長・壊れページは従来の単ページ判定を守る。
    func testUnknownSpreadRejectsWideOrBrokenSecondPage() async throws {
        for broken in [false, true] {
            let source = ControlledPageSource(pageSizes: [.init(width: 40, height: 60), .init(width: 80, height: 40)])
            let book = try await Book.open(source: source)
            book.prefetchAhead = 0
            book.prefetchBehind = 0
            _ = book.updateDisplayPixelCap(60)
            let display = Task { await book.currentSpread() }
            let requests = [await source.nextRequest(), await source.nextRequest()]
            let first = try XCTUnwrap(requests.first { $0.entryID == 0 })
            let second = try XCTUnwrap(requests.first { $0.entryID == 1 })
            await source.finish(first)
            // 表示合流を確認してから失敗を返し、完了済み先読みへの別の表示要求と混同しない(設計書 §5、§7.3)。
            let promotion = try XCTUnwrap(second.promotion)
            while !promotion.isPromoted { await Task.yield() }
            if broken { await source.fail(second) }
            else { await source.finish(second) }
            let spread = await display.value
            XCTAssertEqual(spread.indices, [0])
            await book.close().value
        }
    }

    /// 設計書 §5: 先読みは低優先度で復号し、実行中の合流でも表示の優先度へ昇格する。
    func testRunningPrefetchEscalatesToDisplayPriority() async throws {
        let escalated = expectation(description: "実行中タスクの優先度昇格")
        let source = ControlledPageSource(escalated: escalated)
        let book = try await Book.open(source: source)
        _ = book.updateDisplayPixelCap(60)
        let prefetch = Task(priority: .utility) {
            await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 0) }
        }
        let request = await source.nextRequest()
        XCTAssertEqual(request.priority, .utility)
        let display = Task(priority: .userInitiated) { await book.image(at: 0) }
        await fulfillment(of: [escalated], timeout: 3)
        await source.finish(request)
        let displayed = await display.value
        let prefetched = await prefetch.value
        XCTAssertTrue(displayed === prefetched)
        let priority = await source.decodePriority(for: 0)
        XCTAssertEqual(priority, .userInitiated)
        let count = await source.requestCount
        XCTAssertEqual(count, 1)
    }

    /// 設計書 §5: 表示が合流しない先読みは復号の葉まで utility のまま進む。
    func testUnpromotedDecodeRunsAtUtilityPriority() async throws {
        let source = ControlledPageSource()
        let book = try await Book.open(source: source)
        _ = book.updateDisplayPixelCap(60)
        let completed = expectation(description: "低優先度のまま復号完了")
        let prefetch = Task(priority: .utility) {
            _ = await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 0) }
            completed.fulfill()
        }
        let request = await source.nextRequest()
        await source.finish(request)
        await fulfillment(of: [completed], timeout: 3)
        let priority = await source.decodePriority(for: 0)
        XCTAssertEqual(priority, .utility)
        await prefetch.value
    }

    /// 設計書 §5、§7.3: 他冊がゲートを占有したままでも、閉じた本の待機と参照を解放する。
    func testCloseDrainsQueuedIOAndDecodeWithoutReleasingOtherReaders() async throws {
        for ioWait in [false, true] {
            let gate = SourceReadGate(limit: 1)
            let acquired = await gate.acquire(interactive: false)
            XCTAssertTrue(acquired)
            let requested = expectation(description: "先読み要求がソースへ到達")
            requested.expectedFulfillmentCount = 2
            let image = try ImageDecoding.decode(TestFixtures.pngData(width: 16, height: 24))
            var source: GatedPrefetchSource? = GatedPrefetchSource(gate: ioWait ? SourceReadGate(limit: 2) : gate,
                image: image, pageCount: 3, readGate: ioWait ? gate : nil, requested: requested)
            var book: Book? = try await Book.open(source: try XCTUnwrap(source))
            book?.prefetchAhead = 2
            book?.prefetchBehind = 0
            weak var previousBook = book
            weak var previousSource = source
            book?.reschedulePrefetch()
            await fulfillment(of: [requested], timeout: 3)
            let drain = try XCTUnwrap(book).close()
            book?.reschedulePrefetch()
            book = nil
            source = nil
            XCTAssertNil(previousBook)
            await drain.value
            XCTAssertNil(previousBook)
            XCTAssertNil(previousSource)
            let counts = await gate.debugCounts()
            XCTAssertEqual(counts.active, 1)
            XCTAssertEqual(counts.queued, 0)
            await gate.release()
        }
    }

    /// 設計書 §5、§7.3: 実行中の同期復号だけは完了を待つが、所有する本はその前に解放できる。
    func testCloseReleasesBookBeforeRunningDecodeFinishes() async throws {
        let started = expectation(description: "同期復号の開始")
        let release = DispatchSemaphore(value: 0)
        let image = try ImageDecoding.decode(TestFixtures.pngData(width: 16, height: 24))
        var source: GatedPrefetchSource? = GatedPrefetchSource(gate: SourceReadGate(limit: 2),
            image: image, pageCount: 2, release: release, started: started)
        var book: Book? = try await Book.open(source: try XCTUnwrap(source))
        book?.prefetchAhead = 1
        book?.prefetchBehind = 0
        weak var previousBook = book
        weak var previousSource = source
        book?.reschedulePrefetch()
        await fulfillment(of: [started], timeout: 3)
        let drain = try XCTUnwrap(book).close()
        book = nil
        source = nil
        XCTAssertNil(previousBook)
        XCTAssertNotNil(previousSource)
        release.signal()
        await drain.value
        XCTAssertNil(previousSource)
    }

    /// 設計書 §7.3: 並べ替えの独立計算は、待機中の本とソースを保持しない。
    func testPendingSortDoesNotRetainClosedBook() async throws {
        let started = expectation(description: "並べ替え計算の待機")
        let release = DispatchSemaphore(value: 0)
        let sorter = BlockingBookSorter(started: started, release: release)
        var source: ControlledPageSource? = ControlledPageSource()
        var book: Book? = Book(source: try XCTUnwrap(source), prepared: .empty(for: source!.url), sorter: sorter)
        weak var previousBook = book
        weak var previousSource = source
        let sorting = try XCTUnwrap(book).setSortMode(.creationDate)
        await fulfillment(of: [started], timeout: 3)
        book?.close()
        book = nil
        source = nil
        XCTAssertNil(previousBook)
        XCTAssertNil(previousSource)
        release.signal()
        let applied = await sorting.value
        XCTAssertFalse(applied)
    }

    /// 設計書 §5: 一枚 100ms の仮想時計を使い、実時間の待機なしに最初の見開きの遅延を見積もる。
    func testFirstSpreadLatencyEstimateWithArtificialPageDelay() async throws {
        var estimates: [Int] = []
        for parallel in [false, true] {
            let source = ControlledPageSource(pageSizes: [.init(width: 40, height: 60), .init(width: 40, height: 60)], parallel: parallel)
            let book = try await Book.open(source: source)
            book.prefetchAhead = 0
            book.prefetchBehind = 0
            _ = book.updateDisplayPixelCap(60)
            let display = Task { await book.currentSpread() }
            let first = await source.nextRequest()
            if parallel {
                let second = await source.nextRequest()
                await source.finish(first)
                await source.finish(second)
            } else {
                await source.finish(first)
                let second = await source.nextRequest()
                await source.finish(second)
            }
            let spread = await display.value
            XCTAssertEqual(spread.indices, [0, 1])
            let elapsed = await source.elapsedMilliseconds
            estimates.append(elapsed)
            await book.close().value
        }
        XCTAssertEqual(estimates, [200, 100])
        print("First spread estimate, 100ms/page: serial=200ms, concurrent=100ms")
    }

    private func waitForQueuedDecode(_ gate: SourceReadGate) async -> Bool {
        for _ in 0..<200 {
            if await gate.debugCounts().queued > 0 { return true }
            await Task.yield()
        }
        return false
    }

    /// 設計書 §5: 画面変更中に終わった旧デコードを、新画面のキャッシュへ入れない。
    func testDisplayProfileChangePropagatesAndRejectsObsoleteDecode() async throws {
        let source = ControlledPageSource()
        let book = try await Book.open(source: source)
        let srgb = DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.sRGB)!)
        let p3 = DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.displayP3)!)
        XCTAssertTrue(book.updateDisplayColorTarget(srgb))
        let oldLoad = Task { await book.image(at: 0) }
        let oldRequest = await source.nextRequest()
        XCTAssertEqual(oldRequest.colorTarget, srgb)

        XCTAssertTrue(book.updateDisplayColorTarget(p3))
        let newLoad = Task { await book.image(at: 0) }
        let newRequest = await source.nextRequest()
        XCTAssertEqual(newRequest.colorTarget, p3)
        await source.finish(newRequest)
        let current = await newLoad.value
        await source.finish(oldRequest)
        _ = await oldLoad.value

        let cached = await book.image(at: 0)
        XCTAssertTrue(cached === current)
        XCTAssertEqual(cached?.colorSpace, p3.rgb)
        XCTAssertFalse(book.updateDisplayColorTarget(p3))
        XCTAssertEqual(book.pageCacheStats().count, 1)
    }

    func testLoweringCapKeepsLargerDecodeAlreadyInProgress() async throws {
        let source = ControlledPageSource()
        let book = try await Book.open(source: source)
        _ = book.updateDisplayPixelCap(128)
        let load = Task { await book.image(at: 0) }
        let request = await source.nextRequest()

        _ = book.updateDisplayPixelCap(64)
        await source.finish(request)
        let large = await load.value
        XCTAssertEqual(large?.height, 128)
        XCTAssertEqual(book.pageCacheStats().count, 1,
                       "上限を下げた場合は進行中の大画像も捨てず、再デコードを避ける")
    }

    func testObsoleteDecodeCannotReplaceLargerCacheAfterCapRoundTrip() async throws {
        let source = ControlledPageSource()
        let book = try await Book.open(source: source)
        _ = book.updateDisplayPixelCap(64)
        let oldLoad = Task { await book.image(at: 0) }
        let oldRequest = await source.nextRequest()

        _ = book.updateDisplayPixelCap(128)
        let newLoad = Task { await book.image(at: 0) }
        let newRequest = await source.nextRequest()
        await source.finish(newRequest)
        let large = await newLoad.value
        XCTAssertEqual(large?.height, 128)

        // 上限を下げた後も、取得済みの大きな画像を維持する仕様。
        _ = book.updateDisplayPixelCap(64)
        await source.finish(oldRequest)
        let obsolete = await oldLoad.value
        XCTAssertEqual(obsolete?.height, 64)

        let cached = await book.image(at: 0)
        XCTAssertTrue(cached === large,
                      "上限の値が一周しても失効した旧読み込みを登録し直さない")
        XCTAssertEqual(cached?.height, 128)
    }
}

/// 画像要求を継続で止める。sleep に依存せず設定変更と完了の順を固定する。
private actor ControlledPageSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/controlled-book")
    nonisolated var supportsDateSort: Bool { false }
    nonisolated let supportsParallelPageLoads: Bool
    private(set) var parallelWindows: [[Int]] = []
    private(set) var peakPendingRequests = 0
    private(set) var elapsedMilliseconds = 0

    func currentlySupportsParallelPageLoads(forEntryIDs ids: [Int]) async -> Bool {
        parallelWindows.append(ids)
        return supportsParallelPageLoads
    }

    struct Request: Sendable {
        let id: Int
        let entryID: Int
        let cap: Int?
        let colorTarget: DisplayColorTarget?
        let priority: TaskPriority
        let prefetch: Bool
        let display: Bool
        let promotion: DecodePromotion?
        let startedAtMilliseconds: Int
    }

    private let pageSizes: [CGSize]
    private let started: XCTestExpectation?
    private let escalated: XCTestExpectation?
    private var priorities: [Int: TaskPriority] = [:]
    var requestCount: Int { nextID }

    init(pageSizes: [CGSize] = [.init(width: 128, height: 256)],
         started: XCTestExpectation? = nil, escalated: XCTestExpectation? = nil,
         parallel: Bool = true) {
        self.supportsParallelPageLoads = parallel
        self.pageSizes = pageSizes
        self.started = started
        self.escalated = escalated
    }

    func decodePriority(for id: Int) -> TaskPriority? { priorities[id] }

    private var nextID = 0
    private var queued: [Request] = []
    private var observers: [CheckedContinuation<Request, Never>] = []
    private var pending: [Int: CheckedContinuation<CGImage, any Error>] = [:]

    func entries() async throws -> [PageEntry] {
        pageSizes.indices.map {
            PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let request = Request(id: nextID, entryID: entry.id, cap: maxPixelSize,
                              colorTarget: PageRequestIntent.displayColorTarget,
                              priority: Task.currentPriority, prefetch: PageRequestIntent.isPrefetch,
                              display: PageRequestIntent.isDisplay, promotion: PageRequestIntent.decodePromotion,
                              startedAtMilliseconds: elapsedMilliseconds)
        nextID += 1
        let escalated = escalated
        let image: CGImage = try await withTaskPriorityEscalationHandler {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, any Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    pending[request.id] = continuation
                    peakPendingRequests = max(peakPendingRequests, pending.count)
                    started?.fulfill()
                    if observers.isEmpty { queued.append(request) }
                    else { observers.removeFirst().resume(returning: request) }
                }
            } onCancel: {
                Task { await self.fail(request) }
            }
        } onPriorityEscalated: { _, _ in escalated?.fulfill() }
        let decoded = try await PrefetchDecodeGate.run { (image, Task.currentPriority) }
        priorities[entry.id] = decoded.1
        return decoded.0
    }

    func fail(_ request: Request) {
        pending.removeValue(forKey: request.id)?.resume(throwing: CancellationError())
    }

    func nextRequest() async -> Request {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { observers.append($0) }
    }

    func finish(_ request: Request) {
        elapsedMilliseconds = max(elapsedMilliseconds, request.startedAtMilliseconds + 100)
        let size = request.cap ?? 256
        let ratio = pageSizes[request.entryID].width / pageSizes[request.entryID].height
        let context = CGContext(data: nil, width: max(1, Int(Double(size) * ratio)), height: size,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: request.colorTarget?.rgb ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pending.removeValue(forKey: request.id)?.resume(returning: context.makeImage()!)
    }
}

/// 設計書 §5: I/O のゲートを持たず、同期デコードの葉だけを停止する検証用ソース。
private final class GatedPrefetchSource: BookSource, @unchecked Sendable {
    let url: URL
    let gate: SourceReadGate
    let image: CGImage
    let pageCount: Int
    let release: DispatchSemaphore?
    let started: XCTestExpectation?
    let readGate: SourceReadGate?
    let requested: XCTestExpectation?
    var supportsParallelPageLoads: Bool { true }
    private let priorities = OSAllocatedUnfairLock(initialState: [TaskPriority]())
    var decodePriorities: [TaskPriority] { priorities.withLock { $0 } }
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var supportsDateSort: Bool { false }
    var decodeCount: Int { count.withLock { $0 } }

    init(gate: SourceReadGate, image: CGImage, pageCount: Int = 1,
         release: DispatchSemaphore? = nil, started: XCTestExpectation? = nil,
         readGate: SourceReadGate? = nil, requested: XCTestExpectation? = nil) {
        self.gate = gate
        self.image = image
        self.pageCount = pageCount
        self.release = release
        self.started = started
        self.readGate = readGate
        self.requested = requested
        url = URL(fileURLWithPath: "/stub/gated-\(UUID().uuidString)")
    }

    func entries() async throws -> [PageEntry] {
        (0..<pageCount).map {
            PageEntry(id: $0, name: "\($0).png", pathInBook: "\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        requested?.fulfill()
        if let readGate {
            guard await readGate.acquire() else { throw CancellationError() }
            await readGate.release()
        }
        return try await PrefetchDecodeGate.run(gate: gate) {
            self.priorities.withLock { $0.append(Task.currentPriority) }
            self.count.withLock { $0 += 1 }
            self.started?.fulfill()
            self.release?.wait()
            return self.image
        }
    }
}

/// 設計書 §7.3: 所有者を解放してから並べ替えの計算だけを再開する。
private struct BlockingBookSorter: PageSorting {
    let started: XCTestExpectation
    let release: DispatchSemaphore
    func sorted(_ entries: [PageEntry], mode: SortMode) -> [PageEntry] {
        started.fulfill()
        release.wait()
        return entries
    }
}

/// 設計書 §5、§7.3: 読み取り枠を返す前に順番を記録し、ゲートの許可順だけを観測する。
private actor ReadOrder {
    private(set) var values: [String] = []
    func note(_ value: String) { values.append(value) }
}

/// 設計書 §5: FolderSource と同じ読み取りゲートの前で先読みを待たせる。
private actor OrderedReadSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/ordered-read")
    nonisolated var supportsDateSort: Bool { false }
    let gate: SourceReadGate
    let order: ReadOrder
    let image: CGImage
    private(set) var promotion: DecodePromotion?
    private(set) var requestCount = 0

    init(gate: SourceReadGate, order: ReadOrder, image: CGImage) {
        self.gate = gate
        self.order = order
        self.image = image
    }

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "page.png", pathInBook: "page.png",
                   fileURL: nil, creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        requestCount += 1
        promotion = PageRequestIntent.decodePromotion
        guard await gate.acquire() else { throw CancellationError() }
        await order.note("display")
        await gate.release()
        return image
    }
}
