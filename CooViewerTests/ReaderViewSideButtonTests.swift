import AppKit
import XCTest
@testable import cooViewer

/// サイドボタンを解放したとき、番号を変えず通知する(仕様書 §5.9、設計書 §2.4)。
@MainActor
final class ReaderViewSideButtonTests: XCTestCase {
    func testOtherMouseClickReachesDelegateWithSideButtonNumber() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = ReaderView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let delegate = SideButtonDelegate()
        window.contentView = view
        view.delegate = delegate
        defer {
            view.delegate = nil
            window.contentView = nil
        }

        func mouseEvent(_ type: NSEvent.EventType, timestamp: TimeInterval) throws -> NSEvent {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 60, y: 80), modifierFlags: [],
                timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
            // NSEvent の生成 API にはボタン番号の引数がないため、下位イベントに設定する。
            let cgEvent = try XCTUnwrap(event.cgEvent)
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 3)
            return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        }

        let down = try mouseEvent(.otherMouseDown, timestamp: 1)
        let up = try mouseEvent(.otherMouseUp, timestamp: 1.1)
        XCTAssertEqual(down.buttonNumber, 3)
        XCTAssertEqual(up.buttonNumber, 3)
        view.otherMouseDown(with: down)
        XCTAssertTrue(delegate.clickedButtons.isEmpty)
        view.otherMouseUp(with: up)
        XCTAssertEqual(delegate.clickedButtons, [3])
    }
}

@MainActor
private final class SideButtonDelegate: ReaderViewDelegate {
    var clickedButtons: [Int] = []

    func readerView(_ view: ReaderView, clickedButton button: Int,
                    modifiers: Int, leftHalf: Bool) {
        clickedButtons.append(button)
    }

    func readerView(_ view: ReaderView, didReceiveDropped url: URL) {}
    func readerViewMouseMoved(_ view: ReaderView) {}
    func readerView(_ view: ReaderView, handleKey event: NSEvent) -> Bool { false }
    func readerView(_ view: ReaderView, gesture virtualButton: Int, modifiers: Int,
                    leftHalf: Bool) {}
    func readerView(_ view: ReaderView, dragGesture directionModifier: Int,
                    baseModifiers: Int, button: Int, leftHalf: Bool) {}
    func readerView(_ view: ReaderView, dragTracking dx: CGFloat, dy: CGFloat,
                    button: Int, modifiers: Int, elapsed: TimeInterval) {}
    func readerViewDragTrackingEnded(_ view: ReaderView) {}
    func readerViewSmartMagnify(_ view: ReaderView, at point: CGPoint) {}
    func readerViewZoomWillBegin(_ view: ReaderView) {}
    func readerViewZoomDidEnd(_ view: ReaderView, scale: CGFloat) {}
    func readerViewForceClick(_ view: ReaderView, at point: CGPoint) -> Bool { false }
    func readerViewForceClickEnded(_ view: ReaderView) {}
    func readerViewShouldDragScroll(_ view: ReaderView, button: Int, modifiers: Int) -> Bool {
        false
    }
    func readerView(_ view: ReaderView, scrollWheel event: NSEvent) {}
}
