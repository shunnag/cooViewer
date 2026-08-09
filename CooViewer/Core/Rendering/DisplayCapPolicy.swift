import Foundation

/// 表示用デコード上限(長辺 px)の決定(設計書 キャッシュ節)。
/// 従来は一律 4096px でデコードしていたが、ウインドウの実ピクセルに合わせて
/// 1024 刻みで切り上げた値を使うことで、デコード時間とページキャッシュの
/// 消費を実表示に見合う量へ抑える(小さいウインドウで 2〜4 倍の削減)。
/// 原寸表示(noScale)は従来どおりユーザー上限でデコードする。
/// EN: Display decode cap derived from the window's actual pixel size
/// (rounded up to 1024 buckets) instead of a flat 4096; noScale keeps the
/// user-configured cap.
enum DisplayCapPolicy {
    /// 最低バケット。HDR デコード分岐(>= 2048)とルーペ品質の下限を守る
    /// EN: Floor bucket; keeps the HDR decode branch and loupe quality intact.
    static let minimumCap = 2048

    /// usesUserCap: ウインドウ寸法に収まらない描画をするモード
    /// (原寸 noScale / 縦スクロールの fitWidth / 2 倍幅の fitWidthDivide)は
    /// 従来どおりユーザー上限でデコードする。バケット適用は fitToScreen のみ
    /// EN: Modes that render beyond the window (noScale, fitWidth's unbounded
    /// EN: height, fitWidthDivide's double width) keep the user cap; only
    /// EN: fitToScreen uses the window bucket.
    static func cap(windowLongEdgePixels edge: Int,
                    userCap: Int, usesUserCap: Bool) -> Int {
        guard !usesUserCap else { return userCap }
        guard edge > 0 else { return min(4096, userCap) }
        let bucket = max(minimumCap, ((edge + 1023) / 1024) * 1024)
        return min(bucket, userCap)
    }
}
