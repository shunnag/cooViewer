import XCTest
@testable import cooViewer

/// ComicInfo.xml パーサの検証(cooViewer-4fi.1)。壊れ・部分欠け・大小・エンコード・
/// 章抽出に耐えること。パーサは fail-soft(nil/欠損)で、決してクラッシュしない
final class ComicInfoTests: XCTestCase {

    /// UTF-8 の ComicInfo 文書を作る
    private func utf8(_ body: String) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body).utf8)
    }

    func testParsesFullDocument() throws {
        let data = utf8("""
        <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <Title>第一話</Title>
          <Series>テスト漫画</Series>
          <Number>3</Number>
          <Volume>2</Volume>
          <Count>10</Count>
          <Summary>あらすじ</Summary>
          <Writer>作者太郎</Writer>
          <Publisher>出版社</Publisher>
          <Genre>SF</Genre>
          <Web>https://example.com</Web>
          <PageCount>4</PageCount>
          <LanguageISO>ja</LanguageISO>
          <AgeRating>Teen</AgeRating>
          <Manga>YesAndRightToLeft</Manga>
          <Pages>
            <Page Image="0" Type="FrontCover" />
            <Page Image="1" Bookmark="第1章" />
            <Page Image="2" DoublePage="true" />
            <Page Image="3" Type="BackCover" />
          </Pages>
        </ComicInfo>
        """)
        let info = try XCTUnwrap(ComicInfo.parse(data))
        XCTAssertEqual(info.title, "第一話")
        XCTAssertEqual(info.series, "テスト漫画")
        XCTAssertEqual(info.number, "3")
        XCTAssertEqual(info.volume, 2)
        XCTAssertEqual(info.count, 10)
        XCTAssertEqual(info.summary, "あらすじ")
        XCTAssertEqual(info.writer, "作者太郎")
        XCTAssertEqual(info.publisher, "出版社")
        XCTAssertEqual(info.genre, "SF")
        XCTAssertEqual(info.web, "https://example.com")
        XCTAssertEqual(info.pageCount, 4)
        XCTAssertEqual(info.languageISO, "ja")
        XCTAssertEqual(info.ageRating, "Teen")
        XCTAssertEqual(info.manga, .yesAndRightToLeft)
        XCTAssertEqual(info.manga.readsRightToLeft, true)
        XCTAssertEqual(info.pages.count, 4)
        XCTAssertEqual(info.pages[0].type, .frontCover)
        XCTAssertTrue(info.pages[2].doublePage)
        XCTAssertFalse(info.pages[0].doublePage)
        XCTAssertEqual(info.pages[3].type, .backCover)
    }

    func testPartialDocumentLeavesRestNil() throws {
        let info = try XCTUnwrap(ComicInfo.parse(utf8(
            "<ComicInfo><Series>S</Series><Number>1</Number></ComicInfo>")))
        XCTAssertEqual(info.series, "S")
        XCTAssertEqual(info.number, "1")
        XCTAssertNil(info.title)
        XCTAssertNil(info.writer)
        XCTAssertNil(info.pageCount)
        XCTAssertTrue(info.pages.isEmpty)
        XCTAssertEqual(info.manga, .unknown)
    }

    func testMalformedXMLReturnsNil() {
        // 閉じタグ欠落
        XCTAssertNil(ComicInfo.parse(utf8("<ComicInfo><Series>x")))
        // まったくの非 XML
        XCTAssertNil(ComicInfo.parse(Data([0x00, 0x01, 0x02, 0xFF])))
        // 空データ
        XCTAssertNil(ComicInfo.parse(Data()))
    }

    func testNonComicInfoRootReturnsNil() {
        XCTAssertNil(ComicInfo.parse(utf8("<Other><Series>x</Series></Other>")))
    }

    func testEmptyComicInfoReturnsNil() {
        XCTAssertNil(ComicInfo.parse(utf8("<ComicInfo></ComicInfo>")))
        XCTAssertNil(ComicInfo.parse(utf8("<ComicInfo>   \n  </ComicInfo>")))
    }

    func testMangaReadingDirectionMapping() throws {
        func manga(_ v: String) -> ComicInfo.Manga? {
            ComicInfo.parse(utf8("<ComicInfo><Manga>\(v)</Manga></ComicInfo>"))?.manga
        }
        XCTAssertEqual(manga("YesAndRightToLeft"), .yesAndRightToLeft)
        XCTAssertEqual(manga("yesandrighttoleft"), .yesAndRightToLeft)  // 大小無視
        XCTAssertEqual(manga("Yes"), .yes)
        XCTAssertEqual(manga("No"), .no)
        XCTAssertEqual(manga("Nonsense"), .unknown)
        XCTAssertEqual(ComicInfo.Manga.yesAndRightToLeft.readsRightToLeft, true)
        XCTAssertEqual(ComicInfo.Manga.no.readsRightToLeft, false)
        XCTAssertNil(ComicInfo.Manga.yes.readsRightToLeft)
        XCTAssertNil(ComicInfo.Manga.unknown.readsRightToLeft)
    }

    func testPageAttributesCaseInsensitiveAndDoublePageForms() throws {
        let info = try XCTUnwrap(ComicInfo.parse(utf8("""
        <ComicInfo><Pages>
          <page IMAGE="0" doublepage="1" bookmark="A" />
          <Page Image="1" DoublePage="false" />
          <Page Image="2" DoublePage="TRUE" />
          <Page image="3" />
          <Page Bookmark="no-image" />
        </Pages></ComicInfo>
        """)))
        // Image 無しの最後の 1 件は skip される
        XCTAssertEqual(info.pages.map(\.image), [0, 1, 2, 3])
        XCTAssertTrue(info.pages[0].doublePage)   // "1"
        XCTAssertFalse(info.pages[1].doublePage)  // "false"
        XCTAssertTrue(info.pages[2].doublePage)   // "TRUE"
        XCTAssertFalse(info.pages[3].doublePage)  // 属性なし
        XCTAssertEqual(info.pages[0].bookmark, "A")
    }

    func testChaptersFromBookmarksSortedAndFiltered() throws {
        let info = try XCTUnwrap(ComicInfo.parse(utf8("""
        <ComicInfo><Pages>
          <Page Image="5" Bookmark="第3章" />
          <Page Image="0" Bookmark="第1章" />
          <Page Image="2" Bookmark="" />
          <Page Image="3" Bookmark="第2章" />
          <Page Image="4" />
        </Pages></ComicInfo>
        """)))
        let chapters = info.chapters
        XCTAssertEqual(chapters.map(\.image), [0, 3, 5])          // image 昇順・空名は除外
        XCTAssertEqual(chapters.map(\.name), ["第1章", "第2章", "第3章"])
    }

    func testNonNumericNumericFieldsAreNilButDocumentParses() throws {
        let info = try XCTUnwrap(ComicInfo.parse(utf8("""
        <ComicInfo>
          <Series>S</Series>
          <Count>abc</Count>
          <PageCount>N/A</PageCount>
          <Number>1.5</Number>
        </ComicInfo>
        """)))
        XCTAssertEqual(info.series, "S")
        XCTAssertNil(info.count)          // 数値でない → nil(だが解析は成功)
        XCTAssertNil(info.pageCount)
        XCTAssertEqual(info.number, "1.5") // 小数話数は文字列で保持
    }

    func testUTF16DeclaredDocumentParses() throws {
        let body = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n"
            + "<ComicInfo><Series>波括弧テスト</Series></ComicInfo>"
        let data = try XCTUnwrap(body.data(using: .utf16))  // BOM 付き
        let info = try XCTUnwrap(ComicInfo.parse(data))
        XCTAssertEqual(info.series, "波括弧テスト")
    }
}
