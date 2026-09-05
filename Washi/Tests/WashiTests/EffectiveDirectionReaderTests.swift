import AppKit
import XCTest
@testable import Washi

@MainActor
private final class EffectiveDirectionReaderDelegateSpy: EPUBReaderViewDelegate {
    private(set) var moveCount = 0

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moveCount += 1
    }
}

@MainActor
final class EffectiveDirectionReaderTests: XCTestCase {
    /// cooViewer-oxr.36: PPD のない縦書き本も右綴じとして左方向に進む。
    func testPPDlessVerticalBookTurnsLeftForward() async throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = view.settings
        settings.columnMode = .single
        settings.pageTurnStyle = .none
        settings.insets = .zero
        view.settings = settings
        let delegate = EffectiveDirectionReaderDelegateSpy()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer {
            view.cancelPageCensus()
            view.delegate = nil
            window.contentView = nil
            window.close()
        }

        view.load(publication: publication)
        guard await waitUntil({ delegate.moveCount > 0 }) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }
        guard view.pageCountInItem > 1 else {
            XCTFail("縦書き本文が複数ページへ分割されること")
            return
        }

        XCTAssertEqual(publication.readingDirection, .byDefault)
        XCTAssertEqual(publication.effectiveReadingDirection, .rtl)
        XCTAssertEqual(publication.effectiveReadingDirectionSource,
                       .verticalWritingCSS)
        XCTAssertTrue(view.isRTL)

        view.turnPageLeft()

        let advanced = await waitUntil { view.pageInItem > 0 }
        XCTAssertTrue(advanced)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertGreaterThan(view.pageInItem, 0)
        XCTAssertFalse(view.canGoBack)
    }

    private func makePublication() throws -> EPUBPublication {
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">effective-reader-direction</dc:identifier>
            <dc:title>Effective direction</dc:title>
            <dc:language>ja</dc:language>
          </metadata>
          <manifest>
            <item id="first" href="text/first.xhtml"
                  media-type="application/xhtml+xml"/>
            <item id="second" href="text/second.xhtml"
                  media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="first"/><itemref idref="second"/></spine>
        </package>
        """
        let paragraphs = (0..<160).map {
            "<p>第\($0)段落。縦書きのページ送りを確認する本文。</p>"
        }.joined()
        let first = """
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>First</title><style>html{-epub-writing-mode:vertical-rl}</style></head>
          <body>\(paragraphs)</body>
        </html>
        """
        let second = """
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Second</title></head><body><p>次の項目</p></body>
        </html>
        """
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(package.utf8)),
            ("OEBPS/text/first.xhtml", Data(first.utf8)),
            ("OEBPS/text/second.xhtml", Data(second.utf8)),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/effective-reader-direction.epub"))
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000),
                                size: view.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        return window
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
