import CoreGraphics
import Foundation
import os
import XCTest
@testable import cooViewer

/// ページ送りで計画タスクを差し替えても、残るページの SR を継続する(設計書 §5、§7.6)。
final class PreresampleJobsTests: XCTestCase {
    private final class Inference: Sendable {
        let midway = XCTestExpectation(description: "二つのタイルが完了")
        let cancelled = XCTestExpectation(description: "不要なページへ取消し到達")
        let release = AsyncStream<Void>.makeStream()
        let tiles = OSAllocatedUnfairLock(initialState: [Int]())

        func run(_ image: CGImage) async -> CGImage? {
            await withTaskCancellationHandler {
                for tile in 0..<4 {
                    guard !Task.isCancelled else { return nil }
                    tiles.withLock { $0.append(tile) }
                    if tile == 1 {
                        midway.fulfill()
                        for await _ in release.stream { }
                    }
                }
                return Task.isCancelled ? nil : image
            } onCancel: {
                self.cancelled.fulfill()
            }
        }
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func keys(_ prediction: [[Int]]) -> Set<String> {
        Set(PreresamplePolicy.spreadsToProcess(prediction, usesML: true, conserveEnergy: false)
            .flatMap { $0 }.map { "book#\($0)" })
    }

    func testForwardTurnKeepsPlannedSRWithoutRecomputingCompletedTiles() async throws {
        let jobs = await MainActor.run { PreresampleJobs() }
        let inference = Inference()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = MLSuperResolver(diskRoot: root, diskWriter: DeferredImageWriter(),
            diskWrite: { _, _, _ in }, upscaleOverride: { await inference.run($0) })
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), superResolver: resolver)
        let source = try image()
        let operation: @Sendable () async -> Void = {
            _ = await resampler.resample(source, to: CGSize(width: 16, height: 16),
                cacheKey: "book#4", upscaleWithMetalFX: false, noiseReduction: .maximum,
                priority: .prefetch)
        }
        await jobs.replacePlan(keys([[2, 3], [4, 5]]))
        let oldPlan = Task {
            await jobs.run(key: "book#4", entryID: 4, configuration: "maximum", operation: operation)
        }
        await fulfillment(of: [inference.midway], timeout: 3)
        oldPlan.cancel()
        let next = keys([[4, 5], [6, 7]])
        await jobs.replacePlan(next)
        let joined = expectation(description: "新計画が同じページを要求")
        let newPlan = Task {
            try? await Task.sleep(for: .milliseconds(250))
            joined.fulfill()
            await jobs.run(key: "book#4", entryID: 4, configuration: "maximum", operation: operation)
        }
        await fulfillment(of: [joined], timeout: 3)
        let active = await jobs.activeCount
        XCTAssertEqual(active, 1)
        XCTAssertLessThanOrEqual(active, next.count)
        XCTAssertEqual(inference.tiles.withLock { $0 }, [0, 1])
        inference.release.continuation.finish()
        await oldPlan.value
        await newPlan.value
        XCTAssertEqual(inference.tiles.withLock { $0 }, [0, 1, 2, 3])
        let stats = await resampler.stats()
        XCTAssertEqual(stats.computeCount, 1)
        let remaining = await jobs.activeCount
        XCTAssertEqual(remaining, 0)
    }

    func testPageLeavingPredictionIsCancelledAtTileBoundary() async throws {
        let jobs = await MainActor.run { PreresampleJobs() }
        let inference = Inference()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = MLSuperResolver(diskRoot: root, diskWriter: DeferredImageWriter(),
            diskWrite: { _, _, _ in }, upscaleOverride: { await inference.run($0) })
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), superResolver: resolver)
        let source = try image()
        await jobs.replacePlan(keys([[2, 3], [4, 5]]))
        let oldPlan = Task {
            await jobs.run(key: "book#4", entryID: 4, configuration: "maximum") {
                _ = await resampler.resample(source, to: CGSize(width: 16, height: 16),
                    cacheKey: "book#4", upscaleWithMetalFX: false, noiseReduction: .maximum,
                    priority: .prefetch)
            }
        }
        await fulfillment(of: [inference.midway], timeout: 3)
        oldPlan.cancel()
        await jobs.replacePlan(keys([[8, 9], [10, 11]]))
        await fulfillment(of: [inference.cancelled], timeout: 3)
        inference.release.continuation.finish()
        await oldPlan.value
        XCTAssertEqual(inference.tiles.withLock { $0 }, [0, 1])
        let active = await jobs.activeCount
        XCTAssertEqual(active, 0)
        let stats = await resampler.stats()
        XCTAssertEqual(stats.computeCount, 1)
        XCTAssertEqual(stats.count, 0)
    }

    func testCloseOrOcclusionCancelsEvenPagesStillInPlan() async {
        let jobs = await MainActor.run { PreresampleJobs() }
        let started = expectation(description: "ページ処理開始")
        let cancelled = expectation(description: "閉窓・隠蔽で停止")
        let release = AsyncStream<Void>.makeStream()
        await jobs.replacePlan(["book#4"])
        let plan = Task {
            await jobs.run(key: "book#4", entryID: 4, configuration: "maximum") {
                await withTaskCancellationHandler {
                    started.fulfill()
                    for await _ in release.stream { }
                } onCancel: {
                    cancelled.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        await jobs.cancelAll()
        await fulfillment(of: [cancelled], timeout: 3)
        release.continuation.finish()
        await plan.value
        let active = await jobs.activeCount
        XCTAssertEqual(active, 0)
    }

    func testRetainedJobsStayWithinNewPrediction() async {
        let jobs = await MainActor.run { PreresampleJobs() }
        let first = keys([[2, 3], [4, 5]])
        let next = keys([[4, 5], [6, 7]])
        let releases = Dictionary(uniqueKeysWithValues: first.union(next).map {
            ($0, AsyncStream<Void>.makeStream())
        })
        let started = expectation(description: "旧計画の四ページ開始")
        started.expectedFulfillmentCount = 4
        await jobs.replacePlan(first)
        let oldPlan = first.map { key in
            Task {
                await jobs.run(key: key, entryID: 0, configuration: "maximum") {
                    started.fulfill()
                    for await _ in releases[key]!.stream { }
                }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        await jobs.replacePlan(next)
        let retained = await jobs.activeCount
        XCTAssertEqual(retained, 2)
        let added = expectation(description: "新計画の追加二ページ開始")
        added.expectedFulfillmentCount = 2
        let newPlan = next.subtracting(first).map { key in
            Task {
                await jobs.run(key: key, entryID: 0, configuration: "maximum") {
                    added.fulfill()
                    for await _ in releases[key]!.stream { }
                }
            }
        }
        await fulfillment(of: [added], timeout: 3)
        await jobs.run(key: "unplanned", entryID: 0, configuration: "maximum") {
            XCTFail("計画外のページ処理を始めない")
        }
        let active = await jobs.activeCount
        XCTAssertEqual(active, next.count)
        for release in releases.values { release.continuation.finish() }
        for task in oldPlan + newPlan { await task.value }
        let remaining = await jobs.activeCount
        XCTAssertEqual(remaining, 0)
    }

    private actor CleanupGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class Owner: Sendable {}

    /// 取消し済みのページと旧計画の後始末まで待ち、drain 後に所有者を残さない(設計書 §5、§7.3)。
    func testDrainIncludesRetiredJobsAndPlanFinalization() async throws {
        let jobs = await MainActor.run { PreresampleJobs() }
        let gate = CleanupGate()
        let started = expectation(description: "ページ処理開始")
        let cancelled = expectation(description: "計画外のページを取消し")
        let events = OSAllocatedUnfairLock(initialState: [String]())
        var owner: Owner? = Owner()
        weak var previousOwner = owner
        await jobs.replacePlan(["x"])
        let plan = await jobs.startPlan { [owner = try XCTUnwrap(owner)] in
            defer {
                withExtendedLifetime(owner) {}
                events.withLock { $0.append("plan") }
            }
            await jobs.run(key: "x", entryID: 0, configuration: "maximum") {
                await withTaskCancellationHandler {
                    started.fulfill()
                    await gate.wait()
                    events.withLock { $0.append("page") }
                } onCancel: { cancelled.fulfill() }
            }
        }
        owner = nil
        await fulfillment(of: [started], timeout: 3)
        // 計画から外れても未完了の仕事は、後で始まるアンロードの待機対象になる(設計書 §5)。
        await jobs.replacePlan([])
        await fulfillment(of: [cancelled], timeout: 3)
        let drain = await jobs.cancelAllAndDrain()
        let waiting = expectation(description: "解放待ちの開始")
        let waiter = Task {
            waiting.fulfill()
            await drain.value
            events.withLock { $0.append("drain") }
        }
        await fulfillment(of: [waiting], timeout: 3)
        XCTAssertNotNil(previousOwner)
        await gate.release()
        await waiter.value
        XCTAssertEqual(events.withLock { $0 }, ["page", "plan", "drain"])
        XCTAssertNil(previousOwner)
        await plan.value
    }

    /// SR の待機票は表示ジョブを保持したままでも取り消せる(設計書 §5、§7.3)。
    func testDrainCancelsInnerSRQueueWaitWithoutWaitingForDisplay() async throws {
        let jobs = await MainActor.run { PreresampleJobs() }
        let queue = SRJobQueue()
        let display = SRJobRequest()
        _ = await queue.nextTile(for: display)
        defer { Task { await queue.finish(display) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queued = expectation(description: "内側の SR 待機")
        let resolver = MLSuperResolver(diskRoot: root, diskWriter: DeferredImageWriter(),
            diskWrite: { _, _, _ in }, upscaleOverride: { image in
                let job = SRJobRequest(priority: .prefetch)
                queued.fulfill()
                let acquired = await queue.nextTile(for: job)
                await queue.finish(job)
                return acquired ? image : nil
            })
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), superResolver: resolver)
        let source = try image()
        await jobs.replacePlan(["x"])
        let plan = await jobs.startPlan {
            await jobs.run(key: "x", entryID: 0, configuration: "maximum") {
                _ = await resampler.resample(source, to: CGSize(width: 16, height: 16),
                    cacheKey: "x", upscaleWithMetalFX: false, noiseReduction: .maximum,
                    priority: .prefetch)
            }
        }
        await fulfillment(of: [queued], timeout: 3)
        let deadline = ContinuousClock.now + .seconds(3)
        while await queue.queuedCount != 1 {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            await Task.yield()
        }
        let drain = await jobs.cancelAllAndDrain()
        let done = expectation(description: "表示が終わる前に drain 完了")
        let waiter = Task { await drain.value; done.fulfill() }
        await fulfillment(of: [done], timeout: 3)
        let count = await queue.queuedCount
        XCTAssertEqual(count, 0)
        await queue.finish(display)
        await waiter.value
        await plan.value
    }

    /// 計画とページ処理をどちらも utility で始め、表示合流時の昇格に任せる(設計書 §5)。
    func testPlanAndPageStartAtUtilityPriority() async {
        let jobs = await MainActor.run { PreresampleJobs() }
        let priorities = OSAllocatedUnfairLock(initialState: [TaskPriority]())
        let started = expectation(description: "utility の先読み開始")
        let release = AsyncStream<Void>.makeStream()
        await jobs.replacePlan(["x"])
        let plan = await jobs.startPlan {
            priorities.withLock { $0.append(Task.currentPriority) }
            await jobs.run(key: "x", entryID: 0, configuration: "maximum") {
                priorities.withLock { $0.append(Task.currentPriority) }
                started.fulfill()
                for await _ in release.stream { }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(priorities.withLock { $0 }, [.utility, .utility])
        release.continuation.finish()
        await plan.value
    }
}
