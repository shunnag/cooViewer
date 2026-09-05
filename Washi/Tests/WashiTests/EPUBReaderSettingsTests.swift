import AppKit
import Foundation
import XCTest
@testable import Washi

final class EPUBReaderSettingsTests: XCTestCase {
    private func censusOptions(
        for settings: EPUBReaderSettings
    ) throws -> [String: Any] {
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 400, height: 400), settings: settings)
        let data = try XCTUnwrap(metrics.censusOptionsJSON.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// cooViewer-oxr.60/76: 文字倍率は root の置換 CSS ではなく
    /// setup の実行時乗数として渡し、census の同一性にも含める。
    func testFontScaleUsesRuntimeMultiplierAndChangesCensusKey() throws {
        var base = EPUBReaderSettings()
        base.fontScale = 1.0
        var scaled = base
        scaled.fontScale = 1.25

        let options = try censusOptions(for: scaled)
        XCTAssertEqual(options["fontScale"] as? Double, 1.25)
        XCTAssertFalse(
            (options["userCSS"] as? String ?? "").contains("font-size: 125%"))
        XCTAssertNotEqual(
            EPUBScreenMetrics(viewportSize: CGSize(width: 400, height: 400),
                              settings: base).cacheKey,
            EPUBScreenMetrics(viewportSize: CGSize(width: 400, height: 400),
                              settings: scaled).cacheKey)
    }

    /// cooViewer-oxr.77: 既定フォント名は書籍 CSS より前の専用ルールへ
    /// 安全にエスケープし、後置の userCSS に混ぜない。
    func testDefaultFontFamilyEscapingAndControlCharacterRejection() throws {
        var settings = EPUBReaderSettings()
        let defaultKey = EPUBScreenMetrics(
            viewportSize: CGSize(width: 400, height: 400), settings: settings).cacheKey
        settings.defaultFontFamily = #"A"B\C"#
        let familyKey = EPUBScreenMetrics(
            viewportSize: CGSize(width: 400, height: 400), settings: settings).cacheKey
        XCTAssertNotEqual(defaultKey, familyKey)
        var options = try censusOptions(for: settings)
        var css = try XCTUnwrap(options["defaultFontCSS"] as? String)
        XCTAssertTrue(css.contains(#"font-family: "A\"B\\C", serif;"#))
        XCTAssertFalse(
            (options["userCSS"] as? String ?? "").contains("font-family"))

        settings.defaultFontFamily = "A\u{0000}\nB\u{2028}C"
        options = try censusOptions(for: settings)
        css = try XCTUnwrap(options["defaultFontCSS"] as? String)
        XCTAssertTrue(css.contains(#"font-family: "ABC", serif;"#))
        XCTAssertFalse(css.unicodeScalars.contains("\u{0000}"))
        XCTAssertFalse(css.unicodeScalars.contains("\u{2028}"))
    }

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

    /// cooViewer-oxr.33: 文字組み規則は既定では出力せず、有効にした
    /// 各フィールドが census の同一性を変えることを検証する。
    func testTypographySettingsComposeLayoutCSSAndChangeCensusKey() {
        let size = CGSize(width: 400, height: 400)
        let base = EPUBReaderSettings()
        let baseCSS = base.composedUserCSS(isDark: false)
        let baseKey = EPUBScreenMetrics(
            viewportSize: size, settings: base).cacheKey
        XCTAssertFalse(baseCSS.contains("--washi-line-height-scale"))
        XCTAssertFalse(baseCSS.contains("letter-spacing:"))
        XCTAssertFalse(baseCSS.contains("margin-block-end:"))
        XCTAssertFalse(baseCSS.contains("body *:not(code)"))
        XCTAssertFalse(baseCSS.contains("rt, rp { display: none"))

        var variants: [(EPUBReaderSettings, String)] = []
        var lineHeight = base
        lineHeight.lineHeightScale = 2
        variants.append((lineHeight, "--washi-line-height-scale: 2.0"))
        var letterSpacing = base
        letterSpacing.letterSpacingEm = 0.2
        variants.append((letterSpacing,
                         "html:not(.washi-vertical) body"))
        var paragraphSpacing = base
        paragraphSpacing.paragraphSpacingEm = 0.75
        variants.append((paragraphSpacing, "margin-block-end: 0.75em"))
        var fontOverride = base
        fontOverride.fontFamilyOverride = #"Reader "Override""#
        variants.append((fontOverride,
                         #"font-family: "Reader \"Override\"", serif !important"#))
        var hidesRuby = base
        hidesRuby.hidesRuby = true
        variants.append((hidesRuby, "rt, rp { display: none !important; }"))

        for (settings, needle) in variants {
            let css = settings.composedUserCSS(isDark: false)
            XCTAssertTrue(css.contains(needle), needle)
            XCTAssertNotEqual(
                EPUBScreenMetrics(viewportSize: size, settings: settings).cacheKey,
                baseKey, needle)
        }
        XCTAssertFalse(letterSpacing.composedUserCSS(isDark: false)
            .contains("word-spacing"))
    }

    /// cooViewer-oxr.35: 型付き色が従来の CSS 文字列より優先され、
    /// ページ割り／census の同一性へ入らないことを検証する。
    func testTypedColorsTakePrecedenceWithoutChangingCensusKey() {
        var settings = EPUBReaderSettings()
        let baseKey = EPUBScreenMetrics(
            viewportSize: CGSize(width: 400, height: 400), settings: settings).cacheKey
        settings.backgroundColorCSS = "red"
        settings.textColorCSS = "blue"
        settings.backgroundColor = EPUBRGBAColor(r: 0.1, g: 0.2, b: 0.3, a: 0.4)
        settings.textColor = EPUBRGBAColor(r: 0.8, g: 0.7, b: 0.6)

        let css = settings.composedUserCSS(isDark: false)
        XCTAssertTrue(css.contains(settings.backgroundColor!.cssString))
        XCTAssertTrue(css.contains(settings.textColor!.cssString))
        XCTAssertFalse(css.contains("background-color: red"))
        XCTAssertFalse(css.contains("color: blue"))
        XCTAssertEqual(
            EPUBScreenMetrics(
                viewportSize: CGSize(width: 400, height: 400), settings: settings).cacheKey,
            baseKey)
    }

    /// cooViewer-oxr.35: 対応する hex/rgb/hsl/名前付き表記が、ネイティブ
    /// 余白にも使う同じ sRGB 成分へ解決されることを検証する。
    @MainActor
    func testParseCSSColorSupportsHexRGBHSLAndNamedColors() throws {
        let cases: [(String, EPUBRGBAColor)] = [
            ("#369", EPUBRGBAColor(r: 0.2, g: 0.4, b: 0.6)),
            ("#33669980", EPUBRGBAColor(r: 0.2, g: 0.4, b: 0.6,
                                        a: 128.0 / 255.0)),
            ("rgb(25.5, 51, 76.5)", EPUBRGBAColor(r: 0.1, g: 0.2, b: 0.3)),
            ("rgba(10%, 20%, 30%, 40%)",
             EPUBRGBAColor(r: 0.1, g: 0.2, b: 0.3, a: 0.4)),
            ("hsl(120, 100%, 25%)", EPUBRGBAColor(r: 0, g: 0.5, b: 0)),
            ("hsla(240deg 100% 50% / 0.25)",
             EPUBRGBAColor(r: 0, g: 0, b: 1, a: 0.25)),
            ("papayawhip", EPUBRGBAColor(r: 1, g: 239.0 / 255.0,
                                          b: 213.0 / 255.0)),
            ("transparent", EPUBRGBAColor(r: 0, g: 0, b: 0, a: 0)),
        ]
        for (css, expected) in cases {
            let parsed = EPUBRGBAColor(
                cgColor: try XCTUnwrap(EPUBReaderView.parseCSSColor(css), css))
            XCTAssertEqual(parsed.r, expected.r, accuracy: 0.002, css)
            XCTAssertEqual(parsed.g, expected.g, accuracy: 0.002, css)
            XCTAssertEqual(parsed.b, expected.b, accuracy: 0.002, css)
            XCTAssertEqual(parsed.a, expected.a, accuracy: 0.002, css)
        }
    }

    /// cooViewer-oxr.35: Codable の型付き色と Core Graphics 変換が
    /// 4 成分を保つことを検証する。
    @MainActor
    func testEPUBRGBAColorCodableAndCGColorRoundTrip() throws {
        let original = EPUBRGBAColor(r: 0.125, g: 0.25, b: 0.75, a: 0.625)
        let decoded = try JSONDecoder().decode(
            EPUBRGBAColor.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        let parsed = try XCTUnwrap(EPUBReaderView.parseCSSColor(original.cssString))
        let bridged = EPUBRGBAColor(cgColor: parsed)
        XCTAssertEqual(bridged.r, original.r, accuracy: 0.0001)
        XCTAssertEqual(bridged.g, original.g, accuracy: 0.0001)
        XCTAssertEqual(bridged.b, original.b, accuracy: 0.0001)
        XCTAssertEqual(bridged.a, original.a, accuracy: 0.0001)
    }

    /// cooViewer-oxr.37: 表示配慮が高コントラストと色以外のリンク識別を
    /// 加えつつ、ページ割り設定を変えないことを検証する。
    func testAccessibilityDisplayAccommodationCSS() {
        let settings = EPUBReaderSettings()
        let css = settings.composedUserCSS(
            isDark: true, increaseContrast: true,
            differentiateWithoutColor: true)
        XCTAssertTrue(css.contains("background-color: #000000 !important"))
        XCTAssertTrue(css.contains("color: #ffffff !important"))
        XCTAssertTrue(css.contains(
            "a { text-decoration: underline !important; }"))
        XCTAssertEqual(settings.layoutAffectingCSS(),
                       EPUBReaderSettings().layoutAffectingCSS())
    }

    /// cooViewer-oxr.35: readingDefault が許可した読み上げ submenu を含む
    /// 読書操作だけを残し、余分な区切りを除くことを検証する。
    @MainActor
    func testContextMenuPolicyFiltersByWKIdentifier() {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
        let inspect = NSMenuItem(title: "Inspect", action: nil, keyEquivalent: "")
        inspect.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierInspectElement")
        let speech = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        speech.identifier = NSUserInterfaceItemIdentifier(
            "WKMenuItemIdentifierSpeechMenu")
        speech.submenu = NSMenu(title: "Speech")
        speech.submenu?.addItem(withTitle: "Start", action: nil, keyEquivalent: "")
        menu.addItem(copy)
        menu.addItem(.separator())
        menu.addItem(inspect)
        menu.addItem(.separator())
        menu.addItem(speech)

        XCTAssertTrue(EPUBContextMenuPolicy.readingDefault.filter(menu))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Copy", "Speech"])
        XCTAssertFalse(menu.items.first?.isSeparatorItem ?? true)
        XCTAssertFalse(menu.items.last?.isSeparatorItem ?? true)
    }
}
