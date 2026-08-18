import Foundation

/// 設定「キー割り当て」の「できること別」写像(純関数。設計書 §7.6)。
/// UI と KeyArray 配列(仕様書 §5.1)を相互写像する。マウス側
/// (MouseBindingCatalog)と違いキー空間は列挙できないため固定カタログは
/// 持たず、機能→割当行の逆引きだけを提供する。スキーマと解決順は不変。
enum KeyBindingCatalog {
    /// キー+修飾の完全一致行(先頭一致=resolveKey と同じ)
    static func index(ofKey key: Character, modifiers: Int,
                      in bindings: [KeyBinding]) -> Int? {
        bindings.firstIndex { $0.key == key && $0.modifiers == modifiers }
    }

    /// 指定アクションに割り当てられている行の添字(配列順)
    static func assignmentIndices(for action: Int, in bindings: [KeyBinding]) -> [Int] {
        bindings.indices.filter { bindings[$0].legacyActionNumber == action }
    }

    /// 数値をアクション単位で全割当行へ適用する(%ジャンプ 39 はキーごとに
    /// 値が異なるため呼び出し側で除外する)
    static func setValue(_ value: Double?, forAction action: Int,
                         in bindings: inout [KeyBinding]) {
        for index in bindings.indices
        where bindings[index].legacyActionNumber == action {
            bindings[index].value = value
        }
    }
}
