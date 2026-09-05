import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

@MainActor
final class EPUBScreenThumbnailRendererTests: XCTestCase {
    /// cooViewer-oxr.68: レンダー完了後の idle 期限で不可視 WebKit を解放し、
    /// 次の要求では同じ renderer が遅延再構築して再び画像を返す。
    func testIdleReleaseTearsDownWebViewAndNextThumbnailRebuilds() async throws {
        let publication = try makeSmallPublication()
        let scheduler = ManualOffscreenIdleScheduler()
        let renderer = EPUBScreenThumbnailRenderer(
            publication: publication, idleTimerScheduler: scheduler.scheduler)
        defer { renderer.invalidate() }
        let metrics = makeMetrics()
        let options = metrics.themedOptionsJSON(isDark: false)

        guard await renderer.thumbnail(
            spineIndex: 0, pageInItem: 0, optionsJSON: options,
            contentSize: metrics.contentSize, snapshotWidth: 120) != nil else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }

        XCTAssertTrue(renderer.hasLiveWebView)
        let idle = try XCTUnwrap(scheduler.lastActiveEntry)
        XCTAssertEqual(idle.delay, EPUBOffscreenIdleReleaseTimer.defaultInterval)

        scheduler.fire(idle)
        XCTAssertFalse(renderer.hasLiveWebView)

        let rebuilt = await renderer.thumbnail(
            spineIndex: 0, pageInItem: 0, optionsJSON: options,
            contentSize: metrics.contentSize, snapshotWidth: 120)
        XCTAssertNotNil(rebuilt)
        XCTAssertTrue(renderer.hasLiveWebView)
    }

    /// cooViewer-oxr.68: FXL を委譲する nested rasterizer も idle 時に破棄し、
    /// 次の固定レイアウト要求では新しい rasterizer / WebView を構築する。
    func testIdleReleaseTearsDownFXLRasterizerAndNextThumbnailRebuilds()
        async throws {
        let publication = try makeFXLPublication()
        let scheduler = ManualOffscreenIdleScheduler()
        let renderer = EPUBScreenThumbnailRenderer(
            publication: publication, idleTimerScheduler: scheduler.scheduler)
        defer { renderer.invalidate() }
        let metrics = makeMetrics()
        let options = metrics.themedOptionsJSON(isDark: false)

        guard await renderer.thumbnail(
            spineIndex: 0, pageInItem: 0, optionsJSON: options,
            contentSize: metrics.contentSize, snapshotWidth: 120) != nil else {
            throw XCTSkip("FXL WKWebView rendering is unavailable in this sandbox")
        }

        XCTAssertTrue(renderer.hasLiveWebView)
        let idle = try XCTUnwrap(scheduler.lastActiveEntry)

        scheduler.fire(idle)
        XCTAssertFalse(renderer.hasLiveWebView)

        let rebuilt = await renderer.thumbnail(
            spineIndex: 0, pageInItem: 0, optionsJSON: options,
            contentSize: metrics.contentSize, snapshotWidth: 120)
        XCTAssertNotNil(rebuilt)
        XCTAssertTrue(renderer.hasLiveWebView)
    }

    /// cooViewer-oxr.68: FIFO の先頭と待機中の両要求を busy と数え、旧 idle
    /// callback が競合しても共有 WebKit と要求を中断しない。
    func testStaleIdleTimerDoesNotInterruptQueuedThumbnails() async throws {
        let publication = try makeSmallPublication()
        let scheduler = ManualOffscreenIdleScheduler()
        let renderer = EPUBScreenThumbnailRenderer(
            publication: publication, idleTimerScheduler: scheduler.scheduler)
        defer { renderer.invalidate() }
        let metrics = makeMetrics()
        let options = metrics.themedOptionsJSON(isDark: false)
        guard await renderer.thumbnail(
            spineIndex: 0, pageInItem: 0, optionsJSON: options,
            contentSize: metrics.contentSize, snapshotWidth: 120) != nil else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }
        let staleIdle = try XCTUnwrap(scheduler.lastActiveEntry)

        let first = Task { @MainActor in
            await renderer.thumbnail(
                spineIndex: 0, pageInItem: 0, optionsJSON: options,
                contentSize: metrics.contentSize, snapshotWidth: 120)
        }
        let queued = Task { @MainActor in
            await renderer.thumbnail(
                spineIndex: 0, pageInItem: 0, optionsJSON: options,
                contentSize: metrics.contentSize, snapshotWidth: 120)
        }
        for _ in 0..<100 {
            if staleIdle.isCancelled { break }
            await Task.yield()
        }
        XCTAssertTrue(staleIdle.isCancelled)

        scheduler.fire(staleIdle, includingCancelled: true)
        XCTAssertTrue(renderer.hasLiveWebView)
        let firstImage = await first.value
        let queuedImage = await queued.value
        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(queuedImage)
    }

    /// cooViewer-oxr.62: invalidate は進行中のナビゲーションを即座に止める。
    func testInvalidateDuringRequestReturnsWithinOneSecond() async throws {
        let publication = try makeLargePublication()
        let renderer = EPUBScreenThumbnailRenderer(publication: publication)
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600),
            settings: EPUBReaderSettings())
        let task = Task { @MainActor in
            await renderer.thumbnail(
                spineIndex: 0, pageInItem: 0,
                optionsJSON: metrics.themedOptionsJSON(isDark: false),
                contentSize: metrics.contentSize, snapshotWidth: 120)
        }
        try? await Task.sleep(for: .milliseconds(5))
        let invalidatedAt = ContinuousClock.now

        renderer.invalidate()
        let image = await task.value

        XCTAssertNil(image)
        XCTAssertLessThan(ContinuousClock.now - invalidatedAt, .seconds(1))
    }

    /// cooViewer-oxr.62: thumbnail の呼び出し元キャンセルを、独立した
    /// FIFO レンダージョブと NavigationWaiter へ伝播する。
    func testCallerCancellationReturnsWithinOneSecond() async throws {
        let publication = try makeLargePublication()
        let renderer = EPUBScreenThumbnailRenderer(publication: publication)
        defer { renderer.invalidate() }
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600),
            settings: EPUBReaderSettings())
        let task = Task { @MainActor in
            await renderer.thumbnail(
                spineIndex: 0, pageInItem: 0,
                optionsJSON: metrics.themedOptionsJSON(isDark: false),
                contentSize: metrics.contentSize, snapshotWidth: 120)
        }
        try? await Task.sleep(for: .milliseconds(5))
        let cancelledAt = ContinuousClock.now

        task.cancel()
        let image = await task.value

        XCTAssertNil(image)
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(1))
    }

    /// cooViewer-oxr.62: 先行レンダーの FIFO 待ちにいる要求も、先行処理の
    /// 完了を待たず caller cancellation へ即応する。
    func testQueuedCallerCancellationReturnsWithinOneSecond() async throws {
        let publication = try makeLargePublication()
        let renderer = EPUBScreenThumbnailRenderer(publication: publication)
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600),
            settings: EPUBReaderSettings())
        let options = metrics.themedOptionsJSON(isDark: false)
        let first = Task { @MainActor in
            await renderer.thumbnail(
                spineIndex: 0, pageInItem: 0, optionsJSON: options,
                contentSize: metrics.contentSize, snapshotWidth: 120)
        }
        try? await Task.sleep(for: .milliseconds(5))
        let queued = Task { @MainActor in
            await renderer.thumbnail(
                spineIndex: 0, pageInItem: 1, optionsJSON: options,
                contentSize: metrics.contentSize, snapshotWidth: 120)
        }
        try? await Task.sleep(for: .milliseconds(5))
        let cancelledAt = ContinuousClock.now

        queued.cancel()
        let image = await queued.value

        XCTAssertNil(image)
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(1))
        renderer.invalidate()
        _ = await first.value
    }

    private func makeLargePublication() throws -> EPUBPublication {
        let body = "<p>" + String(repeating: "A long rendering request. ",
                                    count: 100_000) + "</p>"
        return try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.reflowSpreadEntries(
                    renditionSpread: .none, bodyHTML: body),
                method: 8),
            displayURL: URL(
                fileURLWithPath: "/tmp/washi-thumbnail-cancel.epub"))
    }

    private func makeSmallPublication() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.reflowSpreadEntries(
                    renditionSpread: .none,
                    bodyHTML: "<p>Idle thumbnail lifecycle fixture.</p>"),
                method: 8),
            displayURL: URL(
                fileURLWithPath: "/tmp/washi-thumbnail-idle-release.epub"))
    }

    private func makeFXLPublication() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.fxlComicEntries(), method: 8),
            displayURL: URL(
                fileURLWithPath: "/tmp/washi-thumbnail-fxl-idle-release.epub"))
    }

    private func makeMetrics() -> EPUBScreenMetrics {
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        return EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600), settings: settings)
    }
}
