import XCTest
@testable import Washi

final class EPUBReaderSettingsTests: XCTestCase {
    // cooViewer-oxr.4: 両テーマ・両方針と、明示文字色による既存の方針無効化を検証する。
    func testComposedUserCSSThemeRules() {
        let backgroundRule = "body, body *:not(img):not(svg):not(image):not(video):not(canvas) { background-color: transparent !important; }"
        let textSelector = "body, body *:not(a):not(a *):not(pre):not(code):not(pre *):not(code *)"
        let codeRule = "body :is(pre, code):not(img):not(svg):not(image):not(video):not(canvas) { background-color: #242426 !important; }"
        for isDark in [false, true] {
            for forcesReadable in [false, true] {
                for explicitColor: String? in [nil, "#123456"] {
                    var settings = EPUBReaderSettings()
                    settings.forcesReadableColors = forcesReadable
                    settings.textColorCSS = explicitColor
                    settings.userCSS = "p { font-style: italic; }"
                    let css = settings.composedUserCSS(isDark: isDark)
                    let readable = forcesReadable && explicitColor == nil
                    let context = "dark=\(isDark), readable=\(forcesReadable), explicit=\(explicitColor ?? "nil")"
                    XCTAssertTrue(css.contains("html { background-color: \(isDark ? "#1a1a1c" : "#ffffff") !important; }"), context)
                    XCTAssertEqual(css.contains(backgroundRule), readable, context)
                    XCTAssertEqual(css.contains("body { background-color: transparent !important; }"), !readable && isDark, context)
                    // cooViewer-oxr.4: ライトで本の配色を尊重するときは背景を透明化しない。
                    XCTAssertEqual(css.contains("background-color: transparent"), readable || isDark, context)
                    XCTAssertEqual(css.contains(textSelector), readable, context)
                    XCTAssertEqual(css.contains(codeRule), readable && isDark, context)
                    XCTAssertFalse(css.contains("body *:not(a) { color:"), context)
                    if readable {
                        XCTAssertTrue(css.contains("\(textSelector) { color: \(isDark ? "#ececec" : "#1a1a1a") !important; }"), context)
                        XCTAssertTrue(css.contains("a { color: \(isDark ? "#7fb2ff" : "#1a56db") !important; }"), context)
                    }
                    if let explicitColor {
                        XCTAssertTrue(css.contains("body { color: \(explicitColor); }"), context)
                    }
                    XCTAssertTrue(css.hasSuffix(settings.userCSS!), context)
                }
            }
        }
    }
}
