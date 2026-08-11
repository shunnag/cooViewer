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
    /// 見開きモードで先頭ページ(表紙)を単ページにする(新機能・既定オフ)。
    /// marks の強制ペア指定(§4.2.1)はこれより優先される
    /// EN: Keep the first page (cover) single in spread modes; explicit
    /// EN: forced-pair marks still win.
    var coverSingleFirst = false
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

    /// アニメーション判定で「静止画」と分かったページ(entry.id)。
    /// 表示のたびに生データを読み直して判定し直すのを防ぐ
    /// EN: Entry ids probed as NOT animated, so redisplays skip the raw
    /// EN: re-read + re-parse of the animation probe.
    var probedStaticAnimationIDs: Set<Int> = []

    /// 先読みの幅(設計書「キャッシュ・先読み設計」)
    /// 先読み枚数(設定「高度」から注入される。既定は設計書 §3.1 の値)
    /// EN: Prefetch window sizes, injected from the Advanced settings tab.
    var prefetchAhead = 12
    var prefetchBehind = 3
    /// 置き場所の速度プロファイル(先読み並列度・サムネイル並列度の根拠)
    /// EN: Volume-speed profile driving prefetch and thumbnail concurrency.
    var mediaProfile: MediaProfile = .unknown

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

    /// 進行中のデコード(entry.id → タスク)。表示要求が先読みの進行中
    /// デコードに合流し、同じページを二重にデコードしないための単一飛行
    /// EN: In-flight decodes keyed by entry id: the display request joins the
    /// EN: prefetch decode instead of duplicating it (single-flight).
    private var inFlightLoads: [Int: (token: Int, task: Task<CGImage?, Never>)] = [:]
    private var inFlightToken = 0

    func image(at index: Int) async -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        let key = entries[index].id
        if let hit = await cache.image(for: key) { return hit }
        if let running = inFlightLoads[key] {
            return await running.task.value
        }
        // detached: 先読みのキャンセルが、合流している表示要求まで
        // 巻き込まないように独立タスクで走らせる
        // EN: Detached so cancelling the prefetch never kills a decode the
        // EN: on-screen request has joined.
        let source = source
        let entry = entries[index]
        let cap = displayPixelCap
        let cache = cache
        let task = Task<CGImage?, Never>.detached(priority: .userInitiated) {
            try? await source.image(for: entry, maxPixelSize: cap)
        }
        inFlightToken += 1
        let token = inFlightToken
        inFlightLoads[key] = (token, task)
        let image = await task.value
        if inFlightLoads[key]?.token == token {
            inFlightLoads[key] = nil
        }
        if let image {
            // キャッシュへの登録はキャップが変わっていない場合のみ
            // (拡大後に旧キャップの低解像度が居座るのを防ぐ。表示自体は返し、
            //  直後の再表示が新キャップで再デコードする)
            // EN: Insert only if the cap is unchanged, so a raise never gets
            // EN: repopulated with stale low-res decodes.
            if cap == displayPixelCap {
                await cache.insert(image, for: key)
            }
            if pageSizeCache[key] == nil {
                // キャップ付きデコードでも縦横比は保たれるため判定に使える
                // EN: Capped decodes preserve the aspect ratio, fine for pairing.
                pageSizeCache[key] = CGSize(width: image.width, height: image.height)
            }
        }
        return image
    }

    /// 原寸表示・書き出し用: キャッシュと表示上限を介さずフル解像度でデコードする。
    /// EN: Full-resolution decode that bypasses the cache and the display cap.
    func fullResolutionImage(at index: Int) async -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        return try? await source.image(for: entries[index], maxPixelSize: nil)
    }

    /// ページ寸法の索引(entry.id → 寸法)。ヘッダ読みやデコード結果から
    /// 埋まり、見開き判定(縦横比)をデコードなしで行えるようにする
    /// EN: Page-size index (header reads + decode results) so spread pairing
    /// EN: needs no decode.
    private var pageSizeCache: [Int: CGSize] = [:]

    private func pageSize(at index: Int) async -> CGSize? {
        guard entries.indices.contains(index) else { return nil }
        let key = entries[index].id
        if let cached = pageSizeCache[key] { return cached }
        if let hit = await cache.image(for: key) {
            let size = CGSize(width: hit.width, height: hit.height)
            pageSizeCache[key] = size
            return size
        }
        if let size = await source.imageSize(for: entries[index]) {
            pageSizeCache[key] = size
            return size
        }
        return nil
    }

    /// サイズ索引による見開き候補判定。寸法が取れなければ nil(従来判定へ)
    /// EN: Size-index pairing check; nil falls back to the decode-based test.
    private func isSmallFromIndex(at index: Int) async -> Bool? {
        guard let size = await pageSize(at: index) else { return nil }
        return PageLayout.isSmall(size: size, index: index,
                                  marks: marks, singleSetting: singleSetting,
                                  coverSingle: coverSingleFirst)
    }

    /// 表示デコード上限の更新。上げた場合は低解像度の既存キャッシュを破棄する
    /// (ウインドウ拡大・原寸表示切替時。下げた場合は大きい画像を使い続ける)
    /// EN: Update the decode cap; raising it drops the lower-res cache.
    func updateDisplayPixelCap(_ cap: Int) async -> Bool {
        guard cap != displayPixelCap else { return false }
        let raised = cap > (displayPixelCap ?? Int.max)
        displayPixelCap = cap
        if raised {
            await cache.removeAll()
            // 旧キャップで進行中のデコードには合流させない(新規要求は
            // 新キャップで作り直す。旧タスクの結果はキャップ照合で捨てられる)
            // EN: Detach in-flight old-cap decodes; new requests re-decode at
            // EN: the new cap and stale results fail the cap check.
            inFlightLoads.removeAll()
        }
        return raised
    }

    private func isSmall(_ image: CGImage?, at index: Int) -> Bool {
        guard let image else { return false }
        return PageLayout.isSmall(
            size: CGSize(width: image.width, height: image.height),
            index: index, marks: marks, singleSetting: singleSetting,
            coverSingle: coverSingleFirst
        )
    }

    /// 現在位置のスプレッドを確定する(仕様書 §4.2.4 の見開き判定を再現)。
    /// EN: Builds the current 1- or 2-page spread: pair only when both pages
    /// EN: are portrait-ish ("small") and spread mode is on.
    func currentSpread() async -> Spread {
        guard !entries.isEmpty else { return Spread(indices: [], images: []) }
        currentIndex = min(max(0, currentIndex), entries.count - 1)

        // サイズ索引(ヘッダ寸法)でペアが確定するなら、両ページを並列取得する
        // (従来はまず 1 枚目をデコードしないと 2 枚目に着手できなかった)。
        // 壊れページ(デコード失敗)は従来どおり単ページへ落とす
        // EN: When the size index settles the pairing, fetch both halves in
        // EN: parallel; broken pages still collapse to a single page.
        if readMode.isSpread, currentIndex + 1 < entries.count,
           let firstSmall = await isSmallFromIndex(at: currentIndex),
           firstSmall,
           let secondSmall = await isSmallFromIndex(at: currentIndex + 1) {
            if secondSmall {
                async let firstTask = image(at: currentIndex)
                async let secondTask = image(at: currentIndex + 1)
                let (first, second) = await (firstTask, secondTask)
                if first != nil, second != nil {
                    lastDisplayCount = 2
                    schedulePrefetch()
                    return Spread(indices: [currentIndex, currentIndex + 1],
                                  images: [first, second])
                }
                // 片方が壊れていたら従来規則(単ページ)へ
                // EN: A broken half collapses to a single page (legacy rule).
                lastDisplayCount = 1
                schedulePrefetch()
                return Spread(indices: [currentIndex], images: [first])
            }
        }

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
            // サイズ索引が両ページ分あればデコードなしで判定(後方めくりの
            // 逐次 2 デコード待ちを解消)。無ければ従来のデコード判定
            // EN: Judge from the size index when both sizes are known —
            // EN: no decodes on the backward turn; else the legacy path.
            if let firstSmall = await isSmallFromIndex(at: currentIndex - 2),
               let secondSmall = await isSmallFromIndex(at: currentIndex - 1) {
                if firstSmall, secondSmall {
                    currentIndex -= 2
                    return .moved
                }
            } else {
                let first = await image(at: currentIndex - 2)
                let second = await image(at: currentIndex - 1)
                if isSmall(first, at: currentIndex - 2),
                   isSmall(second, at: currentIndex - 1) {
                    currentIndex -= 2
                    return .moved
                }
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
            if let firstSmall = await isSmallFromIndex(at: entries.count - 2),
               let secondSmall = await isSmallFromIndex(at: entries.count - 1) {
                if firstSmall, secondSmall {
                    currentIndex = entries.count - 2
                    return
                }
            } else {
                let first = await image(at: entries.count - 2)
                let second = await image(at: entries.count - 1)
                if isSmall(first, at: entries.count - 2),
                   isSmall(second, at: entries.count - 1) {
                    currentIndex = entries.count - 2
                    return
                }
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
        // 並列幅は置き場所の速度で決める(SSD=6 / HDD=1 / ネットワーク=2)
        // EN: Prefetch width follows the volume-speed profile.
        let width = max(1, mediaProfile.bookPrefetchConcurrency)
        let source = source

        prefetchTask = Task { [weak self] in
            guard let self else { return }
            // solid 書庫のストリーム巻き戻しを避けるため、並列可否は
            // ソースの「現在の状態」(スプール完了・形式)で判断する
            // EN: Parallel-ness is decided from the source's CURRENT state so
            // EN: solid archives never extract out of order.
            let parallel = await source.currentlySupportsParallelPageLoads()
            if parallel {
                await withTaskGroup(of: Void.self) { group in
                    var iterator = targets.makeIterator()
                    for _ in 0..<width {
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
