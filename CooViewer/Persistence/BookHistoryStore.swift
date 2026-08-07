import AppKit

/// 本ごとの設定・履歴・最終ページの永続化(仕様書 §7)。
/// 旧スキーマと互換: BookSettings(表示名キー)/RecentItems(先頭最新)/LastPages。
/// 旧 alias(Carbon)は廃止 API のため、新規書き込みは URL ブックマーク
/// ("bookmark" キー)+ temppath。旧エントリは temppath 文字列で解決する(§13.5)。
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
    }

    struct BookSettings {
        var readMode: ReadMode?
        var sortMode: SortMode?
        var marks: PageMarks
        var bookmarks: [Bookmark]
    }

    // MARK: - エントリ解決

    /// シンボリックリンク(/var → /private/var 等)を解決した正規形で比較する
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

    private func makeEntry(path: String, page: Int?) -> [String: Any] {
        var entry: [String: Any] = ["temppath": path]
        if let data = try? URL(fileURLWithPath: path).bookmarkData() {
            entry["bookmark"] = data
        }
        if let page { entry["page"] = page }
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
        let savedPage = recentItems.first { $0["temppath"] as? String == path }?["page"] as? Int
        var items = recentItems.filter { $0["temppath"] as? String != path }
        while items.count >= limit { items.removeLast() }
        items.insert(makeEntry(path: path, page: savedPage ?? 0), at: 0)
        recentItems = items
    }

    /// 閉じる/切替時に表示中ページを記録(§7.2, §7.3)
    func noteClosed(path rawPath: String, pageIndex: Int) {
        let path = normalize(rawPath)
        var items = recentItems.filter { $0["temppath"] as? String != path }
        items.insert(makeEntry(path: path, page: pageIndex), at: 0)
        recentItems = items

        var lastPages = defaults.array(forKey: "LastPages") as? [[String: Any]] ?? []
        lastPages.removeAll { $0["temppath"] as? String == path }
        // page==0 は「復帰なし」と不可分のため保存しない(§7.3)
        if defaults.bool(forKey: "AlwaysRememberLastPage"), pageIndex > 0 {
            lastPages.append(makeEntry(path: path, page: pageIndex))
        }
        defaults.set(lastPages, forKey: "LastPages")
    }

    /// 保存ページの探索: RecentItems → LastPages の順(仕様書 §4.1.2 手順 7)
    func savedPage(forPath rawPath: String) -> Int? {
        let path = normalize(rawPath)
        for entry in recentItems where entryPath(entry) == path {
            if let page = entry["page"] as? Int, page > 0 { return page }
        }
        let lastPages = defaults.array(forKey: "LastPages") as? [[String: Any]] ?? []
        for entry in lastPages where entryPath(entry) == path {
            if let page = entry["page"] as? Int, page > 0 { return page }
        }
        return nil
    }

    // MARK: - BookSettings(仕様書 §7.1。トップキーは表示名+衝突時 #N)

    private var bookSettingsDict: [String: [String: Any]] {
        get { defaults.dictionary(forKey: "BookSettings") as? [String: [String: Any]] ?? [:] }
        set { defaults.set(newValue, forKey: "BookSettings") }
    }

    /// 表示名で探し、temppath/bookmark がパスと一致するエントリのキーを返す
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
                bookmarks.append(Bookmark(name: name, pageIndex: page - 1))
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
            entry["bookmarks"] = settings.bookmarks.map {
                ["name": $0.name, "page": String($0.pageIndex + 1)]  // 1 始まり文字列(§7.1)
            }
        }
        // alias+temppath 以外に何も無ければエントリごと削除(§7.1 の count>2 相当)
        if entry.keys.allSatisfy({ ["temppath", "bookmark"].contains($0) }) {
            all.removeValue(forKey: key)
        } else {
            all[key] = entry
        }
        bookSettingsDict = all
    }
}
