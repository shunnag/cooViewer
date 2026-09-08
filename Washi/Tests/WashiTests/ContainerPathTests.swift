import XCTest
@testable import Washi
@testable import WashiCore

/// コンテナ内パス解決の検証
final class ContainerPathTests: XCTestCase {
    func testResolveDoesNotDecodeCanonicalBaseAgain() {
        let base = "OEBPS/literal%20folder/ch%2F1.xhtml"
        XCTAssertEqual(ContainerPath.resolve(base: base, href: "#section"), base)
        XCTAssertEqual(ContainerPath.resolve(base: base, href: "?view=1"), base)
        XCTAssertEqual(ContainerPath.resolve(base: base, href: "image%2520.png"),
                       "OEBPS/literal%20folder/image%20.png")
    }

    func testPublicationResolvesResourcesUnderLiteralPercentDirectory() throws {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: "<p>Percent folder text.</p>")
        for index in entries.indices {
            if entries[index].name == "META-INF/container.xml" {
                entries[index].data = Data(String(decoding: entries[index].data, as: UTF8.self)
                    .replacingOccurrences(of: "OEBPS/package.opf", with:
                        "OEBPS/literal%2520folder/package.opf").utf8)
            } else if entries[index].name.hasPrefix("OEBPS/") {
                entries[index].name = entries[index].name.replacingOccurrences(
                    of: "OEBPS/", with: "OEBPS/literal%20folder/")
            }
        }
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/percent-folder.epub"))
        XCTAssertEqual(try publication.extractText(forSpineIndex: 0), "Percent folder text.")
    }

    func testResolveRelativeHref() {
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/package.opf", href: "text/ch1.xhtml"),
            "OEBPS/text/ch1.xhtml")
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/text/ch1.xhtml", href: "../images/a.png"),
            "OEBPS/images/a.png")
        XCTAssertEqual(
            ContainerPath.resolve(base: "package.opf", href: "ch1.xhtml"),
            "ch1.xhtml")
    }

    func testResolveStripsFragmentAndQuery() {
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/nav.xhtml", href: "ch1.xhtml#sec2"),
            "OEBPS/ch1.xhtml")
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/nav.xhtml", href: "ch1.xhtml?x=1"),
            "OEBPS/ch1.xhtml")
        // フラグメントのみは基準文書自身を指す
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/nav.xhtml", href: "#toc"),
            "OEBPS/nav.xhtml")
    }

    /// cooViewer-oxr.18: root より上の .. は WHATWG URL と同じく
    /// container root へ clamp し、外部 URL だけを拒否する。
    func testResolveClampsAboveRootAndRejectsAbsoluteURL() {
        XCTAssertEqual(
            ContainerPath.resolve(base: "a.opf", href: "../outside.xhtml"),
            "outside.xhtml")
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/a.opf", href: "../../outside.xhtml"),
            "outside.xhtml")
        XCTAssertNil(ContainerPath.resolve(base: "OEBPS/a.opf",
                                           href: "http://example.com/x"))
    }

    /// 後続セグメントのコロンはファイル名として許し、先頭セグメントの
    /// URL スキームだけを外部参照として拒否する
    func testColonOnlyIndicatesSchemeInFirstSegment() {
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/package.opf",
                                  href: "images/12:34.png"),
            "OEBPS/images/12:34.png")
        XCTAssertNil(ContainerPath.resolve(base: "OEBPS/package.opf",
                                           href: "http://example.com/x"))
    }

    func testPercentDecoding() {
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/package.opf", href: "%E7%9B%AE%E6%AC%A1.xhtml"),
            "OEBPS/目次.xhtml")
    }

    func testDotSegmentAndRootRelative() {
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/package.opf", href: "./ch1.xhtml"),
            "OEBPS/ch1.xhtml")
        // 仕様外のルート相対はコンテナルート基準で解決する(寛容)
        XCTAssertEqual(
            ContainerPath.resolve(base: "OEBPS/package.opf", href: "/images/a.png"),
            "images/a.png")
    }
}
