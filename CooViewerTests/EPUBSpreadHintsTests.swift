import Washi
import XCTest

@testable import cooViewer

/// page-spread の規範的な組み合わせ判定
/// (cooViewer-oxr.40、仕様書 §4.2.1)。
final class EPUBSpreadHintsTests: XCTestCase {
    func testRTLMismatchedLeadingAndCenterAreSingle() {
        let slots: [PageSpreadSlot?] = [
            .left, .right, .left, .right, .left, .center, .right, .left,
        ]
        XCTAssertEqual(
            EPUBSpreadHints.singleIndices(slots: slots, readingDirection: .rtl),
            [0, 5])
    }

    func testLTRUsesLeftThenRightAsDeclaredPair() {
        let slots: [PageSpreadSlot?] = [.right, .left, .right, .left]
        XCTAssertEqual(
            EPUBSpreadHints.singleIndices(slots: slots, readingDirection: .ltr),
            [0])
    }

    func testRTLPairsRightThenLeft() {
        let slots: [PageSpreadSlot?] = [.right, .left, .right, .left]
        XCTAssertEqual(
            EPUBSpreadHints.singleIndices(slots: slots, readingDirection: .rtl),
            [])
    }

    func testUnspecifiedPageDoesNotBreakFollowingDeclaredPair() {
        let slots: [PageSpreadSlot?] = [nil, .right, .left]
        XCTAssertEqual(
            EPUBSpreadHints.singleIndices(slots: slots, readingDirection: .rtl),
            [])
    }
}
