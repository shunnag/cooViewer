import AppKit
import Washi
import XCTest
@testable import cooViewer

@MainActor
final class ThumbnailHostingLifecycleTests: XCTestCase {
    func testFirstRevealCreatesOneHostAndKeepsItAboveLaterSubviews() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ReaderWindowController(window: window)
        controller.setUpContentViews(in: window)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertNil(controller.thumbnailHostingView)
        controller.hideThumbnailOverlay()
        XCTAssertNil(controller.thumbnailHostingView)

        controller.revealThumbnailOverlay()
        let host = try XCTUnwrap(controller.thumbnailHostingView)
        XCTAssertTrue(host.superview === content)
        XCTAssertTrue(content.subviews.last === host)
        XCTAssertTrue(controller.isThumbnailOverlayVisible)
        XCTAssertEqual(host.frame, content.bounds)

        controller.hideThumbnailOverlay()
        XCTAssertFalse(controller.isThumbnailOverlayVisible)
        content.addSubview(NSView())
        window.setContentSize(NSSize(width: 800, height: 600))
        controller.revealThumbnailOverlay()
        XCTAssertTrue(controller.thumbnailHostingView === host)
        XCTAssertTrue(content.subviews.last === host)
        XCTAssertEqual(host.frame, content.bounds)
        XCTAssertEqual(content.constraints.filter { $0.firstItem === host }.count, 4)
    }

    func testRevealWithoutWindowDoesNotCreateHost() {
        let controller = ReaderWindowController(window: nil)
        controller.revealThumbnailOverlay()
        XCTAssertNil(controller.thumbnailHostingView)
        XCTAssertFalse(controller.isThumbnailOverlayVisible)
    }

    func testEPUBToggleUsesTheSameLazyHost() throws {
        // 設計書 §2.4・§7.6: 本文の WebKit 読み込みとは独立に、EPUB の
        // メニュー入口でも初回生成・再表示・閉じる操作が同じホストへ合流する。
        let files = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
                <rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """),
            ("package.opf", """
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">thumbnail-host</dc:identifier><dc:title>一覧</dc:title><dc:language>ja</dc:language>
                </metadata><manifest><item id="p" href="page.xhtml" media-type="application/xhtml+xml"/></manifest>
                <spine><itemref idref="p"/></spine></package>
                """),
            ("page.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>一覧</title></head><body>本文</body></html>"),
        ]
        let url = URL(fileURLWithPath: "/test/thumbnail-host.epub")
        let publication = try EPUBPublication(
            data: TestFixtures.storedZip(entries: files.map { (Array($0.0.utf8), Data($0.1.utf8)) }),
            displayURL: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ReaderWindowController(window: window)
        controller.epubView = EPUBReaderView()
        controller.epubSession = EPUBReadingSession(publication: publication, url: url)
        defer {
            controller.hideThumbnailOverlay()
            controller.epubSession?.end()
        }
        XCTAssertNil(controller.thumbnailHostingView)
        controller.toggleThumbnailOverlay()
        let host = try XCTUnwrap(controller.thumbnailHostingView)
        XCTAssertTrue(controller.isThumbnailOverlayVisible)
        XCTAssertEqual(controller.thumbnailOverlayModel.snapshot.entries.count, 1)
        controller.toggleThumbnailOverlay()
        XCTAssertFalse(controller.isThumbnailOverlayVisible)
        controller.toggleThumbnailOverlay()
        XCTAssertTrue(controller.thumbnailHostingView === host)
        XCTAssertTrue(controller.isThumbnailOverlayVisible)
    }
}
