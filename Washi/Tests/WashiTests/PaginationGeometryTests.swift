import AppKit
import WebKit
import XCTest
@testable import Washi

/// ページネーションの物理座標を実 WKWebView で測る共通ハーネス。
/// cooViewer-oxr.56 / cooViewer-oxr.57 / cooViewer-oxr.61
@MainActor
final class PaginationGeometryHarness {
    let window: NSWindow
    let webView: WKWebView
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler

    init(bodyHTML: String, size: NSSize, htmlDirection: String? = nil,
         headCSS: String = "") throws {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: bodyHTML)
        if let index = entries.firstIndex(where: { $0.name == "OEBPS/text/c.xhtml" }) {
            var source = String(decoding: entries[index].data, as: UTF8.self)
            if let htmlDirection {
                source = source.replacingOccurrences(
                    of: "xml:lang=\"ja\">",
                    with: "xml:lang=\"ja\" dir=\"\(htmlDirection)\">")
            }
            if !headCSS.isEmpty {
                source = source.replacingOccurrences(
                    of: "</head>", with: "<style>\(headCSS)</style></head>")
            }
            entries[index].data = Data(source.utf8)
        }
        publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-pagination-geometry.epub"))
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        schemeHandler = EPUBSchemeHandler(publication: publication, allowsScripts: false)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBSchemeHandler.scheme)
        for source in [ReaderScripts.pageScript, ReaderScripts.baseCSSInjector] {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: EPUBReaderView.washiWorld))
        }
        webView = WKWebView(
            frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window.contentView = webView
    }

    func load() async throws {
        let entry = try XCTUnwrap(publication.readingOrder.first)
        let url = try XCTUnwrap(schemeHandler.url(forReadingOrderItem: entry))
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        try await waiter.wait(timeout: .seconds(15))
        withExtendedLifetime(waiter) {}
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
    }

    func evaluate<T: Sendable>(_ body: String, as type: T.Type = T.self) async throws -> T {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                body, in: nil, contentWorld: EPUBReaderView.washiWorld)
            return try XCTUnwrap(result as? T)
        }.value
    }

    func setup(width: Int, height: Int, spread: Bool,
               gutter: Int = 48, gap: Int = 24) async throws -> [String: Double] {
        try await evaluate("""
            const result = __washi.setup({width:\(width),height:\(height),gap:\(gap),
                spread:\(spread),gutter:\(gutter),fixedLayout:false,
                keysEnabled:false,userCSS:''});
            return {pageCount:result.pageCount,
                    paddedPageCount:result.paddedPageCount,
                    pagesPerScreen:result.pagesPerScreen,
                    firstPageOnRight:Number(result.firstPageOnRight),
                    horizontal:Number(result.mode === 'htb'),
                    verticalRL:Number(result.mode === 'vrl')};
            """)
    }
}

@MainActor
final class PaginationGeometryTests: XCTestCase {
    private enum WritingMode: String, Equatable {
        case horizontalTB = "horizontal-tb"
        case verticalRL = "vertical-rl"
    }

    /// cooViewer-oxr.58 / cooViewer-oxr.61: document-start の基礎 CSS 注入が
    /// head:first-child / body:nth-child(2) を壊す root 直下要素を作らない。
    func testBaseCSSInjectionPreservesHeadBodyRootStructureAfterLoad() async throws {
        let harness = try PaginationGeometryHarness(
            bodyHTML: "<p>本文</p>", size: NSSize(width: 640, height: 400))
        defer { harness.close() }
        try await harness.load()

        let rootChildren: String = try await harness.evaluate("""
            return Array.from(document.documentElement.children, element =>
                element.localName).join(',');
            """)
        XCTAssertEqual(rootChildren, "head,body")
        let baseIsFirstHeadChild: Bool = try await harness.evaluate("""
            const first = document.head.firstChild;
            return !!first && first.localName === 'style'
                && first.id === 'washi-base';
            """)
        XCTAssertTrue(baseIsFirstHeadChild)
    }

    /// cooViewer-oxr.56: UA による端数の再配分を許さず、偶数・奇数幅とも
    /// 実測カラムピッチとページ送り stride を全4分岐で一致させる。
    func testColumnPitchEqualsStrideAtEvenAndOddWidthsInEveryPaginationBranch() async throws {
        for width in [640, 641] {
            // viewport - gutter を意図的に奇数にし、旧実装の 0.5px 漂流を再現する。
            let gutter = width == 640 ? 45 : 46
            for writingMode in [WritingMode.horizontalTB, .verticalRL] {
                for spread in [false, true] {
                    try await assertExactGeometry(
                        width: width, gutter: gutter,
                        writingMode: writingMode, spread: spread)
                }
            }
        }
    }

    /// cooViewer-oxr.61: viewport の最小 scrollExtent ではなく本文末尾で数え、
    /// 短章を1ページに戻しつつ、多カラム本文を切り詰めない。
    func testContentEndpointCountsShortSpreadAsOneAndPreservesLongChapterCount() async throws {
        let shortHarness = try PaginationGeometryHarness(
            bodyHTML: "<p>短い章</p>", size: NSSize(width: 640, height: 400))
        defer { shortHarness.close() }
        try await shortHarness.load()
        let short = try await shortHarness.setup(
            width: 640, height: 400, spread: true)
        XCTAssertEqual(try XCTUnwrap(short["pageCount"]), 1)
        XCTAssertEqual(try XCTUnwrap(short["paddedPageCount"]), 2)

        let verticalShortHarness = try PaginationGeometryHarness(
            bodyHTML: "<style>html{writing-mode:vertical-rl}</style><p>短い章</p>",
            size: NSSize(width: 641, height: 400))
        defer { verticalShortHarness.close() }
        try await verticalShortHarness.load()
        let verticalShort = try await verticalShortHarness.setup(
            width: 641, height: 400, spread: true, gutter: 46)
        XCTAssertEqual(try XCTUnwrap(verticalShort["verticalRL"]), 1)
        XCTAssertEqual(try XCTUnwrap(verticalShort["pageCount"]), 1)
        XCTAssertEqual(try XCTUnwrap(verticalShort["paddedPageCount"]), 2)

        // 末尾計測用 marker 自身の line box で、満杯の実ページを 2 枚へ
        // 押し出さないことも固定する(cooViewer-oxr.61)。
        let exactPageHarness = try PaginationGeometryHarness(
            bodyHTML: "<div style=\"height:400px;margin:0\">満杯の一ページ</div>",
            size: NSSize(width: 640, height: 400))
        defer { exactPageHarness.close() }
        try await exactPageHarness.load()
        let exactPage = try await exactPageHarness.setup(
            width: 640, height: 400, spread: true)
        XCTAssertEqual(try XCTUnwrap(exactPage["pageCount"]), 1)
        XCTAssertEqual(try XCTUnwrap(exactPage["paddedPageCount"]), 2)

        let longBody = """
            <style>
              p { margin:0; padding:0; }
              p + p { break-before:column; -webkit-column-break-before:always; }
            </style>
            """ + (1...44).map { "<p>第\($0)カラム</p>" }.joined()
        let longHarness = try PaginationGeometryHarness(
            bodyHTML: longBody, size: NSSize(width: 640, height: 400))
        defer { longHarness.close() }
        try await longHarness.load()
        let long = try await longHarness.setup(
            width: 640, height: 400, spread: true)
        XCTAssertEqual(try XCTUnwrap(long["pageCount"]), 44)
        XCTAssertEqual(try XCTUnwrap(long["paddedPageCount"]), 44)
    }

    /// cooViewer-oxr.61: boxed 要素より後ろの直下 Text / display:contents も
    /// 本文末尾として数え、末尾カラムを切り捨てない。
    func testTrailingUnboxedContentDeterminesRealColumnCount() async throws {
        let tails = [
            "末尾の直下テキスト",
            "<span style=\"display:contents\"><em>末尾の contents 子孫</em></span>",
        ]
        for tail in tails {
            let harness = try PaginationGeometryHarness(
                bodyHTML: "<div style=\"height:400px;margin:0\">先頭</div>\(tail)",
                size: NSSize(width: 640, height: 400))
            defer { harness.close() }
            try await harness.load()
            let setup = try await harness.setup(
                width: 640, height: 400, spread: true)
            XCTAssertEqual(try XCTUnwrap(setup["pageCount"]), 2, tail)
            XCTAssertEqual(try XCTUnwrap(setup["paddedPageCount"]), 2, tail)
        }
    }

    /// cooViewer-oxr.61: 通常フローの body::after も末尾 fragment として数え、
    /// 空本文を測るために body:empty を壊す marker は挿入しない。
    func testGeneratedBodyTailCountsAndEmptyBodySelectorSurvives() async throws {
        let pages = (0..<5).map {
            "<p class=\"fixture-page\" id=\"page-\($0)\">第\($0)ページ</p>"
        }.joined()
        let modes: [(css: String, direction: String?, context: String)] = [
            ("", nil, "horizontal LTR"),
            ("html{writing-mode:vertical-rl;-webkit-writing-mode:vertical-rl}",
             nil, "vertical-rl"),
            ("", "rtl", "horizontal RTL"),
        ]
        for mode in modes {
            let generatedTail = try PaginationGeometryHarness(
                bodyHTML: pages, size: NSSize(width: 640, height: 400),
                htmlDirection: mode.direction,
                headCSS: """
                    \(mode.css)
                    .fixture-page { margin:0; padding:0; border:0; }
                    .fixture-page + .fixture-page {
                        break-before:column; -webkit-column-break-before:always;
                    }
                    body::after { content:"生成末尾"; display:block;
                        break-before:column; -webkit-column-break-before:always; }
                    """)
            defer { generatedTail.close() }
            try await generatedTail.load()
            let tailResult = try await generatedTail.setup(
                width: 640, height: 400, spread: true)
            XCTAssertEqual(try XCTUnwrap(tailResult["pageCount"]), 6,
                           mode.context)
            XCTAssertEqual(try XCTUnwrap(tailResult["paddedPageCount"]), 6,
                           mode.context)
        }

        let empty = try PaginationGeometryHarness(
            bodyHTML: "", size: NSSize(width: 640, height: 400),
            headCSS: "body:empty::after { content:\"空本文の生成内容\"; }")
        defer { empty.close() }
        try await empty.load()
        let emptyResult = try await empty.setup(
            width: 640, height: 400, spread: true)
        XCTAssertEqual(try XCTUnwrap(emptyResult["pageCount"]), 1)
        XCTAssertEqual(try XCTUnwrap(emptyResult["paddedPageCount"]), 2)
        let emptyState: String = try await empty.evaluate("""
            return `${document.body.matches(':empty')}`
                + `|${getComputedStyle(document.body, '::after').content}`;
            """)
        XCTAssertEqual(emptyState, "true|\"空本文の生成内容\"")
    }

    /// cooViewer-oxr.61: 見開き viewport の最小 scrollWidth に隠れても、
    /// root::after が強制改ページした二列目を実ページとして数える。
    func testAuthoredHTMLAfterForcedSecondColumnCountsAsRealPage() async throws {
        let cases: [(declarations: String, expectedPages: Int)] = [
            ("display:block; height:1px;", 2),
            ("display:block; height:800px;", 3),
            // break-before は inline-level pseudo には適用されない。
            ("", 1),
            // internal table box にも適用されない。
            ("display:table-cell;", 1),
        ]
        for item in cases {
            let harness = try PaginationGeometryHarness(
                bodyHTML: "<p>一ページ本文</p>",
                size: NSSize(width: 640, height: 400),
                headCSS: """
                    html::after { content:"生成末尾"; \(item.declarations)
                        break-before:column; -webkit-column-break-before:always; }
                    """)
            defer { harness.close() }
            try await harness.load()

            let setup = try await harness.setup(
                width: 640, height: 400, spread: true)
            XCTAssertEqual(try XCTUnwrap(setup["pageCount"]),
                           Double(item.expectedPages), item.declarations)
            XCTAssertEqual(try XCTUnwrap(setup["paddedPageCount"]),
                           Double(item.expectedPages.isMultiple(of: 2)
                               ? item.expectedPages : item.expectedPages + 1),
                           item.declarations)
            let generatedContent: String = try await harness.evaluate(
                "return getComputedStyle(document.documentElement, '::after').content;")
            XCTAssertEqual(generatedContent, "\"生成末尾\"")
        }
    }

    /// cooViewer-oxr.61: float pseudo は normal-flow の本文端点ではないため、
    /// 空の body fragment を実ページへ昇格させない。
    func testFloatedBodyPseudoDoesNotPromoteBlankBodyFragmentsToContent() async throws {
        let harness = try PaginationGeometryHarness(
            bodyHTML: "<p>短い本文</p>", size: NSSize(width: 640, height: 400),
            headCSS: """
                body { height:1200px; }
                body::after { content:"装飾"; display:block; float:left;
                    width:1px; height:1px; }
                """)
        defer { harness.close() }
        try await harness.load()

        let setup = try await harness.setup(
            width: 640, height: 400, spread: true)
        XCTAssertEqual(try XCTUnwrap(setup["pageCount"]), 1)
        XCTAssertEqual(try XCTUnwrap(setup["paddedPageCount"]), 2)
    }

    /// cooViewer-oxr.57: html dir=rtl の横書きは負方向へ進み、単ページ・
    /// 見開きのどちらでも showPage(2) が実際の可視本文を切り替える。
    func testHorizontalRTLUsesNegativeScrollAndChangesVisibleContentInSingleAndSpreadModes()
        async throws {
        let body = (1...120).map {
            "<p id=\"paragraph-\($0)\">فقرة \($0) لاختبار انتقال الصفحات من اليمين إلى اليسار.</p>"
        }.joined()
        for (width, spread) in [(400, false), (800, true)] {
            let harness = try PaginationGeometryHarness(
                bodyHTML: body, size: NSSize(width: CGFloat(width), height: 400),
                htmlDirection: "rtl")
            defer { harness.close() }
            try await harness.load()
            let setup = try await harness.setup(
                width: width, height: 400, spread: spread)
            XCTAssertEqual(try XCTUnwrap(setup["horizontal"]), 1)
            XCTAssertEqual(try XCTUnwrap(setup["pagesPerScreen"]), spread ? 2 : 1)
            XCTAssertGreaterThan(try XCTUnwrap(setup["pageCount"]), 3)
            let isRTL: Bool = try await harness.evaluate(
                "return getComputedStyle(document.documentElement).direction === 'rtl';")
            XCTAssertTrue(isRTL)

            let before = try await visibleParagraphIDs(in: harness)
            let landed: Int = try await harness.evaluate("return __washi.showPage(2);")
            let scrollX: Double = try await harness.evaluate("return window.scrollX;")
            let after = try await visibleParagraphIDs(in: harness)
            XCTAssertEqual(landed, 2, "width=\(width), spread=\(spread)")
            XCTAssertLessThan(scrollX, -1, "width=\(width), spread=\(spread)")
            XCTAssertNotEqual(after, before, "width=\(width), spread=\(spread)")
        }
    }

    private func assertExactGeometry(width: Int, gutter: Int,
                                     writingMode: WritingMode,
                                     spread: Bool) async throws {
        let body = """
            <style>
              html { writing-mode:\(writingMode.rawValue);
                     -webkit-writing-mode:\(writingMode.rawValue); }
              p { margin:0; padding:0; border:0; }
              p + p { break-before:column; -webkit-column-break-before:always; }
            </style>
            <p id="geometry-page-0">甲</p>
            <p id="geometry-page-1">乙</p>
            <p id="geometry-page-2">丙</p>
            """
        let harness = try PaginationGeometryHarness(
            bodyHTML: body, size: NSSize(width: CGFloat(width), height: 400))
        defer { harness.close() }
        try await harness.load()
        let pageGap = 23
        let setup = try await harness.setup(
            width: width, height: 400, spread: spread,
            gutter: gutter, gap: pageGap)
        let context = "\(writingMode.rawValue), width=\(width), spread=\(spread)"
        XCTAssertEqual(try XCTUnwrap(setup["pagesPerScreen"]), spread ? 2 : 1,
                       context)

        let geometry: [String: Double] = try await harness.evaluate("""
            const root = document.documentElement;
            const first = document.getElementById('geometry-page-0').getClientRects()[0];
            const second = document.getElementById('geometry-page-1').getClientRects()[0];
            const horizontal = \(writingMode == .horizontalTB);
            const spread = \(spread);
            const pitch = horizontal || spread
                ? Math.abs(second.left - first.left)
                : Math.abs(second.top - first.top);
            const rootRect = root.getBoundingClientRect();
            const pageExtent = horizontal ? first.width
                : (spread ? rootRect.width : rootRect.height);
            const targetPage = spread ? 2 : 1;
            const beforeOffset = horizontal || spread ? window.scrollX : window.scrollY;
            const landed = __washi.showPage(targetPage);
            const afterOffset = horizontal || spread ? window.scrollX : window.scrollY;
            return {pitch:pitch, pageExtent:pageExtent,
                    gap:pitch - pageExtent,
                    landed:landed,
                    scrollPitch:Math.abs(afterOffset - beforeOffset) / targetPage,
                    rootWidth:rootRect.width, rootHeight:rootRect.height};
            """)

        let expectedPageExtent: Double
        let expectedGap: Double
        if spread {
            expectedPageExtent = Double((width - gutter) / 2)
            expectedGap = Double(width) - 2 * expectedPageExtent
        } else {
            expectedPageExtent = writingMode == .horizontalTB ? Double(width) : 400
            expectedGap = Double(pageGap)
        }
        let measuredPageExtent = try XCTUnwrap(geometry["pageExtent"])
        let measuredGap = try XCTUnwrap(geometry["gap"])
        let measuredPitch = try XCTUnwrap(geometry["pitch"])
        XCTAssertEqual(measuredPageExtent, expectedPageExtent, accuracy: 0.05, context)
        XCTAssertEqual(measuredGap, expectedGap, accuracy: 0.05, context)
        XCTAssertEqual(measuredPitch, expectedPageExtent + expectedGap,
                       accuracy: 0.05, context)
        XCTAssertEqual(try XCTUnwrap(geometry["landed"]), spread ? 2 : 1,
                       context)
        XCTAssertEqual(try XCTUnwrap(geometry["scrollPitch"]), measuredPitch,
                       accuracy: 0.05, context)
        if spread {
            XCTAssertEqual(2 * measuredPageExtent + measuredGap,
                           Double(width), accuracy: 0.05, context)
        } else {
            XCTAssertEqual(try XCTUnwrap(geometry["rootWidth"]),
                           Double(width), accuracy: 0.05, context)
            XCTAssertEqual(try XCTUnwrap(geometry["rootHeight"]),
                           400, accuracy: 0.05, context)
        }
    }

    private func visibleParagraphIDs(in harness: PaginationGeometryHarness) async throws -> String {
        try await harness.evaluate("""
            return Array.from(document.querySelectorAll('p')).filter(element =>
                Array.from(element.getClientRects()).some(rect =>
                    rect.right > 0.5 && rect.left < window.innerWidth - 0.5
                    && rect.bottom > 0.5 && rect.top < window.innerHeight - 0.5))
                .map(element => element.id).join(',');
            """)
    }
}
