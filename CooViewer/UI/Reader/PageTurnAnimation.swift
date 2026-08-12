import Foundation

/// ページめくり効果(新機能・既定オフ)。設定「表示」ペインと表示メニューの
/// 両方から選ぶ(設計書 §7.5 メニュー⇔設定の不変条件)。
/// 効果はページ送り(次/前/半ページ・スライドショー)にのみ適用し、
/// ジャンプ(しおり・%・サムネイル)や設定変更の再表示には適用しない。
/// システムの「視差効果を減らす」が有効なときは常に無効。
enum PageTurnAnimation: Int, CaseIterable {
    case none = 0
    case fade = 1       // クロスフェード
    case slide = 2      // 読み方向連動のプッシュ
    case zoomFade = 3   // わずかな拡大+フェードイン
    case flip = 4       // 進入側エッジを軸にした 3D 回転

    /// 新しいページが画面の左端から入ってくるか(スライド/フリップの向き)。
    /// 右→左読みでは「進む」と左から、左→右読みでは右から入る(逆方向は反転)
    static func entersFromLeft(forward: Bool, readsFromLeft: Bool) -> Bool {
        forward != readsFromLeft
    }
}
