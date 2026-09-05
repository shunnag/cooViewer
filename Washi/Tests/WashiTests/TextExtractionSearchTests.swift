import Foundation
import XCTest
@testable import WashiCore

/// cooViewer-oxr.10/11/89/92: 本文抽出と検索の追加仕様を検証する。
final class PublicationTestsTextExtractionSearch: XCTestCase {
    /// cooViewer-oxr.11: 全角空白と NBSP を本文同様に畳んで検索する。
    func testSearchNormalizesIdeographicAndNonbreakingWhitespace() throws {
        let publication = try makePublication(
            body: "<p>字下げ\u{3000}本文\u{00A0}末尾\n改行検索</p>")

        XCTAssertEqual(publication.search("字下げ\u{3000}本文").count, 1)
        XCTAssertEqual(publication.search("本文\u{00A0}末尾").count, 1)
        XCTAssertEqual(publication.search("末尾\n改行検索").count, 1)
        XCTAssertEqual(try publication.extractText(forSpineIndex: 0),
                       "字下げ 本文 末尾\n改行検索")
    }

    /// cooViewer-oxr.11: additive options が三種の比較感度を個別に制御する。
    func testSearchOptionsControlCaseDiacriticAndWidthSensitivity() throws {
        let publication = try makePublication(
            body: "<p>Map map café cafe Ｚ Z</p>")

        XCTAssertEqual(publication.search("Map").count, 2)
        XCTAssertEqual(publication.search(
            "Map", options: [.caseSensitive]).count, 1)
        XCTAssertEqual(publication.search("cafe").count, 2)
        XCTAssertEqual(publication.search(
            "cafe", options: [.diacriticSensitive]).count, 1)
        XCTAssertEqual(publication.search("Z").count, 2)
        XCTAssertEqual(publication.search(
            "Z", options: [.widthSensitive]).count, 1)
    }

    /// cooViewer-oxr.11: サロゲート対と結合文字より後でも UTF-16 範囲を返す。
    func testSearchHitCarriesUTF16RangeAfterSurrogateAndCombiningMark() throws {
        let publication = try makePublication(body: "<p>😀e\u{0301} 検索語</p>")
        let text = try publication.extractText(forSpineIndex: 0)
        let hit = try XCTUnwrap(publication.search("検索語").first)
        let match = try XCTUnwrap(text.range(of: "検索語"))
        let utf16Lower = try XCTUnwrap(match.lowerBound.samePosition(in: text.utf16))
        let utf16Upper = try XCTUnwrap(match.upperBound.samePosition(in: text.utf16))
        let expectedLower = text.utf16.distance(
            from: text.utf16.startIndex, to: utf16Lower)
        let expectedUpper = text.utf16.distance(
            from: text.utf16.startIndex, to: utf16Upper)

        XCTAssertEqual(hit.utf16Range, expectedLower..<expectedUpper)
        XCTAssertNotEqual(hit.characterOffset, hit.utf16Range.lowerBound)

        let legacy = EPUBSearchHit(spineIndex: 2, characterOffset: 3,
                                   length: 4, snippet: "legacy")
        XCTAssertEqual(legacy.utf16Range, 3..<7)
    }

    /// cooViewer-oxr.89: SVG メタデータと MathML 注釈を捨て、可視 text は残す。
    func testExtractTextSkipsSVGMetadataAndMathMLAnnotations() throws {
        let body = """
            <p>前<svg xmlns="http://www.w3.org/2000/svg"><title>不可視題</title><desc>不可視説明</desc><text>SVG可視検索</text></svg><math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi><annotation>不可視注釈</annotation><annotation-xml><mtext>不可視XML</mtext></annotation-xml></math><title>HTML題</title><desc>HTML説明</desc><annotation>HTML注記</annotation><ruby>漢<rtc>kan</rtc></ruby>後</p>
            """
        let publication = try makePublication(body: body)
        let text = try publication.extractText(forSpineIndex: 0)

        XCTAssertEqual(text, "前SVG可視検索xHTML題HTML説明HTML注記漢後")
        XCTAssertFalse(text.contains("不可視"))
    }

    /// cooViewer-oxr.92: caption/th/td の境界で隣接文字列を分離する。
    func testExtractTextSeparatesCaptionAndTableCells() throws {
        let publication = try makePublication(body: """
            <table><caption>書誌</caption><tr><th>発行者</th><td>山田太郎</td></tr></table>
            """)

        XCTAssertEqual(try publication.extractText(forSpineIndex: 0),
                       "書誌\n発行者\n山田太郎")
    }

    /// cooViewer-oxr.10: XML 風バイトでも非内容文書の spine は解析しない。
    func testExtractTextSkipsXMLShapedUnsupportedSpineMedia() throws {
        let xmlShapedJSON = Data("""
            <?xml version="1.0"?><html><body><p>解析禁止</p></body></html>
            """.utf8)
        let publication = try makePublication(
            body: "", mediaType: "application/json", resourceData: xmlShapedJSON)

        XCTAssertEqual(try publication.extractText(forSpineIndex: 0), "")
    }

    private func makePublication(
        body: String,
        mediaType: String = "application/xhtml+xml",
        resourceData: Data? = nil
    ) throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:text-extraction-search</dc:identifier>
                <dc:title>Text extraction search</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-05T00:00:00Z</meta>
              </metadata>
              <manifest><item id="c" href="text/c.dat" media-type="\(mediaType)"/></manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>"
            + body + "</body></html>"
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/c.dat", resourceData ?? Data(xhtml.utf8)),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/text-extraction-search.epub"))
    }
}
