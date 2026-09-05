import XCTest

@testable import cooViewer

final class EPUBThumbnailCacheKeyTests: XCTestCase {
    func testEffectiveThemeUsesWindowOnlyForSystemSetting() {
        XCTAssertFalse(EPUBThumbnailCacheKey.effectiveIsDark(
            theme: 0, windowIsDark: false))
        XCTAssertTrue(EPUBThumbnailCacheKey.effectiveIsDark(
            theme: 0, windowIsDark: true))
        XCTAssertFalse(EPUBThumbnailCacheKey.effectiveIsDark(
            theme: 1, windowIsDark: true))
        XCTAssertTrue(EPUBThumbnailCacheKey.effectiveIsDark(
            theme: 2, windowIsDark: false))
    }

    func testSingleBookKeySeparatesEveryRenderingConditionCombination() {
        let keys = ["metrics-a", "metrics-b"].flatMap { metricsKey in
            [false, true].flatMap { isDark in
                [false, true].map { forcesReadableColors in
                    EPUBThumbnailCacheKey.singleBook(
                        path: "/books/a.epub", totalPages: 12,
                        pagesPerScreen: 2, fontScale: 1.0,
                        pageMargins: 1, defaultFont: "",
                        metricsKey: metricsKey, isDark: isDark,
                        forcesReadableColors: forcesReadableColors)
                }
            }
        }

        XCTAssertEqual(Set(keys).count, 8)
    }

    func testFixedThemeKeyDoesNotDependOnWindowAppearance() {
        func key(theme: Int, windowIsDark: Bool) -> String {
            EPUBThumbnailCacheKey.singleBook(
                path: "/books/a.epub", totalPages: 12,
                pagesPerScreen: 2, fontScale: 1.0,
                pageMargins: 1, defaultFont: "",
                metricsKey: "metrics-a",
                isDark: EPUBThumbnailCacheKey.effectiveIsDark(
                    theme: theme, windowIsDark: windowIsDark),
                forcesReadableColors: true)
        }

        XCTAssertEqual(key(theme: 1, windowIsDark: false),
                       key(theme: 1, windowIsDark: true))
        XCTAssertEqual(key(theme: 2, windowIsDark: false),
                       key(theme: 2, windowIsDark: true))
        XCTAssertNotEqual(key(theme: 0, windowIsDark: false),
                          key(theme: 0, windowIsDark: true))
    }
}
