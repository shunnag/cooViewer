import AppKit
import WebKit
import XCTest
@testable import Washi

/// cooViewer-oxr.46 C50: scripted content を許可したときに
/// navigator.epubReadingSystem を提供する(RS 3.3 §6.4 MUST)。
@MainActor
final class ReadingSystemTests: XCTestCase {
    private func webView(allowsScripts: Bool) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsScripts
        EPUBScriptedContentHardening.install(
            in: configuration.userContentController,
            allowsScriptedContent: allowsScripts)
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                         configuration: configuration)
    }

    private func load(_ webView: WKWebView) async {
        webView.loadHTMLString("<html><body>x</body></html>", baseURL: nil)
        for _ in 0..<300 where webView.isLoading {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    func testReadingSystemIsExposedToAuthorScripts() async throws {
        let web = webView(allowsScripts: true)
        await load(web)
        let report = try await Task(priority: .userInitiated) { @MainActor () -> [String] in
            let result = try await web.callAsyncJavaScript("""
                const rs = navigator.epubReadingSystem;
                if (!rs) { return ['missing']; }
                return [String(rs.name), String(rs.layoutStyle),
                        String(rs.hasFeature('dom-manipulation')),
                        String(rs.hasFeature('touch-events')),
                        String(rs.hasFeature('nonexistent-feature')),
                        String(rs.version.length > 0)];
                """, arguments: [:], in: nil, contentWorld: .page)
            return (result as? [String]) ?? ["not-an-array"]
        }.value
        XCTAssertEqual(report, ["Washi", "paginated", "true", "false", "false", "true"],
                       "epubReadingSystem の内容が期待と違う: \(report)")
    }

    /// scripted content が無効なら何も注入しない(既定オフの本に影響しない)
    func testNothingIsInjectedWhenScriptsAreDisabled() async throws {
        let web = webView(allowsScripts: false)
        await load(web)
        let present = try await Task(priority: .userInitiated) { @MainActor () -> Bool in
            let result = try await web.callAsyncJavaScript(
                "return !!navigator.epubReadingSystem;",
                arguments: [:], in: nil, contentWorld: .page)
            return (result as? Bool) ?? true
        }.value
        XCTAssertFalse(present)
    }
}
