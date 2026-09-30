import AppKit
import SwiftUI
import Washi
import XCTest

@testable import cooViewer

/// EPUB 表示を離れた後のビュー寿命を検証する(cooViewer-oxr.79、設計書 §2.4)。
@MainActor
final class EPUBViewLifecycleTests: XCTestCase {
    func testNonFinitePercentageDoesNotChangeEPUBPosition() throws {
        let controller = ReaderWindowController(window: nil)
        let view = EPUBReaderView()
        controller.epubView = view
        controller.epubSession = EPUBReadingSession(
            publication: try makePublication(),
            url: URL(fileURLWithPath: "/test/epub-view-lifecycle.epub"))
        let initial = view.currentLocator
        for value in [Double.nan, .infinity, -.infinity] {
            controller.epubJump(toBookFraction: value)
            XCTAssertEqual(view.currentLocator, initial)
        }
    }

    func testDismissEPUBModeDetachesViewButRetainsInstance() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ReaderWindowController(window: window)
        let view = EPUBReaderView()
        let contentView = try XCTUnwrap(controller.window?.contentView)
        contentView.addSubview(view)
        controller.epubView = view
        controller.epubSession = EPUBReadingSession(
            publication: try makePublication(),
            url: URL(fileURLWithPath: "/test/epub-view-lifecycle.epub"))

        controller.dismissEPUBMode()

        XCTAssertNil(view.superview)
        XCTAssertTrue(controller.epubView === view)
        XCTAssertNil(controller.epubSession)
    }

    func testSessionEndCancelsWorkAndRemovesTransientViews() throws {
        let session = try makeSession()
        let task = Task<Void, Never> { await Task.yield() }
        session.saveDebounce = task
        session.search.task = task
        session.search.landingTask = task
        session.footnoteTask = task
        let model = EPUBSearchModel()
        model.beginSearch(query: "本文")
        session.search.model = model
        let parent = NSView()
        let curlHost = NSView()
        let highlight = EPUBSearchHighlightHostView()
        parent.addSubview(curlHost)
        parent.addSubview(highlight)
        session.curlHosts = [curlHost]
        session.search.highlightHost = highlight

        session.end()
        session.end()

        XCTAssertFalse(session.isActive)
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(session.saveDebounce)
        XCTAssertNil(session.search.task)
        XCTAssertNil(session.search.landingTask)
        XCTAssertNil(session.footnoteTask)
        XCTAssertNil(curlHost.superview)
        XCTAssertNil(highlight.superview)
        XCTAssertFalse(model.isSearching)
    }

    func testOldPanelAndTaskCannotControlNewSessionWithSamePublication() async throws {
        let window = makeWindow()
        let controller = ReaderWindowController(window: window)
        let first = try makeSession()
        controller.epubSession = first
        controller.showEPUBSearchMenu(nil)
        let oldView = try searchView(in: first)
        oldView.onQueryChange("本文")
        let oldTask = try XCTUnwrap(first.search.task)

        first.end()
        let next = EPUBReadingSession(publication: first.publication, url: first.url)
        controller.epubSession = next
        defer { next.end() }
        controller.showEPUBSearchMenu(nil)
        let newView = try searchView(in: next)
        newView.onQueryChange("新しい検索")
        let newTask = try XCTUnwrap(next.search.task)
        let epoch = next.search.queryEpoch
        let panel = next.search.panel

        oldView.onQueryChange("古い検索")
        oldView.onSearchNow("本文")
        oldView.onSelect(0)
        oldView.onNext()
        oldView.onPrevious()
        oldView.onClose()
        await oldTask.value

        XCTAssertFalse(controller.ownsEPUBSession(first))
        XCTAssertTrue(controller.ownsEPUBSession(next))
        XCTAssertEqual(next.search.queryEpoch, epoch)
        XCTAssertEqual(next.search.model?.pendingQuery, "新しい検索")
        XCTAssertTrue(next.search.panel === panel)
        await newTask.value
        XCTAssertEqual(next.search.model?.completedQuery, "新しい検索")
    }

    func testClosedPanelCannotControlReopenedSearchInSameSession() throws {
        let controller = ReaderWindowController(window: makeWindow())
        let session = try makeSession()
        controller.epubSession = session
        defer { session.end() }
        controller.showEPUBSearchMenu(nil)
        let oldView = try searchView(in: session)
        controller.teardownEPUBSearch()
        controller.showEPUBSearchMenu(nil)
        let newPanel = session.search.panel
        let epoch = session.search.queryEpoch

        oldView.onSearchNow("本文")
        oldView.onClose()

        XCTAssertEqual(session.search.queryEpoch, epoch)
        XCTAssertNil(session.search.task)
        XCTAssertTrue(session.search.panel === newPanel)
    }

    func testConfiguringSamePublicationSuppressesReadingCallbacks() throws {
        let controller = ReaderWindowController(window: nil)
        let session = try makeSession()
        let view = EPUBReaderView()
        controller.epubView = view
        controller.epubSession = session
        view.load(publication: session.publication)
        defer { session.end(); view.cancelPageCensus() }
        XCTAssertTrue(controller.acceptsEPUBCallback(from: view))

        session.isConfiguringView = true
        controller.readerView(view, didMoveTo: EPUBLocator(spineIndex: 0, progression: 1),
                              pageInItem: 1, pageCountInItem: 2)
        controller.readerViewDidUpdatePageCensus(view)

        XCTAssertFalse(session.contentLoaded)
        XCTAssertEqual(session.search.moveCount, 0)
        XCTAssertNil(session.saveSchedule.lastAttemptAt)
        session.isConfiguringView = false
        XCTAssertTrue(controller.acceptsEPUBCallback(from: view))
        session.end()
        XCTAssertFalse(controller.acceptsEPUBCallback(from: view))
    }

    func testWindowCloseRetainsReadingSessionForReopen() throws {
        let window = makeWindow()
        let controller = ReaderWindowController(window: window)
        let session = try makeSession()
        let view = EPUBReaderView()
        controller.epubSession = session
        controller.epubView = view
        session.latestSelectionText = "本文"
        controller.showEPUBSearchMenu(nil)
        defer { session.end(); window.orderOut(nil) }

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification,
                                               object: window))
        controller.showWindow(nil)

        XCTAssertTrue(controller.epubSession === session)
        XCTAssertTrue(controller.ownsEPUBSession(session))
        XCTAssertTrue(controller.epubView === view)
        XCTAssertEqual(session.latestSelectionText, "本文")
        XCTAssertNil(session.search.panel)
    }

    func testBookmarkEditsAfterSameURLReopenSurviveLaterStateSave() throws {
        let suite = "test.cooViewer.epub-session.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = try TestFixtures.makeTempDir()
        let stateDirectory = directory.appendingPathComponent("BookStates")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = BookHistoryStore(defaults: defaults, directory: stateDirectory)
        let url = directory.appendingPathComponent("reopened.epub")
        try Data("test".utf8).write(to: url)
        let publication = try makePublication()
        let original = EPUBLocator(spineIndex: 0, progression: 0.4)
        let first = EPUBReadingSession(publication: publication, url: url,
            bookmarks: [("before", original), ("remove", original)])
        let window = makeWindow()
        let controller = ReaderWindowController(window: window, history: history)
        let view = EPUBReaderView()
        controller.epubSession = first
        controller.epubView = view
        controller.editEPUBBookmarks()
        let editor = try XCTUnwrap(controller.bookmarkEditorWindow?.contentViewController
            as? NSHostingController<EPUBBookmarkEditorView>).rootView

        first.end()
        let reopened = EPUBReadingSession(publication: publication, url: url,
                                           bookmarks: first.bookmarks)
        controller.epubSession = reopened
        defer { reopened.end(); view.cancelPageCensus(); window.orderOut(nil) }
        // 古いシートのページ編集は再計算せず、名前変更と削除は現在の本にも反映する。
        editor.onSave([("after", original, 99)])
        editor.onClose()
        XCTAssertEqual(reopened.bookmarks.map(\.name), ["after"])
        XCTAssertEqual(reopened.bookmarks.first?.locator, original)

        view.load(publication: publication)
        controller.saveEPUBState()
        XCTAssertNotNil(reopened.saveSchedule.lastSuccessfulSaveAt)
        let restored = BookHistoryStore(defaults: defaults, directory: stateDirectory)
            .savedReflowBookmarks(forPath: url.path)
        XCTAssertEqual(restored.map(\.name), ["after"])
        XCTAssertEqual(restored.first?.progression, original.progression)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                 styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func makeSession() throws -> EPUBReadingSession {
        EPUBReadingSession(publication: try makePublication(),
                           url: URL(fileURLWithPath: "/test/epub-view-lifecycle.epub"))
    }

    private func searchView(in session: EPUBReadingSession) throws -> EPUBSearchView {
        let host = try XCTUnwrap(session.search.panel?.contentViewController
            as? NSHostingController<EPUBSearchView>)
        return host.rootView
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
