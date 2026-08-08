/// 読み方向(仕様書 §4.4.1)。旧実装の整数値をそのまま使う。
/// EN: Reading direction; raw values match the legacy integers.
enum ReadMode: Int, Sendable, CaseIterable {
    case rightToLeftSpread = 0   // 右→左・見開き(既定。日本式マンガ)
    case leftToRightSpread = 1   // 左→右・見開き
    case rightToLeftSingle = 2   // 右→左・単ページ
    case leftToRightSingle = 3   // 左→右・単ページ

    var isSpread: Bool { rawValue < 2 }

    /// 左綴じ(先のページが左)か。旧実装の readFromLeft。
    /// EN: True for left-to-right (Western) reading order.
    var readsFromLeft: Bool { self == .leftToRightSpread || self == .leftToRightSingle }

    /// r キー巡回(0→1→2→3→0。仕様書 §4.4.1)
    var cycled: ReadMode { ReadMode(rawValue: (rawValue + 1) % 4)! }
}
