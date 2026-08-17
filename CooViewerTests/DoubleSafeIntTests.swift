import XCTest
@testable import cooViewer

final class DoubleSafeIntTests: XCTestCase {
    func testFiniteInRangeConverts() {
        XCTAssertEqual((0.0).safeInt, 0)
        XCTAssertEqual((5.0).safeInt, 5)
        XCTAssertEqual((-3.0).safeInt, -3)
        XCTAssertEqual((5.9).safeInt, 5)     // 切り捨て(Int(Double) と同じ)
        XCTAssertEqual((-5.9).safeInt, -5)
    }

    func testNonFiniteReturnsNil() {
        XCTAssertNil(Double.infinity.safeInt)
        XCTAssertNil((-Double.infinity).safeInt)
        XCTAssertNil(Double.nan.safeInt)
    }

    func testOutOfIntRangeReturnsNil() {
        // これらは Int(Double) だと「cannot be converted」でトラップする値
        XCTAssertNil((1e300).safeInt)
        XCTAssertNil((-1e300).safeInt)
        XCTAssertNil((9.5e18).safeInt)       // > 内側境界(9.0e18)
        XCTAssertNil(Double(Int.max).safeInt) // 2^63 は Int.max を超える
    }

    func testNearBoundaryStillConverts() {
        XCTAssertEqual((1_000_000.0).safeInt, 1_000_000)
        XCTAssertNotNil((8.9e18).safeInt)    // 内側境界内は変換できる
    }
}
