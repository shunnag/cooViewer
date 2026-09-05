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

    /// TOC の深さ平坦化(見出しツリーを depth 付きの一列へ)
    func testFlattenedTOC() throws {
        let navigation = try NavigationDocumentParser.parse(
            data: Data(EPUBFixtures.navXHTML.utf8), at: "OEBPS/nav.xhtml")
        let flat = navigation.flattenedTOC
        // 第一章(0) → 一の一(1) → 第二章(0) の深さ優先
        XCTAssertEqual(flat.map(\.title), ["第一章", "一の一", "第二章"])
        XCTAssertEqual(flat.map(\.depth), [0, 1, 0])
        XCTAssertEqual(flat[1].href, "text/ch1.xhtml#sec1")
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
    /// cooViewer-oxr.7: NBSP は可読テキストの空白正規化で通常スペースになる
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

    /// cooViewer-oxr.7: ruby の読みと括弧は目次タイトルへ混入させない
    func testNavTitleDropsRubyReading() throws {
        let xhtml = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="c1.xhtml">第一章<ruby>草枕<rp>（</rp><rt>くさまくら</rt><rp>）</rp></ruby></a></li>
          </ol></nav>
        </body></html>
        """
        let navigation = try NavigationDocumentParser.parse(
            data: Data(xhtml.utf8), at: "nav.xhtml")
        XCTAssertEqual(navigation.toc[0].title, "第一章草枕")
    }

    /// cooViewer-oxr.7: NCX のラベルも nav と同じ可読テキスト規則で読む
    func testNCXTitleUsesReadableText() throws {
        let ncx = """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap><navPoint id="chapter-1">
            <navLabel><text>第一章　<ruby>草枕<rt>くさまくら</rt></ruby></text></navLabel>
            <content src="c1.xhtml"/>
          </navPoint></navMap>
        </ncx>
        """
        let navigation = try NCXParser.parse(
            data: Data(ncx.utf8), at: "toc.ncx")
        XCTAssertEqual(navigation.toc[0].title, "第一章　草枕")
    }

    /// cooViewer-oxr.7: XML 空白ではない全角空白は目次タイトルに保持する
    func testNavTitlePreservesIdeographicSpace() throws {
        let xhtml = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="c1.xhtml">第一章　草枕</a></li>
          </ol></nav>
        </body></html>
        """
        let navigation = try NavigationDocumentParser.parse(
            data: Data(xhtml.utf8), at: "nav.xhtml")
        XCTAssertEqual(navigation.toc[0].title, "第一章　草枕")
    }

    /// cooViewer-oxr.7: 非テキスト目次は最初の画像の alt をタイトルに使う
    func testNavTitleFallsBackToImageAlt() throws {
        let xhtml = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="c1.xhtml" aria-label="リンク名"><img src="chapter.png" alt="第一章" title="画像名"/></a></li>
          </ol></nav>
        </body></html>
        """
        let navigation = try NavigationDocumentParser.parse(
            data: Data(xhtml.utf8), at: "nav.xhtml")
        XCTAssertEqual(navigation.toc[0].title, "第一章")
    }

    /// cooViewer-oxr.7: span の順序や wrapper にかかわらず a を優先する
    func testNavPrefersAnchorOverSpanAndFindsWrappedAnchor() throws {
        let xhtml = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="direct.xhtml">正しい見出し</a><span>誤った見出し</span></li>
            <li><span>誤った wrapper 見出し</span><div><a href="wrapped.xhtml">wrapper 内の見出し</a></div></li>
          </ol></nav>
        </body></html>
        """
        let navigation = try NavigationDocumentParser.parse(
            data: Data(xhtml.utf8), at: "nav.xhtml")
        XCTAssertEqual(navigation.toc.map(\.title), ["正しい見出し", "wrapper 内の見出し"])
        XCTAssertEqual(navigation.toc.map(\.href), ["direct.xhtml", "wrapped.xhtml"])
    }
}
