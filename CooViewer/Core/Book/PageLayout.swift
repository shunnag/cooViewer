import CoreGraphics

/// 単ページ/見開きの強制指定(仕様書 §7.1 の marks)。
/// 保存形式は旧実装と互換の 1 始まり文字列("N"=強制単ページ、"N-M"=強制見開き)。
/// API は 0 始まりのページ index で受ける。
/// EN: Forced single/pair page marks, stored as legacy 1-based strings
/// EN: ("N" = force single, "N-M" = force pair); the API is 0-based.
struct PageMarks: Sendable, Equatable {
    private(set) var raw: Set<String>

    init(raw: Set<String> = []) {
        self.raw = raw
    }

    init(legacyArray: [String]) {
        self.raw = Set(legacyArray)
    }

    var legacyArray: [String] { Array(raw).sorted() }

    /// index を単ページ強制するか
    func forcesSingle(_ index: Int) -> Bool {
        raw.contains(String(index + 1))
    }

    /// index が強制ペアの一部か(仕様書 §4.2.1: "page-(page+1)" または "(page-1)-page")
    /// EN: True when the page is either half of a forced pair mark.
    func forcesPairContaining(_ index: Int) -> Bool {
        raw.contains("\(index + 1)-\(index + 2)") || raw.contains("\(index)-\(index + 1)")
    }

    mutating func setForcedSingle(_ index: Int) {
        raw.insert(String(index + 1))
    }

    mutating func setForcedPair(firstIndex: Int) {
        raw.insert("\(firstIndex + 1)-\(firstIndex + 2)")
    }

    mutating func removeMark(containing index: Int) {
        raw.remove(String(index + 1))
        raw.remove("\(index + 1)-\(index + 2)")
        raw.remove("\(index)-\(index + 1)")
    }
}

/// 見開き合成の判定ロジック(仕様書 §4.2.1)。
/// EN: Decides whether a page is a spread candidate ("small").
enum PageLayout {
    /// 既定のしきい値(SingleSetting = 740 → 縦横比 0.74)
    static let defaultSingleSetting = 740

    /// ページが「小さい」=見開き候補か。
    /// 1. marks の強制指定が最優先
    /// 2. 幅/高さ が singleSetting/1000 以下(縦長)なら見開き候補
    /// EN: Marks win first; otherwise portrait pages (aspect <= threshold)
    /// EN: are pair candidates.
    static func isSmall(
        size: CGSize, index: Int, marks: PageMarks,
        singleSetting: Int = defaultSingleSetting
    ) -> Bool {
        if marks.forcesSingle(index) { return false }
        if marks.forcesPairContaining(index) { return true }
        guard size.height > 0 else { return false }
        return size.width / size.height <= CGFloat(singleSetting) / 1000.0
    }
}
