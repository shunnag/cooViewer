import XCTest

@testable import cooViewer

/// SourceReadGate の優先レーンのテスト。
/// サムネイルの可視セル要求(urgent)が、見えない画面の先読みの行列を
/// 追い越して先に生成へ入れることの根拠(cooViewer-19t)。
final class SourceReadGateTests: XCTestCase {
    func testCancelledBeforeAcquireDoesNotTakeSlot() async {
        let gate = SourceReadGate(limit: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.acquire(interactive: true)
        }
        let acquired = await task.value
        XCTAssertFalse(acquired)
        let counts = await gate.debugCounts()
        XCTAssertEqual(counts.active, 0)
        XCTAssertEqual(counts.queued, 0)
    }

    func testCancelWhileParkedDoesNotLeakSlot() async {
        for interactive in [false, true] {
            let gate = SourceReadGate(limit: 1)
            guard await gate.acquire() else { return XCTFail("取得失敗") }
            let parked = Task { await gate.acquire(interactive: interactive) }
            while await gate.debugCounts().queued == 0 { await Task.yield() }
            parked.cancel()
            let acquired = await parked.value
            XCTAssertFalse(acquired)
            let counts = await gate.debugCounts()
            XCTAssertEqual(counts.active, 1)
            XCTAssertEqual(counts.queued, 0)
            await gate.release()
            guard await gate.acquire() else { return XCTFail("後続の取得失敗") }
            await gate.release()
            let final = await gate.debugCounts()
            XCTAssertEqual(final.active, 0)
        }
    }

    func testCancelRacingReleaseResumesExactlyOnce() async {
        for _ in 0..<100 {
            let gate = SourceReadGate(limit: 1)
            guard await gate.acquire() else { return XCTFail("取得失敗") }
            let parked = Task {
                let acquired = await gate.acquire(interactive: true)
                if acquired { await gate.release() }
            }
            while await gate.debugCounts().queued == 0 { await Task.yield() }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { parked.cancel() }
                group.addTask { await gate.release() }
            }
            await parked.value
            let counts = await gate.debugCounts()
            XCTAssertEqual(counts.active, 0)
            XCTAssertEqual(counts.queued, 0)
            guard await gate.acquire() else { return XCTFail("後続の取得失敗") }
            await gate.release()
        }
    }

    func testInteractiveLaneOvertakesBackgroundQueue() async throws {
        let gate = SourceReadGate(limit: 1)
        guard await gate.acquire(interactive: false) else { return }  // スロットを占有して行列を作る

        let order = OrderRecorder()
        let background = Task {
            guard await gate.acquire(interactive: false) else { return }
            await order.note("background")
            await gate.release()
        }
        // sleep の運任せにせず、実際に並んだことを debugCounts で確認する
        while await gate.debugCounts().queued < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let interactive = Task {
            guard await gate.acquire(interactive: true) else { return }
            await order.note("interactive")
            await gate.release()
        }
        while await gate.debugCounts().queued < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        await gate.release()  // 占有解除 → 待ち行列が流れ始める
        _ = await (background.value, interactive.value)
        let noted = await order.values
        XCTAssertEqual(noted.first, "interactive",
                       "後から並んだ interactive が background を追い越すこと")
        XCTAssertEqual(noted.count, 2)
    }

    /// 無引数 acquire()(currentPriority 推論)版。urgent 生成タスクを
    /// userInitiated で起動する 470 修正が依拠する「優先度→レーン」写像を被覆する
    func testInferredInteractiveLaneOvertakesBackgroundQueue() async throws {
        let gate = SourceReadGate(limit: 1)
        guard await gate.acquire(interactive: false) else { return }  // スロットを占有

        let order = OrderRecorder()
        let background = Task(priority: .utility) {
            guard await gate.acquire() else { return }  // 推論 → utility なので background レーン
            await order.note("background")
            await gate.release()
        }
        while await gate.debugCounts().queued < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let interactive = Task(priority: .userInitiated) {
            guard await gate.acquire() else { return }  // 推論 → userInitiated なので interactive レーン
            await order.note("interactive")
            await gate.release()
        }
        while await gate.debugCounts().queued < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        await gate.release()
        _ = await (background.value, interactive.value)
        let noted = await order.values
        XCTAssertEqual(noted.first, "interactive",
                       "userInitiated 由来の acquire() が utility 由来を追い越すこと")
        XCTAssertEqual(noted.count, 2)
    }
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func note(_ value: String) { values.append(value) }
}
