import XCTest
@testable import Washi
@testable import WashiCore

/// 見開き判定(usesSpread)の検証
final class ScreenMetricsTests: XCTestCase {
    func testColumnModeAndWidth() {
        // 明示 single/double は幅によらず固定
        XCTAssertFalse(EPUBScreenMetrics.usesSpread(
            contentWidth: 2000, columnMode: .single))
        XCTAssertTrue(EPUBScreenMetrics.usesSpread(
            contentWidth: 400, columnMode: .double))
        // auto はウインドウ幅で判定(閾値 700)
        XCTAssertTrue(EPUBScreenMetrics.usesSpread(
            contentWidth: 1400, columnMode: .auto))
        XCTAssertFalse(EPUBScreenMetrics.usesSpread(
            contentWidth: 400, columnMode: .auto))
    }

    /// cacheKey は spread の違い(pagesPerScreen)を反映する
    func testCacheKeyReflectsSpread() {
        let settings = EPUBReaderSettings()
        let wide = EPUBScreenMetrics(
            viewportSize: CGSize(width: 1400, height: 1000), settings: settings)
        let narrow = EPUBScreenMetrics(
            viewportSize: CGSize(width: 400, height: 1000), settings: settings)
        XCTAssertEqual(wide.pagesPerScreen, 2)
        XCTAssertEqual(narrow.pagesPerScreen, 1)
        XCTAssertNotEqual(wide.cacheKey, narrow.cacheKey)
    }
}
