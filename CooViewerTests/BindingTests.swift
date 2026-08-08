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

    func testDragResolutionFallsBackToDirectionless() {
        // mode2 の既定は方向不問ドラッグ(100)=DragScroll のみ
        let binding = bindings.resolveDrag(button: 0, baseModifiers: 0,
                                           directionModifier: LegacyModifier.dragLeft,
                                           fitMode: 1, readsFromLeft: false)
        XCTAssertEqual(binding?.action, .dragScroll)
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
