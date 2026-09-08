import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class NativeKeyDelegateSpy: NSResponder, EPUBReaderViewDelegate {
    var nativeEvents: [NSEvent] = []
    var webKeys: [EPUBKeyEvent] = []
    var upperEvents: [NSEvent] = []
    var onNativeKey: ((EPUBReaderView, NSEvent) -> Bool)?
    var onWebKey: ((EPUBReaderView) -> Void)?

    func readerView(_ view: EPUBReaderView, didReceiveNativeKey event: NSEvent) -> Bool {
        nativeEvents.append(event)
        return onNativeKey?(view, event) ?? false
    }

    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {
        webKeys.append(event)
        onWebKey?(view)
    }

    override func keyDown(with event: NSEvent) { upperEvents.append(event) }
}

@MainActor
final class NativeKeyRoutingTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        return window
    }

    private func reader(in window: NSWindow, delegate: NativeKeyDelegateSpy) -> EPUBReaderView {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        view.delegate = delegate
        view.settings.forwardsKeyEventsNatively = true
        window.contentView?.addSubview(view)
        return view
    }

    private func event(in window: NSWindow, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "-", charactersIgnoringModifiers: "-",
            isARepeat: repeatKey, keyCode: 27))
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    func testNativeResendIsDeliveredOnceAndDistinctRepeatStillArrives() throws {
        let window = window()
        defer { close(window) }
        let delegate = NativeKeyDelegateSpy()
        let view = reader(in: window, delegate: delegate)
        XCTAssertTrue(window.makeFirstResponder(view))
        let first = try event(in: window)

        XCTAssertTrue(view.handleNativeKeyEvent(first) === first)
        XCTAssertTrue(view.handleNativeKeyEvent(first) === first)
        XCTAssertEqual(delegate.nativeEvents.count, 1)

        // 時刻・キーコードが同じでも別の NSEvent は別の入力。
        let repeated = try event(in: window, repeatKey: true)
        XCTAssertTrue(view.handleNativeKeyEvent(repeated) === repeated)
        XCTAssertEqual(delegate.nativeEvents.count, 2)
    }

    func testConsumedNativeEventStaysConsumedOnResend() throws {
        let window = window()
        defer { close(window) }
        let delegate = NativeKeyDelegateSpy()
        delegate.onNativeKey = { _, _ in true }
        let view = reader(in: window, delegate: delegate)
        XCTAssertTrue(window.makeFirstResponder(view))
        let key = try event(in: window)

        XCTAssertNil(view.handleNativeKeyEvent(key))
        XCTAssertNil(view.handleNativeKeyEvent(key))
        XCTAssertEqual(delegate.nativeEvents.count, 1)
    }

    func testNativeDelegateCanReenterWithoutRedispatchingSameEvent() throws {
        let window = window()
        defer { close(window) }
        let delegate = NativeKeyDelegateSpy()
        let view = reader(in: window, delegate: delegate)
        XCTAssertTrue(window.makeFirstResponder(view))
        let key = try event(in: window)
        delegate.onNativeKey = { view, event in
            // 壊れた実装でもテストプロセスを無限再帰させない。
            if delegate.nativeEvents.count == 1 {
                XCTAssertNil(view.handleNativeKeyEvent(event))
            }
            return false
        }

        XCTAssertTrue(view.handleNativeKeyEvent(key) === key)
        XCTAssertEqual(delegate.nativeEvents.count, 1)
    }

    func testNativeMonitorIgnoresSiblingTextFieldHiddenAncestorsAndDetachedReader() throws {
        let window = window()
        defer { close(window) }
        let delegate = NativeKeyDelegateSpy()
        delegate.onNativeKey = { _, _ in true }
        let view = reader(in: window, delegate: delegate)
        let field = NSTextField(frame: NSRect(x: 330, y: 10, width: 200, height: 30))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let key = try event(in: window)
        XCTAssertTrue(view.handleNativeKeyEvent(key) === key)

        XCTAssertTrue(window.makeFirstResponder(view))
        window.contentView?.isHidden = true
        XCTAssertTrue(view.handleNativeKeyEvent(key) === key)
        window.contentView?.isHidden = false
        view.removeFromSuperview()
        XCTAssertTrue(view.handleNativeKeyEvent(key) === key)
        XCTAssertTrue(delegate.nativeEvents.isEmpty)
    }

    func testOnlyFocusedReaderReceivesNativeKeysInSharedWindow() throws {
        let window = window()
        defer { close(window) }
        let leftDelegate = NativeKeyDelegateSpy()
        let rightDelegate = NativeKeyDelegateSpy()
        let left = reader(in: window, delegate: leftDelegate)
        let right = reader(in: window, delegate: rightDelegate)
        right.frame.origin.x = 320
        XCTAssertTrue(window.makeFirstResponder(right))
        let key = try event(in: window)

        XCTAssertTrue(left.handleNativeKeyEvent(key) === key)
        XCTAssertTrue(right.handleNativeKeyEvent(key) === key)
        XCTAssertTrue(leftDelegate.nativeEvents.isEmpty)
        XCTAssertEqual(rightDelegate.nativeEvents.count, 1)
    }

    func testEmbeddedWebViewFocusIsIncludedButHostOverlayFieldIsExcluded() throws {
        let window = window()
        defer { close(window) }
        let delegate = NativeKeyDelegateSpy()
        let view = reader(in: window, delegate: delegate)
        view.load(publication: try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/native-key-focus.epub")))
        let webView = try XCTUnwrap(view.subviews.first { $0 is WKWebView })
        XCTAssertTrue(window.makeFirstResponder(webView))
        let key = try event(in: window)
        XCTAssertTrue(view.handleNativeKeyEvent(key) === key)
        XCTAssertEqual(delegate.nativeEvents.count, 1)

        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 150, height: 30))
        view.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let other = try event(in: window)
        XCTAssertTrue(view.handleNativeKeyEvent(other) === other)
        XCTAssertEqual(delegate.nativeEvents.count, 1)
    }

    func testNativeRoutingRequiresOptIn() throws {
        let window = window()
        defer { close(window) }
        let delegate = NativeKeyDelegateSpy()
        let view = reader(in: window, delegate: delegate)
        view.settings.forwardsKeyEventsNatively = false
        XCTAssertTrue(window.makeFirstResponder(view))
        let key = try event(in: window)

        XCTAssertTrue(view.handleNativeKeyEvent(key) === key)
        XCTAssertTrue(delegate.nativeEvents.isEmpty)
    }

    func testSynchronousKeyDelegateReentryContinuesUpResponderChain() throws {
        let window = window()
        defer { close(window) }
        let delegate = NativeKeyDelegateSpy()
        let view = reader(in: window, delegate: delegate)
        view.settings.handlesKeyboardNavigation = false
        view.nextResponder = delegate
        let key = try event(in: window)
        delegate.onWebKey = { view in
            if delegate.webKeys.count == 1 { view.keyDown(with: key) }
        }

        view.keyDown(with: key)

        XCTAssertEqual(delegate.webKeys.count, 1)
        XCTAssertEqual(delegate.upperEvents.count, 1)
        XCTAssertTrue(delegate.upperEvents.first === key)
    }
}
