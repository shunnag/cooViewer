import XCTest
@testable import Washi
@testable import WashiCore

/// ナビゲーション文書(nav / NCX)パーサの検証
final class NavigationTests: XCTestCase {
    func testNavDocument() throws {
        let navigation = try NavigationDocumentParser.parse(
            data: Data(EPUBFixtures.navXHTML.utf8), at: "OEBPS/nav.xhtml")
        XCTAssertEqual(navigation.toc.count, 2)
        XCTAssertEqual(navigation.toc[0].title, "第一章")
        XCTAssertEqual(navigation.toc[0].href, "text/ch1.xhtml")
        XCTAssertEqual(navigation.toc[0].children.count, 1)
        XCTAssertEqual(navigation.toc[0].children[0].title, "一の一")
        XCTAssertEqual(navigation.toc[0].children[0].href, "text/ch1.xhtml#sec1")
        XCTAssertEqual(navigation.landmarks.count, 1)
        XCTAssertEqual(navigation.landmarks[0].epubType, "bodymatter")
    }

    func testNCX() throws {
        let navigation = try NCXParser.parse(
            data: Data(EPUBFixtures.ncx.utf8), at: "OEBPS/toc.ncx")
        XCTAssertEqual(navigation.toc.count, 2)
        XCTAssertEqual(navigation.toc[0].title, "第一章")
        XCTAssertEqual(navigation.toc[0].children.count, 1)
        XCTAssertEqual(navigation.toc[0].children[0].href, "text/ch1.xhtml#sec1")
        XCTAssertEqual(navigation.toc[1].title, "第二章")
    }

    /// epub:type を欠く nav は最初のものを目次として救済する
    func testNavWithoutType() throws {
        let xhtml = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <nav><ol><li><a href="c1.xhtml">Chapter 1</a></li></ol></nav>
        </body></html>
        """
        let navigation = try NavigationDocumentParser.parse(
            data: Data(xhtml.utf8), at: "nav.xhtml")
        XCTAssertEqual(navigation.toc.count, 1)
        XCTAssertEqual(navigation.toc[0].title, "Chapter 1")
    }

    /// リンクなし見出し(span)+ 入れ子
    func testSpanHeadingItem() throws {
        let xhtml = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><span>第一部</span>
              <ol><li><a href="c1.xhtml">第一章</a></li></ol>
            </li>
          </ol></nav>
        </body></html>
        """
        let navigation = try NavigationDocumentParser.parse(
            data: Data(xhtml.utf8), at: "nav.xhtml")
        XCTAssertEqual(navigation.toc[0].title, "第一部")
        XCTAssertNil(navigation.toc[0].href)
        XCTAssertEqual(navigation.toc[0].children[0].title, "第一章")
    }

    /// HTML 実体(&nbsp;)混じりでも救済パースできる。
    /// NBSP は normalizedText の空白正規化で通常スペースになる(RS の
    /// メタデータ空白正規化と同じ扱い)
    func testEntitySanitization() throws {
        let xhtml = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="c1.xhtml">第一章&nbsp;晩年</a></li>
          </ol></nav>
        </body></html>
        """
        let navigation = try NavigationDocumentParser.parse(
            data: Data(xhtml.utf8), at: "nav.xhtml")
        XCTAssertEqual(navigation.toc[0].title, "第一章 晩年")
    }
}
