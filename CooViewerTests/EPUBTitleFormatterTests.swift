import Washi
import XCTest

@testable import cooViewer

/// EPUB 書名の bidi isolate 整形(cooViewer-oxr.52、設計書 §2.4)。
final class EPUBTitleFormatterTests: XCTestCase {
    func testExplicitRTLUsesRightToLeftIsolate() {
        XCTAssertEqual(
            EPUBTitleFormatter.windowTitle("ספר", direction: .rtl),
            "\u{2067}ספר\u{2069}")
    }

    func testExplicitLTRUsesLeftToRightIsolate() {
        XCTAssertEqual(
            EPUBTitleFormatter.windowTitle("Book 12", direction: .ltr),
            "\u{2066}Book 12\u{2069}")
    }

    func testAutoWithStrongRTLUsesFirstStrongIsolate() {
        XCTAssertEqual(
            EPUBTitleFormatter.windowTitle("كتاب 12", direction: .auto),
            "\u{2068}كتاب 12\u{2069}")
    }

    func testNilDirectionWithStrongRTLUsesFirstStrongIsolate() {
        XCTAssertEqual(
            EPUBTitleFormatter.windowTitle("第2巻 ספר", direction: nil),
            "\u{2068}第2巻 ספר\u{2069}")
    }

    func testAutoAndNilLeaveTitlesWithoutStrongRTLUnchanged() {
        XCTAssertEqual(
            EPUBTitleFormatter.windowTitle("第2巻 Book", direction: .auto),
            "第2巻 Book")
        XCTAssertEqual(
            EPUBTitleFormatter.windowTitle("第2巻 Book", direction: nil),
            "第2巻 Book")
    }

    func testAutoUsesUnicodeBidiClassRatherThanScriptRanges() {
        // U+200F RIGHT-TO-LEFT MARK は文字ではないが強い R。
        XCTAssertEqual(
            EPUBTitleFormatter.windowTitle("\u{200F}12", direction: .auto),
            "\u{2068}\u{200F}12\u{2069}")
        // U+064E ARABIC FATHA は Arabic ブロック内でも NSM。
        XCTAssertEqual(
            EPUBTitleFormatter.windowTitle("\u{064E}12", direction: .auto),
            "\u{064E}12")
    }
}
