import AppKit

/// 本ごとの設定・履歴・最終ページの永続化(仕様書 §7)。
/// 旧スキーマと互換: BookSettings(表示名キー)/RecentItems(先頭最新)/LastPages。
/// 旧 alias(Carbon)は廃止 API のため、新規書き込みは URL ブックマーク
/// ("bookmark" キー)+ temppath。旧エントリは temppath 文字列で解決する(§13.5)。
/// EN: Legacy-compatible per-book settings, recents and last pages; new
/// EN: entries store a URL bookmark plus temppath instead of Carbon aliases.
@MainActor
final class BookHistoryStore {
    static let shared = BookHistoryStore()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    struct Bookmark: Equatable, Sendable {
        var name: String
        var pageIndex: Int  // 0 始まり(保存形式は 1 始まり文字列。§7.1)
        /// しおり先ページの本の中の相対パス(新規キー。旧アプリは無視する)。
        /// エントリ列が変わったとき(ネスト展開の失敗・並び替え)の照合用
        /// EN: In-book path of the target page (new key, ignored by the legacy
        /// EN: app) used to re-resolve the index when the entry list changed.
        var pagePath: String?

        init(name: String, pageIndex: Int, pagePath: String? = nil) {
            self.name = name
            self.pageIndex = pageIndex
            self.pagePath = pagePath
        }
    }

    /// 保存済みインデックスを、保存時のページパスで照合し直す。
    /// パスが一致すればそのまま、ずれていれば同じパスのページを探す。
    /// 見つからなければ(パス未記録の旧データ含め)保存値をそのまま使う
    /// EN: Re-resolve a saved index via its recorded in-book path; falls back
    /// EN: to the raw index for legacy data without a path.
    static func reconciledIndex(saved index: Int, pagePath: String?,
                                entries: [PageEntry]) -> Int {
        guard let pagePath else { return index }
        if entries.indices.contains(index), entries[index].pathInBook == pagePath {
            return index
        }
        return entries.firstIndex { $0.pathInBook == pagePath } ?? index
    }

    struct BookSettings {
        var readMode: ReadMode?
        var sortMode: SortMode?
        var marks: PageMarks
        var bookmarks: [Bookmark]
    }

    // MARK: - エントリ解決

    /// シンボリックリンク(/var → /private/var 等)を解決した正規形で比較する
    /// EN: Canonical path form (symlinks resolved) used for all comparisons.
    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func entryPath(_ entry: [String: Any]) -> String? {
        if let data = entry["bookmark"] as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) {
                return normalize(url.path)
            }
        }
        if let path = entry["temppath"] as? String,
           FileManager.default.fileExists(atPath: path) {
            return normalize(path)
        }
        return nil
    }

    /// path(正規化済み)と同じ本を指すエントリか。temppath の文字列一致を
    /// 早道に、ブックマーク解決経由の正規形でも照合する(§13.5)
    /// EN: Entry-vs-path match: raw temppath fast path, then resolved+normalized.
    private func matches(_ entry: [String: Any], path: String) -> Bool {
        if entry["temppath"] as? String == path { return true }
        return entryPath(entry) == path
    }

    private func makeEntry(path: String, page: Int?,
                           pagePath: String? = nil) -> [String: Any] {
        var entry: [String: Any] = ["temppath": path]
        if let data = try? URL(fileURLWithPath: path).bookmarkData() {
            entry["bookmark"] = data
        }
        if let page { entry["page"] = page }
        // ページ番号の照合用パス(新規キー "pagepath"。旧アプリは無視する)
        // EN: In-book path hint for the page number (new key; legacy ignores it).
        if let pagePath { entry["pagepath"] = pagePath }
        return entry
    }

    // MARK: - RecentItems(仕様書 §7.2。先頭が最新、page は 0 始まり)

    private var recentItems: [[String: Any]] {
        get { defaults.array(forKey: "RecentItems") as? [[String: Any]] ?? [] }
        set { defaults.set(newValue, forKey: "RecentItems") }
    }

    func recentBookPaths() -> [String] {
        recentItems.compactMap { entryPath($0) }
    }

    func mostRecentBook() -> (path: String, page: Int)? {
        for entry in recentItems {
            if let path = entryPath(entry) {
                return (path, entry["page"] as? Int ?? 0)
            }
        }
        return nil
    }

    func noteOpened(path rawPath: String) {
        let path = normalize(rawPath)
        let limit = defaults.object(forKey: "OpenRecentLimit") as? Int ?? 10
        guard limit > 0 else {
            defaults.removeObject(forKey: "RecentItems")  // 0 で機能無効(§7.2)
            return
        }
        // 既存エントリの保存ページを引き継ぐ(仕様書 §4.1.2 手順 8。
        // 0 にリセットすると最終ページ復元が読み出す前に消えてしまう)
        // EN: Preserve the saved page; resetting to 0 here would destroy it
        // EN: before the restore logic gets a chance to read it.
        let existing = recentItems.first { matches($0, path: path) }
        let savedPage = existing?["page"] as? Int
        var items = recentItems.filter { !matches($0, path: path) }
        while items.count >= limit { items.removeLast() }
        items.insert(makeEntry(path: path, page: savedPage ?? 0,
                               pagePath: existing?["pagepath"] as? String), at: 0)
        recentItems = items
    }

    /// 閉じる/切替時に表示中ページを記録(§7.2, §7.3)。
    /// pagePath はそのページの本の中の相対パス(照合用の新規キー)
    /// EN: Records the current page on close/switch (recents + LastPages);
    /// EN: pagePath is the page's in-book path used for re-resolution.
    func noteClosed(path rawPath: String, pageIndex: Int, pagePath: String? = nil) {
        let path = normalize(rawPath)
        var items = recentItems.filter { !matches($0, path: path) }
        items.insert(makeEntry(path: path, page: pageIndex, pagePath: pagePath), at: 0)
        recentItems = items

        var lastPages = defaults.array(forKey: "LastPages") as? [[String: Any]] ?? []
        lastPages.removeAll { matches($0, path: path) }
        // page==0 は「復帰なし」と不可分のため保存しない(§7.3)
        if defaults.bool(forKey: "AlwaysRememberLastPage"), pageIndex > 0 {
            lastPages.append(makeEntry(path: path, page: pageIndex, pagePath: pagePath))
        }
        defaults.set(lastPages, forKey: "LastPages")
    }

    /// 保存ページの探索: RecentItems → LastPages の順(仕様書 §4.1.2 手順 7)。
    /// 照合用のページパス(あれば)も併せて返す
    /// EN: Looks up the restore page (+ its path hint when recorded).
    func savedPage(forPath rawPath: String) -> (page: Int, pagePath: String?)? {
        let path = normalize(rawPath)
        for entry in recentItems where entryPath(entry) == path {
            if let page = entry["page"] as? Int, page > 0 {
                return (page, entry["pagepath"] as? String)
            }
        }
        let lastPages = defaults.array(forKey: "LastPages") as? [[String: Any]] ?? []
        for entry in lastPages where entryPath(entry) == path {
            if let page = entry["page"] as? Int, page > 0 {
                return (page, entry["pagepath"] as? String)
            }
        }
        return nil
    }

    // MARK: - BookSettings(仕様書 §7.1。トップキーは表示名+衝突時 #N)

    private var bookSettingsDict: [String: [String: Any]] {
        get { defaults.dictionary(forKey: "BookSettings") as? [String: [String: Any]] ?? [:] }
        set { defaults.set(newValue, forKey: "BookSettings") }
    }

    /// 表示名で探し、temppath/bookmark がパスと一致するエントリのキーを返す
    /// EN: BookSettings keys are display names (with "#N" on collisions);
    /// EN: the stored path decides which entry actually matches.
    private func settingsKey(displayName: String, path rawPath: String) -> String? {
        let path = normalize(rawPath)
        let all = bookSettingsDict
        var candidates = [displayName]
        candidates += all.keys.filter { $0.hasPrefix(displayName + "#") }
        for key in candidates {
            if let entry = all[key], entryPath(entry) == path { return key }
        }
        return nil
    }

    func settings(displayName: String, path: String) -> BookSettings? {
        guard let key = settingsKey(displayName: displayName, path: path),
              let entry = bookSettingsDict[key] else { return nil }
        var bookmarks: [Bookmark] = []
        for dict in entry["bookmarks"] as? [[String: Any]] ?? [] {
            if let name = dict["name"] as? String,
               let pageString = dict["page"] as? String, let page = Int(pageString) {
                bookmarks.append(Bookmark(name: name, pageIndex: page - 1,
                                          pagePath: dict["path"] as? String))
            }
        }
        return BookSettings(
            readMode: (entry["readMode"] as? Int).flatMap(ReadMode.init(rawValue:)),
            sortMode: (entry["sortMode"] as? Int).flatMap(SortMode.init(rawValue:)),
            marks: PageMarks(legacyArray: entry["marks"] as? [String] ?? []),
            bookmarks: bookmarks
        )
    }

    /// 保存。bookmarks は RememberBookSettings 無関係に保存される(§7.1)。
    /// EN: Saves per-book state; bookmarks persist even when
    /// EN: RememberBookSettings is off, matching the legacy app.
    func save(displayName: String, path: String, settings: BookSettings) {
        var all = bookSettingsDict
        var key = settingsKey(displayName: displayName, path: path)
        if key == nil {
            // 新規キー: 表示名、衝突時 #N 連番(§7.1)
            var candidate = displayName
            var counter = 2
            while all[candidate] != nil {
                candidate = "\(displayName)#\(counter)"
                counter += 1
            }
            key = candidate
        }
        guard let key else { return }

        var entry = makeEntry(path: path, page: nil)
        let remember = defaults.bool(forKey: "RememberBookSettings")
        if remember {
            if let readMode = settings.readMode { entry["readMode"] = readMode.rawValue }
            if let sortMode = settings.sortMode { entry["sortMode"] = sortMode.rawValue }
            if !settings.marks.legacyArray.isEmpty { entry["marks"] = settings.marks.legacyArray }
        }
        if !settings.bookmarks.isEmpty {
            entry["bookmarks"] = settings.bookmarks.map { bookmark in
                var dict: [String: Any] = [
                    "name": bookmark.name,
                    "page": String(bookmark.pageIndex + 1),  // 1 始まり文字列(§7.1)
                ]
                // 照合用パス(新規キー "path"。旧アプリは無視する)
                // EN: Path hint (new key; the legacy app ignores it).
                if let pagePath = bookmark.pagePath { dict["path"] = pagePath }
                return dict
            }
        }
        // alias+temppath 以外に何も無ければエントリごと削除(§7.1 の count>2 相当)
        // EN: Drop the entry entirely when only path bookkeeping remains.
        if entry.keys.allSatisfy({ ["temppath", "bookmark"].contains($0) }) {
            all.removeValue(forKey: key)
        } else {
            all[key] = entry
        }
        bookSettingsDict = all
    }
}
