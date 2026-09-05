import AppKit
import WebKit
import XCTest
@testable import Washi

// cooViewer-oxr.3 / cooViewer-oxr.5 / cooViewer-oxr.6: 実際の setup を呼ぶ
// オフスクリーン環境。描画フレーム通知に依存せず、非表示ウインドウでも計測する。
@MainActor
final class ReaderScriptTestHarness {
    let window: NSWindow
    let webView: WKWebView
    private let schemeHandler: EPUBSchemeHandler

    init(entries: [(name: String, data: Data)]) throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-batch3.epub"))
        let size = NSSize(width: 640, height: 400)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
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
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window.contentView = webView
    }

    func load() async throws {
        let url = try XCTUnwrap(schemeHandler.url(forContainerPath: "OEBPS/text/c.xhtml"))
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

    func setup() async throws -> [String: Double] {
        try await evaluate("""
            const s = __washi.setup({width:640,height:400,gap:24,spread:true,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:''});
            return {imagePage: Number(s.imagePage), pageCount:s.pageCount,
                    pagesPerScreen:s.pagesPerScreen, verticalRL:Number(s.mode === 'vrl')};
            """)
    }
}

@MainActor
final class ImagePageLayoutTests: XCTestCase {
    // cooViewer-oxr.3 / ミラー issue #1: SVG の高さ潰れ・歪み・再計算待ちを再現する。
    func testSVGWrapperFollowsViewport() async throws {
        try await checkLayout(body: svgBody(preserveAspectRatio: "xMidYMid meet"), isSVG: true)
    }

    func testImageFollowsViewport() async throws {
        try await checkLayout(body: "<img src=\"../images/page.png\"/>", isSVG: false)
    }

    func testSVGWithNonePreservesAspectRatio() async throws {
        try await checkLayout(body: svgBody(preserveAspectRatio: "none"), isSVG: true)
    }

    private func svgBody(preserveAspectRatio: String) -> String {
        """
        <div class="main">
          <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%"
               viewBox="0 0 1200 1800" preserveAspectRatio="\(preserveAspectRatio)">
            <image href="../images/page.png" width="1200" height="1800"
                   preserveAspectRatio="\(preserveAspectRatio)"/>
          </svg>
        </div>
        """
    }

    private func checkLayout(body: String, isSVG: Bool) async throws {
        let harness = try ReaderScriptTestHarness(entries: EPUBFixtures.imagePageEntries(bodyHTML: body))
        defer { harness.close() }
        try await harness.load()
        if !isSVG {
            let decoded: Bool = try await harness.evaluate("""
                const img = document.querySelector('img');
                await img.decode();
                return img.naturalWidth === 12 && img.naturalHeight === 18;
                """)
            XCTAssertTrue(decoded)
        }
        let setup = try await harness.setup()
        XCTAssertEqual(setup["imagePage"], 1)
        XCTAssertEqual(setup["pageCount"], 1)
        XCTAssertEqual(setup["pagesPerScreen"], 1)
        if isSVG {
            let meets: Bool = try await harness.evaluate("""
                return document.querySelector('svg').getAttribute('preserveAspectRatio') === 'xMidYMid meet'
                    && document.querySelector('svg image').getAttribute('preserveAspectRatio') === 'xMidYMid meet';
                """)
            XCTAssertTrue(meets)
        }
        try await assertImageRect(harness, width: 640, height: 400)

        // cooViewer-oxr.3: setup/repaginate を一切呼ばず、WebView の箱だけを変える。
        for size in [NSSize(width: 500, height: 700), NSSize(width: 240, height: 700)] {
            harness.window.setContentSize(size)
            harness.webView.setFrameSize(size)
            harness.webView.layoutSubtreeIfNeeded()
            try await assertImageRect(harness, width: size.width, height: size.height)
        }
    }

    private func assertImageRect(_ harness: ReaderScriptTestHarness, width: Double, height: Double,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let rect: [String: Double] = try await harness.evaluate("""
            // cooViewer-oxr.3: 非表示 WKWebView のフレーム反映を有限時間だけ待つ。
            const deadline = Date.now() + 2000;
            while ((innerWidth !== \(width) || innerHeight !== \(height)) && Date.now() < deadline) {
                await new Promise(resolve => setTimeout(resolve, 20));
            }
            const r = document.querySelector('svg, img').getBoundingClientRect();
            return {x:r.x,y:r.y,width:r.width,height:r.height,vw:innerWidth,vh:innerHeight};
            """)
        let x = try XCTUnwrap(rect["x"]), y = try XCTUnwrap(rect["y"])
        let w = try XCTUnwrap(rect["width"]), h = try XCTUnwrap(rect["height"])
        XCTAssertEqual(rect["vw"], width, file: file, line: line)
        XCTAssertEqual(rect["vh"], height, file: file, line: line)
        XCTAssertGreaterThan(w, 0, file: file, line: line)
        XCTAssertGreaterThan(h, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(x, -1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(y, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(x + w, width + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(y + h, height + 1, file: file, line: line)
        XCTAssertEqual(w / h, 2.0 / 3.0, accuracy: (2.0 / 3.0) * 0.02, file: file, line: line)
        XCTAssertEqual(h, min(height, width * 1.5), accuracy: 1, file: file, line: line)
        XCTAssertEqual(x + w / 2, width / 2, accuracy: 1, file: file, line: line)
        XCTAssertEqual(y + h / 2, height / 2, accuracy: 1, file: file, line: line)
    }

    // cooViewer-oxr.6: Core と共有する入力で、可視本文と隠された代替文を区別する。
    func testVisibleTextDetectionAgreesWithCoreFixtures() async throws {
        for fixture in EPUBFixtures.imagePageDetectionCases {
            let harness = try ReaderScriptTestHarness(entries:
                EPUBFixtures.imagePageEntries(bodyHTML: fixture.body))
            defer { harness.close() }
            try await harness.load()
            let setup = try await harness.setup()
            XCTAssertEqual(setup["imagePage"], fixture.expected ? 1 : 0, fixture.name)
            if fixture.expected {
                // cooViewer-oxr.6: CSS 適用で隠し段落が再表示され、次回の判定が変わらないこと。
                let again = try await harness.setup()
                XCTAssertEqual(again["imagePage"], 1, fixture.name)
            }
        }
    }

    func testDetectionIgnoresStylesheetHiddenText() async throws {
        let harness = try ReaderScriptTestHarness(entries: EPUBFixtures.imagePageEntries(bodyHTML:
            "<style>.alt { display:none }</style><div class=\"alt\"><p>代替文</p></div>"
                + "<img src=\"../images/page.png\"/>"))
        defer { harness.close() }
        try await harness.load()
        let setup = try await harness.setup()
        XCTAssertEqual(setup["imagePage"], 1)
    }

    // cooViewer-oxr.3: 未ロード時の属性比率と、一度だけ登録した load 後の自然寸法。
    func testPendingImageUpdatesRatioOnLoad() async throws {
        let harness = try ReaderScriptTestHarness(entries: EPUBFixtures.imagePageEntries(bodyHTML:
            "<img src=\"../images/page.png\" width=\"40\" height=\"10\"/>"))
        defer { harness.close() }
        try await harness.load()
        let fallback: Double = try await harness.evaluate("""
            const img = document.querySelector('img');
            // cooViewer-oxr.3: 通信時間に依存せず、未完了から完了への遷移を再現する。
            Object.defineProperties(img, {
                complete: {configurable:true, value:false},
                naturalWidth: {configurable:true, value:0},
                naturalHeight: {configurable:true, value:0}
            });
            __washi.setup({width:640,height:400,spread:false,fixedLayout:false,userCSS:''});
            return Number(img.style.getPropertyValue('--washi-ratio'));
            """)
        XCTAssertEqual(fallback, 4)
        let loaded: Double = try await harness.evaluate("""
            const img = document.querySelector('img');
            Object.defineProperties(img, {
                complete: {configurable:true, value:true},
                naturalWidth: {configurable:true, value:12},
                naturalHeight: {configurable:true, value:18}
            });
            img.dispatchEvent(new Event('load'));
            return Number(img.style.getPropertyValue('--washi-ratio'));
            """)
        XCTAssertEqual(loaded, 2.0 / 3.0, accuracy: 0.0001)
    }
}
