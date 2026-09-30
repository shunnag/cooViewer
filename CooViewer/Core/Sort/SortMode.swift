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
