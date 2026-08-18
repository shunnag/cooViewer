import XCTest
@testable import cooViewer

/// ドラッグジェスチャ HUD の状態導出の検証(設計書 §7.6)
final class GestureHUDModelTests: XCTestCase {
    func testUnderTenPointsIsHidden() {
        XCTAssertEqual(GestureHUDModel.state(dx: 5, dy: 5, elapsed: 0.2), .hidden)
        XCTAssertEqual(GestureHUDModel.state(dx: 10, dy: 0, elapsed: 0.2), .hidden)
    }

    func testBetweenThresholdsIsFaint() {
        XCTAssertEqual(GestureHUDModel.state(dx: 20, dy: 0, elapsed: 0.2),
                       .faint(direction: LegacyModifier.dragRight))
        XCTAssertEqual(GestureHUDModel.state(dx: 0, dy: -20, elapsed: 0.2),
                       .faint(direction: LegacyModifier.dragUp))
        // ちょうど 30 は本判定(>30)に届かず薄表示のまま
        XCTAssertEqual(GestureHUDModel.state(dx: 30, dy: 0, elapsed: 0.2),
                       .faint(direction: LegacyModifier.dragRight))
    }

    func testOverThresholdIsArmed() {
        XCTAssertEqual(GestureHUDModel.state(dx: -31, dy: 0, elapsed: 0.2),
                       .armed(direction: LegacyModifier.dragLeft))
        XCTAssertEqual(GestureHUDModel.state(dx: 0, dy: 40, elapsed: 0.2),
                       .armed(direction: LegacyModifier.dragDown))
    }

    func testArmedUsesSameTieBreakAsRecognizer() {
        // 同値は水平勝ち(MouseGestureRecognizer.dragDirection と同一規則)
        XCTAssertEqual(GestureHUDModel.state(dx: 40, dy: 40, elapsed: 0.2),
                       .armed(direction: LegacyModifier.dragRight))
    }

    func testOverOneSecondIsExpired() {
        // 1 秒超過は移動量に関わらず「離しても発火しない」予告(仕様書 §5.9)
        XCTAssertEqual(GestureHUDModel.state(dx: 100, dy: 0, elapsed: 1.01), .expired)
        XCTAssertEqual(GestureHUDModel.state(dx: 0, dy: 0, elapsed: 1.01), .expired)
    }

    func testProvisionalDirectionPrefersDominantAxis() {
        XCTAssertEqual(GestureHUDModel.provisionalDirection(dx: 12, dy: -20),
                       LegacyModifier.dragUp)
        XCTAssertEqual(GestureHUDModel.provisionalDirection(dx: 20, dy: 12),
                       LegacyModifier.dragRight)
        XCTAssertNil(GestureHUDModel.provisionalDirection(dx: 8, dy: 8))
    }

    func testSymbolNames() {
        XCTAssertEqual(GestureHUDModel.symbolName(for: LegacyModifier.dragLeft),
                       "arrow.left")
        XCTAssertEqual(GestureHUDModel.symbolName(for: LegacyModifier.dragDown),
                       "arrow.down")
    }
}
