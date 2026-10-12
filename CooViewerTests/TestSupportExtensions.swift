import Foundation

@testable import cooViewer

/// テスト専用の同期ヘルパ。製品コードはメインアクター上でファイルシステムに
/// 触れないため(設計書 §7.3)、これらは製品側から外した同期形を提供する
extension Book {
    /// 初期ソートと同一性キー(stat を含む)を呼び出し元で同期に計算する
    convenience init(source: any BookSource, entries: [PageEntry],
                     sortMode: SortMode = .name,
                     cacheByteLimit: Int = 512 * 1024 * 1024) {
        self.init(source: source,
                  prepared: Book.prepare(url: source.url, entries: entries, sortMode: sortMode,
                                         identity: FileManagerProbe.blockingIdentity(at: source.url)),
                  sortMode: sortMode, cacheByteLimit: cacheByteLimit)
    }
}

extension BookHistoryStore {
    /// 旧 recentBookPaths().contains(path) の復元ゲートを同期に計算する
    /// (実在する最近の一覧の表示上限内に在るか)
    private func inRecentsSynchronously(_ rawPath: String) -> Bool {
        let path = CanonicalPath.normalize(rawPath)
        return recentPaths().lazy
            .filter { FileManager.default.fileExists(atPath: $0) }
            .prefix(max(0, openRecentLimit))
            .contains(path)
    }

    func savedPage(forPath path: String) -> (page: Int, pagePath: String?)? {
        savedPage(forPath: path, inRecents: inRecentsSynchronously(path))
    }

    func savedReflowPosition(forPath path: String)
        -> (spineIndex: Int, progression: Double, idref: String?)? {
        savedReflowPosition(forPath: path, inRecents: inRecentsSynchronously(path))
    }
}
