import PDFKit
import XCTest
@testable import cooViewer

/// PDF 属性/アウトライン → ComicInfo の合成(cooViewer-oo6)。
/// 文書タイトルは documentTitle(窓には出さず情報窓のみ)。アウトライン → 章
final class ComicInfoPDFTests: XCTestCase {
    private func makePDF(pageCount: Int = 3) -> PDFDocument {
        let doc = PDFDocument()
        for i in 0..<pageCount { doc.insert(PDFPage(), at: i) }
        return doc
    }

    func testFromPDFMapsAttributes() throws {
        let doc = makePDF()
        let attrs: [AnyHashable: Any] = [
            PDFDocumentAttribute.titleAttribute: "文書タイトル",
            PDFDocumentAttribute.authorAttribute: "著者花子",
            PDFDocumentAttribute.subjectAttribute: "概要テキスト",
            PDFDocumentAttribute.producerAttribute: "Skia/PDF m121",    // 生成ソフト名
            PDFDocumentAttribute.keywordsAttribute: ["SF", "Fantasy"],  // NSArray
        ]
        doc.documentAttributes = attrs

        let info = try XCTUnwrap(ComicInfo.from(pdf: doc))
        XCTAssertEqual(info.documentTitle, "文書タイトル")
        XCTAssertNil(info.title, "文書タイトルは title(認可)ではなく documentTitle へ入る")
        XCTAssertEqual(info.writer, "著者花子")
        XCTAssertEqual(info.summary, "概要テキスト")
        // 生成ソフト名は publisher に、NSArray の Keywords は genre に流用しない
        // (誤ラベル回避。レビュー wf_c680e2ec-0af)
        XCTAssertNil(info.publisher)
        XCTAssertNil(info.genre)
        // documentTitle は窓タイトル(displayTitle)には出ない = ユーザー決定
        XCTAssertNil(info.displayTitle)
    }

    func testFromPDFOutlineToChaptersSkipsEmptyAndMapsPages() throws {
        let doc = makePDF(pageCount: 3)
        func item(_ label: String?, page: Int) -> PDFOutline {
            let o = PDFOutline()
            if let label { o.label = label }
            o.destination = PDFDestination(page: doc.page(at: page)!, at: .zero)
            return o
        }
        let root = PDFOutline()
        root.insertChild(item("第1章", page: 0), at: 0)
        root.insertChild(item("第2章", page: 2), at: 1)
        root.insertChild(item(nil, page: 1), at: 2)   // ラベル無し → 除外
        doc.outlineRoot = root

        let info = try XCTUnwrap(ComicInfo.from(pdf: doc))
        XCTAssertEqual(info.chapters.map(\.name), ["第1章", "第2章"])
        XCTAssertEqual(info.chapters.map(\.image), [0, 2])
    }

    func testNestedOutlineIsFlattenedInDocumentOrder() throws {
        let doc = makePDF(pageCount: 3)
        func item(_ label: String, page: Int) -> PDFOutline {
            let o = PDFOutline()
            o.label = label
            o.destination = PDFDestination(page: doc.page(at: page)!, at: .zero)
            return o
        }
        let root = PDFOutline()
        let part = item("第1部", page: 0)
        part.insertChild(item("1話", page: 1), at: 0)   // 子(ネスト)
        root.insertChild(part, at: 0)
        root.insertChild(item("第2部", page: 2), at: 1)
        doc.outlineRoot = root

        let info = try XCTUnwrap(ComicInfo.from(pdf: doc))
        XCTAssertEqual(info.chapters.map(\.name), ["第1部", "1話", "第2部"])
        XCTAssertEqual(info.chapters.map(\.image), [0, 1, 2])
    }

    func testFromPDFNilWhenNoMetadata() {
        XCTAssertNil(ComicInfo.from(pdf: makePDF()), "属性もアウトラインも無ければ nil")
    }

    func testDocumentTitleNeverEntersDisplayTitle() {
        var info = ComicInfo()
        info.documentTitle = "PDF の題名"
        XCTAssertNil(info.displayTitle)
    }
}
