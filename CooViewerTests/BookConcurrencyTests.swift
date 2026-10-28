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

    private func waitForQueuedDecode(_ gate: SourceReadGate) async -> Bool {
        for _ in 0..<200 {
            if await gate.debugCounts().queued > 0 { return true }
            try? await Task.sleep(for: .milliseconds(5))
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

    struct Request: Sendable {
        let id: Int
        let entryID: Int
        let cap: Int?
        let colorTarget: DisplayColorTarget?
    }

    private var nextID = 0
    private var queued: [Request] = []
    private var observers: [CheckedContinuation<Request, Never>] = []
    private var pending: [Int: CheckedContinuation<CGImage, any Error>] = [:]

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "p0.png", pathInBook: "p0.png",
                   fileURL: nil, creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let request = Request(id: nextID, entryID: entry.id, cap: maxPixelSize,
                              colorTarget: PageRequestIntent.displayColorTarget)
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            if observers.isEmpty {
                queued.append(request)
            } else {
                observers.removeFirst().resume(returning: request)
            }
        }
    }

    func nextRequest() async -> Request {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { observers.append($0) }
    }

    func finish(_ request: Request) {
        let size = request.cap ?? 256
        let context = CGContext(data: nil, width: size / 2, height: size,
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
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var supportsDateSort: Bool { false }
    var decodeCount: Int { count.withLock { $0 } }

    init(gate: SourceReadGate, image: CGImage, pageCount: Int = 1,
         release: DispatchSemaphore? = nil, started: XCTestExpectation? = nil) {
        self.gate = gate
        self.image = image
        self.pageCount = pageCount
        self.release = release
        self.started = started
        url = URL(fileURLWithPath: "/stub/gated-\(UUID().uuidString)")
    }

    func entries() async throws -> [PageEntry] {
        (0..<pageCount).map {
            PageEntry(id: $0, name: "\($0).png", pathInBook: "\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try await PrefetchDecodeGate.run(gate: gate) {
            self.count.withLock { $0 += 1 }
            self.started?.fulfill()
            self.release?.wait()
            return self.image
        }
    }
}
