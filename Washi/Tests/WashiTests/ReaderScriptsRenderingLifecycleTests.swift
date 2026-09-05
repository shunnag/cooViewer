import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class RenderingLifecycleMessageRecorder: NSObject, WKScriptMessageHandler {
    private(set) var messages: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            messages.append(body)
        }
    }

    func reset() {
        messages.removeAll()
    }

    func count(type: String) -> Int {
        messages.count { $0["type"] as? String == type }
    }

    func first(type: String) -> [String: Any]? {
        messages.first { $0["type"] as? String == type }
    }
}

@MainActor
private final class RenderingLifecycleScriptHarness {
    let window: NSWindow
    let webView: WKWebView
    let messages = RenderingLifecycleMessageRecorder()
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler

    init(bodyHTML: String) throws {
        publication = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.singleSpineEntries(bodyHTML: bodyHTML), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-rendering-lifecycle.epub"))

        let size = NSSize(width: 640, height: 400)
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
        let controller = configuration.userContentController
        controller.add(messages, contentWorld: EPUBReaderView.washiWorld, name: "washi")
        for source in [ReaderScripts.pageScript, ReaderScripts.baseCSSInjector] {
            controller.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: EPUBReaderView.washiWorld))
        }
        webView = WKWebView(frame: NSRect(origin: .zero, size: size),
                            configuration: configuration)
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
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "washi", contentWorld: EPUBReaderView.washiWorld)
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

    func setup(spread: Bool = false, keysEnabled: Bool = false,
               fixedLayout: Bool = false,
               deferTaps: Bool = false) async throws {
        let _: Int = try await evaluate("""
            const result = __washi.setup({width:640,height:400,gap:24,
                spread:\(spread),gutter:48,fixedLayout:\(fixedLayout),
                keysEnabled:\(keysEnabled),deferTaps:\(deferTaps),
                doubleClickDelayMS:250,userCSS:''});
            return result.pageCount;
            """)
    }

    func settleMessages() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    func waitForMessage(type: String) async throws -> Bool {
        for _ in 0..<50 {
            if messages.count(type: type) > 0 { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func waitForMessageCount(type: String, count: Int) async throws -> Bool {
        for _ in 0..<50 {
            if messages.count(type: type) >= count { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

/// cooViewer-oxr.23/24/25/26/27/48/81/82: ReaderScripts のライフサイクル回帰。
@MainActor
final class ReaderScriptsRenderingLifecycleTests: XCTestCase {
    func testVisibleMediaOverlayHighlightDoesNotPostPageChanged() async throws {
        let harness = try RenderingLifecycleScriptHarness(
            bodyHTML: "<p id=\"visible\">現在ページの読み上げ範囲</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup()
        harness.messages.reset()

        let page: Int = try await harness.evaluate(
            "return __washi.mediaOverlayHighlight('visible', 'washi-speaking');")
        XCTAssertEqual(page, 0)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "pageChanged"), 0)
    }

    func testSetKeysEnabledChangesLiveKeyDispatch() async throws {
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: "<p>キー入力</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(keysEnabled: true)
        harness.messages.reset()

        let disabled: Bool = try await harness.evaluate("""
            const value = __washi.setKeysEnabled(false);
            document.dispatchEvent(new KeyboardEvent('keydown', {
                key:'x', code:'KeyX', bubbles:true, cancelable:true
            }));
            return value;
            """)
        XCTAssertFalse(disabled)
        let receivedKey = try await harness.waitForMessage(type: "key")
        XCTAssertTrue(receivedKey)
        XCTAssertEqual(harness.messages.count(type: "key"), 1)

        harness.messages.reset()
        let enabled: Bool = try await harness.evaluate("""
            const value = __washi.setKeysEnabled(true);
            document.dispatchEvent(new KeyboardEvent('keydown', {
                key:'x', code:'KeyX', bubbles:true, cancelable:true
            }));
            return value;
            """)
        XCTAssertTrue(enabled)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "key"), 0)
    }

    /// cooViewer-oxr.81: FXL の組み込みキーも項目境界のめくりとして通知する。
    func testFixedLayoutBuiltInKeysPostBoundaryTurns() async throws {
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: "<p>固定レイアウト</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(keysEnabled: true, fixedLayout: true)
        harness.messages.reset()

        let prevented: String = try await harness.evaluate("""
            const inputs = [
                {key:'ArrowLeft'}, {key:'ArrowRight'},
                {key:'ArrowUp'}, {key:'ArrowDown'},
                {key:'PageUp'}, {key:'PageDown'},
                {key:' '}, {key:' ', shiftKey:true},
                {key:'Home'}, {key:'End'}
            ];
            return inputs.map(input => {
                const event = new KeyboardEvent('keydown', {
                    key:input.key, bubbles:true, cancelable:true,
                    shiftKey:!!input.shiftKey
                });
                document.dispatchEvent(event);
                return event.defaultPrevented;
            }).join('|');
            """)
        XCTAssertEqual(prevented,
                       "true|true|true|true|true|true|true|true|true|true")
        try await harness.settleMessages()
        let directions = harness.messages.messages.compactMap { message -> Bool? in
            guard message["type"] as? String == "boundary" else { return nil }
            return message["forward"] as? Bool
        }
        XCTAssertEqual(directions,
                       [false, true, false, true, false, true,
                        true, false, false, true])
    }

    func testPaginationNeutralizesHTMLMinMaxConstraints() async throws {
        let body = """
            <style>
              html { writing-mode:vertical-rl; max-width:20em; max-height:20em;
                     min-width:20em; min-height:20em; }
              p { margin:0; }
              p + p { break-before:column; -webkit-column-break-before:always; }
            </style>
            <p id="first">第一段</p><p id="second">第二段</p><p>第三段</p>
            """
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(spread: true)

        let constraints: String = try await harness.evaluate("""
            const style = getComputedStyle(document.documentElement);
            return [style.maxWidth, style.maxHeight,
                    style.minWidth, style.minHeight].join('|');
            """)
        XCTAssertEqual(constraints, "none|none|0px|0px")

        let pitch: Double = try await harness.evaluate("""
            const first = document.getElementById('first').getClientRects()[0];
            const second = document.getElementById('second').getClientRects()[0];
            return Math.abs(first.left - second.left);
            """)
        XCTAssertEqual(pitch, 344, accuracy: 2,
                       "カラム間隔は pageW(296) + gutter(48)")
    }

    func testSynthesizedAnchorClickPostsLinkButNeverTap() async throws {
        let harness = try RenderingLifecycleScriptHarness(
            bodyHTML: "<a id=\"link\" href=\"#chapter\">章へ</a><p id=\"plain\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup()
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            document.body.dispatchEvent(new MouseEvent('mousedown', {
                bubbles:true, clientX:200, clientY:100, button:0
            }));
            document.body.dispatchEvent(new MouseEvent('mouseup', {
                bubbles:true, clientX:200, clientY:100, button:0
            }));
            document.getElementById('link').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:0, clientX:0, clientY:0, button:0
            }));
            document.getElementById('plain').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:0, clientX:0, clientY:0, button:0
            }));
            return true;
            """)
        let receivedLink = try await harness.waitForMessage(type: "link")
        XCTAssertTrue(receivedLink)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "link"), 1)
        XCTAssertEqual(harness.messages.first(type: "link")?["href"] as? String, "#chapter")
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    /// cooViewer-oxr.32: noteref の意味情報、戻りリンク、実測矩形を通知する。
    func testNoterefClickPostsMetadataBacklinkAndAnchorRect() async throws {
        let body = """
            <div xmlns:epub="http://www.idpf.org/2007/ops">
              <p><a id="ref1" epub:type="noteref" role="doc-noteref"
                    href="#n1" style="display:inline-block;width:88px;height:24px">注1</a></p>
              <aside id="n1" epub:type="footnote">
                <p>脚注本文 <a href="#ref1">戻る</a></p>
              </aside>
            </div>
            """
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup()
        harness.messages.reset()

        let expectedJSON: String = try await harness.evaluate("""
            const anchor = document.getElementById('ref1');
            const rect = anchor.getBoundingClientRect();
            anchor.dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:rect.x + 2, clientY:rect.y + 2, button:0
            }));
            return JSON.stringify([rect.x, rect.y, rect.width, rect.height]);
            """)
        let expectedData = try XCTUnwrap(expectedJSON.data(using: .utf8))
        let expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: expectedData) as? [Double])
        XCTAssertEqual(expected.count, 4)
        let receivedLink = try await harness.waitForMessage(type: "link")
        XCTAssertTrue(receivedLink)
        let message = try XCTUnwrap(harness.messages.first(type: "link"))

        XCTAssertEqual(message["href"] as? String, "#n1")
        XCTAssertEqual(message["epubType"] as? String, "noteref")
        XCTAssertEqual(message["role"] as? String, "doc-noteref")
        XCTAssertEqual(message["anchorId"] as? String, "ref1")
        XCTAssertEqual(message["backlink"] as? Bool, true)
        XCTAssertEqual(message["targetTag"] as? String, "aside")
        XCTAssertEqual(message["targetEpubType"] as? String, "footnote")
        let rect = try XCTUnwrap(message["anchorRect"] as? [String: Any])
        func number(_ key: String) -> Double? {
            if let value = rect[key] as? NSNumber { return value.doubleValue }
            return rect[key] as? Double
        }
        XCTAssertEqual(try XCTUnwrap(number("x")), expected[0], accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(number("y")), expected[1], accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(number("w")), expected[2], accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(number("h")), expected[3], accuracy: 0.001)
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    func testClickThatClearsExistingSelectionDoesNotPostTap() async throws {
        let harness = try RenderingLifecycleScriptHarness(
            bodyHTML: "<p id=\"text\">選択中の本文をクリックする</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup()
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            const target = document.getElementById('text');
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(target);
            selection.removeAllRanges();
            selection.addRange(range);
            target.dispatchEvent(new MouseEvent('mousedown', {
                bubbles:true, clientX:40, clientY:40, button:0
            }));
            selection.removeAllRanges();
            target.dispatchEvent(new MouseEvent('mouseup', {
                bubbles:true, clientX:40, clientY:40, button:0
            }));
            target.dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    /// cooViewer-oxr.82: ネイティブ操作要素と編集領域はページタップにしない。
    func testInteractiveControlClicksDoNotPostPageTaps() async throws {
        let body = """
            <audio id="audio" controls="controls"></audio>
            <video id="video" controls="controls"></video>
            <button id="button" type="button">ボタン</button>
            <input id="input" type="text" />
            <select id="select"><option>選択肢</option></select>
            <textarea id="textarea">入力欄</textarea>
            <details><summary id="summary">詳細</summary><p>内容</p></details>
            <label for="input"><span id="labelChild">ラベル</span></label>
            <div contenteditable="true"><span id="editableChild">編集可能</span></div>
            <p id="plain">本文</p>
            """
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup()
        harness.messages.reset()

        let defaultsPreserved: Bool = try await harness.evaluate("""
            const ids = ['audio', 'video', 'button', 'input', 'select',
                         'textarea', 'summary', 'labelChild', 'editableChild'];
            return ids.map(id => {
                const event = new MouseEvent('click', {
                    bubbles:true, cancelable:true, detail:1,
                    clientX:40, clientY:40, button:0
                });
                document.getElementById(id).dispatchEvent(event);
                return !event.defaultPrevented;
            }).every(Boolean);
            """)
        XCTAssertTrue(defaultsPreserved)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)

        harness.messages.reset()
        let _: Bool = try await harness.evaluate("""
            document.getElementById('plain').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            return true;
            """)
        let receivedPlainTap = try await harness.waitForMessageCount(
            type: "tap", count: 1)
        XCTAssertTrue(receivedPlainTap)
        XCTAssertEqual(harness.messages.count(type: "tap"), 1)
    }

    /// cooViewer-oxr.27: 既定は detail にかかわらず各 click を遅延なしで通知する。
    func testRapidClicksPostOneTapEachImmediately() async throws {
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: "<p id=\"text\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup()
        harness.messages.reset()

        let scheduledTimers: Int = try await harness.evaluate("""
            const target = document.getElementById('text');
            const originalSetTimeout = window.setTimeout;
            let scheduledTimers = 0;
            window.setTimeout = function () { scheduledTimers += 1; return 1; };
            try {
                target.dispatchEvent(new MouseEvent('click', {
                    bubbles:true, cancelable:true, detail:1,
                    clientX:40, clientY:40, button:0
                }));
                target.dispatchEvent(new MouseEvent('click', {
                    bubbles:true, cancelable:true, detail:2,
                    clientX:140, clientY:40, button:0
                }));
                target.dispatchEvent(new MouseEvent('dblclick', {
                    bubbles:true, cancelable:true, detail:2,
                    clientX:140, clientY:40, button:0
                }));
                target.dispatchEvent(new MouseEvent('click', {
                    bubbles:true, cancelable:true, detail:0,
                    clientX:0, clientY:0, button:0
                }));
            } finally {
                window.setTimeout = originalSetTimeout;
            }
            return scheduledTimers;
            """)
        XCTAssertEqual(scheduledTimers, 0)
        let receivedRapidTaps = try await harness.waitForMessageCount(
            type: "tap", count: 2)
        XCTAssertTrue(receivedRapidTaps)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 2)
    }

    func testOptInDoubleClickEventDoesNotPostTap() async throws {
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: "<p id=\"text\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(deferTaps: true)
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            document.getElementById('text').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            document.getElementById('text').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:2,
                clientX:40, clientY:40, button:0
            }));
            document.getElementById('text').dispatchEvent(new MouseEvent('dblclick', {
                bubbles:true, cancelable:true, detail:2,
                clientX:40, clientY:40, button:0
            }));
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    func testDoubleClickedAnchorPreventsDefaultWithoutDuplicateLink() async throws {
        let harness = try RenderingLifecycleScriptHarness(
            bodyHTML: "<a id=\"link\" href=\"#chapter\">章へ</a>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup()
        harness.messages.reset()

        let prevented: String = try await harness.evaluate("""
            const anchor = document.getElementById('link');
            const first = new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1, clientX:40, clientY:40
            });
            const second = new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:2, clientX:40, clientY:40
            });
            anchor.dispatchEvent(first);
            anchor.dispatchEvent(second);
            return `${first.defaultPrevented}|${second.defaultPrevented}`;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(prevented, "true|true")
        XCTAssertEqual(harness.messages.count(type: "link"), 1)
        XCTAssertEqual(harness.messages.count(type: "tap"), 0)
    }

    func testOptInPlainSingleClickPostsTapAfterDoubleClickWindow() async throws {
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: "<p id=\"text\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(deferTaps: true)
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            document.getElementById('text').dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 1)
    }

    func testOptInRapidIndependentSingleClicksBothPostTaps() async throws {
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: "<p id=\"text\">本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(deferTaps: true)
        harness.messages.reset()

        let _: Bool = try await harness.evaluate("""
            const target = document.getElementById('text');
            target.dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:40, clientY:40, button:0
            }));
            target.dispatchEvent(new MouseEvent('click', {
                bubbles:true, cancelable:true, detail:1,
                clientX:140, clientY:40, button:0
            }));
            return true;
            """)
        try await harness.settleMessages()
        XCTAssertEqual(harness.messages.count(type: "tap"), 2)
    }

    func testColumnAxisDetectionAndForcedFallback() async throws {
        let body = "<style>html{writing-mode:vertical-rl}</style>"
            + (1...80).map { "<p>縦書きの本文 \($0)</p>" }.joined()
        let harness = try RenderingLifecycleScriptHarness(bodyHTML: body)
        defer { harness.close() }
        try await harness.load()

        let supported: String = try await harness.evaluate("""
            const result = __washi.setup({width:640,height:400,gap:24,spread:true,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:''});
            return `${result.mode}|${result.pagesPerScreen}|${result.supportsColumnAxis}`;
            """)
        XCTAssertEqual(supported, "vrl|2|true")

        let fallback: String = try await harness.evaluate("""
            __washi.__forceNoColumnAxis = true;
            const result = __washi.setup({width:640,height:400,gap:24,spread:true,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:''});
            return `${result.mode}|${result.pagesPerScreen}|${result.supportsColumnAxis}`;
            """)
        XCTAssertEqual(fallback, "vrl|1|false")
    }
}
