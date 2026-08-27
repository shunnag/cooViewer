import AppKit
import XCTest
@testable import Washi

/// めくりカバーのライフサイクル(孤児回収・所有権・時間切れ)を、実 WKWebView を
/// 使わず直接検証する。foldTurnCover が唯一の回収経路であることに依拠。
@MainActor
final class TurnCoverLifecycleTests: XCTestCase {
    private func makeView() -> EPUBReaderView {
        EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    }

    private func makeCover() -> NSImageView {
        NSImageView(image: NSImage(size: NSSize(width: 10, height: 10)))
    }

    func testFoldRemovesOrphanKeepsPending() {
        let view = makeView()
        let coverA = makeCover()
        let coverB = makeCover()
        view.installTurnCover(coverA, pending: false)  // 孤児
        view.installTurnCover(coverB, pending: true)   // 現 pending
        view.foldTurnCover(coverA)
        XCTAssertNil(coverA.superview)
        XCTAssertFalse(view.turnOverlays.contains { $0 === coverA })
        XCTAssertTrue(view.turnOverlays.contains { $0 === coverB })
        XCTAssertTrue(view.pendingSpineTurn?.cover === coverB)  // pending は壊さない
        XCTAssertTrue(view.furnitureSuppressed)  // B が残るので抑制継続
    }

    func testFoldClearsPendingWhenCoverIsPending() {
        let view = makeView()
        let a = makeCover()
        view.installTurnCover(a, pending: true)
        view.foldTurnCover(a)
        XCTAssertNil(view.pendingSpineTurn)
        XCTAssertTrue(view.turnOverlays.isEmpty)
        XCTAssertFalse(view.furnitureSuppressed)
    }

    func testTimeoutReclaimsOrphan() async {
        let view = makeView()
        let a = makeCover()
        view.installTurnCover(a, pending: false)  // 孤児(pending でない)
        view.scheduleSpineTurnTimeout(for: a, after: .milliseconds(30))
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertNil(a.superview, "所有権を失った孤児も時間切れで回収される")
        XCTAssertFalse(view.turnOverlays.contains { $0 === a })
    }

    func testTimeoutCancelledDoesNotYankAnimatingCover() async {
        let view = makeView()
        let a = makeCover()
        view.installTurnCover(a, pending: false)
        view.scheduleSpineTurnTimeout(for: a, after: .milliseconds(30))
        // runTurnEffect 冒頭のキャンセルを模擬(演出中に引き剥がされないこと)
        view.spineTurnTimeouts[ObjectIdentifier(a)]?.cancel()
        view.spineTurnTimeouts[ObjectIdentifier(a)] = nil
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(view.turnOverlays.contains { $0 === a }, "演出中はカバーが残る")
    }

    func testFoldCancelsTimeout() async {
        let view = makeView()
        let a = makeCover()
        view.installTurnCover(a, pending: false)
        view.scheduleSpineTurnTimeout(for: a, after: .seconds(10))
        view.foldTurnCover(a)
        XCTAssertNil(view.spineTurnTimeouts[ObjectIdentifier(a)])  // 二重回収なし
        XCTAssertNil(a.superview)
    }
}
