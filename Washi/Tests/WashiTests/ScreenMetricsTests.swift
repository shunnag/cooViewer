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

    /// 見開き専用の余白(spreadInsets)がモードに応じて使い分けられる
    func testSpreadInsetsPerMode() {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(top: 10, left: 20, bottom: 10, right: 20)
        settings.spreadInsets = EPUBReaderInsets(top: 10, left: 100,
                                                 bottom: 10, right: 100)
        // 広い(見開き): spreadInsets(左右 100)で内容幅が決まる
        let wide = EPUBScreenMetrics(
            viewportSize: CGSize(width: 1400, height: 1000), settings: settings)
        XCTAssertEqual(wide.pagesPerScreen, 2)
        XCTAssertEqual(wide.contentSize.width, 1400 - 200, accuracy: 0.5)
        // 狭い(単ページ): 基準 insets(左右 20)
        let narrow = EPUBScreenMetrics(
            viewportSize: CGSize(width: 400, height: 1000), settings: settings)
        XCTAssertEqual(narrow.pagesPerScreen, 1)
        XCTAssertEqual(narrow.contentSize.width, 400 - 40, accuracy: 0.5)
    }

    /// spreadInsets 未設定なら見開きも insets を使う(従来互換)
    func testSpreadInsetsFallsBackToInsets() {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(top: 10, left: 30, bottom: 10, right: 30)
        settings.spreadInsets = nil
        let wide = EPUBScreenMetrics(
            viewportSize: CGSize(width: 1400, height: 1000), settings: settings)
        XCTAssertEqual(wide.pagesPerScreen, 2)
        XCTAssertEqual(wide.contentSize.width, 1400 - 60, accuracy: 0.5)
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
