/// 固定ページのしおり(仕様書 §4.7)。編集・読書・保存で共有する値。
struct PageBookmark: Equatable, Sendable {
    var name: String
    var pageIndex: Int  // 0 始まり
    /// エントリ列が変わったとき(ネスト展開の失敗・並び替え)の照合用。
    var pagePath: String?

    init(name: String, pageIndex: Int, pagePath: String? = nil) {
        self.name = name
        self.pageIndex = pageIndex
        self.pagePath = pagePath
    }
}

/// 復元する本ごとの設定。JSON の表現や保存先から独立させる。
struct SavedBookSettings {
    var readMode: ReadMode?
    var sortMode: SortMode?
    var marks: PageMarks
    var bookmarks: [PageBookmark]
}
