import XCTest
@testable import cooViewer

/// EPUB の 2 本指水平スクロール状態機械の境界値検証。
final class EPUBScrollGestureRecognizerTests: XCTestCase {
    private var recognizer = EPUBScrollGestureRecognizer()

    func testVerticalGestureAlwaysPassesThrough() {
        XCTAssertEqual(
            recognizer.feed(deltaX: 4, deltaY: 10, precise: true,
                            timestamp: 1, interceptHorizontalIfNew: true),
            .passThrough)
        XCTAssertEqual(
            recognizer.feed(deltaX: 100, deltaY: 0, precise: true,
                            timestamp: 1.1, interceptHorizontalIfNew: true),
            .passThrough)
    }

    func testHorizontalGestureWithoutInterceptAlwaysPassesThrough() {
        XCTAssertEqual(
            recognizer.feed(deltaX: 40, deltaY: 0, precise: true,
                            timestamp: 1, interceptHorizontalIfNew: false),
            .passThrough)
        XCTAssertEqual(
            recognizer.feed(deltaX: 40, deltaY: 0, precise: true,
                            timestamp: 1.1, interceptHorizontalIfNew: true),
            .passThrough)
    }

    func testPreciseHorizontalGestureTurnsOnceAtThreshold() {
        XCTAssertEqual(
            recognizer.feed(deltaX: 20, deltaY: 0, precise: true,
                            timestamp: 1, interceptHorizontalIfNew: true),
            .consume)
        XCTAssertEqual(
            recognizer.feed(deltaX: 29, deltaY: 0, precise: true,
                            timestamp: 1.1, interceptHorizontalIfNew: true),
            .consume)
        XCTAssertEqual(
            recognizer.feed(deltaX: 1, deltaY: 0, precise: true,
                            timestamp: 1.2, interceptHorizontalIfNew: true),
            .turn(positive: true))
        XCTAssertEqual(
            recognizer.feed(deltaX: 100, deltaY: 0, precise: true,
                            timestamp: 1.3, interceptHorizontalIfNew: true),
            .consume)
    }

    func testNegativeDeltaTurnsNegative() {
        XCTAssertEqual(
            recognizer.feed(deltaX: -50, deltaY: 0, precise: true,
                            timestamp: 1, interceptHorizontalIfNew: true),
            .turn(positive: false))
    }

    func testImpreciseDeltaUsesFortyTimesScale() {
        XCTAssertEqual(
            recognizer.feed(deltaX: 1, deltaY: 0, precise: false,
                            timestamp: 1, interceptHorizontalIfNew: true),
            .consume)
        XCTAssertEqual(
            recognizer.feed(deltaX: 1, deltaY: 0, precise: false,
                            timestamp: 1.1, interceptHorizontalIfNew: true),
            .turn(positive: true))
    }

    func testQuietPeriodReevaluatesAxis() {
        XCTAssertEqual(
            recognizer.feed(deltaX: 0, deltaY: 50, precise: true,
                            timestamp: 1, interceptHorizontalIfNew: true),
            .passThrough)
        XCTAssertEqual(
            recognizer.feed(deltaX: 50, deltaY: 0, precise: true,
                            timestamp: 1.3, interceptHorizontalIfNew: true),
            .turn(positive: true))
    }

    func testQuietPeriodReevaluatesIntercept() {
        XCTAssertEqual(
            recognizer.feed(deltaX: 50, deltaY: 0, precise: true,
                            timestamp: 1, interceptHorizontalIfNew: false),
            .passThrough)
        XCTAssertEqual(
            recognizer.feed(deltaX: 50, deltaY: 0, precise: true,
                            timestamp: 1.1, interceptHorizontalIfNew: true),
            .passThrough)
        XCTAssertEqual(
            recognizer.feed(deltaX: 50, deltaY: 0, precise: true,
                            timestamp: 1.4, interceptHorizontalIfNew: true),
            .turn(positive: true))
    }
}
