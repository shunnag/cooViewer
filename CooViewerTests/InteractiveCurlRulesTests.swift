import XCTest
@testable import cooViewer

/// カール追従の共有判定(スワイプ/マウスドラッグ共通)の検証
final class InteractiveCurlRulesTests: XCTestCase {
    func testProgressClampsAndScales() {
        XCTAssertEqual(InteractiveCurlRules.progress(for: 0), 0)
        XCTAssertEqual(InteractiveCurlRules.progress(for: 175), 0.5)
        XCTAssertEqual(InteractiveCurlRules.progress(for: -175), 0.5)  // 向きは絶対値
        XCTAssertEqual(InteractiveCurlRules.progress(for: 350), 1)
        XCTAssertEqual(InteractiveCurlRules.progress(for: 1000), 1)
    }

    func testCompletesByDeltaOrProgress() {
        // 60pt 超の移動、または進行度 0.35 超でめくり切る
        XCTAssertTrue(InteractiveCurlRules.completes(finalDelta: 61, progress: 0))
        XCTAssertTrue(InteractiveCurlRules.completes(finalDelta: -61, progress: 0))
        XCTAssertFalse(InteractiveCurlRules.completes(finalDelta: 60, progress: 0.35))
        XCTAssertTrue(InteractiveCurlRules.completes(finalDelta: 0, progress: 0.36))
    }

    func testMouseTrackingBeginsOnlyOnHorizontalRecognition() {
        XCTAssertTrue(InteractiveCurlRules.beginsMouseTracking(dx: 31, dy: 0))
        XCTAssertTrue(InteractiveCurlRules.beginsMouseTracking(dx: -31, dy: 10))
        // 30pt 以下は本判定前(クリック圏内)
        XCTAssertFalse(InteractiveCurlRules.beginsMouseTracking(dx: 30, dy: 0))
        // 垂直はカールの向きと合わないため対象外
        XCTAssertFalse(InteractiveCurlRules.beginsMouseTracking(dx: 0, dy: 40))
        // 同値は水平勝ち(認識機と同一規則)なので追従する
        XCTAssertTrue(InteractiveCurlRules.beginsMouseTracking(dx: 40, dy: 40))
    }
}
