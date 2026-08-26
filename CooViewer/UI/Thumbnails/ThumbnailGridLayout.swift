import Foundation

/// サムネイルのセルサイズ設定(Photos 風の自動グリッド+ピンチ拡縮)。
/// 行×列の固定指定(旧設定 Thumbnail{row, column}、仕様書 §6.1)は廃止し、
/// ウインドウサイズとセルサイズから行列を自動算出する(設計書 §2.4)。
/// 旧キーは 1.x 用に凍結(以後読み書きしない)。新キーは追加のみなので
/// §13.5 の移行マッピングは不要。
enum ThumbnailZoomSetting {
    static let defaultsKey = "ThumbnailCellSize"
    /// セル幅の可動域(pt)。ピンチ・設定スライダ共通
    static let range: ClosedRange<CGFloat> = 80...400
    static let defaultSize: CGFloat = 160
    /// セルの縦横比(縦長ページ+番号ラベルのぶん縦に長い)
    static let cellHeightFactor: CGFloat = 1.45

    static func read(from defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.double(forKey: defaultsKey)
        guard value > 0 else { return defaultSize }
        return clamp(CGFloat(value))
    }

    static func write(_ size: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(size)), forKey: defaultsKey)
    }

    static func clamp(_ size: CGFloat) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, size))
    }
}

/// サムネイルグリッドの構成計算(仕様書 §4.8)。
/// 「どのエントリをどのセルに束ね、何画面に分けるか」だけを扱う純粋な値型。
/// 表示状態(現在画面・強調)はモデル側、描画はビュー側の責務。
struct ThumbnailGridLayout: Equatable {
    /// グリッドのセル間隔(行列計算と描画で共有)
    static let spacing: CGFloat = 8

    /// ビューポートにセル幅 cellSize のセルが何行何列入るか(Photos 風の
    /// 自動グリッド)。極小・非正の寸法でも最低 1×1 を返す
    static func dimensions(for viewport: CGSize, cellSize: CGFloat)
        -> (rows: Int, columns: Int) {
        let size = ThumbnailZoomSetting.clamp(cellSize)
        let columns = Int((viewport.width + spacing) / (size + spacing))
        let rows = Int((viewport.height + spacing)
            / (size * ThumbnailZoomSetting.cellHeightFactor + spacing))
        return (max(1, rows), max(1, columns))
    }

    let rows: Int
    /// 実効列数(見開きモードでは設定値の半分。セルが 2 ページ幅になるため)
    let columns: Int
    /// セル単位のページ組。単ページは [n]、見開きモードは読み順の [n, n+1]
    /// (仕様書 §4.8 mangaMode)。しおり絞り込みは組む前に適用する。
    /// 旧 mangaMode 同様、横長と判明したページ(knownLargePages)はペアにせず
    /// 単独セルにする。判明前(未生成)のページは縦長とみなして進歩的に直す。
    let cellGroups: [[Int]]

    init(entryCount: Int, bookmarkedPages: Set<Int>,
         onlyBookmarks: Bool, comicMode: Bool, rows: Int, columns: Int,
         knownLargePages: Set<Int> = []) {
        self.rows = max(1, rows)
        self.columns = comicMode ? max(1, columns / 2) : max(1, columns)
        let visible = onlyBookmarks
            ? (0..<entryCount).filter(bookmarkedPages.contains)
            : Array(0..<entryCount)
        if comicMode {
            var groups: [[Int]] = []
            var position = 0
            while position < visible.count {
                let first = visible[position]
                if !knownLargePages.contains(first),
                   position + 1 < visible.count,
                   !knownLargePages.contains(visible[position + 1]) {
                    groups.append([first, visible[position + 1]])
                    position += 2
                } else {
                    groups.append([first])
                    position += 1
                }
            }
            cellGroups = groups
        } else {
            cellGroups = visible.map { [$0] }
        }
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
