import CoreGraphics

/// 単ページ/見開きの強制指定(仕様書 §7.1 の marks)。
/// 保存形式は旧実装と互換の 1 始まり文字列("N"=強制単ページ、"N-M"=強制見開き)。
/// API は 0 始まりのページ index で受ける。判定はページ送り・見開き合成・
/// サムネイルのペア判定などホットパスから毎回呼ばれるため、文字列生成を
/// 避けて Int 集合を導出キャッシュとして持つ(raw が正で、変更時に再構築)。
struct PageMarks: Sendable, Equatable {
    private(set) var raw: Set<String>
    /// 導出キャッシュ(0 始まり)。raw から一意に決まるため同値比較は raw のみ
    private var singleIndices: Set<Int> = []
    private var pairMemberIndices: Set<Int> = []

    init(raw: Set<String> = []) {
        self.raw = raw
        rebuildDerived()
    }

    init(legacyArray: [String]) {
        self.raw = Set(legacyArray)
        rebuildDerived()
    }

    static func == (lhs: PageMarks, rhs: PageMarks) -> Bool {
        lhs.raw == rhs.raw
    }

    var legacyArray: [String] { Array(raw).sorted() }

    /// index を単ページ強制するか
    func forcesSingle(_ index: Int) -> Bool {
        singleIndices.contains(index)
    }

    /// index が強制ペアの一部か(仕様書 §4.2.1: "page-(page+1)" または "(page-1)-page")
    func forcesPairContaining(_ index: Int) -> Bool {
        pairMemberIndices.contains(index)
    }

    mutating func setForcedSingle(_ index: Int) {
        raw.insert(String(index + 1))
        rebuildDerived()
    }

    mutating func setForcedPair(firstIndex: Int) {
        raw.insert("\(firstIndex + 1)-\(firstIndex + 2)")
        rebuildDerived()
    }

    mutating func removeMark(containing index: Int) {
        raw.remove(String(index + 1))
        raw.remove("\(index + 1)-\(index + 2)")
        raw.remove("\(index)-\(index + 1)")
        rebuildDerived()
    }

    /// 強制単ページの index 一覧(0 始まり。サムネイル一覧のペア判定用)
    var forcedSingleIndices: [Int] { Array(singleIndices) }

    /// 強制ペアに含まれる index 一覧(0 始まり、両片)
    var forcedPairMemberIndices: [Int] { Array(pairMemberIndices) }

    /// raw(1 始まり文字列)から Int 集合を組み直す。marks は高々数十個
    private mutating func rebuildDerived() {
        singleIndices = []
        pairMemberIndices = []
        for mark in raw {
            if let single = Int(mark) {
                singleIndices.insert(single - 1)
                continue
            }
            let parts = mark.split(separator: "-")
            if parts.count == 2,
               let first = Int(parts[0]), let second = Int(parts[1]) {
                pairMemberIndices.insert(first - 1)
                pairMemberIndices.insert(second - 1)
            }
        }
    }
}

/// 見開き合成の判定ロジック(仕様書 §4.2.1)。
enum PageLayout {
    /// 既定のしきい値(SingleSetting = 740 → 縦横比 0.74)
    static let defaultSingleSetting = 740

    /// ページが「小さい」=見開き候補か。
    /// 1. marks の強制指定が最優先
    /// 2. coverSingle(表紙を単ページにする。新機能・既定オフ)なら先頭ページは単ページ
    /// 3. 幅/高さ が singleSetting/1000 以下(縦長)なら見開き候補
    static func isSmall(
        size: CGSize, index: Int, marks: PageMarks,
        singleSetting: Int = defaultSingleSetting,
        coverSingle: Bool = false
    ) -> Bool {
        if marks.forcesSingle(index) { return false }
        if marks.forcesPairContaining(index) { return true }
        if coverSingle, index == 0 { return false }
        guard size.height > 0 else { return false }
        return size.width / size.height <= CGFloat(singleSetting) / 1000.0
    }
}
