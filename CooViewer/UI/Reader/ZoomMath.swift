import CoreGraphics
import Foundation

/// 連続ピンチズームの状態遷移(純関数。設計書 §7.6 でユニットテスト対象)。
/// zoomScale は「現在の表示モードが算出する表示スケールを 1.0 とした純乗数」で、
/// 下限 1.0(縮小は表示モード側の役目)、上限 maxZoom。
enum ZoomMath {
    static let maxZoom: CGFloat = 8
    /// この倍率以下は 1.0 へ吸着する(離した時の下限スナップ)
    static let snapTolerance: CGFloat = 1.08

    /// ピンチ 1 イベントぶんの倍率更新。1.0 未満は硬クランプ、maxZoom 超は
    /// 対数圧縮のラバーバンド(指を離すと戻る)
    static func updatedScale(current: CGFloat, magnification: CGFloat) -> CGFloat {
        let proposed = current * (1 + magnification)
        if proposed < 1 { return 1 }
        if proposed > maxZoom {
            // 超過分を log 圧縮して抵抗感を出す(戻しは settleTarget が担う)
            return maxZoom + log2(proposed / maxZoom) * 0.5
        }
        return proposed
    }

    /// 指を離した時の収束先。下限付近は 1.0、上限超のラバーバンドは maxZoom へ
    static func settleTarget(scale: CGFloat) -> CGFloat {
        if scale <= snapTolerance { return 1 }
        return min(scale, maxZoom)
    }

    /// 慣性/吸着アニメの 1 ティック。現在値を target へ指数減衰で近づける。
    /// |残差| が eps 未満になったら target に到達したとみなす(呼び出し側で停止)
    static func settleStep(current: CGFloat, target: CGFloat,
                           factor: CGFloat = 0.22, eps: CGFloat = 0.002) -> CGFloat {
        let next = current + (target - current) * factor
        return abs(next - target) < eps ? target : next
    }

    /// ズーム適用後のコンテンツ寸法(各ページのスケールに zoom を乗じた合計)
    static func scaledContentSize(baseScaled: [CGSize], zoom: CGFloat) -> CGSize {
        let widths = baseScaled.map { $0.width * zoom }
        let heights = baseScaled.map { $0.height * zoom }
        return CGSize(width: widths.reduce(0, +), height: heights.max() ?? 0)
    }

    /// カーソル下のコンテンツ点(anchorRatio)を、ビュー上の同じ点(cursor)に
    /// 保つスクロールオフセット。pad はコンテンツが領域より小さい軸の中央寄せ。
    /// クランプは呼び出し側(clampScrollOffset)に任せる
    static func anchoredScrollOffset(anchorRatio: CGPoint, cursor: CGPoint,
                                     contentSize: CGSize, available: CGSize) -> CGPoint {
        let pad = CGPoint(x: max(0, (available.width - contentSize.width) / 2),
                          y: max(0, (available.height - contentSize.height) / 2))
        return CGPoint(x: pad.x + anchorRatio.x * contentSize.width - cursor.x,
                       y: pad.y + anchorRatio.y * contentSize.height - cursor.y)
    }

    /// 確定ズームでの表示ピクセルキャップのバケット(1x/2x/4x)。毎フレームの
    /// 再デコードを避けるため段階的にだけ引き上げる(Book のキャッシュ全破棄対策)
    static func capBucket(zoom: CGFloat) -> CGFloat {
        if zoom <= 1.05 { return 1 }
        if zoom <= 2 { return 2 }
        return 4
    }
}
