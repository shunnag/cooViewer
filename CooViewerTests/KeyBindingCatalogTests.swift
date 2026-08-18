import XCTest
@testable import cooViewer

/// 設定「キー割り当て」の「できること別」写像の検証(設計書 §7.6)
final class KeyBindingCatalogTests: XCTestCase {
    private func row(_ action: Int, _ key: Character, _ modifiers: Int = 0,
                     value: Double? = nil) -> KeyBinding {
        KeyBinding(legacyActionNumber: action, key: key, modifiers: modifiers,
                   value: value, switchAction: false)
    }

    func testCategoriesCoverAllKeyActions() {
        // カテゴリ表はキーアクション 0-53 を重複なく網羅する
        let all = ActionNames.keyActionCategories.flatMap(\.numbers)
        XCTAssertEqual(all.count, Set(all).count, "重複あり")
        XCTAssertEqual(Set(all), Set(0...53))
    }

    func testAssignmentIndicesListAllRowsOfAction() {
        let bindings = [row(0, "z"), row(1, "x"), row(0, " "),
                        row(0, "z", LegacyModifier.shift)]
        XCTAssertEqual(KeyBindingCatalog.assignmentIndices(for: 0, in: bindings),
                       [0, 2, 3])
    }

    func testIndexMatchesKeyAndModifiers() {
        let bindings = [row(0, "z"), row(2, "z", LegacyModifier.shift)]
        XCTAssertEqual(KeyBindingCatalog.index(ofKey: "z", modifiers: 0, in: bindings), 0)
        XCTAssertEqual(KeyBindingCatalog.index(ofKey: "z",
                                               modifiers: LegacyModifier.shift,
                                               in: bindings), 1)
        XCTAssertNil(KeyBindingCatalog.index(ofKey: "q", modifiers: 0, in: bindings))
    }

    func testSetValueAppliesToAllAssignmentsOfAction() {
        var bindings = [row(13, "\t", value: 10), row(13, "n"), row(0, "z")]
        KeyBindingCatalog.setValue(5, forAction: 13, in: &bindings)
        XCTAssertEqual(bindings[0].value, 5)
        XCTAssertEqual(bindings[1].value, 5)
        XCTAssertNil(bindings[2].value)
    }

    func testKeySwitchEligibilityMatchesSwapPairs() {
        // 入替ペア(switchedLegacyKeyNumber)の両側だけが対象
        for number in 0...53 {
            let swaps = ReaderAction.switchedLegacyKeyNumber(number) != number
            XCTAssertEqual(ActionNames.keySwitchActionEligible.contains(number), swaps,
                           "action \(number)")
        }
    }
}
