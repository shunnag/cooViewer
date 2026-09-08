import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class OverlayAuditDelegate: EPUBReaderViewDelegate {
    var onPlayingChanged: ((EPUBReaderView, Bool) -> Void)?
    var finishes = 0
    func readerView(_ view: EPUBReaderView, isPlayingMediaOverlayDidChange playing: Bool) {
        onPlayingChanged?(view, playing)
    }
    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView) { finishes += 1 }
}

@MainActor
final class EPUBReaderStateRegressionTests: XCTestCase {
    private func publication(_ entries: [(name: String, data: Data)]) throws -> EPUBPublication {
        try EPUBPublication(data: ZipBuilder.build(entries, method: 8),
                            displayURL: URL(fileURLWithPath: "/tmp/original-audit.epub"))
    }

    private func silentOverlayPublication(parCount: Int = 3) throws -> EPUBPublication {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML:
            (0..<parCount).map { "<p id=\"p\($0)\">Paragraph \($0)</p>" }.joined())
        let index = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/package.opf" })
        entries[index].data = Data(String(decoding: entries[index].data, as: UTF8.self)
            .replacingOccurrences(of: "id=\"c\" href=", with: "id=\"c\" media-overlay=\"mo\" href=")
            .replacingOccurrences(of: "</manifest>", with:
                "<item id=\"mo\" href=\"overlay.smil\" media-type=\"application/smil+xml\"/></manifest>")
            .utf8)
        let pars = (0..<parCount).map {
            "<par><text src=\"text/c.xhtml#p\($0)\"/></par>"
        }.joined()
        entries.append(("OEBPS/overlay.smil", Data(
            "<smil xmlns=\"http://www.w3.org/ns/SMIL\"><body><seq>\(pars)</seq></body></smil>".utf8)))
        return try publication(entries)
    }

    private func window(for view: EPUBReaderView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private func activeID(in webView: WKWebView) async -> String? {
        try? await webView.evaluateJavaScript(
            "document.querySelector('.-epub-media-overlay-active')?.id || ''") as? String
    }

    func testImportRejectsInvalidCountsWithoutReplacingValidCensus() throws {
        let book = try publication(EPUBFixtures.verticalNovelEntries())
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.load(publication: book)
        let key = EPUBScreenMetrics(viewportSize: view.bounds.size, settings: view.settings,
                                    renditionSpread: book.metadata.rendition.spread).cacheKey
        let valid = EPUBCensusRecord(metricsKey: key, counts: [2, 3, 1],
                                    releaseIdentifier: book.metadata.releaseIdentifier)
        XCTAssertTrue(view.importCensus(valid))
        for counts in [[0, 1, 1], [-1, 2, 1], [Int.min, 1, 1], [Int.max, 1, 1], [Int.max, Int.max, 1]] {
            XCTAssertFalse(view.importCensus(EPUBCensusRecord(
                metricsKey: key, counts: counts,
                releaseIdentifier: book.metadata.releaseIdentifier)), "\(counts)")
            XCTAssertEqual(view.exportCensus(), valid)
        }
    }

    func testFixedToReflowTransitionRestoresUnitZoom() async throws {
        var entries = EPUBFixtures.fxlComicEntries()
        let index = try XCTUnwrap(entries.firstIndex { $0.name == "OEBPS/package.opf" })
        entries[index].data = Data(String(decoding: entries[index].data, as: UTF8.self)
            .replacingOccurrences(of: "idref=\"p2\" properties=\"", with:
                "idref=\"p2\" properties=\"rendition:layout-reflowable ").utf8)
        let book = try publication(entries)
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = window(for: view)
        defer { view.cancelPageCensus(); window.contentView = nil; window.close() }
        view.load(publication: book)
        view.layoutSubtreeIfNeeded()
        let web = try XCTUnwrap(view.subviews.first { $0 is WKWebView } as? WKWebView)
        for _ in 0..<250 where web.alphaValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(web.alphaValue, 0, "The fixed page must finish loading")
        XCTAssertLessThan(web.pageZoom, 1)
        view.go(to: book.locator(forSpineIndex: 1, progression: 0))
        XCTAssertEqual(web.pageZoom, 1, "Reset before the new document is paginated")
        for _ in 0..<250 where web.alphaValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(web.alphaValue, 0)
        XCTAssertEqual(web.pageZoom, 1)
        view.go(to: book.locator(forSpineIndex: 0, progression: 0))
        for _ in 0..<250 where web.alphaValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(web.alphaValue, 0)
        XCTAssertLessThan(web.pageZoom, 1, "Returning to FXL still aspect-fits the page")
    }

    func testMaximumCensusCountMapsEndWithoutFloatingPointConversionTrap() throws {
        let book = try publication(EPUBFixtures.singleSpineEntries(bodyHTML: "<p>Text</p>"))
        let view = EPUBReaderView(frame: .zero)
        view.load(publication: book)
        let key = EPUBScreenMetrics(viewportSize: view.bounds.size, settings: view.settings).cacheKey
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: key, counts: [Int.max],
            releaseIdentifier: book.metadata.releaseIdentifier)))
        XCTAssertEqual(view.censusPageOffset(forSpineIndex: 1), Int.max)
        XCTAssertEqual(view.censusGlobalPage(for: book.locator(forSpineIndex: 0, progression: 1)),
                       Int.max - 1)
        XCTAssertEqual(view.censusGlobalPage(for: book.locator(forSpineIndex: 0, progression: 0)), 0)
    }

    func testSilentOverlayResumesCurrentPar() async throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = window(for: view)
        defer {
            view.stopMediaOverlay(); view.cancelPageCensus()
            window.contentView = nil; window.close()
        }
        view.load(publication: try silentOverlayPublication())
        let web = try XCTUnwrap(view.subviews.first { $0 is WKWebView } as? WKWebView)
        for _ in 0..<250 where web.alphaValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(web.alphaValue, 0)
        view.playMediaOverlay()
        for _ in 0..<100 {
            if await activeID(in: web) == "p1" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = await activeID(in: web)
        XCTAssertEqual(before, "p1")
        view.pauseMediaOverlay()
        view.playMediaOverlay()
        try await Task.sleep(for: .milliseconds(50))
        let after = await activeID(in: web)
        XCTAssertEqual(after, "p1", "Resuming a silent par must not restart the chapter")
    }

    func testFinishCallbackDoesNotLeakIntoReplacementBook() async throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = OverlayAuditDelegate()
        view.delegate = delegate
        let replacement = try publication(EPUBFixtures.verticalNovelEntries())
        view.load(publication: try silentOverlayPublication(parCount: 1))
        delegate.onPlayingChanged = { view, playing in
            if !playing { view.load(publication: replacement) }
        }
        view.playMediaOverlay()
        for _ in 0..<100 where view.publication !== replacement {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(view.publication === replacement)
        XCTAssertEqual(delegate.finishes, 0, "Old-book finish must not follow a reentrant load")
    }

    func testFinishCallbackDoesNotFollowReentrantRestart() async throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = OverlayAuditDelegate()
        view.delegate = delegate
        view.load(publication: try silentOverlayPublication(parCount: 1))
        var restarted = false
        delegate.onPlayingChanged = { view, playing in
            if !playing && !restarted {
                restarted = true
                view.playMediaOverlay()
            }
        }
        view.playMediaOverlay()
        defer { delegate.onPlayingChanged = nil; view.stopMediaOverlay() }
        for _ in 0..<100 where !restarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(restarted)
        XCTAssertTrue(view.isPlayingMediaOverlay)
        XCTAssertEqual(delegate.finishes, 0)
        for _ in 0..<100 where view.isPlayingMediaOverlay {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(view.isPlayingMediaOverlay)
        XCTAssertEqual(delegate.finishes, 1, "Uninterrupted completion must still be reported once")
    }
}
