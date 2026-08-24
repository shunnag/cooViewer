import XCTest
@testable import Washi

/// コンテナ内パス解決の検証
final class ContainerPathTests: XCTestCase {
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

    func testResolveRejectsEscapeAndAbsoluteURL() {
        XCTAssertNil(ContainerPath.resolve(base: "a.opf", href: "../outside.xhtml"))
        XCTAssertNil(ContainerPath.resolve(base: "OEBPS/a.opf",
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
