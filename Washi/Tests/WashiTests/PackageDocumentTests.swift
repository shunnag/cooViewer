import XCTest
@testable import Washi
@testable import WashiCore

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

    /// cooViewer-oxr.7: OPF メタデータでも XML 空白だけを畳み、全角空白を保つ。
    func testMetadataNormalizationPreservesIdeographicSpace() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title> 第一章　草枕 </dc:title><dc:language>ja</dc:language>
          </metadata>
          <manifest><item id="c" href="c.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c"/></spine>
        </package>
        """
        XCTAssertEqual(try parse(opf).metadata.mainTitle, "第一章　草枕")
    }

    /// cooViewer-oxr.37: EPUB Accessibility 1.0 形式の metadata/link を
    /// meta 形式の値と一緒に公開する。
    func testAccessibilityMetadataLinksAreParsed() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title>Accessible book</dc:title><dc:language>en</dc:language>
            <meta property="dcterms:conformsTo">https://example.com/meta-standard</meta>
            <link rel="dcterms:conformsTo"
                  href=" https://example.com/link-standard "/>
            <link rel="a11y:certifierCredential"
                  href="https://example.com/credential"/>
          </metadata>
          <manifest><item id="c" href="c.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c"/></spine>
        </package>
        """

        let accessibility = try parse(opf).metadata.accessibility
        XCTAssertEqual(accessibility.conformsTo, [
            "https://example.com/meta-standard",
            "https://example.com/link-standard",
        ])
        XCTAssertEqual(accessibility.certifierCredentials, [
            "https://example.com/credential",
        ])
        XCTAssertFalse(accessibility.isEmpty)
    }

    /// cooViewer-oxr.37: 宣言のない既存 EPUB では追加配列も空になる。
    func testAccessibilityCertifierCredentialsDefaultToEmpty() throws {
        let accessibility = try parse(EPUBFixtures.verticalNovelOPF)
            .metadata.accessibility
        XCTAssertTrue(accessibility.certifierCredentials.isEmpty)
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

    /// cooViewer-oxr.14: EPUB 3.3 D.3 の rendition meta は同一 property の
    /// 先頭値が有効になる(W3C lay-pp/fxl-layout-duplication 型)。
    func testDocumentRenditionMetadataUsesFirstDeclaration() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title>t</dc:title><dc:language>en</dc:language>
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rendition:layout">reflowable</meta>
            <meta property="rendition:orientation">portrait</meta>
            <meta property="rendition:orientation">landscape</meta>
            <meta property="rendition:spread">landscape</meta>
            <meta property="rendition:spread">none</meta>
            <meta property="rendition:flow">scrolled-doc</meta>
            <meta property="rendition:flow">paginated</meta>
          </metadata>
          <manifest><item id="a" href="a.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """

        let rendition = try parse(opf).metadata.rendition
        XCTAssertEqual(rendition.layout, .prePaginated)
        XCTAssertEqual(rendition.orientation, .portrait)
        XCTAssertEqual(rendition.spread, .landscape)
        XCTAssertEqual(rendition.flow, .scrolledDoc)
    }

    /// cooViewer-oxr.14: itemref の重複 layout は Set の順ではなく
    /// properties 属性の先頭オーバーライドを使う。
    func testItemRefLayoutOverrideUsesFirstPropertyInDocumentOrder() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title>t</dc:title><dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
            <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="a" properties="rendition:layout-reflowable rendition:layout-pre-paginated"/>
            <itemref idref="b" properties="rendition:layout-pre-paginated rendition:layout-reflowable"/>
          </spine>
        </package>
        """

        let package = try parse(opf)
        XCTAssertEqual(package.spine.itemRefs[0].propertyList, [
            "rendition:layout-reflowable", "rendition:layout-pre-paginated",
        ])
        XCTAssertEqual(package.effectiveLayout(for: package.spine.itemRefs[0]),
                       .reflowable)
        XCTAssertEqual(package.effectiveLayout(for: package.spine.itemRefs[1]),
                       .prePaginated)
    }

    /// cooViewer-oxr.51: 旧来の接頭辞なし表記を含む itemref spread override は
    /// 文書既定より優先される。
    func testEffectiveSpreadUsesFirstItemOverrideThenDocumentDefault() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title>t</dc:title><dc:language>en</dc:language>
            <meta property="rendition:spread">both</meta>
          </metadata>
          <manifest>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
            <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
            <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="a" properties="rendition:spread-none rendition:spread-landscape"/>
            <itemref idref="b" properties="spread-landscape"/>
            <itemref idref="c"/>
          </spine>
        </package>
        """

        let package = try parse(opf)
        XCTAssertEqual(package.effectiveSpread(for: package.spine.itemRefs[0]),
                       .none)
        XCTAssertEqual(package.effectiveSpread(for: package.spine.itemRefs[1]),
                       .landscape)
        XCTAssertEqual(package.effectiveSpread(for: package.spine.itemRefs[2]),
                       .both)
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

    /// cooViewer-oxr.49: display-seq が一部にしかない title は
    /// 番号付きを優先せず文書順を保つ。
    func testPartialDisplaySeqPreservesTitleDocumentOrder() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title id="main">Main Title</dc:title>
            <dc:title id="subtitle">Subtitle</dc:title>
            <meta refines="#subtitle" property="display-seq">1</meta>
            <dc:language>en</dc:language>
          </metadata>
          <manifest><item id="a" href="a.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """

        let metadata = try parse(opf).metadata
        XCTAssertEqual(metadata.titles.map(\.value), ["Main Title", "Subtitle"])
        XCTAssertEqual(metadata.mainTitle, "Main Title")
    }

    /// cooViewer-oxr.49: creator/author も display-seq が全員分揃わなければ
    /// EPUB 3.3 D.3.5 どおり文書順で公開する。
    func testPartialDisplaySeqPreservesCreatorAndAuthorDocumentOrder() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier><dc:title>t</dc:title>
            <dc:creator id="first">First Author</dc:creator>
            <dc:creator id="second">Second Author</dc:creator>
            <meta refines="#first" property="role">aut</meta>
            <meta refines="#second" property="role">aut</meta>
            <meta refines="#second" property="display-seq">1</meta>
            <dc:language>en</dc:language>
          </metadata>
          <manifest><item id="a" href="a.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """

        let metadata = try parse(opf).metadata
        XCTAssertEqual(metadata.creators.map(\.value),
                       ["First Author", "Second Author"])
        XCTAssertEqual(metadata.authors, ["First Author", "Second Author"])
    }

    /// cooViewer-oxr.18: refines は URI 参照として percent-decode し、
    /// %23 で符号化された fragment マーカも解決する。
    func testPercentEncodedRefinesTargetIsResolved() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">x</dc:identifier>
            <dc:title id="title-1">Encoded Refines</dc:title>
            <meta refines="%23title%2D1" property="title-type">main</meta>
            <dc:language>en</dc:language>
          </metadata>
          <manifest><item id="a" href="a.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """

        XCTAssertEqual(try parse(opf).metadata.titles.first?.type, "main")
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
