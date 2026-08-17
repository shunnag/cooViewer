import Foundation

extension Double {
    /// トラップしない `Int` 変換。非有限(NaN/±Inf)や `Int` の表現範囲外は `nil` を返す。
    ///
    /// バインディングの `value`(UserDefaults 由来で、壊れた/手編集された/極端な値を
    /// 含みうる `Double?`)や割合計算の積を `Int(Double)` で変換すると、非有限・範囲外の
    /// 値で「Double value cannot be converted to Int because it is either infinite or NaN」
    /// トラップでプロセスごとクラッシュする。呼び出し側はこのアクセサ + フォールバックで
    /// 変換し、極端な設定値でも落ちないようにする。
    var safeInt: Int? {
        // Int は 64bit(±約 9.22e18)。境界近傍の丸め誤差を避けて内側で判定する。
        guard isFinite, self >= -9.0e18, self <= 9.0e18 else { return nil }
        return Int(self)
    }
}
