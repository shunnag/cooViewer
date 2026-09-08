import AppKit
import Foundation
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

/// cooViewer-oxr.46 C42: WebKit に別名の無い -epub- 接頭辞 CSS の補完。
/// 対象は macOS 26 / WebKit の実測で解釈されなかった 6 プロパティ。
final class PrefixedCSSPolyfillTests: XCTestCase {
    func testAddsStandardDeclarationKeepingOriginal() {
        let css = ".tcy { -epub-text-combine-horizontal: all; }"
        let out = EPUBPrefixedCSS.polyfilled(css)
        XCTAssertTrue(out.contains("-epub-text-combine-horizontal: all"))
        XCTAssertTrue(out.contains("text-combine-upright: all"), out)
    }

    func testHandlesDeclarationWithoutTrailingSemicolon() {
        let css = "p { -epub-line-break: strict }"
        let out = EPUBPrefixedCSS.polyfilled(css)
        XCTAssertTrue(out.contains("line-break: strict"), out)
        XCTAssertTrue(out.hasSuffix("}"), out)
    }

    func testKeepsImportantAndMultipleDeclarations() {
        let css = """
            .a { -epub-text-align-last: center !important; color: red; }
            .b { -epub-ruby-position: under; }
            """
        let out = EPUBPrefixedCSS.polyfilled(css)
        XCTAssertTrue(out.contains("text-align-last: center !important"), out)
        XCTAssertTrue(out.contains("ruby-position: under"), out)
        XCTAssertTrue(out.contains("color: red"), out)
    }

    /// WebKit が解釈するものは触らない(二重宣言を増やさない)
    func testLeavesSupportedPrefixedPropertiesAlone() {
        let css = "p { -epub-writing-mode: vertical-rl; -epub-word-break: break-all; }"
        XCTAssertEqual(EPUBPrefixedCSS.polyfilled(css), css)
    }

    /// 名前の一部に一致するだけの綴りへ誤爆しない
    func testDoesNotMatchLongerPropertyNames() {
        let css = "p { -epub-line-breaking: strict; }"
        XCTAssertEqual(EPUBPrefixedCSS.polyfilled(css), css)
    }

    func testNonCSSDataIsUntouched() {
        let data = Data("body{color:#000}".utf8)
        XCTAssertEqual(EPUBPrefixedCSS.polyfilledStylesheet(data), data)
    }
}

/// 実際に配信して WebKit の算出値が変わることまで見る(縦中横が本題)。
@MainActor
final class PrefixedCSSDeliveryTests: XCTestCase {
    func testCombineHorizontalReachesWebKitThroughSchemeHandler() async throws {
        let css = ".tcy { -epub-text-combine-horizontal: all; }"
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><meta charset=\"UTF-8\"/>"
            + "<link rel=\"stylesheet\" type=\"text/css\" href=\"s.css\"/></head>"
            + "<body><p>本文<span class=\"tcy\" id=\"t\">12</span>年</p></body></html>"
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:tcy</dc:identifier>
                <dc:title>縦中横</dc:title><dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-09T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
                <item id="s" href="s.css" media-type="text/css"/>
              </manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/package.opf"
                media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
        let publication = try EPUBPublication(
            data: ZipBuilder.build([
                ("mimetype", Data("application/epub+zip".utf8)),
                ("META-INF/container.xml", Data(container.utf8)),
                ("OEBPS/package.opf", Data(opf.utf8)),
                ("OEBPS/c.xhtml", Data(xhtml.utf8)),
                ("OEBPS/s.css", Data(css.utf8)),
            ], method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-tcy.epub"))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = EPUBSchemeHandler(publication: publication, allowsScripts: false)
        configuration.setURLSchemeHandler(handler, forURLScheme: EPUBSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                configuration: configuration)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        let entry = try XCTUnwrap(publication.readingOrder.first)
        let url = try XCTUnwrap(handler.url(forReadingOrderItem: entry))
        waiter.expect(webView.load(URLRequest(url: url)))
        try await waiter.wait(timeout: .seconds(15))
        withExtendedLifetime(waiter) {}

        let value = try await Task(priority: .userInitiated) { @MainActor () -> String in
            let result = try await webView.callAsyncJavaScript("""
                const el = document.getElementById('t');
                return getComputedStyle(el).getPropertyValue('text-combine-upright');
                """, arguments: [:], in: nil, contentWorld: .page)
            return (result as? String) ?? ""
        }.value
        XCTAssertEqual(value.trimmingCharacters(in: .whitespaces), "all",
                       "縦中横が WebKit へ届いていない")
        webView.navigationDelegate = nil
    }
}
