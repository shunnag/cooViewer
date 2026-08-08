import CoreGraphics
import Foundation

/// 開いている 1 冊の本。ページ列(ソート適用済み)・現在位置・見開き判定・
/// キャッシュ・先読みを束ねる。UI から使うため MainActor に置く。
///
/// 旧実装の「nowPage の二重意味」(仕様書 §1.4)は持ち込まず、
/// `currentIndex` は常に「表示中スプレッドの先頭ページ(読み順)」を指す。
/// EN: One open book: sorted page list, current position, spread pairing,
/// EN: page cache and prefetch. currentIndex is the first page of the spread.
@MainActor
final class Book {
    let source: any BookSource
    private(set) var entries: [PageEntry]
    private(set) var currentIndex = 0
    private(set) var sortMode: SortMode
    var readMode: ReadMode = .rightToLeftSpread
    var marks = PageMarks()
    var singleSetting = PageLayout.defaultSingleSetting
    var bookmarks: [BookHistoryStore.Bookmark] = []

    /// 表示用デコードの長辺上限(px)。原寸表示は fullResolutionImage(at:) を使う
    /// (設計書「キャッシュ・先読み設計」)。nil で無制限。
    /// EN: Long-edge pixel cap for display decodes; nil means uncapped.
    var displayPixelCap: Int? = 4096

    /// サムネイル等のディスクキャッシュ用の同一性キー(パス+更新日時+サイズ由来)
    /// EN: Identity key for disk caches; changes whenever the book content changes.
    let cacheKey: String

    private let cache: PageCache
    private var prefetchTask: Task<Void, Never>?
    private var lastDisplayCount = 1
    private var lastMoveForward = true

    /// 先読みの幅(設計書「キャッシュ・先読み設計」)
    /// 先読み枚数(設定「高度」から注入される。既定は設計書 §3.1 の値)
    /// EN: Prefetch window sizes, injected from the Advanced settings tab.
    var prefetchAhead = 12
    var prefetchBehind = 3

    /// 表示すべきページの組。images の nil は「読めないページ」
    /// (呼び出し側が壊れ画像プレースホルダを当てる。仕様書 §4.17)。
    /// EN: Pages to show now; a nil image means the page failed to decode.
    struct Spread {
        let indices: [Int]
        let images: [CGImage?]
    }

    enum MoveResult {
        case moved
        case hitStart  // 巻頭超え(loopCheck 処理は呼び出し側)
        case hitEnd    // 巻末超え(同上)
    }

    init(source: any BookSource, entries: [PageEntry],
         sortMode: SortMode = .name,
         cacheByteLimit: Int = 512 * 1024 * 1024) {
        self.source = source
        self.sortMode = sortMode
        self.entries = PageSorter.sorted(entries, mode: sortMode)
        self.cache = PageCache(byteLimit: cacheByteLimit)
        self.cacheKey = Self.makeCacheKey(for: source.url, entries: entries)
    }

    static func open(source: any BookSource, sortMode: SortMode = .name,
                     cacheByteLimit: Int = 512 * 1024 * 1024) async throws -> Book {
        let entries = try await source.entries()
        return Book(source: source, entries: entries, sortMode: sortMode,
                    cacheByteLimit: cacheByteLimit)
    }

    /// 本の同一性キー。ファイル情報に加えて**エントリ一覧のダイジェスト**を
    /// 混ぜる: フォルダの本はサブフォルダ内だけの変更や同名上書きで親の
    /// 更新日時が変わらないため、ファイル情報だけでは古いサムネイルが残る。
    /// エントリ側のダイジェストは順序非依存(ソート・シャッフルの影響なし)
    /// EN: Hash of file stat plus an order-independent digest of all entries,
    /// EN: so folder books invalidate even when only subfolder contents change.
    private static func makeCacheKey(for url: URL, entries: [PageEntry]) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let size = attributes?[.size] as? Int ?? 0
        let seed = "\(url.path)|\(modified)|\(size)"
        // 依存を増やさない簡易ハッシュ(djb2 の 64bit 版を 2 系統)で十分
        var hash1: UInt64 = 5381
        var hash2: UInt64 = 52711
        for byte in seed.utf8 {
            hash1 = hash1 &* 33 &+ UInt64(byte)
            hash2 = hash2 &* 37 &+ UInt64(byte)
        }
        var sum1: UInt64 = 0
        var sum2: UInt64 = 0
        for entry in entries {
            let entrySeed = "\(entry.pathInBook)|\(entry.modificationDate?.timeIntervalSince1970 ?? 0)"
            var entryHash1: UInt64 = 5381
            var entryHash2: UInt64 = 52711
            for byte in entrySeed.utf8 {
                entryHash1 = entryHash1 &* 33 &+ UInt64(byte)
                entryHash2 = entryHash2 &* 37 &+ UInt64(byte)
            }
            sum1 &+= entryHash1
            sum2 &+= entryHash2
        }
        return String(format: "%016llx%016llx", hash1 ^ sum1, hash2 ^ sum2)
    }

    var pageCount: Int { entries.count }
    var displayName: String { source.displayName }

    // MARK: - 画像ロード

    func image(at index: Int) async -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        let key = entries[index].id
        if let hit = await cache.image(for: key) { return hit }
        guard let image = try? await source.image(
            for: entries[index], maxPixelSize: displayPixelCap) else {
            return nil
        }
        await cache.insert(image, for: key)
        return image
    }

    /// 原寸表示・書き出し用: キャッシュと表示上限を介さずフル解像度でデコードする。
    /// EN: Full-resolution decode that bypasses the cache and the display cap.
    func fullResolutionImage(at index: Int) async -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        return try? await source.image(for: entries[index], maxPixelSize: nil)
    }

    private func isSmall(_ image: CGImage?, at index: Int) -> Bool {
        guard let image else { return false }
        return PageLayout.isSmall(
            size: CGSize(width: image.width, height: image.height),
            index: index, marks: marks, singleSetting: singleSetting
        )
    }

    /// 現在位置のスプレッドを確定する(仕様書 §4.2.4 の見開き判定を再現)。
    /// EN: Builds the current 1- or 2-page spread: pair only when both pages
    /// EN: are portrait-ish ("small") and spread mode is on.
    func currentSpread() async -> Spread {
        guard !entries.isEmpty else { return Spread(indices: [], images: []) }
        currentIndex = min(max(0, currentIndex), entries.count - 1)

        let first = await image(at: currentIndex)
        var indices = [currentIndex]
        var images: [CGImage?] = [first]

        if readMode.isSpread, currentIndex + 1 < entries.count, isSmall(first, at: currentIndex) {
            let second = await image(at: currentIndex + 1)
            if isSmall(second, at: currentIndex + 1) {
                indices.append(currentIndex + 1)
                images.append(second)
            }
        }
        lastDisplayCount = indices.count
        schedulePrefetch()
        return Spread(indices: indices, images: images)
    }

    // MARK: - ナビゲーション(仕様書 §4.3)

    func moveNext() -> MoveResult {
        guard !entries.isEmpty else { return .hitEnd }
        guard currentIndex + lastDisplayCount < entries.count else { return .hitEnd }
        currentIndex += lastDisplayCount
        lastMoveForward = true
        return .moved
    }

    func movePrevious() async -> MoveResult {
        guard !entries.isEmpty, currentIndex > 0 else { return .hitStart }
        lastMoveForward = false
        if readMode.isSpread, currentIndex >= 2 {
            let first = await image(at: currentIndex - 2)
            let second = await image(at: currentIndex - 1)
            if isSmall(first, at: currentIndex - 2), isSmall(second, at: currentIndex - 1) {
                currentIndex -= 2
                return .moved
            }
        }
        currentIndex -= 1
        return .moved
    }

    /// 見開きから 1 ページだけ進む/戻る(仕様書 §5.5 action 2/3)
    func moveHalfNext() -> MoveResult {
        guard currentIndex + 1 < entries.count else { return .hitEnd }
        currentIndex += 1
        lastMoveForward = true
        return .moved
    }

    func moveHalfPrevious() -> MoveResult {
        guard currentIndex > 0 else { return .hitStart }
        currentIndex -= 1
        lastMoveForward = false
        return .moved
    }

    func goTo(index: Int) {
        guard !entries.isEmpty else { return }
        currentIndex = min(max(0, index), entries.count - 1)
    }

    func goToFirst() {
        currentIndex = 0
        lastMoveForward = true
    }

    /// 末尾へ。見開きなら最終 2 枚がペアになる場合 count-2 に着地(仕様書 §4.3.3)。
    /// EN: Jump to the end; lands on count-2 when the last two pages pair up.
    func goToLast() async {
        guard !entries.isEmpty else { return }
        lastMoveForward = true
        if readMode.isSpread, entries.count >= 2 {
            let first = await image(at: entries.count - 2)
            let second = await image(at: entries.count - 1)
            if isSmall(first, at: entries.count - 2), isSmall(second, at: entries.count - 1) {
                currentIndex = entries.count - 2
                return
            }
        }
        currentIndex = entries.count - 1
    }

    /// パーセントジャンプ(旧 goToPar)。上限クランプなしの旧仕様を維持し、
    /// 100% 以上は hitEnd を返す(仕様書 §13.3)。
    /// EN: Percent jump; values >= 100% report hitEnd (legacy behavior kept).
    func goToPercent(_ percent: Double) -> MoveResult {
        guard !entries.isEmpty else { return .hitEnd }
        let target = Int(Double(entries.count) * percent)
        guard target < entries.count else { return .hitEnd }
        goTo(index: max(0, target))
        return .moved
    }

    /// スキップ(仕様書 §4.3.6 相当。value ページ分移動)
    func skip(by value: Int) {
        goTo(index: currentIndex + value)
    }

    /// ソート変更。旧仕様通り先頭ページへ戻る(仕様書 §13.3 で「維持」判断)。
    /// EN: Re-sorts the pages and resets to page 0, as the legacy app did.
    func setSortMode(_ mode: SortMode) {
        sortMode = mode
        entries = PageSorter.sorted(entries, mode: mode)
        currentIndex = 0
    }

    /// 先読みを打ち切る(本の切替時に旧本の I/O・デコードを止める)
    /// EN: Cancel prefetch so a replaced book stops decoding in the background.
    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    // MARK: - サブフォルダ移動(仕様書 §4.3.5: containerPath 単位で巡回)

    func nextSubFolderIndex() -> Int? {
        guard !entries.isEmpty else { return nil }
        let current = entries[currentIndex].containerPath
        for offset in 1...entries.count {
            let index = (currentIndex + offset) % entries.count
            if entries[index].containerPath != current { return index }
        }
        return nil
    }

    func previousSubFolderIndex() -> Int? {
        guard !entries.isEmpty else { return nil }
        let current = entries[currentIndex].containerPath
        var index = currentIndex
        for _ in 1...entries.count {
            index = (index - 1 + entries.count) % entries.count
            if entries[index].containerPath != current {
                // 前グループの先頭へ(仕様書 §4.3.5)
                // EN: Walk back to the first page of the previous folder group.
                let target = entries[index].containerPath
                var first = index
                while first > 0, entries[first - 1].containerPath == target { first -= 1 }
                return first
            }
        }
        return nil
    }

    // MARK: - しおり移動

    func nextBookmarkIndex() -> Int? {
        bookmarks.map(\.pageIndex).filter { $0 > currentIndex }.min()
    }

    func previousBookmarkIndex() -> Int? {
        bookmarks.map(\.pageIndex).filter { $0 < currentIndex }.max()
    }

    // MARK: - 先読み(仕様書 §4.5 の置換。設計書 §3.1)

    /// EN: Cancels the previous prefetch and warms the cache around the
    /// EN: current position, direction-aware; parallel only for folder books.
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        let ahead = (0..<max(0, prefetchAhead)).map { currentIndex + lastDisplayCount + $0 }
        let behind = prefetchBehind > 0
            ? (1...prefetchBehind).map { currentIndex - $0 } : []
        let targets = (lastMoveForward ? ahead + behind : behind + ahead)
            .filter { entries.indices.contains($0) }
        let parallel = source.supportsParallelPageLoads

        prefetchTask = Task { [weak self] in
            guard let self else { return }
            if parallel {
                // ローカルフォルダ等はデコードを 4 並列で先行させる
                await withTaskGroup(of: Void.self) { group in
                    var iterator = targets.makeIterator()
                    for _ in 0..<4 {
                        if let target = iterator.next() {
                            group.addTask { _ = await self.image(at: target) }
                        }
                    }
                    while await group.next() != nil {
                        if Task.isCancelled { break }
                        if let target = iterator.next() {
                            group.addTask { _ = await self.image(at: target) }
                        }
                    }
                }
            } else {
                for target in targets {
                    if Task.isCancelled { return }
                    _ = await self.image(at: target)
                }
            }
        }
    }
}
