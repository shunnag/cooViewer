import Foundation
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

@MainActor
final class EPUBSchemeHandlerTests: XCTestCase {
    /// cooViewer-oxr.15: 画像 spine の予約 URL は、body が元画像 1 枚だけの
    /// XHTML main resource を応答する。
    func testImageSpineURLServesSynthesizedWrapperResponse() async throws {
        let publication = try Self.makeImageSpinePublication()
        let handler = EPUBSchemeHandler(publication: publication)
        let entry = try XCTUnwrap(publication.readingOrder.first)
        let url = try XCTUnwrap(handler.url(forReadingOrderItem: entry))
        XCTAssertTrue(EPUBSchemeHandler.isImageWrapperURL(url))

        let finished = expectation(description: "wrapper response finished")
        let task = RecordingSchemeTask(request: URLRequest(url: url)) {
            finished.fulfill()
        }
        handler.webView(WKWebView(frame: .zero), start: task)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertNil(task.failure)
        XCTAssertEqual(task.response?.mimeType, EPUBMediaType.xhtml)
        let source = try XCTUnwrap(String(data: task.receivedData,
                                          encoding: .utf8))
        XCTAssertTrue(source.contains("<body><img "))
        XCTAssertTrue(source.contains("OEBPS/images/page.png"))
    }

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

    /// cooViewer-oxr.12: UTF-8 ではない HTML の meta charset 宣言を採用する。
    func testContentTypeUsesHTMLMetaCharset() throws {
        let cp932 = try XCTUnwrap(
            XMLCharsetDetector.encoding(forCharsetName: "CP932"))
        let direct = try XCTUnwrap(
            #"<!doctype html><html><head><meta charset="windows-31j"></head><body>髙</body></html>"#
                .data(using: cp932))
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: "text/html", data: direct),
            "text/html; charset=windows-31j")

        let httpEquiv = try XCTUnwrap(
            #"<html><head><meta content="text/html; charset=Shift_JIS" http-equiv="Content-Type"></head><body>髙</body></html>"#
                .data(using: cp932))
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: "text/html", data: httpEquiv),
            "text/html; charset=Shift_JIS")
    }

    /// cooViewer-oxr.12: UTF-8 として妥当な本文では古い Shift_JIS meta を
    /// 無視し、WebKit が文字化けしない UTF-8 を明示する。
    func testContentTypeUsesUTF8ForStaleMetaCharset() {
        let data = Data(
            #"<html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="Shift_JIS"/></head><body>日本語</body></html>"#.utf8)
        XCTAssertEqual(
            EPUBSchemeHandler.contentType(for: EPUBMediaType.xhtml, data: data),
            "application/xhtml+xml; charset=utf-8")
    }

    /// RFC 7233 の単一 byte range の形式と不正入力を純粋関数で検証する
    func testParseRange() {
        XCTAssertEqual(EPUBSchemeHandler.parseRange("bytes=2-5", total: 10), 2..<6)
        XCTAssertEqual(EPUBSchemeHandler.parseRange("bytes=7-", total: 10), 7..<10)
        XCTAssertEqual(EPUBSchemeHandler.parseRange("bytes=-3", total: 10), 7..<10)
        XCTAssertNil(EPUBSchemeHandler.parseRange("bytes=0-1,4-5", total: 10))
        XCTAssertNil(EPUBSchemeHandler.parseRange("bytes=10-", total: 10))
        XCTAssertNil(EPUBSchemeHandler.parseRange("bytes=5-4", total: 10))
        XCTAssertNil(EPUBSchemeHandler.parseRange("bytes=0-abc", total: 10))
    }

    private static func makeImageSpinePublication() throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:scheme-image</dc:identifier>
                <dc:title>Scheme image</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest><item id="page" href="images/page.png"
                media-type="image/png"/></manifest>
              <spine><itemref idref="page"/></spine>
            </package>
            """
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/images/page.png", EPUBFixtures.tinyPNG),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/scheme-image.epub"))
    }
}

private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let completion: () -> Void
    private(set) var response: URLResponse?
    private(set) var receivedData = Data()
    private(set) var failure: (any Error)?

    init(request: URLRequest, completion: @escaping () -> Void) {
        self.request = request
        self.completion = completion
    }

    func didReceive(_ response: URLResponse) {
        self.response = response
    }

    func didReceive(_ data: Data) {
        receivedData.append(data)
    }

    func didFinish() {
        completion()
    }

    func didFailWithError(_ error: any Error) {
        failure = error
        completion()
    }
}
