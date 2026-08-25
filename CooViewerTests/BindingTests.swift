import AppKit
import XCTest
@testable import cooViewer

final class BindingTests: XCTestCase {
    private let bindings = BindingConfiguration.builtInDefaults
    private let leftArrow = Character(UnicodeScalar(NSLeftArrowFunctionKey)!)

    // MARK: - 既定バインディング(仕様書 §5.7)

    func testDefaultZIsNextPageInRTL() {
        let binding = bindings.resolveKey(character: "z", modifiers: 0,
                                          fitMode: 0, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .nextPage)
    }

    func testSwitchActionSwapsInLTR() {
        // z は switchAction 付きなので左綴じでは PreviousPage になる(仕様書 §5.4)
        let binding = bindings.resolveKey(character: "z", modifiers: 0,
                                          fitMode: 0, readsFromLeft: true)
        XCTAssertEqual(binding?.action, .previousPage)
    }

    func testSpaceHasNoSwitchActionAndStaysNextPage() {
        let binding = bindings.resolveKey(character: " ", modifiers: 0,
                                          fitMode: 0, readsFromLeft: true)
        XCTAssertEqual(binding?.action, .nextPage)
    }

    func testDigitKeyIsGoToPercentWithValue() {
        let binding = bindings.resolveKey(character: "5", modifiers: 0,
                                          fitMode: 0, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .goToPercent)
        XCTAssertEqual(binding?.value, 50)
    }

    // MARK: - モード別解決順(仕様書 §5.3)

    func testFitWidthModeOverridesSpace() {
        // 幅フィット(mode2)では space=27 PageDown+NextPage
        let binding = bindings.resolveKey(character: " ", modifiers: 0,
                                          fitMode: 1, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .pageDownOrNextPage)
    }

    func testFitWidthModeFallsBackToNormalArray() {
        // mode2 に z は無い → ノーマル配列へフォールバック
        let binding = bindings.resolveKey(character: "z", modifiers: 0,
                                          fitMode: 1, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .nextPage)
    }

    func testNoScaleModeUsesMode3HorizontalScroll() {
        let binding = bindings.resolveKey(character: leftArrow, modifiers: 0,
                                          fitMode: 2, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .scrollLeft)
        XCTAssertEqual(binding?.value, 20)
    }

    // MARK: - マウス(仕様書 §5.6, §5.7.4)

    func testLeftClickIsPositionalNextPrev() {
        let binding = bindings.resolveMouse(button: 0, modifiers: 0,
                                            fitMode: 0, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .positionalNextPrevPage)
    }

    func testControlClickIsContextMenu() {
        let binding = bindings.resolveMouse(button: 0, modifiers: LegacyModifier.control,
                                            fitMode: 0, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .contextualMenu)
    }

    func testPinchHasNoDefaultBinding() {
        // ピンチは常に連続ズームに固定なので既定割当を持たない(設計書 §2.4)。
        // 旧既定 pinchOut=63/pinchIn=64 は発火しないため外した
        XCTAssertNil(bindings.resolveMouse(button: VirtualButton.pinchIn, modifiers: 0,
                                           fitMode: 0, readsFromLeft: false))
        XCTAssertNil(bindings.resolveMouse(button: VirtualButton.pinchOut, modifiers: 0,
                                           fitMode: 0, readsFromLeft: false))
        // 回転・スワイプのジェスチャ既定は維持
        XCTAssertNotNil(bindings.resolveMouse(button: VirtualButton.rotateRight, modifiers: 0,
                                              fitMode: 0, readsFromLeft: false))
        XCTAssertNotNil(bindings.resolveMouse(button: VirtualButton.swipeLeft, modifiers: 0,
                                              fitMode: 0, readsFromLeft: false))
    }

    func testDragResolutionFallsBackToDirectionless() {
        // mode2 の既定は方向不問ドラッグ(100)=DragScroll のみ
        let binding = bindings.resolveDrag(button: 0, baseModifiers: 0,
                                           directionModifier: LegacyModifier.dragLeft,
                                           fitMode: 1, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .dragScroll)
    }

    func testDragResolutionHonorsNonPrimaryButton() {
        // 右ボタンの方向別ドラッグ割当も解決される(仕様書 §5.9: 全ボタン共通)
        var config = BindingConfiguration.builtInDefaults
        config.mouseNormal.append(MouseBinding(
            legacyActionNumber: 6, button: 1, modifiers: LegacyModifier.dragLeft,
            value: nil, switchAction: false))
        let binding = config.resolveDrag(button: 1, baseModifiers: 0,
                                         directionModifier: LegacyModifier.dragLeft,
                                         fitMode: 0, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .nextPage)
    }

    // MARK: - DragScroll の照会(仕様書 §5.7.5)

    func testDragScrollResolvesFromModeSpecificArray() {
        // Mode2/3 既定の button0+drag(100)=41
        XCTAssertNotNil(bindings.resolveDragScroll(
            button: 0, modifiers: LegacyModifier.drag, fitMode: 1))
        XCTAssertNotNil(bindings.resolveDragScroll(
            button: 0, modifiers: LegacyModifier.drag, fitMode: 2))
        // 修飾キー・ボタン不一致は不成立
        XCTAssertNil(bindings.resolveDragScroll(
            button: 0, modifiers: LegacyModifier.drag + LegacyModifier.shift, fitMode: 1))
        XCTAssertNil(bindings.resolveDragScroll(
            button: 1, modifiers: LegacyModifier.drag, fitMode: 1))
    }

    func testDragScrollNeverResolvesInFitToScreen() {
        // 旧実装は dragScrollDic を mode1-3 にしか配布しない(仕様書 §5.7.5)
        XCTAssertNil(bindings.resolveDragScroll(
            button: 0, modifiers: LegacyModifier.drag, fitMode: 0))
    }

    func testDragScrollIgnoresMode0Entries() {
        // mode0 配列の 41 はどのモードでも効かない(mode0 フォールバック無し)
        var config = BindingConfiguration.builtInDefaults
        config.mouseNormal.append(MouseBinding(
            legacyActionNumber: 41, button: 2, modifiers: LegacyModifier.drag,
            value: nil, switchAction: false))
        XCTAssertNil(config.resolveDragScroll(
            button: 2, modifiers: LegacyModifier.drag, fitMode: 1))
        XCTAssertNil(config.resolveDragScroll(
            button: 2, modifiers: LegacyModifier.drag, fitMode: 0))
    }

    func testDragScrollHonorsCustomButtonInModeArray() {
        // モード固有配列に置いた右ボタン割当は成立する(旧 dragScrollDic 互換)
        var config = BindingConfiguration.builtInDefaults
        config.mouseMode2.append(MouseBinding(
            legacyActionNumber: 41, button: 1, modifiers: LegacyModifier.drag,
            value: nil, switchAction: false))
        XCTAssertNotNil(config.resolveDragScroll(
            button: 1, modifiers: LegacyModifier.drag, fitMode: 1))
    }

    // MARK: - 旧 defaults 形式の読み込み(仕様書 §5.1)

    func testLegacyKeyArrayDecoding() {
        let legacy: [[String: Any]] = [
            ["action": 0, "key": "z", "keyname": "z", "modifier": 0, "switchAction": true],
            ["action": 13, "key": "\t", "keyname": "tab", "modifier": 0, "value": 5],
            ["action": 0, "key": "P", "keyname": "Play", "modifier": 100],  // Apple Remote 残滓
        ]
        let decoded = BindingConfiguration.keyBindings(fromLegacyArray: legacy)
        XCTAssertEqual(decoded.count, 2)  // Remote エントリは読み飛ばす(設計書 §13.1)
        XCTAssertTrue(decoded[0].switchAction)
        XCTAssertEqual(decoded[1].value, 5)
        XCTAssertFalse(decoded[1].switchAction)  // キー欠落=オフ(仕様書 §5.1)
    }

    func testLegacyMouseNumber28MapsToActualBehavior() {
        // 旧 28 はラベル left・実挙動 R。実挙動を正とする(仕様書 §13.3)
        XCTAssertEqual(ReaderAction.fromLegacyMouseNumber(28), .showInFinderRight)
        XCTAssertEqual(ReaderAction.fromLegacyMouseNumber(29), .showInFinderLeft)
    }

    func testMouseSwitchPairsSwapFolderMoves() {
        XCTAssertEqual(ReaderAction.switchedLegacyMouseNumber(14), 15)
        XCTAssertEqual(ReaderAction.switchedLegacyMouseNumber(44), 45)
        // ゴミ箱・Finder・原寸は入替対象外(仕様書 §5.4)
        XCTAssertEqual(ReaderAction.switchedLegacyMouseNumber(52), 52)
        XCTAssertEqual(ReaderAction.switchedLegacyMouseNumber(28), 28)
    }

    func testAllLegacyKeyNumbersMapped() {
        for number in 0...53 {
            XCTAssertNotNil(ReaderAction.fromLegacyKeyNumber(number), "key action \(number)")
        }
        XCTAssertNil(ReaderAction.fromLegacyKeyNumber(54))
    }

    func testDefaultFKeyTogglesInterpolation() {
        let binding = bindings.resolveKey(character: "f", modifiers: 0,
                                          fitMode: 0, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .toggleInterpolation)
    }

    func testAllLegacyMouseNumbersMapped() {
        for number in 0...64 {
            XCTAssertNotNil(ReaderAction.fromLegacyMouseNumber(number), "mouse action \(number)")
        }
        XCTAssertNil(ReaderAction.fromLegacyMouseNumber(65))
    }
}

extension BindingTests {
    func testStoredKeyArrayGainsInterpolationToggleMigration() {
        let suite = UserDefaults(suiteName: "test.cooViewer.bindings")!
        suite.removePersistentDomain(forName: "test.cooViewer.bindings")
        suite.set([["action": 0, "key": "z", "keyname": "z", "modifier": 0]],
                  forKey: "KeyArray")
        let loaded = BindingConfiguration.load(from: suite)
        XCTAssertTrue(loaded.keyNormal.contains {
            $0.key == "f" && $0.legacyActionNumber == 53
        })
        // f を別用途に使っている場合は追記しない
        suite.set([["action": 0, "key": "f", "keyname": "f", "modifier": 0]],
                  forKey: "KeyArray")
        let custom = BindingConfiguration.load(from: suite)
        XCTAssertFalse(custom.keyNormal.contains { $0.legacyActionNumber == 53 })
        suite.removePersistentDomain(forName: "test.cooViewer.bindings")
    }

    func testSideButtonDefaultsAreLogicalBackForward() {
        // button 3=戻る(前ページ)/4=進む(次ページ)。switchAction なしなので
        // 左綴じでも反転しない(ブラウザ同様の論理ナビゲーション。設計書 §2.4)
        for readsFromLeft in [false, true] {
            XCTAssertEqual(bindings.resolveMouse(button: 3, modifiers: 0, fitMode: 0,
                                                 readsFromLeft: readsFromLeft)?.action,
                           .previousPage)
            XCTAssertEqual(bindings.resolveMouse(button: 4, modifiers: 0, fitMode: 0,
                                                 readsFromLeft: readsFromLeft)?.action,
                           .nextPage)
        }
    }

    func testStoredMouseArrayGainsSideButtonInjection() {
        let suite = UserDefaults(suiteName: "test.cooViewer.mouse")!
        suite.removePersistentDomain(forName: "test.cooViewer.mouse")
        suite.set([["action": 0, "button": 0, "modifier": 0]], forKey: "MouseArray")
        let loaded = BindingConfiguration.load(from: suite)
        XCTAssertTrue(loaded.mouseNormal.contains {
            $0.button == 3 && $0.legacyActionNumber == 7
        })
        XCTAssertTrue(loaded.mouseNormal.contains {
            $0.button == 4 && $0.legacyActionNumber == 6
        })
        // button 3 を別用途に使っている場合はそのボタンへは注入しない
        suite.set([["action": 43, "button": 3, "modifier": 0]], forKey: "MouseArray")
        let custom = BindingConfiguration.load(from: suite)
        XCTAssertFalse(custom.mouseNormal.contains {
            $0.button == 3 && $0.legacyActionNumber == 7
        })
        XCTAssertTrue(custom.mouseNormal.contains {
            $0.button == 4 && $0.legacyActionNumber == 6
        })
        suite.removePersistentDomain(forName: "test.cooViewer.mouse")
    }

    func testKeyInjectionStopsAfterUserEdit() {
        // 設定 UI で KeyArray を保存したら以後 f 注入をしない = 削除が定着する
        let suite = UserDefaults(suiteName: "test.cooViewer.keys.edited")!
        suite.removePersistentDomain(forName: "test.cooViewer.keys.edited")
        BindingConfiguration.saveKeyBindings(
            [KeyBinding(legacyActionNumber: 0, key: "z", modifiers: 0,
                        value: nil, switchAction: false)],
            arrayName: "KeyArray", to: suite)
        XCTAssertTrue(suite.bool(forKey: "KeyArrayUserEdited"))
        let loaded = BindingConfiguration.load(from: suite)
        XCTAssertFalse(loaded.keyNormal.contains { $0.legacyActionNumber == 53 })
        // Mode2/3 の保存ではフラグを立てない
        suite.removeObject(forKey: "KeyArrayUserEdited")
        BindingConfiguration.saveKeyBindings([], arrayName: "KeyArrayMode2", to: suite)
        XCTAssertFalse(suite.bool(forKey: "KeyArrayUserEdited"))
        suite.removePersistentDomain(forName: "test.cooViewer.keys.edited")
    }

    func testSideButtonInjectionStopsAfterUserEdit() {
        // 設定 UI で MouseArray を保存したら以後注入しない = 削除が定着する
        let suite = UserDefaults(suiteName: "test.cooViewer.mouse.edited")!
        suite.removePersistentDomain(forName: "test.cooViewer.mouse.edited")
        BindingConfiguration.saveMouseBindings(
            [MouseBinding(legacyActionNumber: 0, button: 0, modifiers: 0,
                          value: nil, switchAction: false)],
            arrayName: "MouseArray", to: suite)
        XCTAssertTrue(suite.bool(forKey: "MouseArrayUserEdited"))
        let loaded = BindingConfiguration.load(from: suite)
        XCTAssertFalse(loaded.mouseNormal.contains { $0.button == 3 || $0.button == 4 })
        // Mode2/3 の保存ではフラグを立てない(mode0 の注入と無関係)
        suite.removeObject(forKey: "MouseArrayUserEdited")
        BindingConfiguration.saveMouseBindings([], arrayName: "MouseArrayMode2", to: suite)
        XCTAssertFalse(suite.bool(forKey: "MouseArrayUserEdited"))
        suite.removePersistentDomain(forName: "test.cooViewer.mouse.edited")
    }

    // MARK: - 全割当削除の定着(監査 #8: 明示的な空配列は既定を復活させない)

    func testEmptyMouseArrayHonoredAfterUserEdit() {
        // UI でマウス割当を全削除(空を保存)したら、再起動でも既定が復活しない
        let suite = UserDefaults(suiteName: "test.cooViewer.mouse.empty")!
        suite.removePersistentDomain(forName: "test.cooViewer.mouse.empty")
        BindingConfiguration.saveMouseBindings([], arrayName: "MouseArray", to: suite)
        XCTAssertTrue(suite.bool(forKey: "MouseArrayUserEdited"))
        let loaded = BindingConfiguration.load(from: suite)
        XCTAssertTrue(loaded.mouseNormal.isEmpty,
                      "明示的に空保存した配列は既定へ戻してはならない")
        suite.removePersistentDomain(forName: "test.cooViewer.mouse.empty")
    }

    func testAbsentMouseArrayFallsBackToDefaults() {
        // 未設定(キー自体が無い)は従来どおり既定へ
        let suite = UserDefaults(suiteName: "test.cooViewer.mouse.absent")!
        suite.removePersistentDomain(forName: "test.cooViewer.mouse.absent")
        let loaded = BindingConfiguration.load(from: suite)
        XCTAssertFalse(loaded.mouseNormal.isEmpty)
        suite.removePersistentDomain(forName: "test.cooViewer.mouse.absent")
    }

    func testCorruptMouseArrayFallsBackToDefaults() {
        // 非空だが全行が不正(action/button 欠落)= 壊れたデータは既定へ戻す
        let suite = UserDefaults(suiteName: "test.cooViewer.mouse.corrupt")!
        suite.removePersistentDomain(forName: "test.cooViewer.mouse.corrupt")
        suite.set([["nonsense": 1]], forKey: "MouseArray")
        let loaded = BindingConfiguration.load(from: suite)
        XCTAssertFalse(loaded.mouseNormal.isEmpty)
        suite.removePersistentDomain(forName: "test.cooViewer.mouse.corrupt")
    }

    func testEmptyKeyArrayHonoredAfterUserEdit() {
        let suite = UserDefaults(suiteName: "test.cooViewer.keys.empty")!
        suite.removePersistentDomain(forName: "test.cooViewer.keys.empty")
        BindingConfiguration.saveKeyBindings([], arrayName: "KeyArray", to: suite)
        XCTAssertTrue(suite.bool(forKey: "KeyArrayUserEdited"))
        let loaded = BindingConfiguration.load(from: suite)
        XCTAssertTrue(loaded.keyNormal.isEmpty,
                      "明示的に空保存したキー配列は既定へ戻してはならない")
        suite.removePersistentDomain(forName: "test.cooViewer.keys.empty")
    }

    func testDragFallbackDiscardsModifiers() {
        // フォールバック段は修飾キーを捨てた素の 100 固定(仕様書 §5.3、
        // Controller_input.m:1012-1026)。shift 付きドラッグでも (button,100)
        // の割当が効き、(button,101) の割当はジェスチャとして発火しない
        var config = BindingConfiguration.builtInDefaults
        config.mouseNormal.append(MouseBinding(
            legacyActionNumber: 6, button: 2, modifiers: LegacyModifier.drag,
            value: nil, switchAction: false))
        config.mouseNormal.append(MouseBinding(
            legacyActionNumber: 14, button: 5,
            modifiers: LegacyModifier.drag + LegacyModifier.shift,
            value: nil, switchAction: false))
        XCTAssertEqual(config.resolveDrag(
            button: 2, baseModifiers: LegacyModifier.shift,
            directionModifier: LegacyModifier.dragUp,
            fitMode: 0, readsFromLeft: false)?.action, .nextPage)
        XCTAssertNil(config.resolveDrag(
            button: 5, baseModifiers: LegacyModifier.shift,
            directionModifier: LegacyModifier.dragUp,
            fitMode: 0, readsFromLeft: false))
    }

    func testLegacyArrayRoundTrip() {
        // 編集 UI の保存形式(旧互換)を読み戻して同一になること
        let original = [
            KeyBinding(legacyActionNumber: 13, key: "\t",
                       modifiers: LegacyModifier.shift, value: 5, switchAction: true),
            KeyBinding(legacyActionNumber: 39, key: "7", modifiers: 0,
                       value: 70, switchAction: false),
        ]
        let encoded = BindingConfiguration.legacyArray(from: original)
        let decoded = BindingConfiguration.keyBindings(fromLegacyArray: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(encoded[0]["keyname"] as? String, "shift+tab")
    }

    func testBackTabDisplayName() {
        // 実 1.x データの Shift+Tab は key=0x19(NSBackTabCharacter)で保存される。
        // 表示名 case が無いと生の制御文字が出るため "shift+tab" と表示する(cooViewer-5gv)
        let backTab = Character(UnicodeScalar(0x19)!)
        XCTAssertEqual(ActionNames.keyName(for: backTab), "tab")
        let binding = KeyBinding(legacyActionNumber: 14, key: backTab,
                                 modifiers: LegacyModifier.shift, value: 10, switchAction: false)
        let name = ActionNames.displayName(for: binding)
        XCTAssertEqual(name, "shift+tab")
        // 表示名に不可視制御文字が漏れないこと
        XCTAssertFalse(name.unicodeScalars.contains { $0.value < 0x20 })
    }

    func testMouseLegacyArrayRoundTripKeepsSchema() {
        // マウス編集 UI の保存形式が仕様書 §5.1 のスキーマを厳守すること
        let original = [
            MouseBinding(legacyActionNumber: 6, button: 1,
                         modifiers: LegacyModifier.dragLeft + LegacyModifier.shift,
                         value: nil, switchAction: true),
            MouseBinding(legacyActionNumber: 41, button: 0,
                         modifiers: LegacyModifier.drag, value: nil, switchAction: false),
            MouseBinding(legacyActionNumber: 39, button: VirtualButton.pinchOut,
                         modifiers: 0, value: 50, switchAction: false),
        ]
        let encoded = BindingConfiguration.legacyArray(from: original)
        let decoded = BindingConfiguration.mouseBindings(fromLegacyArray: encoded)
        XCTAssertEqual(decoded, original)
        // switchAction は「オンのときだけキーが存在」(仕様書 §13.2)
        XCTAssertNotNil(encoded[0]["switchAction"])
        XCTAssertNil(encoded[1]["switchAction"])
        // キー配列と違い keyname は書かない・スキーマ外のキーを増やさない(§5.1)
        let allowed: Set<String> = ["action", "button", "modifier", "value", "switchAction"]
        for dict in encoded {
            XCTAssertTrue(Set(dict.keys).isSubset(of: allowed), "\(dict.keys)")
        }
    }

    func testMouseTriggerNames() {
        // 表示名はローカライズされるため、実行言語に依存しない構造を検証する:
        // 修飾キー接頭辞(raw 文字列)の合成と、種別ごとの基本名の区別
        XCTAssertEqual(ActionNames.mouseTriggerName(button: 0, modifiers: 0),
                       ActionNames.mouseTriggerBaseName(button: 0, kindModifier: 0))
        let shifted = ActionNames.mouseTriggerName(
            button: 1, modifiers: LegacyModifier.dragLeft + LegacyModifier.shift)
        XCTAssertEqual(shifted, "shift+" + ActionNames.mouseTriggerBaseName(
            button: 1, kindModifier: LegacyModifier.dragLeft))
        // クリック/方向不問ドラッグ/方向別ドラッグ/仮想ボタンは互いに別表記
        let names = [
            ActionNames.mouseTriggerBaseName(button: 0, kindModifier: 0),
            ActionNames.mouseTriggerBaseName(button: 0, kindModifier: LegacyModifier.drag),
            ActionNames.mouseTriggerBaseName(button: 0,
                                             kindModifier: LegacyModifier.dragLeft),
            ActionNames.mouseTriggerBaseName(button: VirtualButton.swipeUp,
                                             kindModifier: 0),
        ]
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
    }

    func testMouseSwitchActionEligibility() {
        // 旧設定シートの可否リスト(仕様書 §5.4 / PreferenceController.m:2182-2196)
        for number in [6, 15, 19, 20, 33, 34, 44, 45] {
            XCTAssertTrue(ActionNames.mouseSwitchActionEligible.contains(number))
        }
        for number in [0, 5, 16, 41, 59] {
            XCTAssertFalse(ActionNames.mouseSwitchActionEligible.contains(number))
        }
    }
}

/// レビュー修正の回帰: 旧データの switchAction=0 は偽として読む
final class LegacyFlagParsingTests: XCTestCase {
    func testExplicitZeroSwitchActionIsFalse() {
        let bindings = BindingConfiguration.keyBindings(fromLegacyArray: [
            ["action": 0, "key": "j", "switchAction": 1],
            ["action": 1, "key": "k", "switchAction": 0],
            ["action": 2, "key": "l"],
        ])
        XCTAssertEqual(bindings.map(\.switchAction), [true, false, false])
    }
}
