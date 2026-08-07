import Foundation

/// 旧設定 Thumbnail{row, column} の読み書き(仕様書 §6.1)。1...8 に丸める
enum ThumbnailGridSetting {
    static func read(from defaults: UserDefaults = .standard)
        -> (rows: Int, columns: Int) {
        let dict = defaults.dictionary(forKey: "Thumbnail")
        return (clamp(dict?["row"] as? Int ?? 3),
                clamp(dict?["column"] as? Int ?? 4))
    }

    static func write(rows: Int, columns: Int,
                      to defaults: UserDefaults = .standard) {
        defaults.set(["row": rows, "column": columns], forKey: "Thumbnail")
    }

    private static func clamp(_ value: Int) -> Int { min(8, max(1, value)) }
}

/// サムネイルグリッドの構成計算(仕様書 §4.8)。
/// 「どのエントリをどのセルに束ね、何画面に分けるか」だけを扱う純粋な値型。
/// 表示状態(現在画面・強調)はモデル側、描画はビュー側の責務。
struct ThumbnailGridLayout: Equatable {
    let rows: Int
    /// 実効列数(見開きモードでは設定値の半分。セルが 2 ページ幅になるため)
    let columns: Int
    /// セル単位のページ組。単ページは [n]、見開きモードは読み順の [n, n+1]
    /// (仕様書 §4.8 mangaMode)。しおり絞り込みは組む前に適用する。
    let cellGroups: [[Int]]

    init(entryCount: Int, bookmarkedPages: Set<Int>,
         onlyBookmarks: Bool, comicMode: Bool, rows: Int, columns: Int) {
        self.rows = max(1, rows)
        self.columns = comicMode ? max(1, columns / 2) : max(1, columns)
        let visible = onlyBookmarks
            ? (0..<entryCount).filter(bookmarkedPages.contains)
            : Array(0..<entryCount)
        cellGroups = comicMode
            ? stride(from: 0, to: visible.count, by: 2).map {
                Array(visible[$0..<min($0 + 2, visible.count)])
            }
            : visible.map { [$0] }
    }

    var cellsPerScreen: Int { rows * columns }

    /// 総画面数(空の本でも 1 画面。ゼロ除算とページ送りの下限を単純化する)
    var screenCount: Int {
        max(1, (cellGroups.count + cellsPerScreen - 1) / cellsPerScreen)
    }

    /// screen 画面目に載るセル組(範囲外は空)
    func groups(onScreen screen: Int) -> [[Int]] {
        let start = screen * cellsPerScreen
        guard start >= 0, start < cellGroups.count else { return [] }
        return Array(cellGroups[start..<min(start + cellsPerScreen, cellGroups.count)])
    }

    /// entryIndex のページを含む画面番号(絞り込みで非表示なら nil)
    func screen(containing entryIndex: Int) -> Int? {
        guard let position = cellGroups.firstIndex(where: {
            $0.contains(entryIndex)
        }) else { return nil }
        return position / cellsPerScreen
    }

    func clamped(screen: Int) -> Int {
        min(max(0, screen), screenCount - 1)
    }
}
