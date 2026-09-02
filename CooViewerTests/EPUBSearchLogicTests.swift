import XCTest

@testable import cooViewer

/// リフロー EPUB 本文検索の近似位置・順序・巡回・件数制限。
@MainActor
final class EPUBSearchLogicTests: XCTestCase {
    func testProgressionUsesCharacterOffsetAndClampsToUnitRange() {
        XCTAssertEqual(EPUBSearchLogic.progression(
            characterOffset: 25, itemTextLength: 100), 0.25)
        XCTAssertEqual(EPUBSearchLogic.progression(
            characterOffset: -1, itemTextLength: 100), 0)
        XCTAssertEqual(EPUBSearchLogic.progression(
            characterOffset: 120, itemTextLength: 100), 1)
        XCTAssertEqual(EPUBSearchLogic.progression(
            characterOffset: 1, itemTextLength: 0), 1)
    }

    func testLimitPreservesBackendReadingOrder() {
        let values = ["spine2", "spine0", "spine1"]
        let result = EPUBSearchLogic.limited(values, limit: 2)
        XCTAssertEqual(result.values, ["spine2", "spine0"])
        XCTAssertTrue(result.isTruncated)
    }

    func testFiveHundredHitsIsExactAndOverflowIsTruncated() {
        let exact = EPUBSearchLogic.limited(Array(0..<500))
        XCTAssertEqual(exact.values.count, 500)
        XCTAssertFalse(exact.isTruncated)

        let overflow = EPUBSearchLogic.limited(Array(0..<501))
        XCTAssertEqual(overflow.values.count, 500)
        XCTAssertTrue(overflow.isTruncated)
    }

    func testNextAndPreviousWrapAround() {
        XCTAssertEqual(EPUBSearchLogic.selectionIndex(
            current: nil, count: 3, forward: true), 0)
        XCTAssertEqual(EPUBSearchLogic.selectionIndex(
            current: nil, count: 3, forward: false), 2)
        XCTAssertEqual(EPUBSearchLogic.selectionIndex(
            current: 2, count: 3, forward: true), 0)
        XCTAssertEqual(EPUBSearchLogic.selectionIndex(
            current: 0, count: 3, forward: false), 2)
        XCTAssertNil(EPUBSearchLogic.selectionIndex(
            current: nil, count: 0, forward: true))
    }
}
