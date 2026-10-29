/// 原寸の強ノイズ低減結果は、現在と隣接の見開きをリサイズできる範囲だけ残す(設計書 §5)。
enum StrongIntermediateRetentionPolicy {
    /// ペア判定が未確定なら 2 ページを保護し、隣接見開きの片側を誤って捨てない。
    static func retainedIndices(currentIndex: Int, displayCount: Int, pageCount: Int,
                                previousIsPair: Bool?, nextIsPair: Bool?) -> Range<Int> {
        guard currentIndex >= 0, currentIndex < pageCount, displayCount > 0 else { return 0..<0 }
        let end = currentIndex + min(displayCount, pageCount - currentIndex)
        let behind = previousIsPair == false ? 1 : 2
        let ahead = nextIsPair == false ? 1 : 2
        return max(0, currentIndex - behind)..<(end + min(ahead, pageCount - end))
    }
}
