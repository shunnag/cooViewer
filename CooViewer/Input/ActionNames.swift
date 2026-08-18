import AppKit

/// キーアクション番号(仕様書 §5.5)の表示名と、キーの人間可読表記。
/// バインディング編集 UI で使う。
enum ActionNames {
    static let allKeyActionNumbers = Array(0...53)

    static func keyActionName(_ number: Int) -> String {
        switch number {
        case 0: String(localized: "Next Page")
        case 1: String(localized: "Previous Page")
        case 2: String(localized: "Half Page Forward")
        case 3: String(localized: "Half Page Backward")
        case 4: String(localized: "Last Page")
        case 5: String(localized: "First Page")
        case 6: String(localized: "Next Bookmark")
        case 7: String(localized: "Previous Bookmark")
        case 8: String(localized: "Next Book")
        case 9: String(localized: "Previous Book")
        case 10: String(localized: "Add/Remove Bookmark")
        case 11: String(localized: "Toggle Single/Spread")
        case 12: String(localized: "Show page number")
        case 13: String(localized: "Skip Forward")
        case 14: String(localized: "Skip Backward")
        case 15: String(localized: "View Original (right)")
        case 16: String(localized: "View Original (left)")
        case 17: String(localized: "Slideshow")
        case 18: String(localized: "Show Thumbnails")
        case 19: String(localized: "Cycle Reading Direction")
        case 20: String(localized: "Show page bar")
        case 21: String(localized: "Go to Page")
        case 22: String(localized: "Show in Finder (right)")
        case 23: String(localized: "Show in Finder (left)")
        case 24: String(localized: "Screen Up")
        case 25: String(localized: "Screen Down")
        case 26: String(localized: "Screen Up / Previous Page")
        case 27: String(localized: "Screen Down / Next Page")
        case 28: String(localized: "Scroll to Top")
        case 29: String(localized: "Scroll to End")
        case 30: String(localized: "Scroll Up")
        case 31: String(localized: "Scroll Down")
        case 32: String(localized: "Scroll Left")
        case 33: String(localized: "Scroll Right")
        case 34: String(localized: "Toggle Loupe")
        case 35: String(localized: "Next Subfolder")
        case 36: String(localized: "Previous Subfolder")
        case 37: String(localized: "Loupe Zoom In")
        case 38: String(localized: "Loupe Zoom Out")
        case 39: String(localized: "Go to Percent")
        case 40: String(localized: "Rotate Right")
        case 41: String(localized: "Rotate Left")
        case 42: String(localized: "Cycle View Mode")
        case 43: String(localized: "Move to Trash (right)")
        case 44: String(localized: "Move to Trash (left)")
        case 45: String(localized: "Cycle Sort Mode")
        case 46: String(localized: "Close")
        case 47: String(localized: "Shuffle")
        case 48: String(localized: "Open the Last Book")
        case 49: String(localized: "Toggle Full Screen")
        case 50: String(localized: "Minimize")
        case 51: String(localized: "Enlarge View Mode")
        case 52: String(localized: "Reduce View Mode")
        case 53: String(localized: "Toggle Interpolation")
        default: "#\(number)"
        }
    }

    static let allMouseActionNumbers = Array(0...64)

    /// マウスアクション番号(仕様書 §5.6)の表示名。ジェスチャ HUD と
    /// マウス割当編集 UI で使う。「(by side)」= 画面のどちら半分で操作したかで
    /// 動作が変わる positional 系(仕様書 §5.6 の ** 付き)。
    /// 28/29 は保存値を変えず実挙動名で表示する(仕様書 §13.3 の読替と同じ向き)
    static func mouseActionName(_ number: Int) -> String {
        switch number {
        case 0: String(localized: "Next/Previous Page (by side)")
        case 1: String(localized: "Half Page Forward/Backward (by side)")
        case 2: String(localized: "Last/First Page (by side)")
        case 3: String(localized: "Next/Previous Bookmark (by side)")
        case 4: String(localized: "Next/Previous Book (by side)")
        case 5: String(localized: "Skip Forward/Backward (by side)")
        case 6: String(localized: "Next Page")
        case 7: String(localized: "Previous Page")
        case 8: String(localized: "Half Page Forward")
        case 9: String(localized: "Half Page Backward")
        case 10: String(localized: "Last Page")
        case 11: String(localized: "First Page")
        case 12: String(localized: "Next Bookmark")
        case 13: String(localized: "Previous Bookmark")
        case 14: String(localized: "Next Book")
        case 15: String(localized: "Previous Book")
        case 16: String(localized: "Add/Remove Bookmark")
        case 17: String(localized: "Toggle Single/Spread")
        case 18: String(localized: "Show page number")
        case 19: String(localized: "Skip Forward")
        case 20: String(localized: "Skip Backward")
        case 21: String(localized: "View Original (right)")
        case 22: String(localized: "View Original (left)")
        case 23: String(localized: "Slideshow")
        case 24: String(localized: "Show Thumbnails")
        case 25: String(localized: "Cycle Reading Direction")
        case 26: String(localized: "Show page bar")
        case 27: String(localized: "View Original (by side)")
        case 28: String(localized: "Show in Finder (right)")
        case 29: String(localized: "Show in Finder (left)")
        case 30: String(localized: "Show in Finder (by side)")
        case 31: String(localized: "Screen Up")
        case 32: String(localized: "Screen Down")
        case 33: String(localized: "Screen Up / Previous Page")
        case 34: String(localized: "Screen Down / Next Page")
        case 35: String(localized: "Scroll to Top")
        case 36: String(localized: "Scroll to End")
        case 37: String(localized: "Scroll Up")
        case 38: String(localized: "Scroll Down")
        case 39: String(localized: "Scroll Left")
        case 40: String(localized: "Scroll Right")
        case 41: String(localized: "Drag Scroll")
        case 42: String(localized: "Screen Up/Down + Turn Page (by side)")
        case 43: String(localized: "Toggle Loupe")
        case 44: String(localized: "Next Subfolder")
        case 45: String(localized: "Previous Subfolder")
        case 46: String(localized: "Next/Previous Subfolder (by side)")
        case 47: String(localized: "Loupe Zoom In")
        case 48: String(localized: "Loupe Zoom Out")
        case 49: String(localized: "Rotate Right")
        case 50: String(localized: "Rotate Left")
        case 51: String(localized: "Cycle View Mode")
        case 52: String(localized: "Move to Trash (right)")
        case 53: String(localized: "Move to Trash (left)")
        case 54: String(localized: "Move to Trash (by side)")
        case 55: String(localized: "Rotate (by side)")
        case 56: String(localized: "Cycle Sort Mode")
        case 57: String(localized: "Close")
        case 58: String(localized: "Shuffle")
        case 59: String(localized: "Contextual Menu")
        case 60: String(localized: "Open the Last Book")
        case 61: String(localized: "Toggle Full Screen")
        case 62: String(localized: "Minimize")
        case 63: String(localized: "Enlarge View Mode")
        case 64: String(localized: "Reduce View Mode")
        default: "#\(number)"
        }
    }

    /// マウス側で switchAction(左綴じ時の対称入替)を付けられるアクション番号
    /// (旧 PreferenceController.m:2182-2196 の可否リスト。仕様書 §5.4)
    static let mouseSwitchActionEligible: Set<Int> =
        Set(6...15).union([19, 20, 33, 34, 44, 45])

    /// マウストリガ(button+modifier)の可読表記("shift+Left Drag Right" 等)
    static func mouseTriggerName(button: Int, modifiers: Int) -> String {
        var parts: [String] = []
        let flags = modifiers % 100  // 下 2 桁が装飾キー(仕様書 §5.2)
        if flags & LegacyModifier.shift != 0 { parts.append("shift") }
        if flags & LegacyModifier.option != 0 { parts.append("option") }
        if flags & LegacyModifier.control != 0 { parts.append("control") }
        parts.append(mouseTriggerBaseName(button: button,
                                          kindModifier: modifiers - flags))
        return parts.joined(separator: "+")
    }

    private static func mouseButtonName(_ button: Int) -> String {
        switch button {
        case 0: String(localized: "Left")
        case 1: String(localized: "Right")
        case 2: String(localized: "Middle")
        default: String(localized: "Button \(button + 1)")
        }
    }

    /// トリガの基本名(装飾キー抜き)。仮想ボタン(1000-8000)は種別名、
    /// 実ボタンは modifier の百の位でクリック/ドラッグ 5 種を区別する
    static func mouseTriggerBaseName(button: Int, kindModifier: Int) -> String {
        switch button {
        case VirtualButton.swipeRight: return String(localized: "Swipe Right")
        case VirtualButton.swipeLeft: return String(localized: "Swipe Left")
        case VirtualButton.swipeUp: return String(localized: "Swipe Up")
        case VirtualButton.swipeDown: return String(localized: "Swipe Down")
        case VirtualButton.pinchIn: return String(localized: "Pinch In")
        case VirtualButton.pinchOut: return String(localized: "Pinch Out")
        case VirtualButton.rotateRight: return String(localized: "Rotate Gesture Right")
        case VirtualButton.rotateLeft: return String(localized: "Rotate Gesture Left")
        default: break
        }
        let name = mouseButtonName(button)
        switch kindModifier {
        case LegacyModifier.drag: return String(localized: "\(name) Drag")
        case LegacyModifier.dragLeft: return String(localized: "\(name) Drag Left")
        case LegacyModifier.dragRight: return String(localized: "\(name) Drag Right")
        case LegacyModifier.dragUp: return String(localized: "\(name) Drag Up")
        case LegacyModifier.dragDown: return String(localized: "\(name) Drag Down")
        default: return String(localized: "\(name) Click")
        }
    }

    /// 数値を使うマウスアクション → (単位, 既定値の表示)。それ以外は
    /// 数値欄を出さない(「数値」列が全行に並ぶ分かりにくさの解消)
    static func mouseValueUnit(_ number: Int) -> (unit: String, defaultValue: String)? {
        switch number {
        case 5, 19, 20: (String(localized: "pages"), "10")
        case 37, 38, 39, 40: ("px", "20")
        default: nil
        }
    }

    /// 「できること別」設定画面のカテゴリ(キーアクション番号 0-53)
    static let keyActionCategories: [(title: String, numbers: [Int])] = [
        (String(localized: "Turn Pages"), [0, 1, 2, 3, 13, 14, 4, 5]),
        (String(localized: "Bookmarks"), [10, 6, 7]),
        (String(localized: "Books & Folders"), [8, 9, 35, 36, 48]),
        (String(localized: "Scrolling"), [24, 25, 26, 27, 28, 29, 30, 31, 32, 33]),
        (String(localized: "View"), [42, 51, 52, 11, 19, 40, 41, 15, 16, 53]),
        (String(localized: "Tools"), [34, 37, 38, 18, 20, 12, 17, 21, 39]),
        (String(localized: "File & Window"), [22, 23, 43, 44, 45, 46, 47, 49, 50]),
    ]

    /// キー側で switchAction(左綴じ時の対称入替)を付けられるアクション
    /// (入替ペア switchedLegacyKeyNumber の両側。仕様書 §5.4)
    static let keySwitchActionEligible: Set<Int> =
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 26, 27, 35, 36]

    /// 数値を使うキーアクション → (単位, 既定値)。39(%ジャンプ)は
    /// キーごとに値が異なるため機能単位の一括編集はせずチップ側で扱う
    static func keyValueUnit(_ number: Int) -> (unit: String, defaultValue: String)? {
        switch number {
        case 13, 14: (String(localized: "pages"), "10")
        case 30, 31, 32, 33: ("px", "20")
        case 39: ("%", "0")
        default: nil
        }
    }

    /// 「できること別」設定画面のカテゴリ(タイトル, マウスアクション番号列)。
    /// ドラッグスクロール(41)は基本セットでは効かない(仕様書 §5.7.5)ため
    /// ここには載せず、表示モード上書きの編集でのみ扱う
    static let mouseActionCategories: [(title: String, numbers: [Int])] = [
        (String(localized: "Turn Pages"), [6, 7, 0, 8, 9, 1, 19, 20, 5, 10, 11, 2]),
        (String(localized: "Bookmarks"), [16, 12, 13, 3]),
        (String(localized: "Books & Folders"), [14, 15, 4, 44, 45, 46, 60]),
        (String(localized: "Scrolling"), [31, 32, 33, 34, 42, 35, 36, 37, 38, 39, 40]),
        (String(localized: "View"), [51, 63, 64, 17, 25, 49, 50, 55, 21, 22, 27]),
        (String(localized: "Tools"), [43, 47, 48, 24, 26, 18, 23, 59]),
        (String(localized: "File & Window"), [28, 29, 30, 52, 53, 54, 56, 57, 58, 61, 62]),
    ]

    /// ボタン単体の表示名(追加シートのボタン選択用。サイドボタンは役割を併記)
    static func mouseButtonDisplayName(_ button: Int) -> String {
        switch button {
        case 3: String(localized: "Button 4 (back side)")
        case 4: String(localized: "Button 5 (forward side)")
        default: mouseButtonName(button)
        }
    }

    /// カタログの人間向けトリガ名。機械的な「ボタン N」表記より先に
    /// サイドボタン等の役割名を使う(設定 UI 用)
    static func catalogTriggerName(button: Int) -> String {
        switch button {
        case 0: String(localized: "Left Click")
        case 1: String(localized: "Right Click")
        case 2: String(localized: "Middle Click")
        case 3: String(localized: "Side Button (Back)")
        case 4: String(localized: "Side Button (Forward)")
        default: mouseTriggerBaseName(button: button, kindModifier: 0)
        }
    }

    /// キー 1 文字の可読表記(矢印・機能キー等)
    static func keyName(for character: Character) -> String {
        guard let scalar = character.unicodeScalars.first else { return String(character) }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSPageUpFunctionKey: return "page up"
        case NSPageDownFunctionKey: return "page down"
        case NSHomeFunctionKey: return "home"
        case NSEndFunctionKey: return "end"
        case NSDeleteFunctionKey: return "del"
        case 0x09: return "tab"
        case 0x0D: return "return"
        case 0x03: return "enter"
        case 0x20: return "space"
        case 0x1B: return "esc"
        case 0x7F: return "delete"
        default:
            if NSF1FunctionKey <= Int(scalar.value), Int(scalar.value) <= NSF35FunctionKey {
                return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
            }
            return String(character)
        }
    }

    /// 修飾込みの表記("shift+option+←" 等。仕様書 §5.2 の符号化に対応)
    static func displayName(for binding: KeyBinding) -> String {
        var parts: [String] = []
        if binding.modifiers & LegacyModifier.shift != 0 { parts.append("shift") }
        if binding.modifiers & LegacyModifier.option != 0 { parts.append("option") }
        if binding.modifiers & LegacyModifier.control != 0 { parts.append("control") }
        if binding.modifiers & LegacyModifier.numericPad != 0 { parts.append("num") }
        parts.append(keyName(for: binding.key))
        return parts.joined(separator: "+")
    }
}
