import AppKit
import XCTest
@testable import cooViewer

/// 微動クリックの救済と既存ドラッグの優先を実際のディスパッチで確かめる(設計書 §2.4)。
@MainActor
final class ReaderInputDispatchTests: XCTestCase {
    func testMiddleAndSideButtonDragKeepsClickModifiersAndPosition() {
        for button in [2, 3, 4] {
            for leftHalf in [false, true] {
                let controller = makeController([
                    binding(55, button: button, modifiers: LegacyModifier.shift),
                ])
                controller.handleDragGesture(directionModifier: LegacyModifier.dragRight,
                    baseModifiers: LegacyModifier.shift, button: button, leftHalf: leftHalf)
                XCTAssertEqual(controller.readerViewForInput.rotation, leftHalf ? 1 : 3)
            }
        }
    }

    func testExplicitAndDirectionlessDragBindingsTakePrecedenceOverClick() {
        for modifiers in [LegacyModifier.dragRight, LegacyModifier.drag] {
            let controller = makeController([
                binding(50, button: 4),
                binding(49, button: 4, modifiers: modifiers),
            ])
            controller.handleDragGesture(directionModifier: LegacyModifier.dragRight,
                baseModifiers: 0, button: 4, leftHalf: true)
            XCTAssertEqual(controller.readerViewForInput.rotation, 3)
        }
    }

    func testUnassignedLeftAndRightDragsDoNotFallBackToClick() {
        for button in [0, 1] {
            let controller = makeController([binding(50, button: button)])
            controller.handleDragGesture(directionModifier: LegacyModifier.dragRight,
                baseModifiers: 0, button: button, leftHalf: true)
            XCTAssertEqual(controller.readerViewForInput.rotation, 0)
        }
    }

    func testConsumedCurlDoesNotDispatchFallbackClickAgain() {
        let controller = makeController([binding(50, button: 4)])
        controller.mouseCurlConsumedGesture = true
        controller.handleDragGesture(directionModifier: LegacyModifier.dragRight,
            baseModifiers: 0, button: 4, leftHalf: true)
        XCTAssertEqual(controller.readerViewForInput.rotation, 0)
        XCTAssertFalse(controller.mouseCurlConsumedGesture)
    }

    /// 同期配送で状態機械から解放まで通し、実 defaults や本の移動には触れない。
    func test31PointMovementDispatchesSideButtonClickButNotLeftButtonClick() throws {
        for button in [0, 4] {
            let controller = makeController([binding(50, button: button)])
            try sendMouseGesture(to: controller, button: button, movement: 31, duration: 0.1)
            XCTAssertEqual(controller.readerViewForInput.rotation, button == 4 ? 1 : 0)
        }
    }

    func testLongPressCancelsSideButtonFallback() throws {
        let controller = makeController([binding(50, button: 4)])
        try sendMouseGesture(to: controller, button: 4, movement: 31, duration: 1.1)
        XCTAssertEqual(controller.readerViewForInput.rotation, 0)
    }

    func testHUDPreviewsFallbackClickAndKeepsUnassignedLeftDrag() async throws {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let originalArguments = arguments
        arguments["GestureHUDEnabled"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }

        let controller = makeController([binding(50, button: 4), binding(50, button: 0)])
        let book = try await Book.open(source: StubSource(sizes: [CGSize(width: 2, height: 4)]))
        controller.replaceBook(book)
        let label = try XCTUnwrap(controller.gestureHUD.subviews.compactMap { $0 as? NSTextField }.first)

        for button in [4, 0, 3] {
            controller.handleDragTracking(dx: 31, dy: 0, button: button, modifiers: 0, elapsed: 0.1)
            XCTAssertFalse(controller.gestureHUD.isHidden)
            XCTAssertEqual(label.stringValue, button == 4
                ? ActionNames.mouseActionName(50) : String(localized: "Not assigned"))
        }
        controller.replaceBook(nil)
    }

    private func makeController(_ bindings: [MouseBinding]) -> ReaderWindowController {
        let controller = ReaderWindowController(window: nil)
        controller.bindings = BindingConfiguration(keyNormal: [], keyMode2: [], keyMode3: [],
            mouseNormal: bindings, mouseMode2: [], mouseMode3: [])
        return controller
    }

    private func binding(_ action: Int, button: Int, modifiers: Int = 0) -> MouseBinding {
        MouseBinding(legacyActionNumber: action, button: button, modifiers: modifiers,
                     value: nil, switchAction: false)
    }

    private func sendMouseGesture(to controller: ReaderWindowController, button: Int,
                                  movement: CGFloat, duration: TimeInterval) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = controller.readerViewForInput
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
        window.contentView = view
        view.delegate = controller
        defer {
            view.delegate = nil
            window.contentView = nil
        }

        func event(_ type: NSEvent.EventType, offset: CGFloat, time: TimeInterval) throws -> NSEvent {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: 60 + offset, y: 80), modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 0))
            // NSEvent の生成 API に無いボタン番号は、既存のサイドボタンテスト同様に設定する。
            let cgEvent = try XCTUnwrap(event.cgEvent)
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        }

        if button == 0 {
            view.mouseDown(with: try event(.leftMouseDown, offset: 0, time: 1))
            view.mouseDragged(with: try event(.leftMouseDragged, offset: movement, time: 1 + duration / 2))
            view.mouseUp(with: try event(.leftMouseUp, offset: movement, time: 1 + duration))
        } else {
            view.otherMouseDown(with: try event(.otherMouseDown, offset: 0, time: 1))
            view.otherMouseDragged(with: try event(.otherMouseDragged, offset: movement, time: 1 + duration / 2))
            view.otherMouseUp(with: try event(.otherMouseUp, offset: movement, time: 1 + duration))
        }
    }
}
