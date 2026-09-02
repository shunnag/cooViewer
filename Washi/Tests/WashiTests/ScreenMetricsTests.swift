import XCTest
@testable import Washi
@testable import WashiCore

/// 見開き判定(usesSpread)の検証
final class ScreenMetricsTests: XCTestCase {
    func testColumnModeRenditionSpreadWidthAndOrientationTruthTable() {
        let modes: [EPUBColumnMode] = [.single, .double, .auto]
        let spreads: [RenditionSpread] = [.auto, .none, .landscape, .both]
        let widths = [CGFloat(699), 700]
        let orientations = [false, true]

        for mode in modes {
            for spread in spreads {
                for width in widths {
                    for isLandscape in orientations {
                        let expected: Bool
                        switch mode {
                        case .single:
                            expected = false
                        case .double:
                            expected = true
                        case .auto:
                            switch spread {
                            case .auto:
                                expected = width >= 700
                            case .none:
                                expected = false
                            case .landscape:
                                expected = isLandscape && width >= 700
                            case .both:
                                expected = true
                            }
                        }
                        XCTAssertEqual(
                            EPUBScreenMetrics.usesSpread(
                                contentWidth: width, columnMode: mode,
                                renditionSpread: spread,
                                isLandscapeViewport: isLandscape),
                            expected,
                            "mode=\(mode.rawValue), spread=\(spread.rawValue), width=\(width), landscape=\(isLandscape)")
                    }
                }
            }
        }
    }

    func testPlansSpreadUsesBaseInsetsAndViewportOrientation() {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(top: 10, left: 30,
                                           bottom: 10, right: 30)
        XCTAssertTrue(EPUBScreenMetrics.plansSpread(
            viewportSize: CGSize(width: 760, height: 500), settings: settings,
            renditionSpread: .landscape))
        XCTAssertFalse(EPUBScreenMetrics.plansSpread(
            viewportSize: CGSize(width: 760, height: 900), settings: settings,
            renditionSpread: .landscape))
        XCTAssertFalse(EPUBScreenMetrics.plansSpread(
            viewportSize: CGSize(width: 759, height: 500), settings: settings,
            renditionSpread: .landscape))
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

    func testApplyingRenditionSpreadPreservesAutoAndDerivesOtherModes() {
        var settings = EPUBReaderSettings()
        settings.fontScale = 1.25
        settings.pageGap = 31
        settings.insets = EPUBReaderInsets(top: 12, left: 20,
                                           bottom: 14, right: 20)
        settings.spreadInsets = EPUBReaderInsets(top: 16, left: 40,
                                                 bottom: 18, right: 40)
        settings.defaultFontFamily = "Hiragino Mincho ProN"
        settings.userCSS = "p { letter-spacing: 0.1em; }"

        let narrowSize = CGSize(width: 650, height: 900)
        let narrow = EPUBScreenMetrics(
            viewportSize: narrowSize, settings: settings)
        let auto = narrow.applyingRenditionSpread(.auto)
        let both = narrow.applyingRenditionSpread(.both)
        XCTAssertEqual(auto.cacheKey, narrow.cacheKey)
        XCTAssertEqual(auto, narrow)
        XCTAssertEqual(narrow.pagesPerScreen, 1)
        XCTAssertEqual(both.pagesPerScreen, 2)
        XCTAssertNotEqual(both.cacheKey, narrow.cacheKey)
        XCTAssertEqual(
            both,
            EPUBScreenMetrics(viewportSize: narrowSize, settings: settings,
                              renditionSpread: .both))

        let wideSize = CGSize(width: 900, height: 600)
        let wide = EPUBScreenMetrics(viewportSize: wideSize, settings: settings)
        let none = wide.applyingRenditionSpread(.none)
        XCTAssertEqual(wide.pagesPerScreen, 2)
        XCTAssertEqual(none.pagesPerScreen, 1)
        XCTAssertNotEqual(none.cacheKey, wide.cacheKey)

        let portrait = EPUBScreenMetrics(
            viewportSize: CGSize(width: 900, height: 1200), settings: settings)
            .applyingRenditionSpread(.landscape)
        let landscape = EPUBScreenMetrics(
            viewportSize: wideSize, settings: settings)
            .applyingRenditionSpread(.landscape)
        XCTAssertEqual(portrait.pagesPerScreen, 1)
        XCTAssertEqual(landscape.pagesPerScreen, 2)
    }
}
