import Foundation

/// 設定「マウスとジェスチャ」のカタログ写像(純関数。設計書 §7.6)。
/// カタログ = 修飾キーなしの代表トリガ(実ボタンのクリックとマルチタッチ)を
/// 常設行として見せ、UI と MouseArray 配列(仕様書 §5.1)を相互写像する。
/// 配列スキーマと解決順(仕様書 §5.3)には一切触れない。
enum MouseBindingCatalog {
    /// マウスセクションの表示順(左/中/右/サイド戻る/サイド進む)
    static let mouseButtons = [0, 2, 1, 3, 4]

    /// トラックパッドセクションの表示順
    static let gestureButtons = [
        VirtualButton.swipeLeft, VirtualButton.swipeRight,
        VirtualButton.swipeUp, VirtualButton.swipeDown,
        VirtualButton.pinchOut, VirtualButton.pinchIn,
        VirtualButton.rotateRight, VirtualButton.rotateLeft,
    ]

    static let allButtons = Set(mouseButtons + gestureButtons)

    /// カタログ行(修飾キーなし)に対応する配列内の行。先頭一致
    /// (resolveMouse と同じ)なので重複行があっても実挙動と表示が揃う
    static func index(of button: Int, in bindings: [MouseBinding]) -> Int? {
        bindings.firstIndex { $0.button == button && $0.modifiers == 0 }
    }

    /// カタログ行への割当変更。action=nil は「なし」=行削除。
    /// アクション変更で switchAction が対象外になったら外す(仕様書 §5.4)
    static func assign(_ bindings: inout [MouseBinding], button: Int, action: Int?) {
        guard let action else {
            bindings.removeAll { $0.button == button && $0.modifiers == 0 }
            return
        }
        if let index = index(of: button, in: bindings) {
            bindings[index].legacyActionNumber = action
            if !ActionNames.mouseSwitchActionEligible.contains(action) {
                bindings[index].switchAction = false
            }
        } else {
            bindings.append(MouseBinding(legacyActionNumber: action, button: button,
                                         modifiers: 0, value: nil, switchAction: false))
        }
    }

    /// カタログに現れない行(修飾キー付き・方向ドラッグ・その他ボタン等)の
    /// 添字。カタログが写すのは「修飾なしの先頭一致」だけなので、同一トリガの
    /// 重複 2 行目以降もここに列挙され、既存データは UI から欠落しない
    static func otherRowIndices(in bindings: [MouseBinding]) -> [Int] {
        var seenCatalog = Set<Int>()
        return bindings.indices.filter { index in
            let binding = bindings[index]
            guard binding.modifiers == 0, allButtons.contains(binding.button),
                  !seenCatalog.contains(binding.button) else { return true }
            seenCatalog.insert(binding.button)
            return false
        }
    }

    /// 上書きセットに行が無い=基本セットから継承されるカタログボタン
    /// (解決順のフォールバック §5.3 をそのまま表示に写す)
    static func inheritedButtons(override bindings: [MouseBinding]) -> [Int] {
        (mouseButtons + gestureButtons).filter { index(of: $0, in: bindings) == nil }
    }

    // MARK: - 「できること別」ビューの写像

    /// 指定アクションに割り当てられている行の添字(配列順)
    static func assignmentIndices(for action: Int, in bindings: [MouseBinding]) -> [Int] {
        bindings.indices.filter { bindings[$0].legacyActionNumber == action }
    }

    /// 数値をアクション単位で全割当行へ適用する(スキーマは行ごとだが、
    /// 同じ機能の入力ごとに別の量を持たせる意味はないため UI は機能単位)
    static func setValue(_ value: Double?, forAction action: Int,
                         in bindings: inout [MouseBinding]) {
        for index in bindings.indices
        where bindings[index].legacyActionNumber == action {
            bindings[index].value = value
        }
    }
}
