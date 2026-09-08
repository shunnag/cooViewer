import Foundation
import XCTest
@testable import WashiCore

/// cooViewer-gse.8: dc:* を落とさず保持する(書誌の完全性)。
/// source / type / relation / coverage / format は switch から漏れていた。
final class DublinCoreMetadataTests: XCTestCase {
    func testAllDublinCoreElementsArePreserved() throws {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:dc-all</dc:identifier>
                <dc:title>書誌の完全性</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-09T00:00:00Z</meta>
                <dc:source>青空文庫 底本</dc:source>
                <dc:type>dictionary</dc:type>
                <dc:relation>https://example.invalid/related</dc:relation>
                <dc:coverage>明治期・日本</dc:coverage>
                <dc:format>application/epub+zip</dc:format>
                <dc:rights>パブリックドメイン</dc:rights>
                <dc:subject>小説</dc:subject>
              </metadata>
              <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let package = try PackageDocumentParser.parse(
            data: Data(opf.utf8), at: "OEBPS/package.opf")
        XCTAssertEqual(package.metadata.sources, ["青空文庫 底本"])
        XCTAssertEqual(package.metadata.types, ["dictionary"])
        XCTAssertEqual(package.metadata.relations, ["https://example.invalid/related"])
        XCTAssertEqual(package.metadata.coverages, ["明治期・日本"])
        XCTAssertEqual(package.metadata.formats, ["application/epub+zip"])
        // 既存の項目が壊れていないこと
        XCTAssertEqual(package.metadata.rights, "パブリックドメイン")
        XCTAssertEqual(package.metadata.subjects, ["小説"])
        XCTAssertEqual(package.metadata.languages, ["ja"])
    }

    /// 同じ要素が複数あればすべて残す
    func testRepeatedElementsAreAllKept() throws {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:dc-multi</dc:identifier>
                <dc:title>複数値</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-09T00:00:00Z</meta>
                <dc:source>底本 A</dc:source>
                <dc:source>底本 B</dc:source>
              </metadata>
              <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let package = try PackageDocumentParser.parse(
            data: Data(opf.utf8), at: "OEBPS/package.opf")
        XCTAssertEqual(package.metadata.sources, ["底本 A", "底本 B"])
    }
}
