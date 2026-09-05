import XCTest
@testable import WashiCore

/// cooViewer-oxr.36: 省略されたページ進行方向の優先順位を検証する。
final class EffectiveReadingDirectionTests: XCTestCase {
    func testDeclaredDirectionHasHighestPriority() throws {
        let publication = try makePublication(
            spineDirection: "rtl",
            metadataExtra: #"<meta name="primary-writing-mode" content="horizontal-lr"/>"#,
            chapterHead: "<style>html { writing-mode: vertical-rl }</style>",
            language: "he")

        XCTAssertEqual(publication.readingDirection, .rtl)
        XCTAssertEqual(publication.effectiveReadingDirection, .rtl)
        XCTAssertEqual(publication.effectiveReadingDirectionSource, .declared)
    }

    func testPrimaryWritingModeMetaDeterminesDirection() throws {
        let rightToLeft = try makePublication(
            metadataExtra: #"<meta name="primary-writing-mode" content="vertical-rl"/>"#)
        XCTAssertEqual(rightToLeft.effectiveReadingDirection, .rtl)
        XCTAssertEqual(
            rightToLeft.effectiveReadingDirectionSource,
            .primaryWritingModeMeta)

        let leftToRight = try makePublication(
            metadataExtra: #"<meta name="primary-writing-mode" content="horizontal-lr"/>"#,
            language: "he")
        XCTAssertEqual(leftToRight.effectiveReadingDirection, .ltr)
        XCTAssertEqual(
            leftToRight.effectiveReadingDirectionSource,
            .primaryWritingModeMeta)
    }

    func testInlineStyleVerticalWritingSelectsRTL() throws {
        let publication = try makePublication(
            chapterHead: "<style>html {-epub-writing-mode: vertical-rl}</style>")

        XCTAssertEqual(publication.effectiveReadingDirection, .rtl)
        XCTAssertEqual(publication.effectiveReadingDirectionSource, .verticalWritingCSS)
    }

    func testLinkedStylesheetVerticalWritingSelectsRTL() throws {
        let publication = try makePublication(
            chapterHead: #"<link rel="stylesheet" href="../style.css"/>"#,
            stylesheet: "body { writing-mode: vertical-rl }")

        XCTAssertEqual(publication.effectiveReadingDirection, .rtl)
        XCTAssertEqual(publication.effectiveReadingDirectionSource, .verticalWritingCSS)
    }

    func testRootStyleAttributeVerticalWritingSelectsRTL() throws {
        let publication = try makePublication(
            htmlAttributes: #"style="-webkit-writing-mode: tb-rl""#)

        XCTAssertEqual(publication.effectiveReadingDirection, .rtl)
        XCTAssertEqual(publication.effectiveReadingDirectionSource, .verticalWritingCSS)
    }

    func testRTLLanguageSelectsRTL() throws {
        let publication = try makePublication(language: "he-IL")

        XCTAssertEqual(publication.effectiveReadingDirection, .rtl)
        XCTAssertEqual(publication.effectiveReadingDirectionSource, .rtlLanguage)
    }

    func testMissingDirectionSignalsFallBackToLTR() throws {
        let publication = try makePublication(language: nil)

        XCTAssertEqual(publication.readingDirection, .byDefault)
        XCTAssertEqual(publication.effectiveReadingDirection, .ltr)
        XCTAssertEqual(publication.effectiveReadingDirectionSource, .fallback)
    }

    private func makePublication(
        spineDirection: String? = nil,
        metadataExtra: String = "",
        chapterHead: String = "",
        htmlAttributes: String = "",
        language: String? = "en",
        stylesheet: String? = nil
    ) throws -> EPUBPublication {
        let directionAttribute = spineDirection.map {
            #" page-progression-direction="\#($0)""#
        } ?? ""
        let languageElement = language.map { "<dc:language>\($0)</dc:language>" } ?? ""
        let stylesheetManifest = stylesheet.map { _ in
            #"<item id="style" href="style.css" media-type="text/css"/>"#
        } ?? ""
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">identifier</dc:identifier>
            <dc:title>Direction fixture</dc:title>
            \(languageElement)
            \(metadataExtra)
          </metadata>
          <manifest>
            <item id="chapter" href="text/chapter.xhtml"
                  media-type="application/xhtml+xml"/>
            \(stylesheetManifest)
          </manifest>
          <spine\(directionAttribute)><itemref idref="chapter"/></spine>
        </package>
        """
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml" \(htmlAttributes)>
          <head><title>Chapter</title>\(chapterHead)</head>
          <body><p>Text</p></body>
        </html>
        """
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/chapter.xhtml", Data(chapter.utf8)),
        ]
        if let stylesheet {
            entries.append(("OEBPS/style.css", Data(stylesheet.utf8)))
        }
        return try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/effective-direction.epub"))
    }
}
