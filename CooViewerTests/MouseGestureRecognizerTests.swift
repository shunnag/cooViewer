import XCTest
@testable import cooViewer

/// マウス状態機械の境界値検証(仕様書 §5.9 / 旧 CustomImageView.m:141-258)
final class MouseGestureRecognizerTests: XCTestCase {
    private var recognizer = MouseGestureRecognizer()

    /// begin→finish を一括で行うヘルパ(点は始点 (100,100) からの変位で指定)
    private func classify(dx: CGFloat, dy: CGFloat, duration: TimeInterval = 0.2,
                          button: Int = 0, modifiers: Int = 0,
                          dragScroll: Bool = false,
                          scrolled: Bool = false) -> MouseGestureRecognizer.Outcome {
        recognizer.begin(button: button, point: CGPoint(x: 100, y: 100),
                         time: 10, dragScroll: dragScroll)
        if scrolled { recognizer.noteDragScrolled() }
        return recognizer.finish(point: CGPoint(x: 100 + dx, y: 100 + dy),
                                 time: 10 + duration, modifiers: modifiers)
    }

    // MARK: - クリック/ジェスチャの 30pt 境界(厳密 >30。旧 CustomImageView.m:199)

    func testSmallMoveIsClick() {
        XCTAssertEqual(classify(dx: 5, dy: 5),
                       .click(button: 0, modifiers: 0))
    }

    func testExactly30ptIsClick() {
        XCTAssertEqual(classify(dx: 30, dy: 0),
                       .click(button: 0, modifiers: 0))
    }

    func test31ptIsGesture() {
        XCTAssertEqual(
            classify(dx: 31, dy: 0),
            .dragGesture(directionModifier: LegacyModifier.dragRight,
                         baseModifiers: 0, button: 0))
    }

    // MARK: - 方向判定(flipped 座標: dy<0=上)

    func testFourDirections() {
        XCTAssertEqual(MouseGestureRecognizer.dragDirection(dx: -40, dy: 0),
                       LegacyModifier.dragLeft)
        XCTAssertEqual(MouseGestureRecognizer.dragDirection(dx: 40, dy: 0),
                       LegacyModifier.dragRight)
        XCTAssertEqual(MouseGestureRecognizer.dragDirection(dx: 0, dy: -40),
                       LegacyModifier.dragUp)
        XCTAssertEqual(MouseGestureRecognizer.dragDirection(dx: 0, dy: 40),
                       LegacyModifier.dragDown)
    }

    func testTieGoesHorizontal() {
        // 同値は水平勝ち(旧 ud>lr の厳密比較)
        XCTAssertEqual(MouseGestureRecognizer.dragDirection(dx: 40, dy: 40),
                       LegacyModifier.dragRight)
    }

    func testLargerAxisWinsWhenBothExceed() {
        XCTAssertEqual(MouseGestureRecognizer.dragDirection(dx: 40, dy: 50),
                       LegacyModifier.dragDown)
        XCTAssertEqual(MouseGestureRecognizer.dragDirection(dx: 50, dy: 40),
                       LegacyModifier.dragRight)
    }

    func testSubThresholdAxisIsIgnored() {
        // 30 以下の軸は候補にならない: |dy|=40 のみ有効 → 垂直
        XCTAssertEqual(MouseGestureRecognizer.dragDirection(dx: 25, dy: -40),
                       LegacyModifier.dragUp)
    }

    // MARK: - 1 秒長押しキャンセル(仕様書 §5.9)

    func testLongPressCancelsClick() {
        XCTAssertEqual(classify(dx: 0, dy: 0, duration: 1.01), .none)
    }

    func testLongPressCancelsGesture() {
        XCTAssertEqual(classify(dx: 100, dy: 0, duration: 1.01), .none)
    }

    func testJustUnderOneSecondFires() {
        XCTAssertEqual(classify(dx: 0, dy: 0, duration: 0.99),
                       .click(button: 0, modifiers: 0))
    }

    // MARK: - DragScroll 排他(仕様書 §5.7.5)

    func testDragScrolledSuppressesClickAndGesture() {
        XCTAssertEqual(classify(dx: 100, dy: 0, dragScroll: true, scrolled: true), .none)
    }

    func testDragScrollWithoutMovementFallsBackToClick() {
        // inDragScroll でも一度も動かさなければクリック扱い(旧の癖)
        XCTAssertEqual(classify(dx: 0, dy: 0, dragScroll: true),
                       .click(button: 0, modifiers: 0))
    }

    func testIsDragScrollingResetsAfterFinish() {
        _ = classify(dx: 0, dy: 0, dragScroll: true, scrolled: true)
        XCTAssertFalse(recognizer.isDragScrolling)
    }

    // MARK: - ボタン・修飾キーの伝搬(右/中ボタンも同一規則。仕様書 §5.9)

    func testRightButtonDragGestureCarriesButton() {
        XCTAssertEqual(
            classify(dx: -50, dy: 0, button: 1, modifiers: LegacyModifier.shift),
            .dragGesture(directionModifier: LegacyModifier.dragLeft,
                         baseModifiers: LegacyModifier.shift, button: 1))
    }

    func testMiddleButtonClickCarriesButtonAndModifiers() {
        XCTAssertEqual(
            classify(dx: 0, dy: 0, button: 2, modifiers: LegacyModifier.control),
            .click(button: 2, modifiers: LegacyModifier.control))
    }

    func testFinishWithoutBeginIsNone() {
        XCTAssertEqual(recognizer.finish(point: .zero, time: 0, modifiers: 0), .none)
    }

    // MARK: - Force click の抑止(設計書 §2.4: ルーペトグルとの二重発火防止)

    func testForceClickSuppressesClickAndGesture() {
        recognizer.begin(button: 0, point: .zero, time: 10, dragScroll: false)
        recognizer.noteForceClick()
        XCTAssertEqual(recognizer.finish(point: .zero, time: 10.2, modifiers: 0), .none)
        // 次の押下では旗がリセットされ通常どおり発火する
        XCTAssertEqual(classify(dx: 0, dy: 0), .click(button: 0, modifiers: 0))
    }
}
