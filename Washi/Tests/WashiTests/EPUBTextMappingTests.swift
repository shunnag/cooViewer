import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
final class EPUBTextMappingTests: XCTestCase {
    private struct Landing: Sendable {
        let page: Int
        let text: String
        let firstUnit: Int
        let lastUnit: Int
        let rectCount: Int
    }

    private enum HarnessError: Error {
        case unexpectedJavaScriptResult(String)
        case navigation(fixture: String, domain: String, code: Int)
    }

    /// WashiCore の抽出本文と washi world の UTF-16 マップを同じ EPUB で
    /// 照合し、各検索ヒットが元の DOM Range へ戻ることを検証する
    func testExtractedTextAndEverySearchHitRoundTripThroughDOM() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.textMappingEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-text-map-fixtures.epub"))
        let size = NSSize(width: 640, height: 480)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // NavigationWaiter は washi-epub 以外のナビゲーションを拒否するため、
        // census と同じくスキームハンドラ経由で spine 項目を読み込む
        let schemeHandler = EPUBSchemeHandler(publication: publication,
                                              allowsScripts: false)
        configuration.setURLSchemeHandler(schemeHandler,
                                          forURLScheme: EPUBSchemeHandler.scheme)
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
        defer {
            webView.navigationDelegate = nil
            window.contentView = nil
            window.orderOut(nil)
        }

        let setupOptions = """
            {"width":640,"height":480,"gap":24,"spread":false,"gutter":48,
             "fixedLayout":false,"keysEnabled":false,"userCSS":""}
            """

        for (index, fixture) in EPUBFixtures.textMappingFixtures.enumerated() {
            let entry = publication.readingOrder[index]
            let url = try XCTUnwrap(
                schemeHandler.url(forContainerPath: entry.containerPath), fixture.name)
            let waiter = NavigationWaiter()
            webView.navigationDelegate = waiter
            webView.load(URLRequest(url: url))
            do {
                try await waiter.wait(timeout: .seconds(15))
            } catch {
                let nsError = error as NSError
                throw HarnessError.navigation(
                    fixture: fixture.name, domain: nsError.domain,
                    code: nsError.code)
            }
            withExtendedLifetime(waiter) {}

            // オフスクリーン WebKit の最初の JS 呼び出しは明示的に
            // userInitiated で開始し、WebContent の QoS 逆転による停止を防ぐ
            let pageCount = try await setup(
                webView: webView, optionsJSON: setupOptions)
            let swiftText = try publication.extractText(forSpineIndex: index)
            let javaScriptText = try await mappedText(webView: webView)
            if fixture.name == "名前付き実体" {
                // 既知の乖離(cooViewer-aj4): WashiCore は外部実体を読まないため
                // &nbsp;/&hellip; を落とし、WebKit は内蔵実体表で展開する。
                // 乖離の形を固定し、厳密位置は progression フォールバックに委ねる
                XCTAssertEqual(swiftText, "実体検索終端", fixture.name)
                XCTAssertEqual(javaScriptText, "実体 検索…終端", fixture.name)
                continue
            }
            XCTAssertEqual(javaScriptText, swiftText,
                           "\(fixture.name): JS 本文と extractText")
            guard javaScriptText == swiftText else { continue }

            let hits = publication.search(fixture.searchQuery)
                .filter { $0.spineIndex == index }
            XCTAssertFalse(hits.isEmpty, "\(fixture.name): search hit が必要")
            for hit in hits {
                let lower = swiftText.index(
                    swiftText.startIndex, offsetBy: hit.characterOffset)
                let upper = swiftText.index(lower, offsetBy: hit.length)
                let utf16Lower = try XCTUnwrap(
                    lower.samePosition(in: swiftText.utf16), fixture.name)
                let utf16Upper = try XCTUnwrap(
                    upper.samePosition(in: swiftText.utf16), fixture.name)
                let offset = swiftText.utf16.distance(
                    from: swiftText.utf16.startIndex, to: utf16Lower)
                let length = swiftText.utf16.distance(
                    from: utf16Lower, to: utf16Upper)
                let expected = String(swiftText[lower..<upper])
                let landing = try await locate(
                    webView: webView, offset: offset, length: length)
                if fixture.name == "非表示テキスト" {
                    // レイアウト箱の無い範囲は null(呼び出し側が近似へ落とす。cooViewer-cvt)
                    XCTAssertNil(landing, "\(fixture.name): locateAndShow は null")
                    continue
                }
                let resolved = try XCTUnwrap(
                    landing, "\(fixture.name): locateAndShow は非 nil")
                XCTAssertEqual(resolved.text, expected,
                               "\(fixture.name): 地図上の本文")
                // Range の端点が期待文字列の先頭/末尾の DOM 文字を指すこと
                // (途中に地図が飛ばした空白ノードや rt が挟まっても成立する)
                XCTAssertEqual(resolved.firstUnit, Int(expected.utf16.first ?? 0),
                               "\(fixture.name): Range 始端")
                XCTAssertEqual(resolved.lastUnit, Int(expected.utf16.last ?? 0),
                               "\(fixture.name): Range 終端")
                XCTAssertTrue((0..<pageCount).contains(resolved.page),
                              "\(fixture.name): page=\(resolved.page), count=\(pageCount)")
                XCTAssertGreaterThan(resolved.rectCount, 0,
                                     "\(fixture.name): 可視 Range 矩形")
            }
        }
    }

    private func setup(webView: WKWebView, optionsJSON: String) async throws -> Int {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                "return __washi.setup(\(optionsJSON));",
                arguments: [:], in: nil,
                contentWorld: EPUBReaderView.washiWorld)
            guard let dictionary = result as? [String: Any],
                  let pageCount = dictionary["pageCount"] as? Int else {
                throw HarnessError.unexpectedJavaScriptResult("setup")
            }
            return max(1, pageCount)
        }.value
    }

    private func mappedText(webView: WKWebView) async throws -> String {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                "return __washi.buildTextMap().text;",
                arguments: [:], in: nil,
                contentWorld: EPUBReaderView.washiWorld)
            guard let text = result as? String else {
                throw HarnessError.unexpectedJavaScriptResult("buildTextMap")
            }
            return text
        }.value
    }

    private func locate(webView: WKWebView, offset: Int, length: Int) async throws
        -> Landing? {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                "return __washi.locateAndShow(o, l);",
                arguments: ["o": offset, "l": length], in: nil,
                contentWorld: EPUBReaderView.washiWorld)
            guard let result else { return nil }
            if let dictionary = result as? [String: Any],
               dictionary["found"] as? Bool == false {
                return nil  // 位置を特定できない範囲(呼び出し側は近似へ落とす)
            }
            guard let dictionary = result as? [String: Any],
                  let page = dictionary["page"] as? Int,
                  let text = dictionary["text"] as? String,
                  let firstUnit = dictionary["firstUnit"] as? Int,
                  let lastUnit = dictionary["lastUnit"] as? Int,
                  let rects = dictionary["rects"] as? [[String: Any]] else {
                throw HarnessError.unexpectedJavaScriptResult("locateAndShow")
            }
            return Landing(page: page, text: text, firstUnit: firstUnit,
                           lastUnit: lastUnit, rectCount: rects.count)
        }.value
    }
}
