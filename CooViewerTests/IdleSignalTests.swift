import XCTest
@testable import cooViewer

@MainActor
final class IdleSignalTests: XCTestCase {
    func testReturnsImmediatelyWhenIdle() async {
        let signal = IdleSignal()
        XCTAssertFalse(signal.isBusy)
        await signal.waitUntilIdle()
    }

    func testWaitersWakeWhenWorkFinishes() async {
        let signal = IdleSignal()
        signal.setBusy(true)
        let finished = expectation(description: "両方の待機者が起きる")
        finished.expectedFulfillmentCount = 2
        var woken = 0
        let waiters = (0..<2).map { _ in
            Task { @MainActor in
                await signal.waitUntilIdle()
                woken += 1
                finished.fulfill()
            }
        }
        // 待機者がぶら下がるまで譲る(busy のままなので起きない)
        for _ in 0..<10 { await Task.yield() }
        signal.setBusy(true)  // 進行中の再通知では起こさない
        XCTAssertTrue(signal.isBusy)
        XCTAssertEqual(woken, 0, "完了前に待機者が戻っていない")
        signal.setBusy(false)
        await fulfillment(of: [finished], timeout: 2)
        for waiter in waiters { _ = await waiter.value }
        // 二度目の完了通知で待機者が残っていても落ちない
        signal.setBusy(false)
    }

    func testCancellationEndsWaitWithoutIdleEvent() async {
        let signal = IdleSignal()
        signal.setBusy(true)
        let ended = expectation(description: "キャンセルで待ちが解ける")
        let task = Task { @MainActor in
            await signal.waitUntilIdle()
            ended.fulfill()
        }
        for _ in 0..<10 { await Task.yield() }
        task.cancel()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertTrue(signal.isBusy, "キャンセルは状態を変えない")
        // 後の完了通知でも二重再開にならない
        signal.setBusy(false)
    }

    func testAlreadyCancelledTaskDoesNotWait() async {
        let signal = IdleSignal()
        signal.setBusy(true)
        let task = Task { @MainActor in
            // キャンセル済みタスクからの待機は arm の時点で即座に戻る
            await signal.waitUntilIdle()
            return true
        }
        task.cancel()
        let returned = await task.value
        XCTAssertTrue(returned)
        XCTAssertTrue(signal.isBusy)
    }
}
