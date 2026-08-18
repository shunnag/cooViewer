import XCTest
@testable import cooViewer

/// 設定「マウスとジェスチャ」のカタログ写像の検証(設計書 §7.6)
final class MouseBindingCatalogTests: XCTestCase {
    private func row(_ action: Int, _ button: Int, _ modifiers: Int = 0,
                     sw: Bool = false) -> MouseBinding {
        MouseBinding(legacyActionNumber: action, button: button, modifiers: modifiers,
                     value: nil, switchAction: sw)
    }

    func testIndexMatchesFirstUnmodifiedRow() {
        // 先頭一致(resolveMouse と同じ)なので重複行があっても表示と実挙動が揃う
        let bindings = [row(0, 0), row(6, 0), row(1, 0, LegacyModifier.shift)]
        XCTAssertEqual(MouseBindingCatalog.index(of: 0, in: bindings), 0)
        XCTAssertNil(MouseBindingCatalog.index(of: 2, in: bindings))
    }

    func testAssignUpsertsAndRemoves() {
        var bindings = [row(0, 0)]
        MouseBindingCatalog.assign(&bindings, button: 2, action: 43)
        XCTAssertEqual(bindings.count, 2)
        MouseBindingCatalog.assign(&bindings, button: 0, action: 6)
        XCTAssertEqual(bindings[0].legacyActionNumber, 6)
        MouseBindingCatalog.assign(&bindings, button: 0, action: nil)  // 「なし」
        XCTAssertNil(MouseBindingCatalog.index(of: 0, in: bindings))
    }

    func testAssignClearsIneligibleSwitchAction() {
        // 入替不可のアクションへ変えたら switchAction を外す(仕様書 §5.4)
        var bindings = [row(6, VirtualButton.swipeLeft, sw: true)]
        MouseBindingCatalog.assign(&bindings, button: VirtualButton.swipeLeft, action: 59)
        XCTAssertFalse(bindings[0].switchAction)
    }

    func testOtherRowsKeepModifiedAndDuplicateEntries() {
        // 修飾キー付き・方向ドラッグ・重複 2 行目はカタログ外として列挙され、
        // 既存データが UI から欠落しない
        let bindings = [
            row(0, 0),                                   // カタログ(左クリック)
            row(1, 0, LegacyModifier.shift),             // 修飾キー付き
            row(6, 1, LegacyModifier.dragLeft),          // 方向ドラッグ
            row(7, 0),                                   // 左クリックの重複 2 行目
            row(41, 0, LegacyModifier.drag),             // 方向不問ドラッグ
        ]
        XCTAssertEqual(MouseBindingCatalog.otherRowIndices(in: bindings), [1, 2, 3, 4])
    }

    func testInheritedButtonsAreCatalogMinusOverrides() {
        // Mode2/3 既定(クリック+ドラッグスクロール)では左クリックだけが上書き済み
        let overrides = [row(41, 0, LegacyModifier.drag), row(42, 0)]
        let inherited = MouseBindingCatalog.inheritedButtons(override: overrides)
        XCTAssertFalse(inherited.contains(0))
        XCTAssertTrue(inherited.contains(2))
        XCTAssertTrue(inherited.contains(VirtualButton.swipeLeft))
        XCTAssertEqual(inherited.count, MouseBindingCatalog.mouseButtons.count
                       + MouseBindingCatalog.gestureButtons.count - 1)
    }

    func testAssignmentIndicesListAllRowsOfAction() {
        // できること別ビュー: 1 機能に複数入力(修飾キー付き含む)を列挙する
        let bindings = [
            row(6, VirtualButton.swipeLeft), row(0, 0),
            row(6, 4), row(6, 1, LegacyModifier.shift),
        ]
        XCTAssertEqual(MouseBindingCatalog.assignmentIndices(for: 6, in: bindings),
                       [0, 2, 3])
        XCTAssertTrue(MouseBindingCatalog.assignmentIndices(for: 43, in: bindings).isEmpty)
    }

    func testSetValueAppliesToAllAssignmentsOfAction() {
        var bindings = [row(19, 0), row(19, 4), row(6, 1)]
        MouseBindingCatalog.setValue(5, forAction: 19, in: &bindings)
        XCTAssertEqual(bindings[0].value, 5)
        XCTAssertEqual(bindings[1].value, 5)
        XCTAssertNil(bindings[2].value)  // 他の機能には触れない
        MouseBindingCatalog.setValue(nil, forAction: 19, in: &bindings)
        XCTAssertNil(bindings[0].value)
    }

    func testCategoriesCoverAllMouseActionsExceptDragScroll() {
        // カテゴリ表は 0-64 を重複なく網羅する(41=ドラッグスクロールだけは
        // 基本セットで効かないため除外。仕様書 §5.7.5)
        let all = ActionNames.mouseActionCategories.flatMap(\.numbers)
        XCTAssertEqual(all.count, Set(all).count, "重複あり")
        XCTAssertEqual(Set(all), Set(0...64).subtracting([41]))
    }

    func testValueUnitOnlyForValueUsingActions() {
        XCTAssertNotNil(ActionNames.mouseValueUnit(19))  // スキップ=ページ数
        XCTAssertNotNil(ActionNames.mouseValueUnit(38))  // スクロール=px
        XCTAssertNil(ActionNames.mouseValueUnit(6))      // 次のページは数値不使用
        XCTAssertNil(ActionNames.mouseValueUnit(41))
    }
}
