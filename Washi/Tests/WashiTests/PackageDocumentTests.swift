import XCTest
@testable import Washi

/// パッケージ文書(OPF)パーサの検証
final class PackageDocumentTests: XCTestCase {
    private func parse(_ opf: String) throws -> EPUBPackage {
        try PackageDocumentParser.parse(data: Data(opf.utf8), at: "OEBPS/package.opf")
    }

    func testVerticalNovelMetadata() throws {
        let package = try parse(EPUBFixtures.verticalNovelOPF)
        XCTAssertEqual(package.version, "3.0")
        XCTAssertEqual(package.metadata.mainTitle, "吾輩は猫である")
        XCTAssertEqual(package.metadata.titles.first?.fileAs, "わがはいはねこである")
        XCTAssertEqual(package.metadata.creators.first?.value, "夏目漱石")
        XCTAssertEqual(package.metadata.creators.first?.role, "aut")
        XCTAssertEqual(package.metadata.creators.first?.fileAs, "なつめそうせき")
        XCTAssertEqual(package.metadata.languages, ["ja"])
        XCTAssertEqual(package.metadata.uniqueIdentifier,
                       "urn:uuid:12345678-1234-1234-1234-123456789abc")
        XCTAssertEqual(package.metadata.modified, "2026-01-01T00:00:00Z")
        XCTAssertEqual(package.metadata.releaseIdentifier,
                       "urn:uuid:12345678-1234-1234-1234-123456789abc@2026-01-01T00:00:00Z")
        // シリーズ(belongs-to-collection + refines)
        XCTAssertEqual(package.metadata.collections.count, 1)
        XCTAssertEqual(package.metadata.collections.first?.name, "漱石全集")
        XCTAssertEqual(package.metadata.collections.first?.type, "series")
        XCTAssertEqual(package.metadata.collections.first?.groupPosition, "1")
    }

    func testSpineAndProgression() throws {
        let package = try parse(EPUBFixtures.verticalNovelOPF)
        XCTAssertEqual(package.spine.pageProgressionDirection, .rtl)
        XCTAssertEqual(package.spine.itemRefs.count, 3)
        XCTAssertEqual(package.spine.itemRefs[0].idref, "ch1")
        XCTAssertTrue(package.spine.itemRefs[0].linear)
        XCTAssertFalse(package.spine.itemRefs[2].linear)  // linear="no"
        XCTAssertEqual(package.spine.tocItemID, "ncx")
        XCTAssertEqual(package.navItem?.id, "nav")
        XCTAssertEqual(package.coverImageItem?.id, "cover")
        XCTAssertFalse(package.isFixedLayout)
    }

    func testFXLRenditionAndPrefixRemapping() throws {
        let package = try parse(EPUBFixtures.fxlComicOPF)
        XCTAssertTrue(package.isFixedLayout)
        // 独自接頭辞 rend: → 予約接頭辞 rendition: へ正規化されて解釈される
        XCTAssertEqual(package.metadata.rendition.spread, .landscape)
        let refs = package.spine.itemRefs
        XCTAssertTrue(refs[0].properties.contains("rendition:page-spread-center"))
        // EPUB 3.1+ の接頭辞付き同義形もそのまま保持される
        XCTAssertTrue(refs[1].properties.contains("rendition:page-spread-left"))
        XCTAssertTrue(refs[2].properties.contains("page-spread-right"))
    }

    func testEPUB2Compatibility() throws {
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                    xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>旧式の本</dc:title>
            <dc:creator opf:role="aut" opf:file-as="サクシャ">作者</dc:creator>
            <dc:identifier id="bookid" opf:scheme="ISBN">978-4-00-000000-0</dc:identifier>
            <dc:language>ja</dc:language>
            <meta name="cover" content="cover-img"/>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="cover-img" href="cover.jpg" media-type="image/jpeg"/>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="c1"/>
          </spine>
        </package>
        """
        let package = try parse(opf)
        XCTAssertEqual(package.version, "2.0")
        XCTAssertEqual(package.metadata.creators.first?.role, "aut")
        XCTAssertEqual(package.metadata.creators.first?.fileAs, "サクシャ")
        XCTAssertEqual(package.metadata.identifiers.first?.scheme, "ISBN")
        // EPUB2 の meta name="cover" → カバー解決
        XCTAssertEqual(package.coverImageItem?.id, "cover-img")
        XCTAssertEqual(package.spine.pageProgressionDirection, .byDefault)
    }

    func testItemRefRenditionOverride() throws {
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title>t</dc:title><dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
            <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="a"/>
            <itemref idref="b" properties="rendition:layout-pre-paginated"/>
          </spine>
        </package>
        """
        let package = try parse(opf)
        XCTAssertEqual(package.effectiveLayout(for: package.spine.itemRefs[0]),
                       .reflowable)
        XCTAssertEqual(package.effectiveLayout(for: package.spine.itemRefs[1]),
                       .prePaginated)
    }

    func testDisplaySeqOrdersTitles() throws {
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title id="t2">副題</dc:title>
            <dc:title id="t1">主題</dc:title>
            <meta refines="#t2" property="display-seq">2</meta>
            <meta refines="#t1" property="display-seq">1</meta>
            <dc:language>ja</dc:language>
          </metadata>
          <manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """
        let package = try parse(opf)
        XCTAssertEqual(package.metadata.titles.map(\.value), ["主題", "副題"])
    }

    func testFallbackChain() throws {
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier><dc:title>t</dc:title>
            <dc:language>ja</dc:language>
          </metadata>
          <manifest>
            <item id="tiff" href="a.tif" media-type="image/tiff" fallback="png"/>
            <item id="png" href="a.png" media-type="image/png" fallback="tiff"/>
            <item id="doc" href="a.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="doc"/></spine>
        </package>
        """
        let package = try parse(opf)
        // 循環フォールバックでも無限ループしない
        let publication = try makePublication(opf: opf)
        let chain = publication.fallbackChain(
            for: package.manifestByID["tiff"]!)
        XCTAssertEqual(chain.map(\.id), ["tiff", "png"])
    }

    private func makePublication(opf: String) throws -> EPUBPublication {
        let zip = ZipBuilder.build([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/a.xhtml", Data(EPUBFixtures.chapterXHTML(title: "t", body: "<p>x</p>").utf8)),
        ])
        return try EPUBPublication(data: zip,
                                   displayURL: URL(fileURLWithPath: "/tmp/t.epub"))
    }
}
