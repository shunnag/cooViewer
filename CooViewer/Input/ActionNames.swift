import AppKit

/// キーアクション番号(仕様書 §5.5)の表示名と、キーの人間可読表記。
/// バインディング編集 UI で使う。
enum ActionNames {
    static let allKeyActionNumbers = Array(0...52)

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
        default: "#\(number)"
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
