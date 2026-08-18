import AppKit

/// 修飾キーの符号化(仕様書 §5.2)。旧実装の整数加算方式と互換。
enum LegacyModifier {
    static let shift = 1
    static let option = 2
    static let control = 4
    static let numericPad = 8    // キーのみ。矢印キーには付けない
    static let drag = 100        // マウス: 方向不問ドラッグ起点
    static let dragLeft = 200    // +200/300/400/500 = 方向別ドラッグ
    static let dragRight = 300
    static let dragUp = 400
    static let dragDown = 500

    /// NSEvent の修飾フラグから旧符号を作る(キー用)
    static func encode(keyEvent event: NSEvent) -> Int {
        var modifier = 0
        let flags = event.modifierFlags
        if flags.contains(.shift) { modifier += shift }
        if flags.contains(.option) { modifier += option }
        if flags.contains(.control) { modifier += control }
        if flags.contains(.numericPad) {
            // 矢印キーには意図的に付けない(仕様書 §5.2)
            let char = event.charactersIgnoringModifiers?.unicodeScalars.first
            let arrows: Set<UInt32> = [0xF700, 0xF701, 0xF702, 0xF703]
            if let char, !arrows.contains(char.value) { modifier += numericPad }
        }
        return modifier
    }

    static func encode(flags: NSEvent.ModifierFlags) -> Int {
        var modifier = 0
        if flags.contains(.shift) { modifier += shift }
        if flags.contains(.option) { modifier += option }
        if flags.contains(.control) { modifier += control }
        return modifier
    }
}

/// マルチタッチジェスチャの仮想ボタン番号(仕様書 §5.1)
enum VirtualButton {
    static let swipeRight = 1000
    static let swipeLeft = 2000
    static let swipeUp = 3000
    static let swipeDown = 4000
    static let pinchIn = 5000
    static let pinchOut = 6000
    static let rotateRight = 7000
    static let rotateLeft = 8000
}

struct KeyBinding: Sendable, Equatable {
    var legacyActionNumber: Int
    var key: Character          // 矢印等は Function キーのコードポイント
    var modifiers: Int
    var value: Double?
    var switchAction: Bool

    var action: ReaderAction? { ReaderAction.fromLegacyKeyNumber(legacyActionNumber) }
}

struct MouseBinding: Sendable, Equatable {
    var legacyActionNumber: Int
    var button: Int             // 0-10=ボタン番号、1000-8000=ジェスチャ仮想ボタン
    var modifiers: Int
    var value: Double?
    var switchAction: Bool

    var action: ReaderAction? { ReaderAction.fromLegacyMouseNumber(legacyActionNumber) }
}

/// 6 本のバインディング配列(仕様書 §5.1)と解決ロジック(§5.3, §5.4)。
struct BindingConfiguration: Sendable {
    var keyNormal: [KeyBinding]
    var keyMode2: [KeyBinding]     // 幅フィット(fitScreenMode 1)用
    var keyMode3: [KeyBinding]     // 原寸/幅分割(fitScreenMode 2/3)用
    var mouseNormal: [MouseBinding]
    var mouseMode2: [MouseBinding]
    var mouseMode3: [MouseBinding]

    // MARK: - 解決(仕様書 §5.3。マウスもキーと同型に統一 = 設計書 §2.4 の仕様変更)

    /// fitScreenMode に応じた探索順のキー配列
    private func keyArrays(for fitMode: Int) -> [[KeyBinding]] {
        switch fitMode {
        case 1: [keyMode2, keyNormal]
        case 2, 3: [keyMode3, keyNormal]
        default: [keyNormal]
        }
    }

    private func mouseArrays(for fitMode: Int) -> [[MouseBinding]] {
        switch fitMode {
        case 1: [mouseMode2, mouseNormal]
        case 2, 3: [mouseMode3, mouseNormal]
        default: [mouseNormal]
        }
    }

    /// キーバインディングを解決する。readsFromLeft のとき switchAction 付きは
    /// 対称アクションへ入替える(仕様書 §5.4)。
    func resolveKey(character: Character, modifiers: Int,
                    fitMode: Int, readsFromLeft: Bool) -> KeyBinding? {
        for array in keyArrays(for: fitMode) {
            if var binding = array.first(where: { $0.key == character && $0.modifiers == modifiers }) {
                if readsFromLeft, binding.switchAction {
                    binding.legacyActionNumber =
                        ReaderAction.switchedLegacyKeyNumber(binding.legacyActionNumber)
                }
                return binding
            }
        }
        return nil
    }

    func resolveMouse(button: Int, modifiers: Int,
                      fitMode: Int, readsFromLeft: Bool) -> MouseBinding? {
        for array in mouseArrays(for: fitMode) {
            if var binding = array.first(where: { $0.button == button && $0.modifiers == modifiers }) {
                if readsFromLeft, binding.switchAction {
                    binding.legacyActionNumber =
                        ReaderAction.switchedLegacyMouseNumber(binding.legacyActionNumber)
                }
                return binding
            }
        }
        return nil
    }

    /// DragScroll(41)の照会(仕様書 §5.7.5)。旧実装は起動時にモード固有配列の
    /// action==41 エントリだけを dragScrollDic へ配布するため、mode0 配列の 41 は
    /// どのモードでも効かない — resolveMouse の mode0 フォールバックは通さない。
    /// Fit to Screen(fitMode 0)では配布自体が無いので常に nil。
    func resolveDragScroll(button: Int, modifiers: Int, fitMode: Int) -> MouseBinding? {
        let array: [MouseBinding] = switch fitMode {
        case 1: mouseMode2
        case 2, 3: mouseMode3
        default: []
        }
        return array.first {
            $0.button == button && $0.modifiers == modifiers && $0.action == .dragScroll
        }
    }

    /// ドラッグジェスチャの解決: 方向別(+200..500)→ 方向不問(100)の順に
    /// フォールバックする(仕様書 §5.3)。フォールバック段は旧実装どおり
    /// 修飾キーを捨てた素の 100 固定(Controller_input.m:1012-1026。
    /// 100+修飾 の照合は DragScroll の押下時判定 resolveDragScroll だけが行う)
    func resolveDrag(button: Int, baseModifiers: Int, directionModifier: Int,
                     fitMode: Int, readsFromLeft: Bool) -> MouseBinding? {
        if let binding = resolveMouse(button: button, modifiers: directionModifier + baseModifiers,
                                      fitMode: fitMode, readsFromLeft: readsFromLeft) {
            return binding
        }
        return resolveMouse(button: button, modifiers: LegacyModifier.drag,
                            fitMode: fitMode, readsFromLeft: readsFromLeft)
    }

    // MARK: - 旧 defaults 形式との相互変換(仕様書 §5.1)

    /// 旧データの真偽値。キーが無ければ偽、明示保存された 0/NO も偽として扱う
    private static func legacyFlag(_ value: Any?) -> Bool {
        guard let value else { return false }
        return (value as? NSNumber)?.boolValue ?? true
    }

    static func keyBindings(fromLegacyArray array: [[String: Any]]) -> [KeyBinding] {
        array.compactMap { dict in
            guard let action = dict["action"] as? Int,
                  let keyString = dict["key"] as? String,
                  let first = keyString.first else { return nil }
            let modifiers = dict["modifier"] as? Int ?? 0
            if modifiers == LegacyModifier.drag { return nil }  // Apple Remote 残滓は読み飛ばす
            return KeyBinding(
                legacyActionNumber: action,
                key: first,
                modifiers: modifiers,
                value: (dict["value"] as? NSNumber)?.doubleValue,
                switchAction: legacyFlag(dict["switchAction"])
            )
        }
    }

    static func mouseBindings(fromLegacyArray array: [[String: Any]]) -> [MouseBinding] {
        array.compactMap { dict in
            guard let action = dict["action"] as? Int,
                  let button = dict["button"] as? Int else { return nil }
            return MouseBinding(
                legacyActionNumber: action,
                button: button,
                modifiers: dict["modifier"] as? Int ?? 0,
                value: (dict["value"] as? NSNumber)?.doubleValue,
                switchAction: legacyFlag(dict["switchAction"])
            )
        }
    }

    /// 旧 defaults 形式へ書き出す(編集 UI の保存用。仕様書 §5.1 のスキーマ)
    static func legacyArray(from bindings: [KeyBinding]) -> [[String: Any]] {
        bindings.map { binding in
            var dict: [String: Any] = [
                "action": binding.legacyActionNumber,
                "key": String(binding.key),
                "keyname": ActionNames.displayName(for: binding),
                "modifier": binding.modifiers,
            ]
            if let value = binding.value { dict["value"] = value }
            if binding.switchAction { dict["switchAction"] = true }
            return dict
        }
    }

    /// 編集結果を UserDefaults(旧キー名)へ保存する
    static func saveKeyBindings(_ bindings: [KeyBinding], arrayName: String,
                                to defaults: UserDefaults = .standard) {
        defaults.set(legacyArray(from: bindings), forKey: arrayName)
        // 2.0 の UI で KeyArray を編集したら以後 f(補間切替)の自動注入を
        // やめる(削除が定着するように。MouseArrayUserEdited と同型)
        if arrayName == "KeyArray" {
            defaults.set(true, forKey: "KeyArrayUserEdited")
        }
    }

    /// マウス配列を旧 defaults 形式へ書き出す(仕様書 §5.1 のスキーマ:
    /// button/modifier/action(+value)。キー配列と違い keyname は無い。
    /// switchAction は「オンのときだけキーが存在」(§13.2)を厳守する)
    static func legacyArray(from bindings: [MouseBinding]) -> [[String: Any]] {
        bindings.map { binding in
            var dict: [String: Any] = [
                "action": binding.legacyActionNumber,
                "button": binding.button,
                "modifier": binding.modifiers,
            ]
            if let value = binding.value { dict["value"] = value }
            if binding.switchAction { dict["switchAction"] = true }
            return dict
        }
    }

    static func saveMouseBindings(_ bindings: [MouseBinding], arrayName: String,
                                  to defaults: UserDefaults = .standard) {
        defaults.set(legacyArray(from: bindings), forKey: arrayName)
        // 2.0 の UI で MouseArray を編集したら以後サイドボタンの自動注入を
        // やめる(削除が定着するように。キーは legacy スキーマ外の新規)
        if arrayName == "MouseArray" {
            defaults.set(true, forKey: "MouseArrayUserEdited")
        }
    }

    /// UserDefaults(旧キー名のまま)から読む。無ければ既定を返す。
    static func load(from defaults: UserDefaults = .standard) -> BindingConfiguration {
        func keys(_ name: String, fallback: [KeyBinding]) -> [KeyBinding] {
            guard let array = defaults.array(forKey: name) as? [[String: Any]] else {
                return fallback
            }
            var bindings = keyBindings(fromLegacyArray: array)
            guard !bindings.isEmpty else { return fallback }
            // 保存済み配列への新既定の移行: f が未使用かつ補間切替(53)が
            // 未割当のときだけ追記する(ユーザーのカスタマイズは尊重)。
            // 2.0 の UI で編集済み(KeyArrayUserEdited)なら注入しない —
            // UI で削除した行が復活しないように
            if name == "KeyArray",
               !defaults.bool(forKey: "KeyArrayUserEdited"),
               !bindings.contains(where: { $0.key == "f" && $0.modifiers == 0 }),
               !bindings.contains(where: { $0.legacyActionNumber == 53 }) {
                bindings.append(KeyBinding(legacyActionNumber: 53, key: "f",
                                           modifiers: 0, value: nil, switchAction: false))
            }
            return bindings
        }
        func mice(_ name: String, fallback: [MouseBinding]) -> [MouseBinding] {
            guard let array = defaults.array(forKey: name) as? [[String: Any]] else {
                return fallback
            }
            var bindings = mouseBindings(fromLegacyArray: array)
            guard !bindings.isEmpty else { return fallback }
            // 保存済み配列への新既定の移行(メモリ内注入): サイドボタンを
            // 戻る/進むに。ユーザーが button 3/4 を既に使っている場合と、
            // 2.0 の設定 UI で MouseArray を編集済み(MouseArrayUserEdited)の
            // 場合は尊重して注入しない — UI で削除したら復活しない(設計書 §2.4)
            if name == "MouseArray", !defaults.bool(forKey: "MouseArrayUserEdited") {
                if !bindings.contains(where: { $0.button == 3 }) {
                    bindings.append(MouseBinding(legacyActionNumber: 7, button: 3,
                                                 modifiers: 0, value: nil,
                                                 switchAction: false))
                }
                if !bindings.contains(where: { $0.button == 4 }) {
                    bindings.append(MouseBinding(legacyActionNumber: 6, button: 4,
                                                 modifiers: 0, value: nil,
                                                 switchAction: false))
                }
            }
            return bindings
        }
        let builtIn = BindingConfiguration.builtInDefaults
        return BindingConfiguration(
            keyNormal: keys("KeyArray", fallback: builtIn.keyNormal),
            keyMode2: keys("KeyArrayMode2", fallback: builtIn.keyMode2),
            keyMode3: keys("KeyArrayMode3", fallback: builtIn.keyMode3),
            mouseNormal: mice("MouseArray", fallback: builtIn.mouseNormal),
            mouseMode2: mice("MouseArrayMode2", fallback: builtIn.mouseMode2),
            mouseMode3: mice("MouseArrayMode3", fallback: builtIn.mouseMode3)
        )
    }

    // MARK: - 既定バインディング(仕様書 §5.7。Apple Remote 分は除外)

    static let builtInDefaults: BindingConfiguration = {
        let left = Character(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = Character(UnicodeScalar(NSRightArrowFunctionKey)!)
        let up = Character(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = Character(UnicodeScalar(NSDownArrowFunctionKey)!)
        let pageUp = Character(UnicodeScalar(NSPageUpFunctionKey)!)
        let pageDown = Character(UnicodeScalar(NSPageDownFunctionKey)!)
        let home = Character(UnicodeScalar(NSHomeFunctionKey)!)
        let end = Character(UnicodeScalar(NSEndFunctionKey)!)
        let tab = Character("\t")
        let space = Character(" ")
        let returnKey = Character("\r")
        let enterKey = Character(UnicodeScalar(3))  // numpad enter

        func key(_ action: Int, _ key: Character, _ modifiers: Int = 0,
                 value: Double? = nil, sw: Bool = false) -> KeyBinding {
            KeyBinding(legacyActionNumber: action, key: key, modifiers: modifiers,
                       value: value, switchAction: sw)
        }
        func mouse(_ action: Int, _ button: Int, _ modifiers: Int = 0,
                   sw: Bool = false) -> MouseBinding {
            MouseBinding(legacyActionNumber: action, button: button, modifiers: modifiers,
                         value: nil, switchAction: sw)
        }

        // §5.7.1 KeyArray(Fit to Screen 用)
        var keyNormal: [KeyBinding] = [
            key(0, "z", sw: true), key(0, left, sw: true), key(0, space),
            key(1, "x", sw: true), key(1, right, sw: true),
            key(1, space, LegacyModifier.shift),
            key(2, "z", LegacyModifier.shift, sw: true),
            key(2, left, LegacyModifier.shift, sw: true),
            key(3, "x", LegacyModifier.shift, sw: true),
            key(3, right, LegacyModifier.shift, sw: true),
            key(4, "z", LegacyModifier.option, sw: true),
            key(4, left, LegacyModifier.option, sw: true),
            key(5, "x", LegacyModifier.option, sw: true),
            key(5, right, LegacyModifier.option, sw: true),
            key(6, "c"), key(6, down),
            key(7, "d"), key(7, up),
            key(8, "c", LegacyModifier.control), key(8, down, LegacyModifier.control),
            key(9, "d", LegacyModifier.control), key(9, up, LegacyModifier.control),
            key(10, "a"), key(11, "s"), key(12, "p"),
            key(13, tab, value: 10), key(14, tab, LegacyModifier.shift, value: 10),
            key(15, "w"), key(16, "q"), key(17, "g"), key(18, "t"), key(19, "r"),
            key(20, "o"), key(34, "l"), key(53, "f"),
            key(35, "c", LegacyModifier.shift + LegacyModifier.control),
            key(35, down, LegacyModifier.shift + LegacyModifier.control),
            key(36, "d", LegacyModifier.shift + LegacyModifier.control),
            key(36, up, LegacyModifier.shift + LegacyModifier.control),
            key(21, enterKey, LegacyModifier.numericPad), key(21, returnKey),
        ]
        for digit in 0...9 {
            keyNormal.append(key(39, Character("\(digit)"), value: Double(digit * 10)))
        }

        // §5.7.2 KeyArrayMode2(幅フィット用)
        let keyMode2: [KeyBinding] = [
            key(24, pageUp), key(25, pageDown),
            key(26, space, LegacyModifier.shift), key(27, space),
            key(28, home), key(29, end),
            key(30, up, value: 20), key(31, down, value: 20),
        ]

        // §5.7.3 KeyArrayMode3(原寸/幅分割用)= Mode2 + 左右スクロール
        let keyMode3 = keyMode2 + [
            key(32, left, value: 20), key(33, right, value: 20),
        ]

        // §5.7.4 MouseArray(+ サイドボタン戻る/進むは 2.0 の新規既定。
        // ブラウザ同様の論理ナビゲーションなので switchAction なし=綴じ方向
        // 非依存。設計書 §2.4)
        let mouseNormal: [MouseBinding] = [
            mouse(0, 0),
            mouse(1, 0, LegacyModifier.shift),
            mouse(7, 3), mouse(6, 4),
            mouse(6, VirtualButton.swipeLeft, sw: true),
            mouse(7, VirtualButton.swipeRight, sw: true),
            mouse(14, VirtualButton.swipeDown),
            mouse(15, VirtualButton.swipeUp),
            mouse(49, VirtualButton.rotateRight),
            mouse(50, VirtualButton.rotateLeft),
            // ピンチは常に連続ズームに固定(設計書 §2.4)。旧既定の
            // pinchOut=63/pinchIn=64(拡大/縮小表示)は発火しないため既定から外す。
            // 表示モードの拡大/縮小はキー(51/52)や他ボタン割当で行う
            mouse(43, 2),
            mouse(59, 1), mouse(59, 0, LegacyModifier.control),
        ]

        // §5.7.5 MouseArrayMode2/3(同一内容)
        let mouseScrollModes: [MouseBinding] = [
            mouse(41, 0, LegacyModifier.drag),
            mouse(42, 0),
        ]

        return BindingConfiguration(
            keyNormal: keyNormal, keyMode2: keyMode2, keyMode3: keyMode3,
            mouseNormal: mouseNormal,
            mouseMode2: mouseScrollModes, mouseMode3: mouseScrollModes
        )
    }()
}
