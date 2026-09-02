import AppKit
import WebKit
import XCTest
@testable import Washi

/// cooViewer-97e: 見開きで奇数総ページの末尾単独ページへ到達できること。
@MainActor
final class TrailingSpreadPageTests: XCTestCase {
    func testLastLonePageOfOddSpreadIsReachable() async throws {
        let body = (1...44).map { "<p>\u{884C}\(String(format: "%02d", $0)) \u{672C}\u{6587} \($0)</p>" }
            .joined()
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.singleSpineEntries(bodyHTML: body), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-trailing.epub"))
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
            return s.pagesPerScreen === 2 ? s.pageCount : -1;
            """)
        let count = try XCTUnwrap(pageCount)
        XCTAssertGreaterThanOrEqual(count, 3, "\u{898B}\u{958B}\u{304D}\u{3067} 3 \u{30DA}\u{30FC}\u{30B8}\u{4EE5}\u{4E0A}")
        XCTAssertEqual(count % 2, 1, "\u{5947}\u{6570}\u{7DCF}\u{30DA}\u{30FC}\u{30B8}(\u{672B}\u{5C3E}\u{5358}\u{72EC})")

        let landed = try await intJS("return __washi.showLastPage();")
        XCTAssertEqual(landed, count - 1, "showLastPage \u{306F}\u{672B}\u{5C3E}")
        let atMax = try await boolJS("""
            const r = document.documentElement;
            return (r.scrollWidth - r.clientWidth) - window.scrollX <= 2;
            """)
        XCTAssertEqual(atMax, true, "\u{672B}\u{5C3E}\u{3067}\u{6A2A}\u{30B9}\u{30AF}\u{30ED}\u{30FC}\u{30EB}\u{304C}\u{4E0A}\u{9650}")
        let progression = try await doubleJS("return __washi.currentProgression();")
        XCTAssertEqual(progression ?? 0, 1.0, accuracy: 0.0001, "\u{9032}\u{884C}\u{7387} 1.0")
    }
}
