import Foundation
import XCTest
@testable import Washi

@MainActor
final class EPUBSchemeHandlerTests: XCTestCase {
    /// Shift_JIS 宣言を UTF-8 で上書きせず、宣言値をレスポンスへ渡す
    func testContentTypeUsesDeclaredShiftJIS() throws {
        let source = """
        <?xml version="1.0" encoding="Shift_JIS"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>日本語</body></html>
        """
        let data = try XCTUnwrap(source.data(using: .shiftJIS))
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(
                for: EPUBMediaType.xhtml, data: data).lowercased(),
            "application/xhtml+xml; charset=shift_jis")
    }

    /// 宣言なし UTF-8 は charset を強制せず、XML の既定 UTF-8 判定に任せる
    func testContentTypeLeavesUndeclaredUTF8Unqualified() {
        let data = Data(
            #"<html xmlns="http://www.w3.org/1999/xhtml"><body>日本語</body></html>"#.utf8)
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: EPUBMediaType.xhtml, data: data),
            EPUBMediaType.xhtml)
    }

    /// HTML の meta charset 宣言もレスポンスの charset として採用する
    func testContentTypeUsesHTMLMetaCharset() {
        let direct = Data(
            #"<!doctype html><html><head><meta charset="windows-31j"></head></html>"#.utf8)
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: "text/html", data: direct),
            "text/html; charset=windows-31j")

        let httpEquiv = Data(
            #"<html><head><meta content="text/html; charset=Shift_JIS" http-equiv="Content-Type"></head></html>"#.utf8)
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: "text/html", data: httpEquiv),
            "text/html; charset=Shift_JIS")
    }
}
