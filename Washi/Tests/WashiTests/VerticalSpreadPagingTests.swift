import AppKit
import WebKit
import XCTest
@testable import Washi

/// cooViewer-oxr.1: 縦書き見開きで負方向へスクロールし、章内の末尾まで到達できること。
@MainActor
final class VerticalSpreadPagingTests: XCTestCase {
    func testVerticalSpreadMovesTowardNegativeScrollAndReachesEnd() async throws {
        let body = "<style>html{writing-mode:vertical-rl;-epub-writing-mode:vertical-rl}</style>"
            + (1...80).map {
                "<p>\u{884C}\(String(format: "%02d", $0)) \u{7E26}\u{66F8}\u{304D}\u{672C}\u{6587}\u{3002}\u{7E26}\u{66F8}\u{304D}\u{898B}\u{958B}\u{304D}\u{306E}\u{30DA}\u{30FC}\u{30B8}\u{9001}\u{308A}\u{3092}\u{691C}\u{8A3C}\u{3059}\u{308B}\u{3002}</p>"
            }.joined()
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.singleSpineEntries(bodyHTML: body), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-vertical-spread.epub"))
        let size = NSSize(width: 640, height: 400)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let schemeHandler = EPUBSchemeHandler(publication: publication, allowsScripts: false)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBSchemeHandler.scheme)
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.pageScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: EPUBReaderView.washiWorld))
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.baseCSSInjector, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: EPUBReaderView.washiWorld))
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size),
                                configuration: configuration)
        window.contentView = webView
        defer { webView.navigationDelegate = nil; window.contentView = nil; window.orderOut(nil) }

        let entry = publication.readingOrder[0]
        let url = try XCTUnwrap(schemeHandler.url(forContainerPath: entry.containerPath))
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        try await waiter.wait(timeout: .seconds(15))
        withExtendedLifetime(waiter) {}

        func intJS(_ body: String) async throws -> Int? {
            try await Task(priority: .userInitiated) { @MainActor in
                (try await webView.callAsyncJavaScript(
                    body, in: nil, contentWorld: EPUBReaderView.washiWorld)) as? Int
            }.value
        }
        func boolJS(_ body: String) async throws -> Bool? {
            try await Task(priority: .userInitiated) { @MainActor in
                (try await webView.callAsyncJavaScript(
                    body, in: nil, contentWorld: EPUBReaderView.washiWorld)) as? Bool
            }.value
        }
        func doubleJS(_ body: String) async throws -> Double? {
            try await Task(priority: .userInitiated) { @MainActor in
                (try await webView.callAsyncJavaScript(
                    body, in: nil, contentWorld: EPUBReaderView.washiWorld)) as? Double
            }.value
        }

        let pageCount = try await intJS("""
            const s = __washi.setup({width:640,height:400,gap:24,spread:true,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:''});
            globalThis.__washiVerticalSpreadSetup = s;
            return s.pageCount;
            """)
        let count = try XCTUnwrap(pageCount)
        let isSpread = try await boolJS(
            "return globalThis.__washiVerticalSpreadSetup.pagesPerScreen === 2;")
        XCTAssertEqual(isSpread, true, "\u{898B}\u{958B}\u{304D}\u{306F} 2 \u{30DA}\u{30FC}\u{30B8}")
        let isVerticalRL = try await boolJS(
            "return globalThis.__washiVerticalSpreadSetup.mode === 'vrl';")
        XCTAssertEqual(isVerticalRL, true, "vertical-rl \u{3092}\u{691C}\u{51FA}")
        XCTAssertGreaterThanOrEqual(count, 5, "\u{898B}\u{958B}\u{304D}\u{3067} 5 \u{30DA}\u{30FC}\u{30B8}\u{4EE5}\u{4E0A}")
        XCTAssertEqual(count % 2, 1, "\u{5947}\u{6570}\u{7DCF}\u{30DA}\u{30FC}\u{30B8}(\u{672B}\u{5C3E}\u{5358}\u{72EC})")

        let initialXResult = try await doubleJS("return window.scrollX;")
        let initialX = try XCTUnwrap(initialXResult)
        let landed = try await intJS("return __washi.showPage(2);")
        XCTAssertEqual(landed, 2, "showPage(2) \u{306F}\u{7B2C} 2 \u{30DA}\u{30FC}\u{30B8}")
        let movedXResult = try await doubleJS("return window.scrollX;")
        let movedX = try XCTUnwrap(movedXResult)
        XCTAssertLessThan(movedX, initialX, "\u{5F8C}\u{7D9A}\u{30DA}\u{30FC}\u{30B8}\u{3078}\u{8CA0}\u{65B9}\u{5411}\u{306B}\u{30B9}\u{30AF}\u{30ED}\u{30FC}\u{30EB}")

        let lastPage = try await intJS("return __washi.showLastPage();")
        XCTAssertEqual(lastPage, count - 1, "showLastPage \u{306F}\u{672B}\u{5C3E}")
        let progression = try await doubleJS("return __washi.currentProgression();")
        XCTAssertEqual(progression ?? 0, 1.0, accuracy: 0.0001, "\u{9032}\u{884C}\u{7387} 1.0")
        let terminalXResult = try await doubleJS("return Math.abs(window.scrollX);")
        let terminalX = try XCTUnwrap(terminalXResult)
        let maximumXResult = try await doubleJS("""
            const r = document.documentElement;
            return r.scrollWidth - r.clientWidth;
            """)
        let maximumX = try XCTUnwrap(maximumXResult)
        XCTAssertEqual(terminalX, maximumX, accuracy: 2, "\u{672B}\u{5C3E}\u{3067}\u{6A2A}\u{30B9}\u{30AF}\u{30ED}\u{30FC}\u{30EB}\u{304C}\u{8CA0}\u{65B9}\u{5411}\u{306E}\u{4E0A}\u{9650}")
    }
}
