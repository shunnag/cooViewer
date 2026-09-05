import Foundation
import Washi
import XCTest

@testable import cooViewer

/// EPUB の解析再利用と画像のみ判定(cooViewer-oxr.42/44、設計書 §2.4)。
final class EPUBSourceBatchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0"
                   xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf"
                      media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    private func makeEPUB(
        named name: String,
        imageOnly: Bool,
        fixedLayout: Bool = false,
        spreads: [String?] = [nil]
    ) throws -> URL {
        let manifest = spreads.indices.map { index in
            let page = index + 1
            let imageItem = imageOnly
                ? "<item id=\"i\(page)\" href=\"images/p\(page).png\" media-type=\"image/png\"/>"
                : ""
            return """
                <item id="p\(page)" href="p\(page).xhtml"
                      media-type="application/xhtml+xml"/>
                \(imageItem)
                """
        }.joined(separator: "\n")
        let spine = spreads.indices.map { index in
            let property = spreads[index].map { " properties=\"page-spread-\($0)\"" }
                ?? ""
            return "<itemref idref=\"p\(index + 1)\"\(property)/>"
        }.joined(separator: "\n")
        let layout = fixedLayout
            ? "<meta property=\"rendition:layout\">pre-paginated</meta>" : ""
        let package = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:\(name)</dc:identifier>
                <dc:title>\(name)</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-05T00:00:00Z</meta>
                \(layout)
              </metadata>
              <manifest>\(manifest)</manifest>
              <spine page-progression-direction="rtl">\(spine)</spine>
            </package>
            """
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(package.utf8)),
        ]
        for index in spreads.indices {
            let page = index + 1
            let body = imageOnly
                ? "<div><img src=\"images/p\(page).png\" alt=\"\"/></div>"
                : "<p>本文 \(page)</p>"
            let xhtml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>\(page)</title></head><body>\(body)</body></html>
                """
            entries.append(("OEBPS/p\(page).xhtml", Data(xhtml.utf8)))
            if imageOnly {
                entries.append((
                    "OEBPS/images/p\(page).png",
                    TestFixtures.pngData(width: 70 + index, height: 100)))
            }
        }
        let url = tempDir.appendingPathComponent(name).appendingPathExtension("epub")
        let data = TestFixtures.storedZip(entries: entries.map {
            (Array($0.0.utf8), $0.1)
        })
        try data.write(to: url)
        return url
    }

    func testImageOnlyReflowQualifiesAndPrefillsEPUBSource() async throws {
        let url = try makeEPUB(
            named: "image-only", imageOnly: true, spreads: [nil, nil])
        let publication = try EPUBPublication(url: url)

        XCTAssertFalse(publication.isFixedLayout)
        XCTAssertTrue(EPUBImageOnlyHeuristic.qualifies(publication))
        XCTAssertEqual(
            EPUBImageOnlyHeuristic.imageOnlyPageInfos(publication)?.count, 2)

        let source = try EPUBSource(publication: publication, url: url)
        let cachedPageInfoCount = await source.cachedPageInfoCount
        XCTAssertEqual(cachedPageInfoCount, 2,
                       "判定済み XHTML 情報を初期キャッシュへ引き継ぐ")
        let pages = try await source.entries()
        XCTAssertEqual(pages.count, 2)
        let image = try await source.image(for: pages[0], maxPixelSize: nil)
        XCTAssertEqual(image.width, 70)
    }

    func testTextReflowDoesNotQualify() throws {
        let url = try makeEPUB(named: "text", imageOnly: false)
        let publication = try EPUBPublication(url: url)

        XCTAssertFalse(EPUBImageOnlyHeuristic.qualifies(publication))
        XCTAssertNil(EPUBImageOnlyHeuristic.imageOnlyPageInfos(publication))
        XCTAssertThrowsError(try EPUBSource(publication: publication, url: url))
        XCTAssertNoThrow(
            try ReflowEPUBPlaceholderSource(publication: publication, url: url))
    }

    func testImageOnlyReflowIsRejectedByPlaceholder() throws {
        let url = try makeEPUB(named: "image-placeholder", imageOnly: true)
        let publication = try EPUBPublication(url: url)
        XCTAssertThrowsError(
            try ReflowEPUBPlaceholderSource(publication: publication, url: url))
    }

    func testFactoryUsesMatchingPreparsedPublicationIdentity() async throws {
        let url = try makeEPUB(named: "factory", imageOnly: true)
        let publication = try EPUBPublication(url: url)

        let made = try await BookSourceFactory.make(
            for: url, readSubFolders: false, preparsedEPUB: publication)
        let source = try XCTUnwrap(made as? EPUBSource)
        XCTAssertTrue(source.publication === publication)
    }

    func testPlaceholderReusesPublicationUntilFileIdentityChanges() async throws {
        let url = try makeEPUB(named: "placeholder", imageOnly: false)
        let publication = try EPUBPublication(url: url)
        let source = try ReflowEPUBPlaceholderSource(
            publication: publication, url: url)

        let reused = await source.preparsedReflowPublication(for: url)
        XCTAssertTrue(reused === publication)

        var replaced = try Data(contentsOf: url)
        replaced.append(0)
        try replaced.write(to: url)
        let stale = await source.preparsedReflowPublication(for: url)
        XCTAssertNil(stale, "同名ファイル差し替え後は再解析へ戻す")
    }

    func testNestedFolderForwardsChildPreparsedPublication() async throws {
        let url = try makeEPUB(named: "nested-text", imageOnly: false)
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        XCTAssertTrue(source is NestedFolderSource)
        _ = try await source.entries()

        let first = await source.preparsedReflowPublication(for: url)
        let second = await source.preparsedReflowPublication(for: url)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "子が保持する同じ Publication を返す")
    }

    func testNestedFolderRoutesImageOnlyReflowAsImagePages() async throws {
        _ = try makeEPUB(
            named: "nested-images", imageOnly: true, spreads: [nil, nil])
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        let pages = try await source.entries()

        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages.allSatisfy { $0.reflowEPUBURL == nil })
        let image = try await source.image(for: pages[0], maxPixelSize: nil)
        XCTAssertEqual(image.width, 70)
    }

    func testNestedArchiveProbeAcceptsImageOnlyReflow() async throws {
        let epubURL = try makeEPUB(
            named: "archive-images", imageOnly: true, spreads: [nil, nil])
        let archiveURL = tempDir.appendingPathComponent("outer.zip")
        let archiveData = TestFixtures.storedZip(entries: [
            (Array("comic.epub".utf8), try Data(contentsOf: epubURL)),
        ])
        try archiveData.write(to: archiveURL)

        let source = try ArchiveSource(url: archiveURL)
        let pages = try await source.entries()
        XCTAssertEqual(pages.map(\.pathInBook), [
            "comic.epub/000000", "comic.epub/000001",
        ])
        let image = try await source.image(for: pages[1], maxPixelSize: nil)
        XCTAssertEqual(image.width, 71)
    }

    func testEPUBSourceReadsPageSpreadSlotsLazily() async throws {
        let url = try makeEPUB(
            named: "spread", imageOnly: true, fixedLayout: true,
            spreads: ["left", "right", "left"])
        let source = try EPUBSource(url: url)
        let first = await source.layoutSinglePageIndices()
        let second = await source.layoutSinglePageIndices()
        XCTAssertEqual(first, [0])
        XCTAssertEqual(second, [0],
                       "二回目はキャッシュした結果を返す")
    }
}
