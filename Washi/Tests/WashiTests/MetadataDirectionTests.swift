import XCTest
@testable import WashiCore

/// cooViewer-oxr.52: OPF の dir / xml:lang 継承を検証する。
final class MetadataDirectionTests: XCTestCase {
    func testTitleElementDirectionAndLanguageOverrideParents() throws {
        let metadata = try parse(
            packageAttributes: #"dir="ltr" xml:lang="en""#,
            metadataAttributes: #"dir="auto" xml:lang="ar""#,
            titleAttributes: #"dir="rtl" xml:lang="he""#).metadata

        XCTAssertEqual(metadata.direction, .auto)
        XCTAssertEqual(metadata.language, "ar")
        XCTAssertEqual(metadata.titles.first?.direction, .rtl)
        XCTAssertEqual(metadata.titles.first?.language, "he")
    }

    func testTitleInheritsPackageDirectionAndLanguage() throws {
        let metadata = try parse(
            packageAttributes: #"dir="rtl" xml:lang="he""#).metadata

        XCTAssertEqual(metadata.direction, .rtl)
        XCTAssertEqual(metadata.language, "he")
        XCTAssertEqual(metadata.titles.first?.direction, .rtl)
        XCTAssertEqual(metadata.titles.first?.language, "he")
    }

    func testCreatorDirectionOverridesMetadataAndInheritsLanguage() throws {
        let metadata = try parse(
            packageAttributes: #"dir="ltr" xml:lang="en""#,
            metadataAttributes: #"dir="auto" xml:lang="yi""#,
            creatorAttributes: #"dir="rtl""#).metadata

        XCTAssertEqual(metadata.creators.first?.direction, .rtl)
        XCTAssertEqual(metadata.creators.first?.language, "yi")
        XCTAssertEqual(metadata.contributors.first?.direction, .auto)
        XCTAssertEqual(metadata.contributors.first?.language, "yi")
    }

    private func parse(
        packageAttributes: String = "",
        metadataAttributes: String = "",
        titleAttributes: String = "",
        creatorAttributes: String = ""
    ) throws -> EPUBPackage {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid" \(packageAttributes)>
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" \(metadataAttributes)>
            <dc:identifier id="uid">identifier</dc:identifier>
            <dc:title \(titleAttributes)>CSS: הרפתקה חדשה!</dc:title>
            <dc:creator \(creatorAttributes)>Author</dc:creator>
            <dc:contributor>Contributor</dc:contributor>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="chapter" href="chapter.xhtml"
                  media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
        return try PackageDocumentParser.parse(
            data: Data(opf.utf8),
            at: "OEBPS/package.opf")
    }
}
