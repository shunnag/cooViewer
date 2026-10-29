import Foundation
import XCTest
@testable import cooViewer

/// 推論器を合図で止め、OS のタスク実行順に依存せず境界の優先制御を確認する(設計書 §5、§7.6)。
final class SRJobQueueTests: XCTestCase {
    private actor Tiles {
        var events: [String] = []
        let started: XCTestExpectation
        let release: AsyncStream<Void>

        init(started: XCTestExpectation, release: AsyncStream<Void>) {
            self.started = started
            self.release = release
        }

        func process(_ name: String, tile: Int) async -> [UInt8] {
            events.append("\(name)\(tile)")
            if name == "p", tile == 1 {
                started.fulfill()
                for await _ in release { }
            }
            return (0..<64).map { UInt8(truncatingIfNeeded: tile * 37 + $0) }
        }
    }

    private static func run(_ name: String, count: Int, queue: SRJobQueue,
                            request: SRJobRequest, tiles: Tiles) async -> [UInt8]? {
        var output: [UInt8] = []
        for tile in 0..<count {
            guard await queue.nextTile(for: request), !Task.isCancelled else {
                await queue.finish(request)
                return nil
            }
            output += await tiles.process(name, tile: tile)
        }
        await queue.finish(request)
        return Task.isCancelled ? nil : output
    }

    private func waitForQueue(_ queue: SRJobQueue, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await queue.queuedCount != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("待機列への登録が期限内に完了しない")
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    func testDisplayFinishesBeforePrefetchResumesWithoutRepeatingTiles() async throws {
        let queue = SRJobQueue()
        let started = expectation(description: "先読みの途中タイル")
        let release = AsyncStream<Void>.makeStream()
        let tiles = Tiles(started: started, release: release.stream)
        let prefetch = Task {
            await SRJobQueueTests.run("p", count: 5, queue: queue,
                           request: SRJobRequest(priority: .prefetch), tiles: tiles)
        }
        await fulfillment(of: [started], timeout: 3)
        let display = Task {
            await SRJobQueueTests.run("d", count: 3, queue: queue,
                           request: SRJobRequest(), tiles: tiles)
        }
        try await waitForQueue(queue, count: 1)
        release.continuation.finish()
        let displayed = await display.value
        let prefetched = await prefetch.value
        let events = await tiles.events
        XCTAssertEqual(events, ["p0", "p1", "d0", "d1", "d2", "p2", "p3", "p4"])
        let serialDisplay = (0..<3).flatMap { tile in
            (0..<64).map { UInt8(truncatingIfNeeded: tile * 37 + $0) }
        }
        let serialPrefetch = (0..<5).flatMap { tile in
            (0..<64).map { UInt8(truncatingIfNeeded: tile * 37 + $0) }
        }
        XCTAssertEqual(displayed, serialDisplay)
        XCTAssertEqual(prefetched, serialPrefetch)
    }

    func testCancellationStopsAtNextTileAndReleasesQueue() async throws {
        let queue = SRJobQueue()
        let started = expectation(description: "取消し前のタイル")
        let release = AsyncStream<Void>.makeStream()
        let tiles = Tiles(started: started, release: release.stream)
        let prefetch = Task {
            await SRJobQueueTests.run("p", count: 10, queue: queue,
                           request: SRJobRequest(priority: .prefetch), tiles: tiles)
        }
        await fulfillment(of: [started], timeout: 3)
        prefetch.cancel()
        release.continuation.finish()
        let cancelled = await prefetch.value
        XCTAssertNil(cancelled)
        let display = await SRJobQueueTests.run("d", count: 2, queue: queue,
                                     request: SRJobRequest(), tiles: tiles)
        XCTAssertNotNil(display)
        let events = await tiles.events
        XCTAssertEqual(events, ["p0", "p1", "d0", "d1"])
    }

    func testQueuedCancellationReturnsBeforeActiveTileFinishes() async throws {
        let queue = SRJobQueue()
        let active = SRJobRequest()
        let acquired = await queue.nextTile(for: active)
        XCTAssertTrue(acquired)
        let queued = SRJobRequest(priority: .prefetch)
        let waiting = Task { await queue.nextTile(for: queued) }
        try await waitForQueue(queue, count: 1)
        waiting.cancel()
        let result = await waiting.value
        XCTAssertFalse(result)
        await queue.finish(queued)
        await queue.finish(active)
    }

    func testDisplayPromotionPassesQueuedPrefetch() async throws {
        let queue = SRJobQueue()
        let active = SRJobRequest()
        _ = await queue.nextTile(for: active)
        let first = SRJobRequest(priority: .prefetch)
        let promoted = SRJobRequest(priority: .prefetch)
        let a = Task { await queue.nextTile(for: first) }
        try await waitForQueue(queue, count: 1)
        let b = Task { await queue.nextTile(for: promoted) }
        try await waitForQueue(queue, count: 2)
        promoted.promote()
        await queue.finish(active)
        let result = await b.value
        XCTAssertTrue(result)
        let remaining = await queue.queuedCount
        XCTAssertEqual(remaining, 1)
        await queue.finish(promoted)
        _ = await a.value
        await queue.finish(first)
    }

    func testDisplayLatencyIsOneRemainingTilePlusOwnWork() async throws {
        let queue = SRJobQueue()
        let request = SRJobRequest(priority: .prefetch)
        _ = await queue.nextTile(for: request)
        let start = ContinuousClock.now
        let display = Task {
            let job = SRJobRequest()
            guard await queue.nextTile(for: job) else { return }
            for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(10)) }
            await queue.finish(job)
        }
        try await waitForQueue(queue, count: 1)
        // 進行中タイルの残り 40ms と表示の 30ms だけを待つ(設計書 §5、§7.6)。
        try await Task.sleep(for: .milliseconds(40))
        let resumed = Task { await queue.nextTile(for: request) }
        await display.value
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(70))
        XCTAssertLessThan(elapsed, .milliseconds(250))
        print("SR display latency: \(elapsed) (remaining tile 40ms + display 30ms)")
        _ = await resumed.value
        await queue.finish(request)
    }
}
