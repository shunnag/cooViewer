import Foundation
import XCTest
@testable import WashiCore

/// cooViewer-oxr.46 C46: rendition:layout より前の時代の固定レイアウト表明。
/// これが無いと 2011〜2013 年の iBooks/Kobo 向け漫画や Amazon 形式からの
/// 中間 EPUB がリフロー扱いになり、ホストが固定レイアウトとして開けない。
final class LegacyFixedLayoutTests: XCTestCase {
    private func book(metas: String = "", displayOptions: String? = nil,
                      renditionLayout: String? = nil) throws -> EPUBPublication {
        let rendition = renditionLayout.map {
            "<meta property=\"rendition:layout\">\($0)</meta>"
        } ?? ""
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:legacy-fxl</dc:identifier>
                <dc:title>旧世代 FXL</dc:title><dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-09T00:00:00Z</meta>
                \(rendition)
                \(metas)
              </metadata>
              <manifest>
                <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/package.opf"
                media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>本文</p></body></html>"
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/c.xhtml", Data(xhtml.utf8)),
        ]
        if let displayOptions {
            entries.append(("META-INF/com.apple.ibooks.display-options.xml",
                            Data(displayOptions.utf8)))
        }
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-legacy-fxl.epub"))
    }

    func testKoboStyleFixedLayoutMeta() throws {
        let book = try book(metas: "<meta name=\"fixed-layout\" content=\"true\"/>")
        XCTAssertTrue(book.package.isFixedLayout)
    }

    func testIBooksStyleBookTypeComic() throws {
        let book = try book(metas: "<meta name=\"book-type\" content=\"comic\"/>")
        XCTAssertTrue(book.package.isFixedLayout)
    }

    func testAmazonStyleOriginalResolution() throws {
        let book = try book(metas: "<meta name=\"original-resolution\" content=\"1200x1600\"/>")
        XCTAssertTrue(book.package.isFixedLayout)
    }

    func testAppleDisplayOptionsFixedLayout() throws {
        let options = """
            <?xml version="1.0" encoding="UTF-8"?>
            <display_options><platform name="*">
              <option name="fixed-layout">true</option>
            </platform></display_options>
            """
        let book = try book(displayOptions: options)
        XCTAssertTrue(book.package.isFixedLayout)
    }

    /// 明示の rendition:layout があればそちらを優先する(旧表明で上書きしない)
    func testExplicitRenditionLayoutWins() throws {
        let book = try book(metas: "<meta name=\"fixed-layout\" content=\"true\"/>",
                            renditionLayout: "reflowable")
        XCTAssertFalse(book.package.isFixedLayout, "明示の宣言を旧表明が上書きした")
    }

    /// 表明が無い普通の本はリフローのまま(退行防止)
    func testPlainBookStaysReflowable() throws {
        XCTAssertFalse(try book().package.isFixedLayout)
        // 数値でない original-resolution は表明とみなさない
        XCTAssertFalse(try book(
            metas: "<meta name=\"original-resolution\" content=\"unknown\"/>")
            .package.isFixedLayout)
    }
}
