import Foundation
import Washi
import XCTest

@testable import cooViewer

/// EPUBSource の綴じ方向 → ComicInfo ヒント写像(入力系監査 2026-08-20)。
/// 明示 rtl/ltr は対称に写し、属性省略(default)はヒント化しない
final class EPUBSourceTests: XCTestCase {
    func testMangaHintMapsExplicitDirectionsSymmetrically() {
        XCTAssertEqual(EPUBSource.mangaHint(for: .rtl), .yesAndRightToLeft)
        XCTAssertEqual(EPUBSource.mangaHint(for: .ltr), .no)
        XCTAssertNil(EPUBSource.mangaHint(for: .byDefault))
    }

    /// ppd の無い FXL 縦組みでも CSS から解決した実効方向を
    /// Manga ヒントに使う(cooViewer-oxr.36、設計書 §2.4)。
    func testPublicationMangaHintUsesEffectiveVerticalDirection() throws {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0"
          xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/package.opf"
            media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
          unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">ppd-less-vertical-fxl</dc:identifier>
            <dc:title>縦組み見本</dc:title><dc:language>ja</dc:language>
            <meta property="rendition:layout">pre-paginated</meta>
          </metadata>
          <manifest><item id="page" href="page.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="page"/></spine>
        </package>
        """
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>本文</title><style>html { writing-mode: vertical-rl; }</style></head>
          <body><p>本文</p></body>
        </html>
        """
        let publication = try EPUBPublication(
            data: TestFixtures.storedZip(entries: [
                (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
                (Array("META-INF/container.xml".utf8), Data(container.utf8)),
                (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
                (Array("OEBPS/page.xhtml".utf8), Data(chapter.utf8)),
            ]),
            displayURL: URL(fileURLWithPath: "/tmp/ppd-less-vertical.epub"))

        XCTAssertEqual(publication.readingDirection, .byDefault)
        XCTAssertEqual(publication.effectiveReadingDirection, .rtl)
        XCTAssertEqual(EPUBSource.mangaHint(for: publication),
                       .yesAndRightToLeft)
    }
}
