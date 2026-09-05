import AppKit
import Washi
import XCTest

@testable import cooViewer

/// EPUB 表示を離れた後のビュー寿命を検証する(cooViewer-oxr.79、設計書 §2.4)。
@MainActor
final class EPUBViewLifecycleTests: XCTestCase {
    func testDismissEPUBModeDetachesViewButRetainsInstance() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ReaderWindowController(window: window)
        let view = EPUBReaderView()
        let contentView = try XCTUnwrap(controller.window?.contentView)
        contentView.addSubview(view)
        controller.epubView = view
        controller.epubPublication = try makePublication()

        controller.dismissEPUBMode()

        XCTAssertNil(view.superview)
        XCTAssertTrue(controller.epubView === view)
    }

    private func makePublication() throws -> EPUBPublication {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">epub-view-lifecycle-test</dc:identifier>
            <dc:title>ビュー寿命</dc:title>
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-09-05T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let chapter = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>本文</title></head><body><p>本文</p></body>
        </html>
        """
        let data = TestFixtures.storedZip(entries: [
            (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
            (Array("META-INF/container.xml".utf8), Data(container.utf8)),
            (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
            (Array("OEBPS/chapter.xhtml".utf8), Data(chapter.utf8)),
        ])
        return try EPUBPublication(
            data: data,
            displayURL: URL(fileURLWithPath: "/test/epub-view-lifecycle.epub"))
    }
}
