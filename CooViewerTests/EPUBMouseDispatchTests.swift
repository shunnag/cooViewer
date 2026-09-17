import XCTest
@testable import cooViewer

/// EPUB の中・サイドボタンが画像本と同じ割当規則で発火することを検証する(設計書 §2.4)。
final class EPUBMouseDispatchTests: XCTestCase {
    private func mouse(_ action: Int, _ button: Int, _ modifiers: Int = 0,
                       value: Double? = nil, sw: Bool = false) -> MouseBinding {
        MouseBinding(legacyActionNumber: action, button: button, modifiers: modifiers,
                     value: value, switchAction: sw)
    }

    func testDefaultSideButtonsNavigateBooks() {
        for readsFromLeft in [false, true] {
            XCTAssertEqual(EPUBMouseDispatch.resolve(
                .click(button: 4, modifiers: 0), bindings: .builtInDefaults,
                readsFromLeft: readsFromLeft)?.action, .nextBook)
            XCTAssertEqual(EPUBMouseDispatch.resolve(
                .click(button: 3, modifiers: 0), bindings: .builtInDefaults,
                readsFromLeft: readsFromLeft)?.action, .previousBook)
        }
    }

    func testUnassignedSideButtonDragFallsBackToClick() {
        let resolved = EPUBMouseDispatch.resolve(
            .dragGesture(directionModifier: LegacyModifier.dragRight,
                         baseModifiers: 0, button: 4),
            bindings: .builtInDefaults, readsFromLeft: false)
        XCTAssertEqual(resolved?.action, .nextBook)
        XCTAssertNil(resolved?.value)
    }

    func testAssignedDragTakesPriorityOverClick() {
        var bindings = BindingConfiguration.builtInDefaults
        bindings.mouseNormal.append(mouse(49, 4, LegacyModifier.dragRight))
        XCTAssertEqual(EPUBMouseDispatch.resolve(
            .dragGesture(directionModifier: LegacyModifier.dragRight,
                         baseModifiers: 0, button: 4),
            bindings: bindings, readsFromLeft: false)?.action, .rotateRight)
    }

    func testDirectionlessDragTakesPriorityOverClick() {
        var bindings = BindingConfiguration.builtInDefaults
        bindings.mouseNormal.append(mouse(49, 4, LegacyModifier.drag))
        XCTAssertEqual(EPUBMouseDispatch.resolve(
            .dragGesture(directionModifier: LegacyModifier.dragRight,
                         baseModifiers: LegacyModifier.shift, button: 4),
            bindings: bindings, readsFromLeft: false)?.action, .rotateRight)
    }

    func testNoneDoesNotDispatch() {
        XCTAssertNil(EPUBMouseDispatch.resolve(
            .none, bindings: .builtInDefaults, readsFromLeft: false))
    }

    func testSwitchActionFollowsReadingDirection() {
        var bindings = BindingConfiguration.builtInDefaults
        bindings.mouseNormal = [mouse(6, VirtualButton.swipeLeft, sw: true)]
        let outcome = MouseGestureRecognizer.Outcome.click(
            button: VirtualButton.swipeLeft, modifiers: 0)
        XCTAssertEqual(EPUBMouseDispatch.resolve(
            outcome, bindings: bindings, readsFromLeft: false)?.action, .nextPage)
        XCTAssertEqual(EPUBMouseDispatch.resolve(
            outcome, bindings: bindings, readsFromLeft: true)?.action, .previousPage)
    }

    func testMiddleButtonFallbackPreservesModifiersAndValue() {
        var bindings = BindingConfiguration.builtInDefaults
        bindings.mouseNormal = [mouse(14, 2), mouse(19, 2, LegacyModifier.shift, value: 7)]
        let outcomes: [MouseGestureRecognizer.Outcome] = [
            .click(button: 2, modifiers: LegacyModifier.shift),
            .dragGesture(directionModifier: LegacyModifier.dragRight,
                         baseModifiers: LegacyModifier.shift, button: 2),
        ]
        for outcome in outcomes {
            let resolved = EPUBMouseDispatch.resolve(
                outcome, bindings: bindings, readsFromLeft: false)
            XCTAssertEqual(resolved?.action, .skip)
            XCTAssertEqual(resolved?.value, 7)
        }
    }

    func testInvalidAssignedDragDoesNotFallBackToClick() {
        var bindings = BindingConfiguration.builtInDefaults
        bindings.mouseNormal.append(mouse(999, 4, LegacyModifier.dragRight))
        XCTAssertNil(EPUBMouseDispatch.resolve(
            .dragGesture(directionModifier: LegacyModifier.dragRight,
                         baseModifiers: 0, button: 4),
            bindings: bindings, readsFromLeft: false))
    }

    func testPrimaryButtonsDoNotFallBackToClick() {
        var bindings = BindingConfiguration.builtInDefaults
        bindings.mouseNormal = [mouse(14, 0), mouse(15, 1)]
        for button in [0, 1] {
            XCTAssertNil(EPUBMouseDispatch.resolve(
                .dragGesture(directionModifier: LegacyModifier.dragRight,
                             baseModifiers: 0, button: button),
                bindings: bindings, readsFromLeft: false))
        }
    }

    func testModeSpecificBindingsAreIgnored() {
        var bindings = BindingConfiguration.builtInDefaults
        let overrides = [mouse(15, 4), mouse(49, 4, LegacyModifier.dragRight)]
        bindings.mouseMode2 = overrides
        bindings.mouseMode3 = overrides
        let outcomes: [MouseGestureRecognizer.Outcome] = [
            .click(button: 4, modifiers: 0),
            .dragGesture(directionModifier: LegacyModifier.dragRight,
                         baseModifiers: 0, button: 4),
        ]
        for outcome in outcomes {
            XCTAssertEqual(EPUBMouseDispatch.resolve(
                outcome, bindings: bindings, readsFromLeft: false)?.action, .nextBook)
        }
    }

    func test31PointMovementStillNavigatesToNextBook() {
        var recognizer = MouseGestureRecognizer()
        recognizer.begin(button: 4, point: .zero, time: 10, dragScroll: false)
        let outcome = recognizer.finish(
            point: CGPoint(x: 31, y: 0), time: 10.2, modifiers: 0)
        XCTAssertEqual(EPUBMouseDispatch.resolve(
            outcome, bindings: .builtInDefaults, readsFromLeft: false)?.action, .nextBook)
        XCTAssertFalse(recognizer.isTracking)
    }

    func testLongPressCancelsClickAndDragFallback() {
        for distance: CGFloat in [0, 31] {
            var recognizer = MouseGestureRecognizer()
            recognizer.begin(button: 4, point: .zero, time: 10, dragScroll: false)
            let outcome = recognizer.finish(
                point: CGPoint(x: distance, y: 0), time: 11.01, modifiers: 0)
            XCTAssertNil(EPUBMouseDispatch.resolve(
                outcome, bindings: .builtInDefaults, readsFromLeft: false))
            XCTAssertFalse(recognizer.isTracking)
        }
    }
}
