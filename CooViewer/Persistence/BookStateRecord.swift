import Foundation

/// 1 冊分の状態(JSON)。しおり・per-book 設定・最終ページを 1 箇所に持つ
struct BookStateRecord: Codable {
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
    /// リフロー EPUB のしおり。固定ページ番号ではなく読書位置と同じ
    /// spine 項目 + 項目内進行率で持つ(仕様書 §4.7、設計書 §2.4)
    var reflowBookmarks: [StoredReflowBookmark] = []
    /// リフロー EPUB の全文ページ実測(census)の旧ビルド互換ミラー。
    /// 常に censusRecords の先頭を写し、旧ビルドにも最新値を渡す
    /// (cooViewer-oxr.45、設計書 §2.4)
    var lastCensus: StoredCensus?
    /// 表示メトリクス別 census の MRU。先頭が最新で最大 3 件、
    /// metricsKey の重複は持たない(cooViewer-oxr.45、設計書 §2.4)
    var censusRecords: [StoredCensus] = []
    /// リフロー EPUB の見開き/単ページ固定(s キー = EPUBColumnMode の
    /// rawValue。1=single / 2=double。nil/0=auto)。画像本の単/見開き固定
    /// (marks)に相当する表示設定で、RememberBookSettings が ON のときだけ
    /// 残る。オプショナル追加なので旧 JSON はデコード互換(cooViewer-0dh)
    var columnMode: Int?

    /// lastCensus と censusRecords を除いた「残す価値のある内容」が空か。
    /// columnMode を消した結果 census だけが残る状態(合本の子で起きうる)を
    /// 検出し、census 単独ファイルを残さない方針を保つために使う
    /// (cooViewer-oxr.45、設計書 §2.4)
    var isEmptyIgnoringCensus: Bool {
        readMode == nil && sortMode == nil && marks.isEmpty
            && bookmarks.isEmpty && (lastPageIndex ?? 0) <= 0
            && lastReflowPosition == nil && reflowBookmarks.isEmpty
            && columnMode == nil
    }

    var isEmpty: Bool {
        isEmptyIgnoringCensus && lastCensus == nil && censusRecords.isEmpty
    }

    mutating func applyImagePosition(pageIndex: Int, pagePath: String?,
                                    rememberBeyondRecents: Bool, closedAt: Double) {
        lastPageIndex = pageIndex
        lastPagePath = pagePath
        self.rememberBeyondRecents = rememberBeyondRecents
        lastOpened = closedAt
    }

    mutating func applySettings(_ settings: SavedBookSettings, remember: Bool) {
        readMode = remember ? settings.readMode?.rawValue : nil
        sortMode = remember ? settings.sortMode?.rawValue : nil
        marks = remember ? settings.marks.legacyArray : []
        bookmarks = settings.bookmarks.map {
            StoredBookmark(name: $0.name, pageIndex: $0.pageIndex, pagePath: $0.pagePath)
        }
    }

    mutating func applyReflowPosition(_ position: ReflowReadingPosition,
                                     rememberBeyondRecents: Bool) {
        // 先頭位置は「復帰なし」と不可分(仕様書 §7.3)。
        lastReflowPosition = position.spineIndex == 0 && position.progression <= 0
            ? nil
            : ReflowPosition(spineIndex: position.spineIndex,
                             progression: position.progression, idref: position.idref)
        self.rememberBeyondRecents = rememberBeyondRecents
    }

    mutating func applyReflowBookmarks(_ bookmarks: [ReflowBookmarkSnapshot]) {
        reflowBookmarks = bookmarks.map {
            StoredReflowBookmark(name: $0.name, spineIndex: $0.position.spineIndex,
                                 progression: $0.position.progression, idref: $0.position.idref)
        }
    }

    mutating func applyColumnMode(_ mode: Int, remember: Bool) {
        columnMode = remember && mode != 0 ? mode : nil
    }

    mutating func applyCensus(_ census: ReflowCensusSnapshot) {
        // 同じメトリクスを更新して先頭へ移し、最大 3 件と旧版向けミラーを維持する。
        censusRecords.removeAll { $0.metricsKey == census.metricsKey }
        censusRecords.insert(StoredCensus(
            metricsKey: census.metricsKey, counts: census.counts,
            releaseIdentifier: census.releaseIdentifier), at: 0)
        if censusRecords.count > 3 {
            censusRecords.removeSubrange(3...)
        }
        lastCensus = censusRecords.first
    }

    /// 位置・しおり・表示設定を消した結果、実測だけが残るファイルを回収する。
    /// 一括保存では全内容を反映した後に判定し、途中の空状態で実測を失わない。
    mutating func discardOrphanedCensus() {
        if isEmptyIgnoringCensus {
            lastCensus = nil
            censusRecords.removeAll()
        }
    }

    init(path: String) {
        self.path = path
    }

    /// reflowBookmarks 追加前の v2 JSON も空配列として読む。
    /// 非 Optional 配列の合成 Decodable は欠落キーを許さないため、追加項目
    /// だけ decodeIfPresent にする(設計書 §13.5 の後方互換方針)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
        path = try container.decode(String.self, forKey: .path)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        urlBookmark = try container.decodeIfPresent(Data.self, forKey: .urlBookmark)
        readMode = try container.decodeIfPresent(Int.self, forKey: .readMode)
        sortMode = try container.decodeIfPresent(Int.self, forKey: .sortMode)
        marks = try container.decodeIfPresent([String].self, forKey: .marks) ?? []
        bookmarks = try container.decodeIfPresent(
            [StoredBookmark].self, forKey: .bookmarks) ?? []
        lastPageIndex = try container.decodeIfPresent(
            Int.self, forKey: .lastPageIndex)
        lastPagePath = try container.decodeIfPresent(
            String.self, forKey: .lastPagePath)
        rememberBeyondRecents = try container.decodeIfPresent(
            Bool.self, forKey: .rememberBeyondRecents)
        lastOpened = try container.decodeIfPresent(Double.self, forKey: .lastOpened)
        lastReflowPosition = try container.decodeIfPresent(
            ReflowPosition.self, forKey: .lastReflowPosition)
        reflowBookmarks = try container.decodeIfPresent(
            [StoredReflowBookmark].self, forKey: .reflowBookmarks) ?? []
        let legacyCensus = try container.decodeIfPresent(
            StoredCensus.self, forKey: .lastCensus)
        let decodedCensuses = try container.decodeIfPresent(
            [StoredCensus].self, forKey: .censusRecords) ?? []
        var seenMetricsKeys: Set<String> = []
        censusRecords = decodedCensuses.filter {
            seenMetricsKeys.insert($0.metricsKey).inserted
        }
        if censusRecords.count > 3 {
            censusRecords.removeSubrange(3...)
        }
        // censusRecords 導入前の JSON は lastCensus を 1 件の MRU として昇格する。
        // 新形式では先頭を互換ミラーへ戻し、不整合な永続値も正規化する
        // (cooViewer-oxr.45、設計書 §2.4)
        if censusRecords.isEmpty, let legacyCensus {
            censusRecords = [legacyCensus]
        }
        lastCensus = censusRecords.first
        columnMode = try container.decodeIfPresent(Int.self, forKey: .columnMode)
    }

    /// リフロー EPUB の全文ページ実測(表示メトリクスキー + 項目別ページ数 +
    /// 版識別子)。メトリクス・版が一致する再オープンでのみ再利用する
    struct StoredCensus: Codable {
        var metricsKey: String
        var counts: [Int]
        var releaseIdentifier: String?
    }

    /// リフロー EPUB の読書位置(spine 項目 + 項目内進行率 0..1)。
    /// リフローに固定ページ番号は存在しないため進行率で持つ
    struct ReflowPosition: Codable {
        var spineIndex: Int
        var progression: Double
        /// spine itemref の idref(あれば配信本の改版で spine が並べ替わっても
        /// 正しい章へ復元できる。旧 JSON は idref を持たずデコード互換)
        var idref: String?
    }

    /// リフロー EPUB のしおり。BookHistoryStore は Washi 非依存を保ち、
    /// 境界では ReflowPosition と同じタプルで授受する(設計書 §2.4)
    struct StoredReflowBookmark: Codable {
        var name: String
        var spineIndex: Int
        var progression: Double
        var idref: String?
    }

    struct StoredBookmark: Codable {
        var name: String
        var pageIndex: Int  // 0 始まり(v2 は文字列変換なし)
        var pagePath: String?
    }
}
