import Foundation
import Washi
import XCTest

@testable import cooViewer

/// ファイル情報の EPUB Accessibility 節(cooViewer-oxr.37、
/// 設計書 §2.4)の純粋整形を検証する。
final class EPUBAccessibilityFormatterTests: XCTestCase {
    func testSectionFormatsEveryAccessibilityField() throws {
        let publication = try makePublication(accessibilityMetadata: """
            <meta property="schema:accessMode">textual</meta>
            <meta property="schema:accessMode">visual</meta>
            <meta property="schema:accessModeSufficient">textual, visual</meta>
            <meta property="schema:accessModeSufficient">auditory</meta>
            <meta property="schema:accessibilityFeature">alternativeText</meta>
            <meta property="schema:accessibilityFeature">structuralNavigation</meta>
            <meta property="schema:accessibilityHazard">noFlashingHazard</meta>
            <meta property="schema:accessibilitySummary">Accessible summary</meta>
            <meta property="dcterms:conformsTo">https://example.com/spec/EPUB-A11Y-11</meta>
            <meta property="a11y:certifiedBy">Standards Lab</meta>
            <meta property="a11y:certifierCredential">https://example.com/credentials/a</meta>
            """)

        let section = try XCTUnwrap(EPUBAccessibilityFormatter.section(
            for: publication.metadata.accessibility))

        XCTAssertEqual(section.title, String(localized: "Accessibility"))
        XCTAssertEqual(section.rows.map(\.value), [
            "textual, visual",
            "textual + visual; auditory",
            "alternativeText, structuralNavigation",
            "noFlashingHazard",
            "Accessible summary",
            "EPUB-A11Y-11",
            "Standards Lab",
            "https://example.com/credentials/a",
        ])
        let conformance = try XCTUnwrap(section.rows.first {
            $0.value == "EPUB-A11Y-11"
        })
        XCTAssertEqual(conformance.tooltip,
                       "https://example.com/spec/EPUB-A11Y-11")
        XCTAssertTrue(section.rows.filter { $0.value != "EPUB-A11Y-11" }
            .allSatisfy { $0.tooltip == nil })
    }

    func testEmptyAccessibilityOmitsSection() throws {
        let publication = try makePublication(accessibilityMetadata: "")

        XCTAssertTrue(publication.metadata.accessibility.isEmpty)
        XCTAssertNil(EPUBAccessibilityFormatter.section(
            for: publication.metadata.accessibility))
    }

    func testPageDetailsAppendsAccessibilitySection() throws {
        let publication = try makePublication(accessibilityMetadata:
            #"<meta property="schema:accessMode">textual</meta>"#)
        let details = PageFileInfo.details(
            entryName: "page.xhtml", pathInBook: "text/page.xhtml",
            containerURL: URL(fileURLWithPath: "/tmp/book.epub"),
            pageNumber: 1, pageCount: 1,
            imageData: nil, fallbackPixelSize: nil,
            epubAccessibility: publication.metadata.accessibility)

        let section = try XCTUnwrap(details.sections.last)
        XCTAssertEqual(section.title, String(localized: "Accessibility"))
        XCTAssertEqual(section.rows.map(\.value), ["textual"])
    }

    private func makePublication(accessibilityMetadata: String) throws
        -> EPUBPublication {
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
            <dc:identifier id="uid">accessibility-formatter</dc:identifier>
            <dc:title>Accessible Book</dc:title><dc:language>en</dc:language>
            \(accessibilityMetadata)
          </metadata>
          <manifest><item id="chapter" href="chapter.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
          <body><p>Text</p></body></html>
        """
        return try EPUBPublication(
            data: TestFixtures.storedZip(entries: [
                (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
                (Array("META-INF/container.xml".utf8), Data(container.utf8)),
                (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
                (Array("OEBPS/chapter.xhtml".utf8), Data(chapter.utf8)),
            ]),
            displayURL: URL(fileURLWithPath: "/tmp/accessibility.epub"))
    }
}
