import XCTest
@testable import Washi

@MainActor
final class EPUBOffscreenIdleReleaseTimerTests: XCTestCase {
    /// cooViewer-oxr.68: キャンセル済み期限が競合して到着しても発火せず、
    /// 置き換えた期限だけが既定の 20 秒後に発火する。
    func testRestartInvalidatesStaleCallbackAndKeepsTwentySecondDeadline() throws {
        let scheduler = ManualOffscreenIdleScheduler()
        let timer = EPUBOffscreenIdleReleaseTimer(scheduler: scheduler.scheduler)
        var releaseCount = 0

        timer.restart { releaseCount += 1 }
        let stale = try XCTUnwrap(scheduler.lastActiveEntry)
        timer.restart { releaseCount += 1 }
        let current = try XCTUnwrap(scheduler.lastActiveEntry)

        XCTAssertTrue(stale.isCancelled)
        XCTAssertEqual(stale.delay, .seconds(20))
        XCTAssertEqual(current.delay, EPUBOffscreenIdleReleaseTimer.defaultInterval)
        scheduler.fire(stale, includingCancelled: true)
        XCTAssertEqual(releaseCount, 0)

        scheduler.fire(current)
        XCTAssertEqual(releaseCount, 1)
    }

    /// cooViewer-oxr.68: scheduler が schedule から戻る前に発火し、callback が
    /// 次の期限を設定しても、最初の cancellation で置き換えてしまわない。
    func testSynchronousFirePreservesReplacementDeadlineCancellation() throws {
        let scheduler = ManualOffscreenIdleScheduler()
        scheduler.firesNextEntrySynchronously = true
        let timer = EPUBOffscreenIdleReleaseTimer(scheduler: scheduler.scheduler)

        timer.restart {
            timer.restart {}
        }
        XCTAssertEqual(scheduler.entries.count, 2)

        timer.cancel()

        XCTAssertTrue(scheduler.entries[0].isCancelled)
        XCTAssertTrue(scheduler.entries[1].isCancelled)
    }
}
