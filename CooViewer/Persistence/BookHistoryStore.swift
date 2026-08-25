import AppKit
import CryptoKit

/// 本ごとの設定・履歴・最終ページの永続化(仕様書 §7 の v2 実装)。
///
/// v2: Application Support/jp.coo.cooViewer/BookStates/ に **1 冊 = 1 JSON**
/// (ファイル名はパスの SHA-256)+ recents.json。パスから O(1) で参照でき、
/// 旧形式のような「表示名キーの衝突解決+セキュリティスコープ付きブックマーク
/// blob の逐次解決」「配列全体の UserDefaults 書き直し」を行わない。
/// 初回起動時に旧形式(BookSettings/RecentItems/LastPages)を一括インポート
/// 変換し、旧キーは 1.x 用に**凍結保持**する(以後は読み書きしない)。
@MainActor
final class BookHistoryStore {
    static let shared = BookHistoryStore()
    private let defaults: UserDefaults
    private let directory: URL

    /// 読み込んだ状態のメモリキャッシュ(正規化パス → 状態)
    private var stateCache: [String: BookState] = [:]
    /// 参照ミスの記録(状態のない本を開くたびに再配置スキャンしないため)
    private var missCache: Set<String> = []
    private var recentsCache: [RecentEntry]?

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default
            .userDomainDirectory(.applicationSupportDirectory)
            .appendingPathComponent("jp.coo.cooViewer/BookStates")
    }

    struct Bookmark: Equatable, Sendable {
        var name: String
        var pageIndex: Int  // 0 始まり
        /// しおり先ページの本の中の相対パス。エントリ列が変わったとき
        /// (ネスト展開の失敗・並び替え)の照合用
        var pagePath: String?

        init(name: String, pageIndex: Int, pagePath: String? = nil) {
            self.name = name
            self.pageIndex = pageIndex
            self.pagePath = pagePath
        }
    }

    struct BookSettings {
        var readMode: ReadMode?
        var sortMode: SortMode?
        var marks: PageMarks
        var bookmarks: [Bookmark]
    }

    /// 保存済みインデックスを、保存時のページパスで照合し直す。
    /// パスが一致すればそのまま、ずれていれば同じパスのページを探す。
    /// 見つからなければ(パス未記録の旧データ含め)保存値をそのまま使う
    static func reconciledIndex(saved index: Int, pagePath: String?,
                                entries: [PageEntry]) -> Int {
        guard let pagePath else { return index }
        if entries.indices.contains(index), entries[index].pathInBook == pagePath {
            return index
        }
        return entries.firstIndex { $0.pathInBook == pagePath } ?? index
    }

    // MARK: - v2 ストレージ

    /// 1 冊分の状態(JSON)。しおり・per-book 設定・最終ページを 1 箇所に持つ
    private struct BookState: Codable {
        var version = 2
        var path: String
        var displayName: String?
        /// 移動した本の追跡用(参照時は解決しない。ミス時の再配置でのみ使う)
        var urlBookmark: Data?
        var readMode: Int?
        var sortMode: Int?
        var marks: [String] = []
        var bookmarks: [StoredBookmark] = []
        var lastPageIndex: Int?
        var lastPagePath: String?
        /// 閉じた時点の AlwaysRememberLastPage(旧仕様の write-time 意味論:
        /// 一覧から外れた後の復元可否は「閉じた時」の設定で決まる。§7.3)
        var rememberBeyondRecents: Bool?
        var lastOpened: Double?
        /// リフロー EPUB の最終位置(固定ページ index と排他ではなく併存可。
        /// オプショナル追加のみなので旧ビルドとの相互読み書きは壊れない)
        var lastReflowPosition: ReflowPosition?
        /// リフロー EPUB の全文ページ実測(census)。再オープン時に注入すると
        /// オフスクリーン再実測を省けて N/M・ページバーが即出る(オプショナル追加)
        var lastCensus: StoredCensus?

        var isEmpty: Bool {
            readMode == nil && sortMode == nil && marks.isEmpty
                && bookmarks.isEmpty && (lastPageIndex ?? 0) <= 0
                && lastReflowPosition == nil && lastCensus == nil
        }
    }

    /// リフロー EPUB の全文ページ実測(表示メトリクスキー + 項目別ページ数 +
    /// 版識別子)。メトリクス・版が一致する再オープンでのみ再利用する
    private struct StoredCensus: Codable {
        var metricsKey: String
        var counts: [Int]
        var releaseIdentifier: String?
    }

    /// リフロー EPUB の読書位置(spine 項目 + 項目内進行率 0..1)。
    /// リフローに固定ページ番号は存在しないため進行率で持つ
    private struct ReflowPosition: Codable {
        var spineIndex: Int
        var progression: Double
        /// spine itemref の idref(あれば配信本の改版で spine が並べ替わっても
        /// 正しい章へ復元できる。旧 JSON は idref を持たずデコード互換)
        var idref: String?
    }

    private struct StoredBookmark: Codable {
        var name: String
        var pageIndex: Int  // 0 始まり(v2 は文字列変換なし)
        var pagePath: String?
    }

    private struct RecentEntry: Codable {
        var path: String
        var lastOpened: Double
    }

    /// シンボリックリンク(/var → /private/var 等)を解決した正規形で比較する
    /// (PasswordVault と共通の CanonicalPath.normalize)
    private func normalize(_ path: String) -> String {
        CanonicalPath.normalize(path)
    }

    private func stateURL(forNormalizedPath path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }

    private var recentsURL: URL { directory.appendingPathComponent("recents.json") }

    private func loadState(forNormalizedPath path: String,
                           allowRelocation: Bool = true) -> BookState? {
        if let cached = stateCache[path] { return cached }
        if missCache.contains(path) { return nil }
        let url = stateURL(forNormalizedPath: path)
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(BookState.self, from: data) {
            stateCache[path] = state
            return state
        }
        // ミス時のみ: 移動した本を URL ブックマークで探して付け替える
        // (移行中は全パスが必然的にミスなのでスキャンしない)
        if allowRelocation, let relocated = relocateState(toNormalizedPath: path) {
            return relocated
        }
        missCache.insert(path)
        return nil
    }

    @discardableResult
    private func writeState(_ state: BookState, forNormalizedPath path: String) -> Bool {
        if state.isEmpty {
            // 実内容が何もなければファイルごと消す(旧 §7.1 のエントリ削除相当)
            stateCache[path] = nil
            missCache.insert(path)
            try? FileManager.default.removeItem(
                at: stateURL(forNormalizedPath: path))
            return true
        }
        stateCache[path] = state
        missCache.remove(path)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try data.write(to: stateURL(forNormalizedPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 移動した本の再配置: 同じファイル名の状態だけを対象に URL ブックマークを
    /// 解決し、要求パスを指していれば新しいキーへ移し替える(参照ミス時のみ)
    private func relocateState(toNormalizedPath path: String) -> BookState? {
        let requestedName = (path as NSString).lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "json"
            && file.lastPathComponent != "recents.json" {
            guard let data = try? Data(contentsOf: file),
                  var state = try? JSONDecoder().decode(BookState.self, from: data),
                  (state.path as NSString).lastPathComponent == requestedName,
                  state.path != path,
                  let bookmarkData = state.urlBookmark else { continue }
            var stale = false
            // マウント誘発と UI 表示を抑止して解決する(メインアクター上で
            // ネットワークボリュームのマウント待ちにならないように)
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale),
                normalize(resolved.path) == path else { continue }
            let oldPath = state.path
            state.path = path
            try? FileManager.default.removeItem(at: file)
            stateCache[oldPath] = nil
            missCache.insert(oldPath)
            writeState(state, forNormalizedPath: path)
            // 最近の一覧も新しいパスへ付け替える(最終ページ復元の一覧内判定と
            // 「最近使った本」メニューが移動後も機能するように)
            let recents = loadRecents().map { entry in
                entry.path == oldPath
                    ? RecentEntry(path: path, lastOpened: entry.lastOpened) : entry
            }
            writeRecents(recents)
            return state
        }
        return nil
    }

    // MARK: - 最近使った本

    private func loadRecents() -> [RecentEntry] {
        if let cached = recentsCache { return cached }
        let recents = (try? Data(contentsOf: recentsURL))
            .flatMap { try? JSONDecoder().decode([RecentEntry].self, from: $0) } ?? []
        recentsCache = recents
        return recents
    }

    private func writeRecents(_ recents: [RecentEntry]) {
        recentsCache = recents
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(recents) {
            try? data.write(to: recentsURL, options: .atomic)
        }
    }

    /// 先頭挿入+重複除去。保持は 50 件まで(表示は OpenRecentLimit で切る)
    private func touchRecents(path: String) {
        let limit = defaults.object(forKey: "OpenRecentLimit") as? Int ?? 10
        guard limit > 0 else {
            writeRecents([])  // 0 で機能無効(§7.2)
            return
        }
        var recents = loadRecents().filter { $0.path != path }
        recents.insert(RecentEntry(
            path: path, lastOpened: Date().timeIntervalSince1970), at: 0)
        writeRecents(Array(recents.prefix(50)))
    }

    /// 実在する本だけを返す(旧 §7.2 の「解決できないエントリは飛ばす」)。
    /// 一覧自体は書き換えない: 外付け/ネットワークの本はマウントし直せば戻る
    func recentBookPaths() -> [String] {
        let limit = defaults.object(forKey: "OpenRecentLimit") as? Int ?? 10
        guard limit > 0 else { return [] }
        return loadRecents().lazy
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(limit).map(\.path)
    }

    func mostRecentBook() -> (path: String, page: Int)? {
        // 消えた本を飛ばして最初に実在する本(旧挙動: 次の本へフォールバック)
        guard let first = loadRecents().first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return nil }
        let page = loadState(forNormalizedPath: first.path)?.lastPageIndex ?? 0
        return (first.path, page)
    }

    func noteOpened(path rawPath: String) {
        let path = normalize(rawPath)
        var state = loadState(forNormalizedPath: path)
            ?? BookState(path: path)
        state.lastOpened = Date().timeIntervalSince1970
        writeState(state, forNormalizedPath: path)
        touchRecents(path: path)
    }

    /// 閉じる/切替時に表示中ページを記録(§7.2, §7.3)。
    /// pagePath はそのページの本の中の相対パス(照合用)
    func noteClosed(path rawPath: String, pageIndex: Int, pagePath: String? = nil) {
        let path = normalize(rawPath)
        var state = loadState(forNormalizedPath: path)
            ?? BookState(path: path)
        state.lastPageIndex = pageIndex
        state.lastPagePath = pagePath
        // 一覧から外れた後も復元できるかは「閉じた時点」の設定で固定する
        // (旧 LastPages の write-time 意味論 §7.3)
        state.rememberBeyondRecents = defaults.bool(forKey: "AlwaysRememberLastPage")
        state.lastOpened = Date().timeIntervalSince1970
        writeState(state, forNormalizedPath: path)
        touchRecents(path: path)
    }

    /// リフロー EPUB の位置を記録(noteClosed のリフロー版。§7.3 と同じ
    /// write-time 意味論)。**recents は並べ替えない**: 位置はページ送りの
    /// たびにデバウンス保存され、⌘Q でも両ウインドウ分が保存されるため、
    /// ここで touch すると「昔開いた EPUB」が終了のたびに最前列へ来てしまう
    /// (最近の一覧の順序は noteOpened =「開いた時」だけが動かす)
    /// forceRememberBeyondRecents: コレクション(合本)経由の子 EPUB 用。
    /// 子は意図的に recents へ入れないため、復元ゲート(inRecents ||
    /// rememberBeyondRecents)を書込時に通しておかないと保存が永遠に
    /// 復元されない(§7.3 write-time 意味論の継承)
    func noteClosedReflow(path rawPath: String, spineIndex: Int,
                          progression: Double, idref: String? = nil,
                          forceRememberBeyondRecents: Bool = false) {
        let path = normalize(rawPath)
        var state = loadState(forNormalizedPath: path)
            ?? BookState(path: path)
        // 先頭位置は「復帰なし」と不可分のため保存しない(savedPage と同じ規則)
        if spineIndex == 0 && progression <= 0 {
            state.lastReflowPosition = nil
        } else {
            state.lastReflowPosition = ReflowPosition(
                spineIndex: spineIndex, progression: progression, idref: idref)
        }
        state.rememberBeyondRecents =
            defaults.bool(forKey: "AlwaysRememberLastPage")
                || forceRememberBeyondRecents
        // 移動追跡用の URL ブックマーク(画像本は save() が書くが EPUB は
        // save() を通らないためここで書く。無いと relocateState が成立せず
        // ファイル移動で読書位置が失われる。cooViewer-c6s.18)
        if let data = try? URL(fileURLWithPath: path).bookmarkData() {
            state.urlBookmark = data
        }
        writeState(state, forNormalizedPath: path)
    }

    /// リフロー EPUB の保存位置(savedPage と同じ復元可否ゲート)
    func savedReflowPosition(forPath rawPath: String)
        -> (spineIndex: Int, progression: Double, idref: String?)? {
        let path = normalize(rawPath)
        guard let state = loadState(forNormalizedPath: path),
              let position = state.lastReflowPosition else { return nil }
        let inRecents = recentBookPaths().contains(path)
        guard inRecents || state.rememberBeyondRecents == true else { return nil }
        return (position.spineIndex, position.progression, position.idref)
    }

    /// リフロー EPUB の census(全文ページ実測)を保存する。位置と同居させ、
    /// 存在する状態にだけ追記する(census だけのために新規状態は作らない)
    func noteReflowCensus(path rawPath: String, metricsKey: String,
                          counts: [Int], releaseIdentifier: String?) {
        let path = normalize(rawPath)
        // 既存の状態にだけ追記する。census だけのために状態ファイルを新規作成
        // しない — さもないと「ちょっと開いただけ」の本や合本の子(recents に
        // 入れない設計)にまで census 専用ファイルが残り、回収経路が無いため
        // 際限なく増える。位置やしおりを持つ「読んでいる本」にのみ相乗りさせる
        guard var state = loadState(forNormalizedPath: path) else { return }
        state.lastCensus = StoredCensus(metricsKey: metricsKey, counts: counts,
                                        releaseIdentifier: releaseIdentifier)
        writeState(state, forNormalizedPath: path)
    }

    /// 保存済みの census(再オープン時の注入用。整合検証は注入側=Washi が行う)
    func savedReflowCensus(forPath rawPath: String)
        -> (metricsKey: String, counts: [Int], releaseIdentifier: String?)? {
        let path = normalize(rawPath)
        guard let state = loadState(forNormalizedPath: path),
              let census = state.lastCensus else { return nil }
        return (census.metricsKey, census.counts, census.releaseIdentifier)
    }

    /// 保存ページの探索(仕様書 §4.1.2 手順 7)。
    /// 旧仕様どおり、最近の一覧に残っている本はいつでも、外れた本は
    /// AlwaysRememberLastPage が ON のときだけ復元できる(§7.3)。
    /// page==0 は「復帰なし」と不可分のため返さない
    func savedPage(forPath rawPath: String) -> (page: Int, pagePath: String?)? {
        let path = normalize(rawPath)
        // 「最近の一覧に残っている」は表示上限(OpenRecentLimit)内で判定する
        // (保持自体は 50 件。旧仕様の「一覧から外れたら要 AlwaysRemember」と一致)
        guard let state = loadState(forNormalizedPath: path),
              let page = state.lastPageIndex, page > 0 else { return nil }
        // 一覧内ならいつでも、外れた本は「閉じた時点で」AlwaysRememberLastPage が
        // ON だった場合のみ(旧 LastPages の write-time 意味論 §7.3)
        let inRecents = recentBookPaths().contains(path)
        guard inRecents || state.rememberBeyondRecents == true else { return nil }
        return (page, state.lastPagePath)
    }

    // MARK: - 本ごとの設定としおり

    func settings(displayName: String, path rawPath: String) -> BookSettings? {
        let path = normalize(rawPath)
        guard let state = loadState(forNormalizedPath: path) else { return nil }
        return BookSettings(
            readMode: state.readMode.flatMap(ReadMode.init(rawValue:)),
            sortMode: state.sortMode.flatMap(SortMode.init(rawValue:)),
            marks: PageMarks(legacyArray: state.marks),
            bookmarks: state.bookmarks.map {
                Bookmark(name: $0.name, pageIndex: $0.pageIndex, pagePath: $0.pagePath)
            }
        )
    }

    /// 保存。bookmarks は RememberBookSettings 無関係に保存される(§7.1)。
    /// readMode/sortMode/marks は RememberBookSettings が ON のときだけ残る
    /// (OFF での保存は旧仕様どおり既存値も消す)
    func save(displayName: String, path rawPath: String, settings: BookSettings) {
        let path = normalize(rawPath)
        var state = loadState(forNormalizedPath: path)
            ?? BookState(path: path)
        state.displayName = displayName
        if let data = try? URL(fileURLWithPath: path).bookmarkData() {
            state.urlBookmark = data
        }
        if defaults.bool(forKey: "RememberBookSettings") {
            state.readMode = settings.readMode?.rawValue
            state.sortMode = settings.sortMode?.rawValue
            state.marks = settings.marks.legacyArray
        } else {
            state.readMode = nil
            state.sortMode = nil
            state.marks = []
        }
        state.bookmarks = settings.bookmarks.map {
            StoredBookmark(name: $0.name, pageIndex: $0.pageIndex, pagePath: $0.pagePath)
        }
        writeState(state, forNormalizedPath: path)
    }

    // MARK: - 旧形式からの一括インポート(§13.5 の移行マッピング v2)

    /// 旧形式(BookSettings/RecentItems/LastPages)を v2 へ変換する。
    /// 一度だけ実行し、旧キーは 1.x 用にそのまま残す(以後読み書きしない)。
    /// 変換: しおり page(1 始まり文字列)→ 0 始まり Int、
    /// LastPages/RecentItems の page(0 始まり)→ lastPageIndex
    /// (旧探索順 RecentItems → LastPages を「Recents 優先」で再現)
    func migrateLegacyDataIfNeeded() {
        guard defaults.integer(forKey: "BookStateStoreVersion") < 2 else { return }
        var allWritesSucceeded = true

        // BookSettings: 表示名キー(#N 衝突込み)→ パスへ解決して変換。
        // キーをソートして決定的に処理し、同じパスへ複数キーが解決した場合は
        // フィールド単位でマージする(空の後勝ちでしおりを消さない)
        let legacySettings = defaults.dictionary(forKey: "BookSettings")
            as? [String: [String: Any]] ?? [:]
        for key in legacySettings.keys.sorted() {
            guard let entry = legacySettings[key],
                  let path = legacyEntryPath(entry) else { continue }
            var state = loadState(forNormalizedPath: path, allowRelocation: false)
                ?? BookState(path: path)
            var displayName = key
            if let hashIndex = displayName.range(of: "#", options: .backwards),
               Int(displayName[hashIndex.upperBound...]) != nil {
                displayName = String(displayName[..<hashIndex.lowerBound])
            }
            state.displayName = displayName
            state.urlBookmark = entry["bookmark"] as? Data ?? state.urlBookmark
            state.readMode = entry["readMode"] as? Int ?? state.readMode
            state.sortMode = entry["sortMode"] as? Int ?? state.sortMode
            let marks = entry["marks"] as? [String] ?? []
            if !marks.isEmpty { state.marks = marks }
            let bookmarks = (entry["bookmarks"] as? [[String: Any]] ?? [])
                .compactMap { dict -> StoredBookmark? in
                    guard let name = dict["name"] as? String,
                          let pageString = dict["page"] as? String,
                          let page = Int(pageString), page >= 1 else { return nil }
                    return StoredBookmark(name: name, pageIndex: page - 1,
                                          pagePath: dict["path"] as? String)
                }
            if !bookmarks.isEmpty { state.bookmarks = bookmarks }
            allWritesSucceeded = writeState(state, forNormalizedPath: path)
                && allWritesSucceeded
        }

        // LastPages → lastPageIndex(RecentItems が後で上書き=旧探索順の再現)。
        // LastPages に載っている=閉じた時点で AlwaysRememberLastPage が ON
        let lastPages = defaults.array(forKey: "LastPages") as? [[String: Any]] ?? []
        for entry in lastPages {
            guard let path = legacyEntryPath(entry),
                  let page = entry["page"] as? Int, page > 0 else { continue }
            var state = loadState(forNormalizedPath: path, allowRelocation: false)
                ?? BookState(path: path)
            state.lastPageIndex = page
            state.lastPagePath = entry["pagepath"] as? String
            state.rememberBeyondRecents = true
            allWritesSucceeded = writeState(state, forNormalizedPath: path)
                && allWritesSucceeded
        }

        // RecentItems: 並び順+保存ページ(先頭が最新)
        let recentItems = defaults.array(forKey: "RecentItems") as? [[String: Any]] ?? []
        var recents: [RecentEntry] = []
        var seenPaths = Set<String>()
        let now = Date().timeIntervalSince1970
        for (offset, entry) in recentItems.enumerated() {
            guard let path = legacyEntryPath(entry) else { continue }
            // 同一パスは最初の出現(=最新)のみ採用。壊れた RecentItems(例: 全件が
            // temppath='null.rar' で単一パスへ collapse)でも recents.json とページ
            // 状態に重複を残さない。touchRecents の dedup 不変条件に揃える(cooViewer-0pk)
            guard seenPaths.insert(path).inserted else { continue }
            recents.append(RecentEntry(path: path,
                                       lastOpened: now - Double(offset)))
            if let page = entry["page"] as? Int, page > 0 {
                var state = loadState(forNormalizedPath: path, allowRelocation: false)
                    ?? BookState(path: path)
                state.lastPageIndex = page
                if let pagePath = entry["pagepath"] as? String {
                    state.lastPagePath = pagePath
                }
                allWritesSucceeded = writeState(state, forNormalizedPath: path)
                    && allWritesSucceeded
            }
        }
        if !recents.isEmpty {
            writeRecents(Array(recents.prefix(50)))  // 保持上限は touchRecents と同じ 50 件
        }
        // 書き込みが失敗した場合はフラグを立てず、次回起動で再試行する
        // (旧キーは凍結保持なので再実行しても失われない)
        if allWritesSucceeded {
            defaults.set(2, forKey: "BookStateStoreVersion")
        }
    }

    /// 旧エントリのパス解決(移行時のみ使用): bookmark → temppath 実在 →
    /// temppath 文字列(不在でも保持: ドライブ再接続後に有効になる)
    private func legacyEntryPath(_ entry: [String: Any]) -> String? {
        if let data = entry["bookmark"] as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return normalize(url.path)
            }
        }
        if let path = entry["temppath"] as? String {
            return normalize(path)
        }
        return nil
    }
}
