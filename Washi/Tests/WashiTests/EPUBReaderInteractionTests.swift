import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class ReaderInteractionDelegate: EPUBReaderViewDelegate {
    var moves = 0
    var clicks: [EPUBClickEvent] = []
    var selections: [EPUBTextSelection?] = []
    var printPages: [String?] = []
    var suppressesContextMenuFromDelegate = false
    var contextMenuCallCount = 0
    var contextMenuItemCounts: [Int] = []
    var contextMenuEvents: [EPUBClickEvent?] = []
    var contextMenuResolver: ((NSMenu) -> NSMenu?)?

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moves += 1
    }

    func readerView(_ view: EPUBReaderView,
                    didClick event: EPUBClickEvent) -> Bool {
        clicks.append(event)
        return true
    }

    func readerView(_ view: EPUBReaderView,
                    selectionDidChange selection: EPUBTextSelection?) {
        selections.append(selection)
    }

    func readerView(_ view: EPUBReaderView,
                    didChangePrintPage label: String?) {
        printPages.append(label)
    }

    func readerView(_ view: EPUBReaderView, willShowContextMenu menu: NSMenu,
                    at event: EPUBClickEvent?) -> NSMenu? {
        contextMenuCallCount += 1
        contextMenuItemCounts.append(menu.items.count)
        contextMenuEvents.append(event)
        if let contextMenuResolver {
            return contextMenuResolver(menu)
        }
        return suppressesContextMenuFromDelegate ? nil : menu
    }
}

@MainActor
final class EPUBReaderInteractionTests: XCTestCase {
    private func makePublication(body: String) throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.singleSpineEntries(bodyHTML: body), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-reader-interaction.epub"))
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

    private func close(_ window: NSWindow, view: EPUBReaderView) {
        view.cancelPageCensus()
        view.delegate = nil
        window.contentView = nil
        window.close()
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

    /// cooViewer-oxr.34: DOM 選択を検索と同じ正規化本文へ写し、view 矩形へ
    /// 逆写像でき、可視ページを変えずに着地し、clearSelection が nil を
    /// 通知することを検証する。
    func testSelectionAPIReportsRoundTripsAndClears() async throws {
        let body = (1...30).map {
            "<p id=\"p\($0)\">段落\($0) の選択対象本文です。</p>"
        }.joined()
        let publication = try makePublication(body: body)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = view.settings
        settings.columnMode = .single
        view.settings = settings
        let delegate = ReaderInteractionDelegate()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        guard await waitUntil({ delegate.moves > 0 }) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }
        let webView = try XCTUnwrap(
            view.subviews.first { $0 is WKWebView } as? WKWebView)
        let selected = try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                """
                const node = document.getElementById('p1').firstChild;
                window.getSelection().setBaseAndExtent(node, 0, node, 6);
                return true;
                """,
                arguments: [:], in: nil, contentWorld: EPUBReaderView.washiWorld)
            return result as? Bool ?? false
        }.value
        XCTAssertTrue(selected)
        let didPublishSelection = await waitUntil {
            view.currentSelection != nil
        }
        XCTAssertTrue(didPublishSelection)
        let selection = try XCTUnwrap(view.currentSelection)
        XCTAssertFalse(selection.text.isEmpty)
        XCTAssertEqual(selection.spineIndex, 0)
        XCTAssertGreaterThan(selection.utf16Range.count, 0)
        XCTAssertFalse(selection.rects.isEmpty)

        let mappedRects = await view.rects(
            forTextRange: selection.utf16Range,
            inSpineIndex: selection.spineIndex)
        XCTAssertFalse(mappedRects.isEmpty)
        let pageBefore = view.pageInItem
        let landing = await view.go(
            to: view.currentLocator,
            textRange: (selection.utf16Range.lowerBound,
                        selection.utf16Range.count))
        XCTAssertNotNil(landing)
        XCTAssertEqual(view.pageInItem, pageBefore)

        view.clearSelection()
        XCTAssertNil(view.currentSelection)
        let didPublishClearedSelection = await waitUntil {
            guard let last = delegate.selections.last else { return false }
            return last == nil && delegate.selections.count >= 2
        }
        XCTAssertTrue(didPublishClearedSelection)
    }

    /// cooViewer-oxr.35: 本文と余白の経路が同じ合成点を reader 座標で表し、
    /// context-menu delegate の nil が menu を空にして抑止することを検証する。
    func testClickLocationsAndContextMenuDelegateIntervention() throws {
        let publication = try makePublication(body: "<p>本文</p>")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let delegate = ReaderInteractionDelegate()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        let webView = try XCTUnwrap(
            view.subviews.first { $0 is WKWebView } as? WKWebView)
        XCTAssertEqual(view.contentFrame, webView.frame)

        let point = CGPoint(x: 20, y: 200)
        let normalizedX = Double((point.x - webView.frame.minX)
                                 / webView.frame.width)
        let normalizedY = Double(1 - (point.y - webView.frame.minY)
                                 / webView.frame.height)
        view.handleScriptMessage([
            "type": "tap", "x": normalizedX, "y": normalizedY,
            "button": 0, "shift": false, "alt": false,
            "ctrl": false, "meta": false,
        ])
        let contentLocation = try XCTUnwrap(delegate.clicks.last?.locationInView)

        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: 1.1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        let marginLocation = try XCTUnwrap(delegate.clicks.last?.locationInView)
        XCTAssertEqual(contentLocation.x, point.x, accuracy: 0.001)
        XCTAssertEqual(contentLocation.y, point.y, accuracy: 0.001)
        XCTAssertEqual(marginLocation.x, contentLocation.x, accuracy: 0.001)
        XCTAssertEqual(marginLocation.y, contentLocation.y, accuracy: 0.001)

        delegate.suppressesContextMenuFromDelegate = true
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        XCTAssertNil(view.contextMenu(menu, for: down))
        XCTAssertTrue(menu.items.isEmpty)
    }

    /// cooViewer-oxr.93: policy が native 項目をすべて除いても delegate を
    /// 1 回呼び、delegate の nil／空／非空 menu で表示可否を決めることを検証する。
    func testContextMenuDelegateRunsOnceAfterFilteringAndControlsPresentation()
        throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let delegate = ReaderInteractionDelegate()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: try makePublication(body: "<p>本文</p>"))
        let webView = try XCTUnwrap(
            view.subviews.first { $0 is WKWebView } as? WKWebView)

        let point = CGPoint(x: 20, y: 200)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))

        func makeWebKitNavigationMenu() -> NSMenu {
            let menu = NSMenu()
            let reload = NSMenuItem(
                title: "Reload", action: nil, keyEquivalent: "")
            reload.identifier = NSUserInterfaceItemIdentifier(
                "WKMenuItemIdentifierReload")
            menu.addItem(reload)
            let goBack = NSMenuItem(
                title: "Go Back", action: nil, keyEquivalent: "")
            goBack.identifier = NSUserInterfaceItemIdentifier(
                "WKMenuItemIdentifierGoBack")
            menu.addItem(goBack)
            return menu
        }

        var settings = view.settings
        settings.contextMenuPolicy = .readingDefault
        view.settings = settings
        let filteredMenu = makeWebKitNavigationMenu()
        let filteredResult = view.contextMenu(filteredMenu, for: event)
        XCTAssertEqual(delegate.contextMenuCallCount, 1)
        XCTAssertEqual(delegate.contextMenuItemCounts, [0])
        let filteredEvent = try XCTUnwrap(
            delegate.contextMenuEvents.first.flatMap { $0 })
        XCTAssertEqual(filteredEvent.locationInView.x, point.x, accuracy: 0.001)
        XCTAssertEqual(filteredEvent.locationInView.y, point.y, accuracy: 0.001)
        XCTAssertTrue(filteredResult === filteredMenu)
        XCTAssertTrue(filteredResult?.items.isEmpty == true)

        let customMenu = NSMenu()
        customMenu.addItem(withTitle: "Host Action", action: nil,
                           keyEquivalent: "")
        delegate.contextMenuResolver = { _ in customMenu }
        settings.contextMenuPolicy = .suppressed
        view.settings = settings
        let suppressedMenu = makeWebKitNavigationMenu()
        webView.willOpenMenu(suppressedMenu, with: event)
        XCTAssertEqual(delegate.contextMenuCallCount, 2)
        XCTAssertEqual(delegate.contextMenuItemCounts, [0, 0])
        XCTAssertEqual(suppressedMenu.items.map(\.title), ["Host Action"])

        delegate.contextMenuResolver = { _ in nil }
        settings.contextMenuPolicy = .system
        view.settings = settings
        let nilMenu = makeWebKitNavigationMenu()
        webView.willOpenMenu(nilMenu, with: event)
        XCTAssertEqual(delegate.contextMenuCallCount, 3)
        XCTAssertEqual(delegate.contextMenuItemCounts, [0, 0, 2])
        XCTAssertTrue(nilMenu.items.isEmpty)
    }

    /// cooViewer-oxr.35: native ノンブル上の click も NSTextField に奪われず、
    /// reader の余白入力として同じ view 座標で delegate へ届くことを検証する。
    func testFurnitureHitTestingPassesClicksThroughToReader() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let delegate = ReaderInteractionDelegate()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: try makePublication(body: "<p>本文</p>"))

        let furniture = try XCTUnwrap(view.subviews.compactMap {
            $0 as? NSTextField
        }.first(where: { !$0.isHidden }))
        let point = CGPoint(x: furniture.frame.midX, y: furniture.frame.midY)
        guard let hit = view.hitTest(point) as? EPUBReaderView else {
            XCTFail("page furniture must pass hit testing through to the reader")
            return
        }
        XCTAssertTrue(hit === view)

        let windowPoint = view.convert(point, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [],
            timestamp: 2, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: windowPoint, modifierFlags: [],
            timestamp: 2.1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 4, clickCount: 1, pressure: 0))
        hit.mouseDown(with: down)
        hit.mouseUp(with: up)

        let click = try XCTUnwrap(delegate.clicks.last)
        XCTAssertEqual(click.locationInView.x, point.x, accuracy: 0.001)
        XCTAssertEqual(click.locationInView.y, point.y, accuracy: 0.001)
    }

    /// cooViewer-oxr.37: 重複したページ通知を確定時の 1 回へ畳み、view が
    /// reader label とページ value を公開することを検証する。
    func testAccessibilityAnnouncementSettlesOnceAndPublishesViewMetadata() async throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.accessibilityAnnouncementDelay = .zero
        view.accessibilityPreferredLanguageOverride = "en"
        var announcements: [String] = []
        view.accessibilityAnnouncementHandler = { announcements.append($0) }

        let page0: [String: Any] = [
            "type": "pageChanged", "page": 0, "pageCount": 5,
            "pagesPerScreen": 1,
        ]
        view.handleScriptMessage(page0)
        view.handleScriptMessage(page0)
        let didAnnounceFirstPage = await waitUntil {
            announcements.count == 1
        }
        XCTAssertTrue(didAnnounceFirstPage)
        XCTAssertEqual(announcements, ["Page 1 of 5"])

        view.handleScriptMessage([
            "type": "pageChanged", "page": 1, "pageCount": 5,
            "pagesPerScreen": 1,
        ])
        let didAnnounceSecondPage = await waitUntil {
            announcements.count == 2
        }
        XCTAssertTrue(didAnnounceSecondPage)
        XCTAssertEqual(announcements.last, "Page 2 of 5")
        XCTAssertEqual(view.accessibilityLabel(), "EPUB reader")
        XCTAssertEqual(view.accessibilityValue() as? String, "Page 2 of 5")

        let titled = EPUBReaderView(frame: view.frame)
        titled.load(publication: try makePublication(body: "<p>本文</p>"))
        defer { titled.cancelPageCensus() }
        XCTAssertEqual(titled.accessibilityLabel(),
                       "EPUB reader — Single spine")

        var settings = view.settings
        settings.theme = .light
        view.settings = settings
        let key = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings).cacheKey
        view.accessibilityIncreaseContrastOverride = true
        view.accessibilityDifferentiateWithoutColorOverride = true
        let options = try XCTUnwrap(view.setupOptionsJSON().data(using: .utf8))
        let dictionary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: options) as? [String: Any])
        let css = dictionary["userCSS"] as? String ?? ""
        XCTAssertTrue(css.contains("background-color: #ffffff !important"))
        XCTAssertTrue(css.contains("text-decoration: underline !important"))
        XCTAssertEqual(EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings).cacheKey, key)
    }

    /// cooViewer-oxr.38: page-list ラベルが本文 pagebreak へ移動し、ページ送りに
    /// 追従し、次 spine の最初の marker より前では直前 spine のラベルを
    /// 引き継ぐことを検証する。
    func testPrintPageListNavigationTracksMarkersAcrossSpines() async throws {
        let publication = try makePrintPagePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        var settings = view.settings
        settings.columnMode = .single
        settings.insets = .zero
        view.settings = settings
        let delegate = ReaderInteractionDelegate()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        XCTAssertEqual(view.printPageLabels, ["1", "3", "4", "5"])
        guard await waitUntil({ delegate.moves > 0 }) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }

        XCTAssertTrue(view.go(toPrintPage: "3"))
        XCTAssertFalse(view.go(toPrintPage: "missing"))
        let didReachPrintPage3 = await waitUntil {
            view.currentPrintPage == "3"
        }
        XCTAssertTrue(didReachPrintPage3)
        view.goForward()
        let didReachPrintPage4 = await waitUntil {
            view.currentPrintPage == "4"
        }
        XCTAssertTrue(didReachPrintPage4)

        view.go(to: publication.navigation.toc[1])
        let didCarryPrintPageIntoSecondSpine = await waitUntil {
            view.currentSpineIndex == 1 && view.currentPrintPage == "4"
        }
        XCTAssertTrue(didCarryPrintPageIntoSecondSpine)
        XCTAssertTrue(delegate.printPages.contains { $0 == "3" })
        XCTAssertTrue(delegate.printPages.contains { $0 == "4" })
    }

    private func makePrintPagePublication() throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:print-pages</dc:identifier>
                <dc:title>Print pages</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"
                      properties="nav"/>
                <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
            </package>
            """
        let nav = """
            <html xmlns="http://www.w3.org/1999/xhtml"
                  xmlns:epub="http://www.idpf.org/2007/ops"><body>
              <nav epub:type="toc"><ol>
                <li><a href="text/c1.xhtml">One</a></li>
                <li><a href="text/c2.xhtml">Two</a></li>
              </ol></nav>
              <nav epub:type="page-list"><ol>
                <li><a href="text/c1.xhtml#p1">1</a></li>
                <li><a href="text/c1.xhtml#p3">3</a></li>
                <li><a href="text/c1.xhtml#p4">4</a></li>
                <li><a href="text/c2.xhtml#p5">5</a></li>
              </ol></nav>
            </body></html>
            """
        let head = """
            <head><meta charset="UTF-8"/><style>
              html, body { margin: 0; font-size: 18px; line-height: 1.5; }
              .forced { display: block; break-before: column;
                        -webkit-column-break-before: always; height: 1px; }
            </style></head>
            """
        let c1 = """
            <html xmlns="http://www.w3.org/1999/xhtml"
                  xmlns:epub="http://www.idpf.org/2007/ops">\(head)<body>
              <span epub:type="pagebreak" id="p1" title="1"></span>
              <p>First printed page.</p>
              <span class="forced" epub:type="pagebreak" id="p3" title="3"></span>
              <p>Third printed page.</p>
              <span class="forced" epub:type="pagebreak" id="p4" title="4"></span>
              <p>Fourth printed page.</p>
            </body></html>
            """
        let c2 = """
            <html xmlns="http://www.w3.org/1999/xhtml"
                  xmlns:epub="http://www.idpf.org/2007/ops">\(head)<body>
              <p>Before this item's first print marker.</p>
              <span class="forced" role="doc-pagebreak" id="p5"
                    aria-label="5"></span><p>Fifth printed page.</p>
            </body></html>
            """
        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
            ("OEBPS/text/c1.xhtml", Data(c1.utf8)),
            ("OEBPS/text/c2.xhtml", Data(c2.utf8)),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-print-pages.epub"))
    }
}
