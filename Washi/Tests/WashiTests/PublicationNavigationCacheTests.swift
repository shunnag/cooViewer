import Foundation
import XCTest
@testable import WashiCore

// cooViewer-oxr.8 / cooViewer-oxr.9 / cooViewer-oxr.67 / cooViewer-oxr.71:
// 目次索引・NCX 補完・本文キャッシュの回帰検証。
final class PublicationTestsNavigationCache: XCTestCase {
    func testChapterTitlePrefersFirstTOCEntryAtSameSpine() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="text/ch1.xhtml">親章</a><ol>
              <li><a href="text/ch1.xhtml#section">子節</a></li>
            </ol></li>
            <li><a href="text/ch2.xhtml">次章</a></li>
          </ol></nav>
        </body></html>
        """
        let publication = try makePublication(nav: nav, contentCount: 2)

        XCTAssertEqual(publication.chapterTitle(forSpineIndex: 0), "親章")
        XCTAssertEqual(publication.chapterTitle(forSpineIndex: 1), "次章")
    }

    func testChapterTitleReturnsNilForEmptyTOC() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol/></nav>
        </body></html>
        """
        let publication = try makePublication(nav: nav)
        XCTAssertNil(publication.chapterTitle(forSpineIndex: 0))
    }

    func testChapterTitleReturnsNilWhenOnlyTOCEntriesAreLater() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="text/ch2.xhtml">次章</a></li>
          </ol></nav>
        </body></html>
        """
        let publication = try makePublication(nav: nav, contentCount: 2)
        XCTAssertNil(publication.chapterTitle(forSpineIndex: 0))
    }

    func testEmptyNavTOCFallsBackToNCXAndPreservesNavAuxiliaryLists() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol/></nav>
          <nav epub:type="page-list"><ol>
            <li><a href="../text/ch1.xhtml#page1">nav 1</a></li>
          </ol></nav>
          <nav epub:type="landmarks"><ol>
            <li><a epub:type="bodymatter" href="../text/ch1.xhtml">本文</a></li>
          </ol></nav>
        </body></html>
        """
        let publication = try makePublication(
            nav: nav, ncx: ncxDocument, navPath: "navigation/nav.xhtml")

        XCTAssertEqual(publication.navigation.toc.first?.title, "NCX 第一章")
        XCTAssertEqual(publication.navigation.toc.first?.href,
                       "/OEBPS/text/ch1.xhtml")
        XCTAssertEqual(publication.navigation.pageList.first?.title, "nav 1")
        XCTAssertEqual(publication.navigation.landmarks.first?.title, "本文")
        XCTAssertEqual(publication.spineIndex(
            forNavItem: try XCTUnwrap(publication.navigation.pageList.first)), 0)
        XCTAssertEqual(publication.chapterTitle(forSpineIndex: 0), "NCX 第一章")
    }

    func testNCXPageListFillsEmptyNavPageList() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol/></nav>
        </body></html>
        """
        let publication = try makePublication(
            nav: nav, ncx: ncxDocument, navPath: "navigation/nav.xhtml")
        XCTAssertEqual(publication.navigation.pageList.first?.title, "NCX 1")
        XCTAssertEqual(publication.navigation.pageList.first?.href,
                       "/OEBPS/text/ch1.xhtml#page1")
        XCTAssertEqual(publication.spineIndex(
            forNavItem: try XCTUnwrap(publication.navigation.pageList.first)), 0)
    }

    func testEPUB2WithoutSpineTOCFindsFirstNCXManifestItem() throws {
        let publication = try makePublication(
            nav: nil, ncx: ncxDocument, declaresSpineTOC: false,
            packageVersion: "2.0")

        XCTAssertEqual(publication.navigation.toc.first?.title, "NCX 第一章")
        XCTAssertEqual(publication.spineIndex(
            forNavItem: try XCTUnwrap(publication.navigation.toc.first)), 0)
    }

    func testExtractedTextCacheIsSharedByExtractionSearchAndPageEstimation() throws {
        let entries = makeEntries(nav: nil, contentCount: 1)
        let reader = CountingContainerReader(entries: entries)
        let publication = try EPUBPublication(
            url: URL(fileURLWithPath: "/tmp/cache.epub"), reader: reader)
        let path = "OEBPS/text/ch1.xhtml"

        let first = try publication.extractText(forSpineIndex: 0)
        XCTAssertEqual(try publication.extractText(forSpineIndex: 0), first)
        let firstSearch = publication.search("本文")
        let secondSearch = publication.search("本文")
        XCTAssertEqual(firstSearch, secondSearch)
        XCTAssertEqual(firstSearch.count, 1)
        XCTAssertEqual(publication.estimatedPageCounts(), [1])
        XCTAssertEqual(reader.readCount(for: path), 1)
    }

    private var ncxDocument: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap><navPoint id="n1" playOrder="1">
            <navLabel><text>NCX 第一章</text></navLabel>
            <content src="text/ch1.xhtml"/>
          </navPoint></navMap>
          <pageList><pageTarget id="p1" type="normal" value="1" playOrder="2">
            <navLabel><text>NCX 1</text></navLabel>
            <content src="text/ch1.xhtml#page1"/>
          </pageTarget></pageList>
        </ncx>
        """
    }

    private func makePublication(
        nav: String?, ncx: String? = nil, declaresSpineTOC: Bool = true,
        packageVersion: String = "3.0", contentCount: Int = 1,
        navPath: String = "nav.xhtml"
    ) throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(makeEntries(
                nav: nav, ncx: ncx, declaresSpineTOC: declaresSpineTOC,
                packageVersion: packageVersion, contentCount: contentCount,
                navPath: navPath),
                method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/navigation-cache.epub"))
    }

    private func makeEntries(
        nav: String?, ncx: String? = nil, declaresSpineTOC: Bool = true,
        packageVersion: String = "3.0", contentCount: Int = 1,
        navPath: String = "nav.xhtml"
    ) -> [(name: String, data: Data)] {
        let contentManifest = (1...contentCount).map {
            "<item id=\"ch\($0)\" href=\"text/ch\($0).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let navManifest = nav == nil ? "" :
            "<item id=\"nav\" href=\"\(navPath)\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        let ncxManifest = ncx == nil ? "" :
            "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
        let tocAttribute = ncx != nil && declaresSpineTOC ? " toc=\"ncx\"" : ""
        let spine = (1...contentCount).map {
            "<itemref idref=\"ch\($0)\"/>"
        }.joined()
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="\(packageVersion)"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:navigation-cache</dc:identifier>
            <dc:title>Navigation cache</dc:title><dc:language>ja</dc:language>
          </metadata>
          <manifest>\(contentManifest)\(navManifest)\(ncxManifest)</manifest>
          <spine\(tocAttribute)>\(spine)</spine>
        </package>
        """
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
        ]
        if let nav { entries.append(("OEBPS/\(navPath)", Data(nav.utf8))) }
        if let ncx { entries.append(("OEBPS/toc.ncx", Data(ncx.utf8))) }
        for index in 1...contentCount {
            let xhtml = """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <p>第\(index)章の本文</p>
            </body></html>
            """
            entries.append(("OEBPS/text/ch\(index).xhtml", Data(xhtml.utf8)))
        }
        return entries
    }
}

private final class CountingContainerReader: ContainerReader, @unchecked Sendable {
    private let entries: [String: Data]
    private let lock = NSLock()
    private var readCounts: [String: Int] = [:]

    init(entries: [(name: String, data: Data)]) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.data) })
    }

    var allPaths: [String] { entries.keys.sorted() }

    func exists(_ path: String) -> Bool { entries[path] != nil }

    func read(_ path: String) throws -> Data {
        guard let data = entries[path] else {
            throw EPUBError.resourceNotFound(path)
        }
        lock.lock()
        readCounts[path, default: 0] += 1
        lock.unlock()
        return data
    }

    func readCount(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readCounts[path, default: 0]
    }
}
