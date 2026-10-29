import CoreGraphics
import Foundation
import os
import XCTest
@testable import cooViewer

/// 共有タスクの所有者と合流した待ち手の取消しを、内側の推論まで通す(設計書 §5、§7.3、§7.6)。
final class SRResamplerCancellationTests: XCTestCase {
    private final class Inference: Sendable {
        let started = XCTestExpectation(description: "内側の推論開始")
        let cancelled = XCTestExpectation(description: "内側へ取消し到達")
        let release = AsyncStream<Void>.makeStream()
        let completedTiles = OSAllocatedUnfairLock(initialState: 0)

        func run(_ image: CGImage) async -> CGImage? {
            started.fulfill()
            return await withTaskCancellationHandler {
                for await _ in release.stream { }
                for _ in 0..<4 {
                    guard !Task.isCancelled else { return nil }
                    completedTiles.withLock { $0 += 1 }
                }
                return image
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

    private func waitForWaiters(_ count: Int, in resampler: ImageResampler) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await resampler.inFlightWaiterCount != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("共有計算の待ち手数が期限内に変わらない")
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    func testLastWaiterCancellationReachesInnerWorkAndDoesNotCacheFallback() async throws {
        let inference = Inference()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = DeferredImageWriter()
        let resolver = MLSuperResolver(diskRoot: root, diskWriter: writer,
            diskWrite: { _, _, _ in }, upscaleOverride: { await inference.run($0) })
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), superResolver: resolver)
        let source = try image()
        let request = Task {
            await resampler.resample(source, to: CGSize(width: 16, height: 16),
                cacheKey: "cancelled", upscaleWithMetalFX: false,
                noiseReduction: .maximum, priority: .prefetch)
        }
        await fulfillment(of: [inference.started], timeout: 3)
        request.cancel()
        await fulfillment(of: [inference.cancelled], timeout: 3)
        inference.release.continuation.finish()
        let result = await request.value
        XCTAssertNil(result)
        XCTAssertEqual(inference.completedTiles.withLock { $0 }, 0)
        let stats = await resampler.stats()
        XCTAssertEqual(stats.count, 0)
        let cached = await resampler.cached(source, to: CGSize(width: 16, height: 16),
            cacheKey: "cancelled", upscaleWithMetalFX: false, noiseReduction: .maximum)
        XCTAssertNil(cached)
    }

    func testCancellingEitherSharedWaiterKeepsOtherRequestAlive() async throws {
        for cancelPrefetch in [true, false] {
            let inference = Inference()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let writer = DeferredImageWriter()
            let resolver = MLSuperResolver(diskRoot: root, diskWriter: writer,
                diskWrite: { _, _, _ in }, upscaleOverride: { await inference.run($0) })
            let resampler = ImageResampler(pressure: FixedMemoryPressure(), superResolver: resolver)
            let source = try image()
            let prefetch = Task {
                await resampler.resample(source, to: CGSize(width: 16, height: 16),
                    cacheKey: "shared", upscaleWithMetalFX: false,
                    noiseReduction: .maximum, priority: .prefetch)
            }
            await fulfillment(of: [inference.started], timeout: 3)
            let display = Task {
                await resampler.resample(source, to: CGSize(width: 16, height: 16),
                    cacheKey: "shared", upscaleWithMetalFX: false, noiseReduction: .maximum)
            }
            try await waitForWaiters(2, in: resampler)
            if cancelPrefetch { prefetch.cancel() } else { display.cancel() }
            try await waitForWaiters(1, in: resampler)
            inference.release.continuation.finish()
            let a = await prefetch.value, b = await display.value
            XCTAssertEqual(a == nil, cancelPrefetch)
            XCTAssertEqual(b == nil, !cancelPrefetch)
            XCTAssertEqual(inference.completedTiles.withLock { $0 }, 4)
            let stats = await resampler.stats()
            XCTAssertEqual(stats.computeCount, 1)
            await writer.waitForPendingWrites()
        }
    }
}
