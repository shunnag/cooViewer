import Foundation

/// EPUB モードの 2 本指スクロールを「水平スワイプめくり相当」の 1 ジェスチャ=1 発火へ
/// 量子化する純値型ステートマシン(設計書 §7.6 の MouseGestureRecognizer と同系)。
/// 軸判定・閾値・ラッチのみを担い、割当解決や副作用は持たない(単体テスト可能)。
/// Washi の EPUBReaderView.scrollWheel(marginWheel)と同一のパラメータ。
struct EPUBScrollGestureRecognizer: Sendable, Equatable {
    enum Decision: Sendable, Equatable {
        case passThrough
        case consume
        case turn(positive: Bool)
    }

    private var lastTime: TimeInterval = 0
    private var horizontal = false
    private var intercept = false
    private var latched = false
    private var accumulator: CGFloat = 0

    /// interceptHorizontalIfNew は新規ジェスチャ開始時点の「横取りするか」。
    /// 新規ジェスチャのときだけ取り込む。
    mutating func feed(deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                       timestamp: TimeInterval,
                       interceptHorizontalIfNew: Bool) -> Decision {
        if timestamp - lastTime > 0.25 {
            horizontal = abs(deltaX) > abs(deltaY)
            intercept = interceptHorizontalIfNew
            latched = false
            accumulator = 0
        }
        lastTime = timestamp
        guard horizontal, intercept else { return .passThrough }
        if latched { return .consume }
        let scale: CGFloat = precise ? 1 : 40
        accumulator += scale * deltaX
        guard abs(accumulator) >= 50 else { return .consume }
        let positive = accumulator > 0
        accumulator = 0
        latched = true
        return .turn(positive: positive)
    }
}
