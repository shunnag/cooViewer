import Foundation
import XCTest
@testable import Washi
@testable import WashiCore

/// cooViewer-oxr.46 C44: 自炊層に多い梱包ミスからの救済。
/// いずれも従来は notAnEPUB / resourceNotFound で開けなかった。
final class ContainerRescueTests: XCTestCase {
    private func entries(prefix: String = "",
                         opfName: String = "OEBPS/package.opf",
                         cssHref: String = "style.css",
                         cssName: String = "OEBPS/style.css")
        -> [(name: String, data: Data)] {
        let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/package.opf"
                media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:rescue</dc:identifier>
                <dc:title>救済</dc:title><dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-09T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/>
                <item id="s" href="\(cssHref)" media-type="text/css"/>
              </manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>本文</p></body></html>"
        _ = opfName
        return [
            ("\(prefix)mimetype", Data("application/epub+zip".utf8)),
            ("\(prefix)META-INF/container.xml", Data(container.utf8)),
            ("\(prefix)OEBPS/package.opf", Data(opf.utf8)),
            ("\(prefix)OEBPS/text/c.xhtml", Data(xhtml.utf8)),
            ("\(prefix)\(cssName)", Data("body{color:#000}".utf8)),
        ]
    }

    /// フォルダごと圧縮(OS の既定操作)で全エントリが 1 段深くなった本
    func testFolderCompressedRootPrefixIsDetected() throws {
        let data = ZipBuilder.build(entries(prefix: "わたしの本/"), method: 8)
        let book = try EPUBPublication(
            data: data, displayURL: URL(fileURLWithPath: "/tmp/rescue-prefix.epub"))
        XCTAssertEqual(book.readingOrder.count, 1)
        XCTAssertNoThrow(try book.resource(at: "OEBPS/text/c.xhtml"))
    }

    /// OPF の href と実体で大文字小文字が食い違う本(一意に定まる場合だけ救う)
    func testCaseMismatchedHrefResolvesWhenUnique() throws {
        let data = ZipBuilder.build(
            entries(cssHref: "Style.CSS", cssName: "OEBPS/style.css"), method: 8)
        let book = try EPUBPublication(
            data: data, displayURL: URL(fileURLWithPath: "/tmp/rescue-case.epub"))
        let css = try book.resource(at: "OEBPS/Style.CSS")
        XCTAssertEqual(String(data: css.data, encoding: .utf8), "body{color:#000}")
    }

    /// 旧 Windows ツールの \ 区切り(/ を含まない名前だけ直す)
    func testBackslashSeparatorsAreNormalized() throws {
        var raw = entries()
        raw = raw.map { ($0.name.replacingOccurrences(of: "/", with: "\\"), $0.data) }
        let data = ZipBuilder.build(raw, method: 8)
        let book = try EPUBPublication(
            data: data, displayURL: URL(fileURLWithPath: "/tmp/rescue-backslash.epub"))
        XCTAssertEqual(book.readingOrder.count, 1)
        XCTAssertNoThrow(try book.resource(at: "OEBPS/text/c.xhtml"))
    }

    /// 末尾にゴミが付いた ZIP(Python/Info-ZIP は開ける)
    func testTrailingGarbageAfterEndOfCentralDirectoryIsTolerated() throws {
        var data = ZipBuilder.build(entries(), method: 8)
        data.append(Data(repeating: 0x5A, count: 512))
        let book = try EPUBPublication(
            data: data, displayURL: URL(fileURLWithPath: "/tmp/rescue-garbage.epub"))
        XCTAssertEqual(book.readingOrder.count, 1)
        XCTAssertNoThrow(try book.resource(at: "OEBPS/text/c.xhtml"))
    }

    /// 正しい本は救済経路を通らずそのまま開ける(退行防止)
    func testWellFormedBookStillOpens() throws {
        let data = ZipBuilder.build(entries(), method: 8)
        let book = try EPUBPublication(
            data: data, displayURL: URL(fileURLWithPath: "/tmp/rescue-ok.epub"))
        XCTAssertEqual(book.readingOrder.count, 1)
        XCTAssertNoThrow(try book.resource(at: "OEBPS/style.css"))
    }
}
