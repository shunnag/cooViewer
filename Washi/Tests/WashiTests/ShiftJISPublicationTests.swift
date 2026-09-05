import Foundation
import XCTest
import WashiCore

final class ShiftJISPublicationTests: XCTestCase {
    /// OPF と本文の双方が Shift_JIS の EPUB を解析層だけで開ける。
    func testShiftJISPackageAndBodyCanBeExtractedAndSearched() throws {
        let package = """
        <?xml version="1.0" encoding="Shift_JIS"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid" xml:lang="ja">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:shift-jis-fixture</dc:identifier>
            <dc:title>日本語の本</dc:title>
            <dc:language>ja</dc:language>
          </metadata>
          <manifest>
            <item id="chapter" href="chapter.xhtml"
                  media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let chapter = """
        <?xml version="1.0" encoding="Shift_JIS"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">
          <head><title>第一章</title></head>
          <body><h1>第一章</h1><p>吾輩は日本語を読む猫である。</p></body>
        </html>
        """
        let packageData = try XCTUnwrap(package.data(using: .shiftJIS))
        let chapterData = try XCTUnwrap(chapter.data(using: .shiftJIS))
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", packageData),
            ("OEBPS/chapter.xhtml", chapterData),
        ]

        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/shift-jis.epub"))
        XCTAssertEqual(publication.metadata.mainTitle, "日本語の本")

        let text = try publication.extractText(forSpineIndex: 0)
        XCTAssertTrue(text.contains("吾輩は日本語を読む猫である"), "抽出結果: \(text)")
        let hits = publication.search("日本語")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.spineIndex, 0)
    }

    /// cooViewer-oxr.90: Shift_JIS 宣言を CP932 として復号し、NEC/IBM 拡張
    /// 文字と HTML 名前実体を本文抽出で失わない。
    func testCP932ExtensionCharactersAndNamedEntitiesArePreserved() throws {
        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid" xml:lang="ja">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:cp932-fixture</dc:identifier>
            <dc:title>CP932 の本</dc:title><dc:language>ja</dc:language>
          </metadata>
          <manifest><item id="chapter" href="chapter.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let chapter = """
        <?xml version="1.0" encoding="Shift_JIS"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>拡張文字</title></head>
        <body><p>①髙㈱&nbsp;&hellip;</p></body></html>
        """
        let cp932 = try XCTUnwrap(
            XMLCharsetDetector.encoding(forCharsetName: "CP932"))
        let chapterData = try XCTUnwrap(chapter.data(using: cp932))
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(package.utf8)),
            ("OEBPS/chapter.xhtml", chapterData),
        ]

        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/cp932.epub"))
        let text = try publication.extractText(forSpineIndex: 0)
        XCTAssertTrue(text.contains("①髙㈱"), "抽出結果: \(text)")
        XCTAssertTrue(text.contains("…"), "抽出結果: \(text)")
        XCTAssertFalse(publication.search("髙").isEmpty)
    }
}
