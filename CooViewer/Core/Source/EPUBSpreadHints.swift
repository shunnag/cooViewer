import Washi

/// EPUB の page-spread 宣言から、見開きへ組み込まないページを導く。
/// 宣言のないページは従来の縦横比判定へ委ねる
/// (cooViewer-oxr.40、仕様書 §4.2.1)。
enum EPUBSpreadHints {
    static func singleIndices(
        slots: [PageSpreadSlot?],
        readingDirection: PageProgressionDirection
    ) -> Set<Int> {
        let first: PageSpreadSlot = readingDirection == .rtl ? .right : .left
        let second: PageSpreadSlot = first == .right ? .left : .right
        var singles: Set<Int> = []
        var index = 0

        while index < slots.count {
            guard let slot = slots[index] else {
                index += 1
                continue
            }
            if slot == .center {
                singles.insert(index)
                index += 1
                continue
            }
            if slot == first {
                // 末尾の「見開き先頭」宣言は相手不足を断定せず、従来の
                // 縦横比判定へ委ねる。
                guard index + 1 < slots.count else { break }
                if slots[index + 1] == second {
                    index += 2
                } else {
                    singles.insert(index)
                    index += 1
                }
                continue
            }

            // 対になる先頭ページを伴わない「見開き後半」は単ページにする。
            singles.insert(index)
            index += 1
        }
        return singles
    }
}
