import XCTest

@testable import cooViewer

/// SourceReadGate の優先レーンのテスト。
/// サムネイルの可視セル要求(urgent)が、見えない画面の先読みの行列を
/// 追い越して先に生成へ入れることの根拠(cooViewer-19t)。
final class SourceReadGateTests: XCTestCase {
    func testInteractiveLaneOvertakesBackgroundQueue() async throws {
        let gate = SourceReadGate(limit: 1)
        await gate.acquire(interactive: false)  // スロットを占有して行列を作る

        let order = OrderRecorder()
        let background = Task {
            await gate.acquire(interactive: false)
            await order.note("background")
            await gate.release()
        }
        // sleep の運任せにせず、実際に並んだことを debugCounts で確認する
        while await gate.debugCounts().queued < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let interactive = Task {
            await gate.acquire(interactive: true)
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
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func note(_ value: String) { values.append(value) }
}
