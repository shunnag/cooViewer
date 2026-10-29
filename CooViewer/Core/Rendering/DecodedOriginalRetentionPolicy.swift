import Foundation

/// 設計書 §5: 完成画像を再利用できる後方ページだけを捨て、表示と先読みの入力を守る。
enum DecodedOriginalRetentionPolicy {
    static func canEvict(index: Int, currentIndex: Int, decodeBehind: Int,
                         adjacentIndices: Range<Int>, protected: Bool,
                         displayReady: Bool) -> Bool {
        index >= 0 && index < currentIndex
            && currentIndex - index > max(0, decodeBehind)
            && !adjacentIndices.contains(index) && !protected && displayReady
    }
}

/// 設計書 §5: 通常表示以外は元画像から再計算し、完成画像の拡大・再フィルタを避ける。
enum ResampledDisplayPolicy {
    static func allows(fitMode: ReaderFitMode, rotation: Int, zoomed: Bool,
                       loupe: Bool, interpolation: ImageInterpolation) -> Bool {
        fitMode != .noScale && rotation == 0 && !zoomed && !loupe
            && (interpolation == .systemDefault || interpolation == .high)
    }
}
