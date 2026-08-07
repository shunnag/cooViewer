import Foundation

/// ページのソート(仕様書 §4.4.2)。
/// 旧実装の値をそのまま使う: 0=名前 / 1=シャッフル / 2=作成日 / 3=変更日。
/// 4=名前(単純)は新実装で追加した値(旧データと衝突しない)。
enum SortMode: Int, Sendable, CaseIterable {
    /// Finder 互換の自然順。数値部分は数値の大小で比較する
    /// (hoge-2 < hoge-03 < hoge-4 < hoge-006)
    case name = 0
    case shuffle = 1
    case creationDate = 2
    case modificationDate = 3
    /// 単純な文字コード順(hoge-0 < hoge-006 < hoge-03 < hoge-1)
    case literalName = 4
}

enum PageSorter {
    /// 指定モードでソートする。旧実装同様、どのモードでも
    /// まず名前順(Finder 互換自然順)に正規化してから適用する。
    /// シャッフルは旧実装の「非決定的比較器によるソート」を廃し
    /// Fisher-Yates で行う(設計書 §2.4)。
    static func sorted(
        _ entries: [PageEntry],
        mode: SortMode,
        using generator: inout some RandomNumberGenerator
    ) -> [PageEntry] {
        if mode == .literalName {
            // 単純な名前ソート: 数値解釈やロケール照合を行わない文字コード順
            return entries.sorted { $0.pathInBook < $1.pathInBook }
        }
        // Finder 互換自然順(旧 finderCompareS ≒ localizedStandardCompare。仕様書 §4.4.3)
        var result = entries.sorted {
            $0.pathInBook.localizedStandardCompare($1.pathInBook) == .orderedAscending
        }
        switch mode {
        case .name, .literalName:
            break
        case .shuffle:
            result.shuffle(using: &generator)
        case .creationDate:
            result = stableSort(result) { $0.creationDate }
        case .modificationDate:
            result = stableSort(result) { $0.modificationDate }
        }
        return result
    }

    static func sorted(_ entries: [PageEntry], mode: SortMode) -> [PageEntry] {
        var generator = SystemRandomNumberGenerator()
        return sorted(entries, mode: mode, using: &generator)
    }

    /// 日付なしエントリは末尾(名前順維持)。Swift の sorted は安定ソートではないため
    /// インデックスを添えて安定化する。
    private static func stableSort(
        _ entries: [PageEntry],
        by key: (PageEntry) -> Date?
    ) -> [PageEntry] {
        entries.enumerated().sorted { lhs, rhs in
            switch (key(lhs.element), key(rhs.element)) {
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
