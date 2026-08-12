import CoreGraphics
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
    case curl = 4       // 画面中央(ノド)を軸に半面がカールしてめくれる

    /// 新しいページが画面の左側から現れるか。スライドの進入方向と、
    /// カールでめくれる半面(=空く側)の決定に使う。
    /// 右→左読みでは「進む」と左、左→右読みでは右(逆方向は反転)
    static func entersFromLeft(forward: Bool, readsFromLeft: Bool) -> Bool {
        forward != readsFromLeft
    }
}

/// ページカールの幾何計算(純関数。PageCurlGeometryTests)。
///
/// 物理モデル: 画面を中央(本のノド)で左右に分割し、めくれる半面を
/// 「リーフ」として縦のストリップ列に分ける。リーフはノドを軸に 0→π まで
/// 回転し、各ストリップにはノドからの距離に応じた曲げ角を加えて、
/// 紙がしなるカールを表現する。ストリップは前のストリップの端に連結される
/// (piecewise 円筒近似)。α が π/2 を超えたストリップは裏面が見えるので、
/// 表示内容を新しいページの鏡像へ切り替える(実際の紙の裏=次のページ)。
enum PageCurlGeometry {
    /// ストリップ 1 本の配置(ノド基準の座標。x は画面右が正、z は手前が正)
    struct Strip: Equatable {
        /// ストリップ始端(ノド側)の位置
        var offsetX: CGFloat
        var offsetZ: CGFloat
        /// ストリップの傾き α(0=開いた状態、π=めくり終わり)
        var angle: CGFloat
    }

    /// 巻き込みの強さ。外側(自由端)ほど角が大きくなる倍率で、
    /// めくり始めに自由端が先に裏返る「紙が剥がれてめくれる」動きになる
    /// (Apple Books 風)。0 なら板のような一様回転
    static let defaultCurl: CGFloat = 1.6

    /// 進行度 progress(0-1)→ リーフの基本角 θ(0-π)。ease-in-out
    static func easedTheta(progress: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, progress))
        // smoothstep(3t² - 2t³)
        let eased = clamped * clamped * (3 - 2 * clamped)
        return eased * .pi
    }

    /// θ 時点の全ストリップ配置。
    /// - towardRight: リーフがノドから右へ伸びているか(左リーフは false)。
    ///   回転はリーフが反対側の半面へ倒れる向きに進む。
    /// - 各ストリップの角: α_j = min(π, θ × (1 + curl × 外側度) × (1 + lift))。
    ///   自由端に近いほど先行して立ち上がり π で止まる(=先に裏返って
    ///   丸まっていき、ノド側が追いつく)。θ=0 で全て 0、θ=π で全て π
    ///   なので始端・終端は正確に平らになる。
    /// - lift: 帯(横割り)ごとの先行度。下の帯ほど大きくして「下の角から
    ///   めくれる」ねじれを作る。**連結は常にノド(原点)から始まる**ため、
    ///   どの帯もノドに縫い留められたまま(綴じが離れない)
    static func strips(theta: CGFloat, curl: CGFloat = defaultCurl,
                       lift: CGFloat = 0,
                       count: Int, stripLength: CGFloat,
                       towardRight: Bool) -> [Strip] {
        guard count > 0 else { return [] }
        let sign: CGFloat = towardRight ? 1 : -1
        var result: [Strip] = []
        var x: CGFloat = 0
        var z: CGFloat = 0
        for index in 0..<count {
            let outward = (CGFloat(index) + 0.5) / CGFloat(count)
            let angle = min(.pi, max(0, theta * (1 + curl * outward) * (1 + lift)))
            result.append(Strip(offsetX: x, offsetZ: z, angle: angle))
            x += stripLength * sign * cos(angle)
            z += stripLength * sin(angle)
        }
        return result
    }

    /// あるストリップの α 時系列(サンプル列)から、裏面(新内容)へ切り替える
    /// キータイム(0-1)を返す。π/2 を跨がなければ 1(=切替なし)
    static func backfaceKeyTime(angleSamples: [CGFloat]) -> Double {
        guard angleSamples.count > 1 else { return 1 }
        for (index, angle) in angleSamples.enumerated() where angle >= .pi / 2 {
            return Double(index) / Double(angleSamples.count - 1)
        }
        return 1
    }
}
