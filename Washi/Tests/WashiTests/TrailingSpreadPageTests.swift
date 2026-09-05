import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class TrailingSpreadDelegateSpy: EPUBReaderViewDelegate {
    var moveCount = 0

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moveCount += 1
    }
}

/// cooViewer-oxr.58: 奇数末尾を空列で補い、単独ページとして表示する。
@MainActor
final class TrailingSpreadPageTests: XCTestCase {
    private enum FirstSlot {
        case left
        case right
    }

    private struct PageMeasurement: Sendable {
        let landed: Int
        let ids: String
        let center: Double
    }

    func testTrailingLonePageOccupiesFirstReadingSlotAndPreviousSpreadIsUnique()
        async throws {
        try await assertTrailingPage(
            writingModeCSS: "", htmlDirection: nil,
            firstSlot: .left, context: "horizontal LTR")
        try await assertTrailingPage(
            writingModeCSS: "html { writing-mode:vertical-rl; -webkit-writing-mode:vertical-rl; }",
            htmlDirection: nil, firstSlot: .right, context: "vertical-rl")
        try await assertTrailingPage(
            writingModeCSS: "", htmlDirection: "rtl",
            firstSlot: .right, context: "horizontal RTL")
    }

    private func assertTrailingPage(writingModeCSS: String,
                                    htmlDirection: String?,
                                    firstSlot: FirstSlot,
                                    context: String) async throws {
        let body = """
            <style>
              \(writingModeCSS)
              .fixture-page { margin:0; padding:0; border:0; }
              body:last-child .fixture-page + .fixture-page {
                break-before:column; -webkit-column-break-before:always;
              }
            </style>
            """ + (0..<5).map {
                "<p class=\"fixture-page\" id=\"page-\($0)\">第\($0)ページ</p>"
            }.joined()
        let harness = try PaginationGeometryHarness(
            bodyHTML: body, size: NSSize(width: 640, height: 400),
            htmlDirection: htmlDirection)
        defer { harness.close() }
        try await harness.load()

        let setup = try await harness.setup(
            width: 640, height: 400, spread: true)
        XCTAssertEqual(try XCTUnwrap(setup["pagesPerScreen"]), 2, context)
        XCTAssertEqual(try XCTUnwrap(setup["pageCount"]), 5, context)
        XCTAssertEqual(try XCTUnwrap(setup["paddedPageCount"]), 6, context)
        XCTAssertEqual(try XCTUnwrap(setup["firstPageOnRight"]),
                       firstSlot == .right ? 1 : 0, context)

        let landed: Int = try await harness.evaluate("return __washi.showLastPage();")
        XCTAssertEqual(landed, 4, context)
        let progression: Double = try await harness.evaluate(
            "return __washi.currentProgression();")
        XCTAssertEqual(progression, 1, accuracy: 0.0001, context)
        let lastVisiblePages = try await visibleFixturePages(in: harness)
        XCTAssertEqual(lastVisiblePages, "page-4", context)

        let lastCenter: Double = try await harness.evaluate("""
            const rect = document.getElementById('page-4').getClientRects()[0];
            return rect.left + rect.width / 2;
            """)
        switch firstSlot {
        case .left:
            XCTAssertLessThan(lastCenter, 320, context)
        case .right:
            XCTAssertGreaterThan(lastCenter, 320, context)
        }

        let result: String = try await harness.evaluate(
            "return __washi.turnInDoc(false);")
        XCTAssertEqual(result, "turned", context)
        let previousVisiblePages = try await visibleFixturePages(in: harness)
        XCTAssertEqual(previousVisiblePages, "page-2,page-3", context)
    }

    /// cooViewer-oxr.58: owned 空列は書籍の生成 content を上書きせず、
    /// body 内の :last-child も変えない。
    func testTrailingPaddingPreservesAuthoredBodyAfterContent() async throws {
        let body = """
            <style>
              body::after { content:"AUTHORED-AFTER"; visibility:visible; }
              .fixture-page { margin:0; padding:0; border:0; }
              .fixture-page + .fixture-page {
                break-before:column; -webkit-column-break-before:always;
              }
            </style>
            """ + (0..<5).map {
                "<p class=\"fixture-page\" id=\"page-\($0)\">第\($0)ページ</p>"
            }.joined()
        let harness = try PaginationGeometryHarness(
            bodyHTML: body, size: NSSize(width: 640, height: 400))
        defer { harness.close() }
        try await harness.load()

        let setup = try await harness.setup(
            width: 640, height: 400, spread: true)
        XCTAssertEqual(try XCTUnwrap(setup["pageCount"]), 5)
        XCTAssertEqual(try XCTUnwrap(setup["paddedPageCount"]), 6)
        let authoredAfter: String = try await harness.evaluate("""
            const style = getComputedStyle(document.body, '::after');
            return `${style.content}|${style.visibility}|${document.body.lastElementChild.id}`
                + `|${document.body.matches(':last-child')}`;
            """)
        XCTAssertEqual(authoredAfter, "\"AUTHORED-AFTER\"|visible|page-4|true")
        let paddingGeometry: [String: Double] = try await harness.evaluate("""
            const previous = document.getElementById('page-3').getClientRects()[0];
            const last = document.getElementById('page-4').getClientRects()[0];
            const pagePitch = Math.abs(last.left - previous.left);
            const gap = pagePitch - last.width;
            return {pagePitch:pagePitch,
                    paddedExtentCount:Math.ceil(
                        (document.documentElement.scrollWidth + gap) / pagePitch)};
            """)
        XCTAssertGreaterThan(try XCTUnwrap(paddingGeometry["pagePitch"]), 0)
        XCTAssertEqual(try XCTUnwrap(paddingGeometry["paddedExtentCount"]), 6)
        let landed: Int = try await harness.evaluate("return __washi.showLastPage();")
        XCTAssertEqual(landed, 4)
        let visiblePages = try await visibleFixturePages(in: harness)
        XCTAssertEqual(visiblePages, "page-4")
    }

    /// cooViewer-oxr.58: root の authored ::after が最終 generated box の場合も、
    /// 内容を消さず、その後ろまで末尾ページの相手スロットを確保する。
    func testTrailingPaddingPreservesAuthoredHTMLAfterContent() async throws {
        let pages = (0..<5).map {
            "<p class=\"fixture-page\" id=\"page-\($0)\">第\($0)ページ</p>"
        }.joined()
        let modes: [(css: String, direction: String?, firstSlot: FirstSlot,
                     context: String)] = [
            ("", nil, .left, "horizontal LTR"),
            ("html{writing-mode:vertical-rl;-webkit-writing-mode:vertical-rl}",
             nil, .right, "vertical-rl"),
            ("", "rtl", .right, "horizontal RTL"),
        ]
        for mode in modes {
            let harness = try PaginationGeometryHarness(
                bodyHTML: pages, size: NSSize(width: 640, height: 400),
                htmlDirection: mode.direction,
                headCSS: """
                    \(mode.css)
                    html::after { content:"AUTHORED-ROOT-AFTER"; visibility:visible; }
                    .fixture-page { margin:0; padding:0; border:0; }
                    body:last-child .fixture-page + .fixture-page {
                        break-before:column; -webkit-column-break-before:always;
                    }
                    """)
            defer { harness.close() }
            try await harness.load()

            let setup = try await harness.setup(
                width: 640, height: 400, spread: true)
            XCTAssertEqual(try XCTUnwrap(setup["pageCount"]), 5, mode.context)
            XCTAssertEqual(try XCTUnwrap(setup["paddedPageCount"]), 6, mode.context)
            XCTAssertEqual(try XCTUnwrap(setup["firstPageOnRight"]),
                           mode.firstSlot == .right ? 1 : 0, mode.context)
            let state: String = try await harness.evaluate("""
                const style = getComputedStyle(document.documentElement, '::after');
                return `${style.content}|${style.visibility}`
                    + `|${document.body.matches(':last-child')}`;
                """)
            XCTAssertEqual(state, "\"AUTHORED-ROOT-AFTER\"|visible|true",
                           mode.context)
            let landed: Int = try await harness.evaluate(
                "return __washi.showLastPage();")
            XCTAssertEqual(landed, 4, mode.context)
            let visiblePages = try await visibleFixturePages(in: harness)
            XCTAssertEqual(visiblePages, "page-4", mode.context)
            let center: Double = try await harness.evaluate("""
                const rect = document.getElementById('page-4').getClientRects()[0];
                return rect.left + rect.width / 2;
                """)
            XCTAssertEqual(center > 320, mode.firstSlot == .right, mode.context)
        }
    }

    /// cooViewer-oxr.58: root/body の四 pseudo が全て著者所有でも、空列追加は
    /// root の child list を変えず body:nth-child(2) による本文配置を保つ。
    func testAllOccupiedPseudosPreserveRootStructuralSelectors() async throws {
        let pages = (0..<5).map {
            "<p class=\"fixture-page\" id=\"page-\($0)\">第\($0)ページ</p>"
        }.joined()
        let harness = try PaginationGeometryHarness(
            bodyHTML: pages, size: NSSize(width: 640, height: 400),
            headCSS: """
                html::before, html::after, body::before, body::after {
                    content:"AUTHORED"; position:absolute; visibility:hidden;
                }
                .fixture-page { margin:0; padding:0; border:0; }
                body:nth-child(2) .fixture-page + .fixture-page {
                    break-before:column; -webkit-column-break-before:always;
                }
                """)
        defer { harness.close() }
        try await harness.load()
        let primedHead: Bool = try await harness.evaluate("""
            document.head.style.setProperty('display', 'none', 'important');
            document.head.style.setProperty('position', 'static', 'important');
            return document.head.matches(':first-child');
            """)
        XCTAssertTrue(primedHead)

        let setup = try await harness.setup(
            width: 640, height: 400, spread: true)
        XCTAssertEqual(try XCTUnwrap(setup["pageCount"]), 5)
        XCTAssertEqual(try XCTUnwrap(setup["paddedPageCount"]), 6)
        let structure: String = try await harness.evaluate("""
            return `${document.documentElement.children.length}`
                + `|${document.head.matches(':first-child')}`
                + `|${document.body.matches(':nth-child(2)')}`;
            """)
        XCTAssertEqual(structure, "2|true|true")
        let landed: Int = try await harness.evaluate(
            "return __washi.showLastPage();")
        XCTAssertEqual(landed, 4)
        let visiblePages = try await visibleFixturePages(in: harness)
        XCTAssertEqual(visiblePages, "page-4")

        _ = try await harness.setup(width: 640, height: 400, spread: false)
        let restoredHead: String = try await harness.evaluate("""
            return `${document.head.style.getPropertyValue('display')}`
                + `|${document.head.style.getPropertyPriority('display')}`
                + `|${document.head.style.getPropertyValue('position')}`
                + `|${document.head.style.getPropertyPriority('position')}`;
            """)
        XCTAssertEqual(restoredHead, "none|important|static|important")
    }

    /// cooViewer-oxr.58: JS が実測した先頭読書スロットを native へ渡し、
    /// 末尾本文と唯一のノンブルを LTR / 縦書き / html RTL で同じ側へ置く。
    func testNativeFolioMatchesTrailingVisibleContentSlot() async throws {
        let cases: [(css: String, direction: String?, firstSlot: FirstSlot,
                     context: String)] = [
            ("", nil, .left, "horizontal LTR"),
            ("html { writing-mode:vertical-rl; -webkit-writing-mode:vertical-rl; }",
             nil, .right, "vertical-rl"),
            ("", "rtl", .right, "horizontal RTL"),
        ]
        for item in cases {
            try await assertNativeFolio(
                writingModeCSS: item.css, htmlDirection: item.direction,
                firstSlot: item.firstSlot, context: item.context)
        }
    }

    /// cooViewer-oxr.58: setup の実測方向が native の左右ノンブル順へ届くことを、
    /// WebKit を起動できない環境でも固定する。
    func testMeasuredFirstPageSlotDrivesNativeFolioOrder() {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 752, height: 508))
        view.applySetupResult([
            "pageCount": 5, "pagesPerScreen": 2, "imagePage": false,
            "firstPageOnRight": true, "supportsColumnAxis": true,
        ])
        view.handleScriptMessage([
            "type": "pageChanged", "page": 4, "pageCount": 5,
            "pagesPerScreen": 2,
        ])
        XCTAssertEqual(view.pageFurnitureSlotNumbers, [nil, 5])

        view.applySetupResult([
            "pageCount": 5, "pagesPerScreen": 2, "imagePage": false,
            "firstPageOnRight": false, "supportsColumnAxis": true,
        ])
        XCTAssertEqual(view.pageFurnitureSlotNumbers, [5, nil])
    }

    private func assertNativeFolio(writingModeCSS: String,
                                   htmlDirection: String?,
                                   firstSlot: FirstSlot,
                                   context: String) async throws {
        let body = """
            <style>
              \(writingModeCSS)
              .fixture-page { margin:0; padding:0; border:0; }
              .fixture-page + .fixture-page {
                break-before:column; -webkit-column-break-before:always;
              }
            </style>
            """ + (0..<5).map {
                "<p class=\"fixture-page\" id=\"page-\($0)\">第\($0)ページ</p>"
            }.joined()
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: body)
        if let htmlDirection,
           let index = entries.firstIndex(where: { $0.name == "OEBPS/text/c.xhtml" }) {
            let source = String(decoding: entries[index].data, as: UTF8.self)
            entries[index].data = Data(source.replacingOccurrences(
                of: "xml:lang=\"ja\">",
                with: "xml:lang=\"ja\" dir=\"\(htmlDirection)\">").utf8)
        }
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath:
                "/tmp/washi-native-folio-\(context.replacingOccurrences(of: " ", with: "-")).epub"))
        // 既定 inset を差し引いた WebView が spec と同じ 640 x 400 になる寸法。
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 752, height: 508))
        var settings = view.settings
        settings.columnMode = .double
        settings.pageTurnStyle = .none
        view.settings = settings
        let delegate = TrailingSpreadDelegateSpy()
        view.delegate = delegate
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000),
                                size: view.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
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
        XCTAssertEqual(view.pageCountInItem, 5, context)
        XCTAssertEqual(view.pagesPerScreen, 2, context)

        let webView = try XCTUnwrap(
            view.subviews.first { $0 is WKWebView } as? WKWebView)
        let measurement = try await Task(priority: .userInitiated) { @MainActor in
            let raw = try await webView.callAsyncJavaScript(
                """
                const landed = __washi.showLastPage();
                const visible = Array.from(document.querySelectorAll('.fixture-page')).filter(
                    element => Array.from(element.getClientRects()).some(rect =>
                        rect.right > 0.5 && rect.left < window.innerWidth - 0.5
                        && rect.bottom > 0.5 && rect.top < window.innerHeight - 0.5));
                const rect = document.getElementById('page-4').getClientRects()[0];
                return {landed:landed, ids:visible.map(element => element.id).join(','),
                        center:rect.left + rect.width / 2};
                """,
                in: nil, contentWorld: EPUBReaderView.washiWorld)
            let result = try XCTUnwrap(raw as? [String: Any])
            return PageMeasurement(
                landed: try XCTUnwrap(result["landed"] as? Int),
                ids: try XCTUnwrap(result["ids"] as? String),
                center: try XCTUnwrap(result["center"] as? Double))
        }.value
        XCTAssertEqual(measurement.landed, 4, context)
        XCTAssertEqual(measurement.ids, "page-4", context)
        let didLand = await waitUntil { view.pageInItem == 4 }
        XCTAssertTrue(didLand, context)

        let labels = view.subviews.compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }
        XCTAssertEqual(labels.map(\.stringValue), ["5"], context)
        let contentIsRight = measurement.center > webView.bounds.midX
        let folio = try XCTUnwrap(labels.first)
        let folioIsRight = folio.frame.midX > webView.frame.midX
        XCTAssertEqual(contentIsRight, firstSlot == .right, context)
        XCTAssertEqual(folioIsRight, contentIsRight, context)
        XCTAssertEqual(view.pageFurnitureSlotNumbers,
                       firstSlot == .right ? [nil, 5] : [5, nil], context)
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

    private func visibleFixturePages(in harness: PaginationGeometryHarness) async throws -> String {
        try await harness.evaluate("""
            return Array.from(document.querySelectorAll('.fixture-page')).filter(element =>
                Array.from(element.getClientRects()).some(rect =>
                    rect.right > 0.5 && rect.left < window.innerWidth - 0.5
                    && rect.bottom > 0.5 && rect.top < window.innerHeight - 0.5))
                .map(element => element.id).join(',');
            """)
    }
}
