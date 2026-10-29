import CoreGraphics
import Foundation

/// 開いている 1 冊の本。ページ列(ソート適用済み)・現在位置・見開き判定・
/// キャッシュ・先読みを束ねる。UI から使うため MainActor に置く。
///
/// 旧実装の「nowPage の二重意味」(仕様書 §1.4)は持ち込まず、
/// `currentIndex` は常に「表示中スプレッドの先頭ページ(読み順)」を指す。
@MainActor
final class Book {
    let source: any BookSource
    private(set) var entries: [PageEntry] {
        didSet {
            entriesGeneration &+= 1
            resampleLayouts.removeAll()
            evictedResampleKeys.removeAll()
        }
    }
    private(set) var entriesGeneration = 0
    private var placeholderGeneration = -1
    private var cachedReflowPlaceholders: [(index: Int, url: URL)] = []
    private(set) var reflowPlaceholderScanCount = 0

    /// 毎ページの全件走査を避け、同数の並べ替えも世代で失効させる(設計書 §7.4)。
    var reflowPlaceholders: [(index: Int, url: URL)] {
        if placeholderGeneration != entriesGeneration {
            cachedReflowPlaceholders = entries.enumerated().compactMap { index, entry in
                entry.reflowEPUBURL.map { (index: index, url: $0) }
            }
            placeholderGeneration = entriesGeneration
            reflowPlaceholderScanCount += 1
        }
        return cachedReflowPlaceholders
    }
    let missingVolumeCount: Int
    var isSyntheticPreview = false
    var isPartial: Bool { missingVolumeCount > 0 }
    var incompleteSuffix: String {
        Self.incompleteSuffix(missingVolumeCount: missingVolumeCount)
    }

    nonisolated static func incompleteSuffix(missingVolumeCount count: Int) -> String {
        guard count > 0 else { return "" }
        return String(localized: " (\(count) volumes missing)")
    }

    private(set) var currentIndex = 0 {
        didSet { if currentIndex != oldValue { stateRevision &+= 1 } }
    }
    private(set) var sortMode: SortMode
    var readMode: ReadMode = .rightToLeftSpread {
        didSet { if readMode != oldValue { invalidateSpreadLayout() } }
    }
    var marks = PageMarks() {
        didSet { if marks != oldValue { invalidateSpreadLayout() } }
    }
    var singleSetting = PageLayout.defaultSingleSetting {
        didSet { if singleSetting != oldValue { invalidateSpreadLayout() } }
    }
    /// 見開きモードで先頭ページ(表紙)を単ページにする(新機能・既定オフ)。
    /// marks の強制ペア指定(§4.2.1)はこれより優先される
    var coverSingleFirst = false {
        didSet { if coverSingleFirst != oldValue { invalidateSpreadLayout() } }
    }
    var bookmarks: [PageBookmark] = []

    /// 表示用デコードの長辺上限(px)。原寸表示は fullResolutionImage(at:) を使う
    /// (設計書「キャッシュ・先読み設計」)。nil で無制限。
    private(set) var displayPixelCap: Int? = ReadingResourceDefaults.displayPixelCap

    /// サムネイル等のディスクキャッシュ用の同一性キー(パス+更新日時+サイズ由来)
    let cacheKey: String

    private let cache: PageCache
    private let resampler: ImageResampler
    private let sorter: any PageSorting
    private var prefetchTask: Task<Void, Never>?
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    private var decodeTasks: [Int: Task<ImageLoadResult, Never>] = [:]
    private var isClosed = false
    private var lastDisplayCount = 1
    private var lastReadingPosition: (volume: Int, forward: Bool, generation: Int)?
    // 復旧後の別 Book も同じソースを使うため、通知の連番はプロセス全体で共有する。
    private static var readingPositionSequence: UInt64 = 0
    /// 別 Book の表示更新も含め、遅着した保持要求で現在見開きを追い出さない(設計書 §7.3)。
    private static var strongRetentionSequence: UInt64 = 0
    /// 見開き取得は同じ位置・並び・配置条件で完了した結果だけを採用する。
    /// ナビゲーション世代は後発のジャンプ/設定変更で旧判定を失効させる一方、
    /// 後退どうしの競合では位置を取り直して全操作を反映する(設計書 §7.3)。
    private var stateRevision = 0
    private var navigationGeneration = 0
    /// 設定編集による再描画世代と、保存位置を変更する明示ナビゲーションを分ける(設計書 §7.4)。
    private(set) var explicitNavigationRevision = 0
    /// 直近の移動方向(先読み・事前リサンプルの向きの決定に使う)
    private(set) var lastMoveForward = true

    /// アニメーション判定で「静止画」と分かったページ(entry.id)。
    /// 表示のたびに生データを読み直して判定し直すのを防ぐ
    var probedStaticAnimationIDs: Set<Int> = []

    /// 先読み枚数(設計書「キャッシュ・先読み設計」。設定「高度」または
    /// メディアプロファイルから注入される。既定は SSD 想定の値)
    var prefetchAhead = ReadingResourceDefaults.prefetchAhead
    var prefetchBehind = ReadingResourceDefaults.prefetchBehind
    /// 置き場所の速度プロファイル(先読み並列度・サムネイル並列度の根拠)
    var mediaProfile: MediaProfile = .unknown

    /// 表示すべきページの組。images の nil は「読めないページ」
    /// (呼び出し側が壊れ画像プレースホルダを当てる。仕様書 §4.17)。
    struct Spread {
        let indices: [Int]
        let images: [CGImage?]
        /// 設計書 §5: 完成画像を元画像と区別し、ルーペや再補間へ流用しない。
        var resampledPages: [ResampledPage]? = nil
        var decodedSources: [DecodedPageInfo]? = nil
    }

    struct DisplayCandidate {
        let indices: [Int]
        let sources: [DecodedPageInfo]
        fileprivate let revision: Int
    }

    private var decodedPageInfo: [Int: DecodedPageInfo] = [:]
    private var resampleLayouts: [Int: [Int]] = [:]
    private var resampledDisplayContext: String?
    private var evictedResampleKeys: [Int: String] = [:]
    private(set) var spreadLayoutRevision = 0

    enum MoveResult {
        case moved
        case hitStart  // 巻頭超え(loopCheck 処理は呼び出し側)
        case hitEnd    // 巻末超え(同上)
        case superseded  // 待機中のジャンプ/設定変更により失効。端の処理を行わない
    }

    /// 初期ソートと同一性キーはメインアクター外で済ませた結果(prepare)を受け取る。
    /// 実際に開く経路は open(source:) を使う
    init(source: any BookSource, prepared: PreparedEntries,
         sortMode: SortMode = .name, cacheByteLimit: Int = 512 * 1024 * 1024,
         sorter: any PageSorting = StandardPageSorter(), resampler: ImageResampler = .shared) {
        self.source = source
        self.sortMode = sortMode
        self.entries = prepared.sortedEntries
        self.missingVolumeCount = prepared.sortedEntries.filter { $0.unreadableVolume != nil }.count
        self.cache = PageCache(byteLimit: cacheByteLimit)
        self.resampler = resampler
        self.cacheKey = prepared.cacheKey
        self.sorter = sorter
    }

    static func open(source: any BookSource, sortMode: SortMode = .name,
                     cacheByteLimit: Int = 512 * 1024 * 1024,
                     probe: any FileSystemProbing = FileManagerProbe(),
                     sorter: any PageSorting = StandardPageSorter()) async throws -> Book {
        let entries = try await source.entries()
        // 名前順ソート(2 万件で約 100ms)と本ファイルの stat(NAS では数 ms、
        // 死んだマウントでは SMB タイムアウトまで)はメインアクターを止めない
        // よう別タスクで済ませる
        let url = source.url
        let prepared = await Task.detached(priority: .userInitiated) {
            let identity = await probe.identity(at: url)
            return prepare(url: url, entries: entries, sortMode: sortMode,
                           identity: identity, sorter: sorter)
        }.value
        return Book(source: source, prepared: prepared, sortMode: sortMode,
                    cacheByteLimit: cacheByteLimit, sorter: sorter)
    }

    /// init に渡す「メインアクター外で済ませておく計算」の結果
    struct PreparedEntries: Sendable {
        let sortedEntries: [PageEntry]
        let cacheKey: String

        /// 開けなかった本の空プレースホルダ用。ページが無いのでキャッシュキーは
        /// 使われず、stat を省いてメインアクター上で即座に作れる
        static func empty(for url: URL) -> PreparedEntries {
            PreparedEntries(sortedEntries: [],
                            cacheKey: makeCacheKey(for: url, entries: [], identity: .init()))
        }
    }

    /// identity は呼び出し側が probe で取っておく(stat だけが await を要し、
    /// ソートとキー計算は同期の純関数のまま)
    nonisolated static func prepare(url: URL, entries: [PageEntry], sortMode: SortMode,
                                    identity: BookFileIdentity,
                                    sorter: any PageSorting = StandardPageSorter())
        -> PreparedEntries {
        PreparedEntries(sortedEntries: sorter.sorted(entries, mode: sortMode),
                        cacheKey: makeCacheKey(for: url, entries: entries, identity: identity))
    }

    /// 本の同一性キー。ファイル情報に加えて**エントリ一覧のダイジェスト**を
    /// 混ぜる: フォルダの本はサブフォルダ内だけの変更や同名上書きで親の
    /// 更新日時が変わらないため、ファイル情報だけでは古いサムネイルが残る。
    /// エントリ側のダイジェストは順序非依存(ソート・シャッフルの影響なし)。
    /// 第2版はパスと ID の対応も含め、書庫の副ファイル方針変更による番号の
    /// 振り直しでサムネイル・超解像が別ページへ当たるのを防ぐ(設計書 §5)。
    nonisolated static func makeCacheKey(for url: URL, entries: [PageEntry],
                                         identity: BookFileIdentity) -> String {
        let seed = "pages-v2|\(url.path)|\(identity.modified)|\(identity.size)"
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
            let entrySeed = "\(entry.id)|\(entry.pathInBook)|\(entry.modificationDate?.timeIntervalSince1970 ?? 0)"
            var entryHash1: UInt64 = 5381
            var entryHash2: UInt64 = 52711
            for byte in entrySeed.utf8 {
                entryHash1 = entryHash1 &* 33 &+ UInt64(byte)
                entryHash2 = entryHash2 &* 37 &+ UInt64(byte)
            }
            // 同じ長さのパス同士で ID を交換しても加算で相殺しないよう混ぜる(設計書 §5)。
            entryHash1 = (entryHash1 ^ (entryHash1 >> 30)) &* 0xbf58_476d_1ce4_e5b9
            entryHash2 = (entryHash2 ^ (entryHash2 >> 27)) &* 0x94d0_49bb_1331_11eb
            sum1 &+= entryHash1
            sum2 &+= entryHash2
        }
        return String(format: "%016llx%016llx", hash1 ^ sum1, hash2 ^ sum2)
    }

    var pageCount: Int { entries.count }
    var displayName: String { source.displayName }
    var currentPageIndex: Int { currentIndex }

    /// ComicInfo.xml メタデータ(read-only ヒント。cooViewer-4fi.2)。一度成功したら
    /// キャッシュする。暗号化書庫は解錠後に呼ぶこと(未解錠の nil は焼き付けず、
    /// 後の呼び出しで再取得できるようにする)
    private var comicInfoCache: ComicInfo?
    func comicInfo() async -> ComicInfo? {
        if let cached = comicInfoCache { return cached }
        let info = await source.metadata()
        if info != nil { comicInfoCache = info }
        return info
    }

    /// ウインドウ表示名。ComicInfo があればそのタイトル、無ければファイル名
    /// (displayName)。ファイル名はファイル情報窓で確認できる(cooViewer-4fi.3)
    func displayTitle() async -> String {
        await comicInfo()?.displayTitle ?? displayName
    }

    /// ComicInfo の章(目次)を実ページへ写像したもの(cooViewer-4fi.6)。
    /// メニューから同期参照するため open 時に loadChapterMarks() で構築する。
    /// image は 0 始まりのページ番号として扱い、実ページ範囲外の章は捨てる
    /// (PageCount と実ページ数のズレ耐性)
    private(set) var chapterMarks: [(page: Int, name: String)] = []

    /// ComicInfo が「単ページ(見開きにしない)」と示すページ(DoublePage /
    /// FrontCover)と、ソースの規範的な単ページ指定を実ページへ写像した集合。
    /// ComicInfo は useLayoutHints オプトイン時だけ、EPUB page-spread は無条件で
    /// 構築する(cooViewer-bt1/oxr.40、仕様書 §4.2.1)。isSmall の判定に渡す
    private(set) var comicSingleIndices: Set<Int> = [] {
        didSet { if comicSingleIndices != oldValue { invalidateSpreadLayout() } }
    }

    /// open 時に ComicInfo 由来の状態(章メニュー・見開き補助)をまとめて構築する。
    /// image は 0 始まりページとして実ページへ写像し、範囲外は捨てる
    /// (PageCount と実ページ数のズレ耐性)
    func loadComicInfoState(useLayoutHints: Bool) async {
        let info = isPartial ? nil : await comicInfo()
        let count = pageCount
        chapterMarks = Array((info?.chapters ?? []).compactMap { chapter -> (page: Int, name: String)? in
            guard chapter.image >= 0, chapter.image < count else { return nil }
            return (page: chapter.image, name: chapter.name)
        }.prefix(5000))
        let metadataIndices: Set<Int>
        if useLayoutHints, let pages = info?.pages {
            metadataIndices = Set(pages.compactMap { page in
                guard page.image >= 0, page.image < count,
                      page.doublePage || page.type == .frontCover else { return nil }
                return page.image
            })
        } else {
            metadataIndices = []
        }
        // page-spread は EPUB の規範的な配置指定なので、ComicInfo の設定ゲートを
        // 通さず常に統合する(cooViewer-oxr.40、仕様書 §4.2.1)。
        let sourceIndices = Set((await source.layoutSinglePageIndices()).filter {
            $0 >= 0 && $0 < count
        })
        comicSingleIndices = metadataIndices.union(sourceIndices)
    }

    // MARK: - アクティビティ窓向けの実態アクセサ

    /// 進行中デコード件数(実態)
    var inFlightLoadCount: Int { inFlightLoads.count }
    /// 表示中スプレッドの枚数(1 か 2)
    var displayedPageCount: Int { lastDisplayCount }
    /// デコード用ページキャッシュの件数・使用バイト(実態)と実効上限(圧迫段階適用後)
    func pageCacheStats() -> (count: Int, cost: Int, limit: Int) {
        (cache.count, cache.currentCost, cache.byteLimit)
    }

    /// 圧迫段階をキャッシュへ同期的に適用する。キャッシュ自身も通知で追従するが、
    /// 先読みの再計画が新しい実効上限を読めるよう呼び出し側が先に適用する(冪等。設計書 §5)
    func applyMemoryPressure(_ level: MemoryPressureLevel) {
        cache.applyMemoryPressure(level)
    }

    // MARK: - 画像ロード

    /// ソースキャッシュも縮小復号時の出力先を含む名前空間で管理する(設計書 §5)。
    private var decodeColorTarget: DisplayColorTarget?
    private var decodeColorIdentity: String { decodeColorTarget?.identity ?? "source" }

    @discardableResult
    func updateDisplayColorTarget(_ target: DisplayColorTarget) -> Bool {
        guard target != decodeColorTarget else { return false }
        decodeColorTarget = target
        stateRevision &+= 1
        cache.removeAll()
        decodedPageInfo.removeAll()
        evictedResampleKeys.removeAll()
        declineQueuedPrefetchLoads()
        inFlightLoads.removeAll()
        return true
    }

    /// 辞退だけを合流側で再試行できるよう、通常の復号失敗と区別する(CV5-2)。
    private struct ImageLoadResult: Sendable {
        let image: CGImage?
        let declined: Bool
    }
    /// 進行中のデコード(entry.id → タスク)。表示要求が先読みの進行中
    /// デコードに合流し、同じページを二重にデコードしないための単一飛行
    private var inFlightLoads: [Int: (token: Int, prefetch: Bool, promotion: DecodePromotion?, task: Task<ImageLoadResult, Never>)] = [:]
    private var inFlightToken = 0

    func image(at index: Int) async -> CGImage? {
        guard !isClosed, entries.indices.contains(index), !Task.isCancelled else { return nil }
        let key = entries[index].id
        if let hit = cache.image(for: key, colorSpaceIdentity: decodeColorIdentity) { return hit }
        let joinedPrefetch = inFlightLoads[key]?.prefetch == true
        guard let task = beginImageLoad(at: index) else { return nil }
        let result = await task.value
        // 辞退した先読みに合流した表示だけを再試行し、通常の復号失敗は焼き直さない(設計書 §5、§7.3)。
        if result.declined, joinedPrefetch, !PageRequestIntent.isPrefetch, !isClosed, !Task.isCancelled {
            if let hit = cache.image(for: key, colorSpaceIdentity: decodeColorIdentity) { return hit }
            // 再計画された先読みに戻らず、別の表示が再発行済みならそこへ合流する(設計書 §5、§7.3)。
            return await beginImageLoad(at: index, replacingPrefetch: true)?.value.image
        }
        return result.image
    }

    /// 待機を伴う呼び出しから所有者を切り離し、先読みが本の寿命を延ばさないようにする(設計書 §5、§7.3)。
    private func beginImageLoad(at index: Int, replacingPrefetch: Bool = false) -> Task<ImageLoadResult, Never>? {
        guard !isClosed, !Task.isCancelled, entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        let key = entry.id
        if cache.image(for: key, colorSpaceIdentity: decodeColorIdentity) != nil { return nil }
        let prefetch = PageRequestIntent.isPrefetch
        let display = PageRequestIntent.isDisplay && !prefetch
        if let running = inFlightLoads[key], !replacingPrefetch || !running.prefetch {
            if !prefetch {
                // 待機解除より先に優先度を上げ、既に実行中の復号にも表示の優先度を届ける(設計書 §5)。
                running.task.escalatePriority(to: .userInitiated)
                running.promotion?.promote()
            }
            return running.task
        }
        // detached: 先読みのキャンセルが、合流している表示要求まで
        // 巻き込まないように独立タスクで走らせる
        let source = source
        let cap = displayPixelCap
        let colorTarget = decodeColorTarget
        let promotion = prefetch ? DecodePromotion() : nil
        inFlightToken &+= 1
        let token = inFlightToken
        let task = Task<ImageLoadResult, Never>.detached(priority: prefetch ? .utility : .userInitiated) { [weak self] in
            let result = await PageRequestIntent.$isDisplay.withValue(display) {
                await PageRequestIntent.$isPrefetch.withValue(prefetch) {
                    do {
                        let image = try await PageRequestIntent.$displayColorTarget.withValue(colorTarget) {
                            try await PageRequestIntent.$decodePromotion.withValue(promotion) {
                                try Task.checkCancellation()
                                let image = try await source.image(for: entry, maxPixelSize: cap)
                                try Task.checkCancellation()
                                return image
                            }
                        }
                        return ImageLoadResult(image: image, declined: false)
                    } catch is PrefetchDecodeGate.Declined {
                        return ImageLoadResult(image: nil, declined: true)
                    } catch BookSourceError.temporarilyUnavailable {
                        return ImageLoadResult(image: nil, declined: true)
                    } catch {
                        return ImageLoadResult(image: nil, declined: false)
                    }
                }
            }
            // 合流側も同じ完了を待つため、画像と寸法を公開してから結果を返す(設計書 §7.3)。
            return await MainActor.run { [weak self] in
                self?.completeImageLoad(result, for: key, token: token) ?? result
            }
        }
        inFlightLoads[key] = (token, prefetch, promotion, task)
        decodeTasks[token] = task
        return task
    }

    private func completeImageLoad(_ result: ImageLoadResult, for key: Int, token: Int) -> ImageLoadResult {
        decodeTasks[token] = nil
        // 上限の値が一周しても旧要求は復活させない。失効と登録を同じ
        // MainActor で完結させ、古い小画像が新しい大画像を上書きするのを防ぐ。
        guard inFlightLoads[key]?.token == token else { return result }
        inFlightLoads[key] = nil
        if let image = result.image {
            // 上限を下げただけなら大画像を活かす。上げた場合は上の世代照合で除外される。
            cache.insert(image, for: key, colorSpaceIdentity: decodeColorIdentity)
            evictedResampleKeys[key] = nil
            decodedPageInfo[key] = DecodedPageInfo(image)
            if pageSizeCache[key] == nil {
                // キャップ付きデコードでも縦横比は保たれるため判定に使える
                pageSizeCache[key] = CGSize(width: image.width, height: image.height)
            }
        }
        return result
    }

    /// 原寸表示・書き出し用: キャッシュと表示上限を介さずフル解像度でデコードする。
    func fullResolutionImage(at index: Int) async -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        return try? await source.image(for: entries[index], maxPixelSize: nil)
    }

    /// ページ寸法の索引(entry.id → 寸法)。ヘッダ読みやデコード結果から
    /// 埋まり、見開き判定(縦横比)をデコードなしで行えるようにする
    private var pageSizeCache: [Int: CGSize] = [:]

    private func pageSize(at index: Int) async -> CGSize? {
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        let key = entry.id
        if let cached = pageSizeCache[key] { return cached }
        if let hit = cache.image(for: key, colorSpaceIdentity: decodeColorIdentity) {
            let size = CGSize(width: hit.width, height: hit.height)
            pageSizeCache[key] = size
            return size
        }
        if let size = await source.imageSize(for: entry) {
            pageSizeCache[key] = size
            return size
        }
        return nil
    }

    /// サイズ索引による見開き候補判定。寸法が取れなければ nil(従来判定へ)
    private func isSmallFromIndex(at index: Int) async -> Bool? {
        // 巻の代理ページを単独にし、EPUB 入場や欠落の案内を隣の画像へ埋め込まない(仕様書 §4.17、設計書 §7.4、§2.4)。
        if entries.indices.contains(index), entries[index].isStandalonePage {
            return false
        }
        guard let size = await pageSize(at: index) else { return nil }
        return PageLayout.isSmall(size: size, index: index,
                                  marks: marks, singleSetting: singleSetting,
                                  coverSingle: coverSingleFirst,
                                  comicSingleIndices: comicSingleIndices)
    }

    /// 表示デコード上限の更新。上げた場合は低解像度の既存キャッシュを破棄する
    /// (ウインドウ拡大・原寸表示切替時。下げた場合は大きい画像を使い続ける)
    func updateDisplayPixelCap(_ cap: Int?) -> Bool {
        guard cap != displayPixelCap else { return false }
        let raised = (cap ?? Int.max) > (displayPixelCap ?? Int.max)
        displayPixelCap = cap
        if raised {
            stateRevision &+= 1
            cache.removeAll()
            decodedPageInfo.removeAll()
            evictedResampleKeys.removeAll()
            // 旧キャップで進行中のデコードには合流させない(新規要求は
            // 新キャップで作り直す。旧タスクの結果は登録世代の照合で捨てられる)
            declineQueuedPrefetchLoads()
            inFlightLoads.removeAll()
        }
        return raised
    }

    private func isSmall(_ image: CGImage?, at index: Int) -> Bool {
        // 寸法索引がなくても巻の代理ページを単独に保つ(設計書 §7.4、§2.4)。
        if entries.indices.contains(index), entries[index].isStandalonePage {
            return false
        }
        guard let image else { return false }
        return PageLayout.isSmall(
            size: CGSize(width: image.width, height: image.height),
            index: index, marks: marks, singleSetting: singleSetting,
            coverSingle: coverSingleFirst,
            comicSingleIndices: comicSingleIndices
        )
    }

    /// 現在位置のスプレッドを確定する(仕様書 §4.2.4 の見開き判定を再現)。
    func currentSpread() async -> Spread {
        while !isClosed, !entries.isEmpty, !Task.isCancelled {
            let revision = stateRevision
            noteReadingPositionIfNeeded()
            let spread = await PageRequestIntent.$isDisplay.withValue(true) {
                await loadSpread(at: currentIndex)
            }
            // 旧ページの取得中に位置/ソート/見開き条件が変わったら再計算する。
            // 画像と番号の対応、次ページの送り幅を同じ状態で確定するため。
            // 取消し後の欠けた取得結果で、画面に残る見開きの送り幅を変えない(設計書 §5、§7.3)。
            guard revision == stateRevision, !Task.isCancelled else { continue }
            finishCurrentSpread(spread.indices)
            return spread
        }
        return Spread(indices: [], images: [])
    }

    private func finishCurrentSpread(_ indices: [Int]) {
        lastDisplayCount = indices.count
        noteResampleLayout(indices)
        scheduleStrongIntermediateRetention()
        schedulePrefetch()
    }

    /// 設計書 §5: 未表示の先行リサンプルも、ジャンプ後には同じ距離解放の対象にする。
    func noteResampleLayout(_ indices: [Int]) {
        guard !isClosed, resampledDisplayContext != nil, let first = indices.first,
              indices.allSatisfy({ entries.indices.contains($0) }) else { return }
        resampleLayouts[first] = indices
    }

    /// 設計書 §5: 表示条件が変わったら先読みの省略情報も失効させ、旧サイズで復号を抑止しない。
    func updateResampledDisplayContext(_ context: String?) {
        guard context != resampledDisplayContext else { return }
        resampledDisplayContext = context
        evictedResampleKeys.removeAll()
        stateRevision &+= 1
    }

    func decodedSources(at indices: [Int]) -> [DecodedPageInfo]? {
        let sources = indices.compactMap { index -> DecodedPageInfo? in
            guard entries.indices.contains(index),
                  let info = decodedPageInfo[entries[index].id], !info.preservesHDR else { return nil }
            return info
        }
        return !indices.isEmpty && sources.count == indices.count ? sources : nil
    }

    func hasMissingOriginal(at indices: [Int]) -> Bool {
        indices.contains { entries.indices.contains($0)
            && !cache.contains(entries[$0].id, colorSpaceIdentity: decodeColorIdentity) }
    }

    /// 設計書 §5: 既知の配置だけで照会し、初回・前方の通常表示にヘッダ I/O や actor 待ちを足さない。
    func resampledDisplayCandidate() -> DisplayCandidate? {
        guard !isClosed, resampledDisplayContext != nil, entries.indices.contains(currentIndex) else { return nil }
        var indices = [currentIndex]
        if readMode.isSpread, currentIndex + 1 < entries.count {
            func small(_ index: Int) -> Bool? {
                if entries[index].isStandalonePage { return false }
                guard let size = pageSizeCache[entries[index].id] else { return nil }
                return PageLayout.isSmall(size: size, index: index, marks: marks,
                    singleSetting: singleSetting, coverSingle: coverSingleFirst,
                    comicSingleIndices: comicSingleIndices)
            }
            let first = small(currentIndex)
            if first != false {
                let second = small(currentIndex + 1)
                guard first != nil, second != nil else { return nil }
                if first == true, second == true { indices.append(currentIndex + 1) }
            }
        }
        guard indices.contains(where: hasCachedResampleForEvictedOriginal),
              hasMissingOriginal(at: indices), let sources = decodedSources(at: indices) else { return nil }
        return DisplayCandidate(indices: indices, sources: sources, revision: stateRevision)
    }

    /// 設計書 §7.3: 照会中の位置・配置・復号条件の変更を弾いてから送り幅と先読みを確定する。
    func acceptResampledDisplay(_ candidate: DisplayCandidate, pages: [ResampledPage]) -> Spread? {
        guard !isClosed, !Task.isCancelled, candidate.revision == stateRevision,
              candidate.indices.first == currentIndex, pages.count == candidate.indices.count else { return nil }
        noteReadingPositionIfNeeded()
        finishCurrentSpread(candidate.indices)
        return Spread(indices: candidate.indices, images: pages.map { $0.image },
                      resampledPages: pages, decodedSources: candidate.sources)
    }

    /// 設計書 §5: 表示・先行計算の配置寸法を使い、片側だけの予測で誤った完成サイズを照会しない。
    func decodedRetentionCandidates() -> [DisplayCandidate] {
        guard !isClosed, resampledDisplayContext != nil else { return [] }
        // 設計書 §5: 解放済みの配置を走査対象から外し、読了枚数に比例するメインアクターの仕事を残さない。
        resampleLayouts = resampleLayouts.filter { _, indices in
            indices.contains { cache.contains(entries[$0].id, colorSpaceIdentity: decodeColorIdentity) }
        }
        let adjacent = strongIntermediateRetentionIndices()
        return resampleLayouts.values.compactMap { indices in
            guard indices.contains(where: { index in
                DecodedOriginalRetentionPolicy.canEvict(index: index, currentIndex: currentIndex,
                    decodeBehind: prefetchBehind, adjacentIndices: adjacent, protected: false, displayReady: true)
                    && cache.contains(entries[index].id, colorSpaceIdentity: decodeColorIdentity)
            }), let sources = decodedSources(at: indices) else { return nil }
            return DisplayCandidate(indices: indices, sources: sources, revision: stateRevision)
        }
    }

    /// 設計書 §5、§7.3: actor 照会後に再検査し、表示中・隣接・実行中・先読み予定の入力を守る。
    func evictDecodedOriginals(_ readyIndices: Set<Int>, candidate: DisplayCandidate,
                               pages: [ResampledPage], protectedPageKeys: Set<String>) {
        guard !isClosed, !Task.isCancelled, candidate.revision == stateRevision,
              pages.count == candidate.indices.count else { return }
        let adjacent = strongIntermediateRetentionIndices()
        let targets = Set(Self.prefetchTargets(currentIndex: currentIndex, displayCount: lastDisplayCount,
            ahead: prefetchAhead, behind: prefetchBehind, forward: lastMoveForward, count: entries.count,
            volumeKey: { source.prefetchVolumeKey(for: entries[$0]) }))
        for index in readyIndices where entries.indices.contains(index) {
            let id = entries[index].id
            let protected = targets.contains(index) || inFlightLoads[id] != nil
                || protectedPageKeys.contains("\(cacheKey)#\(id)")
            if DecodedOriginalRetentionPolicy.canEvict(index: index, currentIndex: currentIndex,
                decodeBehind: prefetchBehind, adjacentIndices: adjacent,
                protected: protected, displayReady: true),
               cache.contains(id, colorSpaceIdentity: decodeColorIdentity),
               let position = candidate.indices.firstIndex(of: index),
               let key = ImageResampler.cacheIdentity(source: candidate.sources[position], to: pages[position].size,
                   cacheKey: "\(cacheKey)#\(id)", processing: pages[position].processing,
                   displayTarget: pages[position].colorTarget), resampler.cacheResidency.contains(key) {
                cache.remove(id, colorSpaceIdentity: decodeColorIdentity)
                evictedResampleKeys[id] = key
            }
        }
    }

    /// 設計書 §5: 完成画像の失効後も先読みを止め続けず、その場で通常の復号へ戻す。
    func hasCachedResampleForEvictedOriginal(at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        let id = entries[index].id
        guard let key = evictedResampleKeys[id] else { return false }
        guard resampler.cacheResidency.contains(key) else {
            evictedResampleKeys[id] = nil
            return false
        }
        return true
    }

    func clearResampledDisplayMiss(_ candidate: DisplayCandidate) {
        guard candidate.revision == stateRevision else { return }
        for index in candidate.indices { evictedResampleKeys[entries[index].id] = nil }
    }

    /// 設計書 §5: ペアと目標サイズが変わる設定は、復号先読みの省略情報も同時に失効させる。
    private func invalidateSpreadLayout() {
        spreadLayoutRevision &+= 1
        evictedResampleKeys.removeAll()
        resampleLayouts.removeAll()
        invalidatePendingNavigation()
    }

    /// 忙しい描画 actor をページ表示で待たず、close では全更新の排出後に条件を外す(設計書 §5、§7.3)。
    private func scheduleStrongIntermediateRetention() {
        let bookKey = cacheKey
        let pageKeys = Set(strongIntermediateRetentionIndices().map { "\(bookKey)#\(entries[$0].id)" })
        Self.strongRetentionSequence &+= 1
        let revision = Self.strongRetentionSequence
        let id = UUID()
        let task = Task<Void, Never>.detached(priority: .utility) { [weak self] in
            await ImageResampler.shared.retainStrongIntermediates(
                bookKey: bookKey, pageKeys: pageKeys, revision: revision)
            await MainActor.run { [weak self] in self?.backgroundTasks[id] = nil }
        }
        backgroundTasks[id] = task
    }

    /// ヘッダ I/O を増やさず、既知の配置だけで原寸中間画像の保持範囲を絞る(設計書 §5)。
    private func strongIntermediateRetentionIndices() -> Range<Int> {
        func small(_ index: Int) -> Bool? {
            guard entries.indices.contains(index) else { return false }
            if entries[index].isStandalonePage { return false }
            guard let size = pageSizeCache[entries[index].id] else { return nil }
            return PageLayout.isSmall(size: size, index: index, marks: marks,
                singleSetting: singleSetting, coverSingle: coverSingleFirst,
                comicSingleIndices: comicSingleIndices)
        }
        func pair(_ first: Int, _ second: Int) -> Bool? {
            guard readMode.isSpread else { return false }
            let a = small(first), b = small(second)
            if a == false || b == false { return false }
            return a == true && b == true ? true : nil
        }
        let next = currentIndex + lastDisplayCount
        return StrongIntermediateRetentionPolicy.retainedIndices(
            currentIndex: currentIndex, displayCount: lastDisplayCount, pageCount: entries.count,
            previousIsPair: pair(currentIndex - 2, currentIndex - 1),
            nextIsPair: pair(next, next + 1))
    }

    private func noteReadingPositionIfNeeded() {
        guard entries.indices.contains(currentIndex) else { return }
        let current = entries[currentIndex]
        let volume = source.prefetchVolumeKey(for: current)
        if let lastReadingPosition, lastReadingPosition.volume == volume,
           lastReadingPosition.forward == lastMoveForward, lastReadingPosition.generation == entriesGeneration { return }
        lastReadingPosition = (volume, lastMoveForward, entriesGeneration)
        // 今の巻だけを走査し、合本 actor や別の子を表示経路で待たない(cooViewer-tg48、設計書 §5)。
        var first = currentIndex
        var end = currentIndex + 1
        while first > 0, source.prefetchVolumeKey(for: entries[first - 1]) == volume { first -= 1 }
        while end < entries.count, source.prefetchVolumeKey(for: entries[end]) == volume { end += 1 }
        let previous = first > 0 ? entries[first - 1] : nil
        let next = end < entries.count ? entries[end] : nil
        let source = source
        let forward = lastMoveForward
        Self.readingPositionSequence += 1
        let sequence = Self.readingPositionSequence
        let id = UUID()
        backgroundTasks[id] = Task { [weak self] in
            if !Task.isCancelled {
                await source.noteReadingPosition(current: current, next: next, previous: previous, forward: forward, sequence: sequence)
            }
            self?.backgroundTasks[id] = nil
        }
    }

    private func loadSpread(at index: Int) async -> Spread {
        if readMode.isSpread, index + 1 < entries.count {
            let firstSmall = await isSmallFromIndex(at: index)
            let secondSmall = firstSmall == false ? false : await isSmallFromIndex(at: index + 1)
            if firstSmall == true, secondSmall == true {
                async let firstTask = image(at: index)
                async let secondTask = image(at: index + 1)
                let (first, second) = await (firstTask, secondTask)
                if first != nil, second != nil {
                    return Spread(indices: [index, index + 1], images: [first, second])
                }
                return Spread(indices: [index], images: [first])
            }
            if firstSmall != false, secondSmall != false {
                // solid の主復号器を競合させないため、通常先読みと同じ窓の並列可否を守る。
                // 許可時だけ二枚目を先読みし、ペア成立時に昇格させる(設計書 §5、§7.3)。
                let ids = [entries[index].id, entries[index + 1].id]
                if await source.currentlySupportsParallelPageLoads(forEntryIDs: ids) {
                    _ = beginImageLoad(at: index)
                    PageRequestIntent.$isPrefetch.withValue(true) {
                        _ = beginImageLoad(at: index + 1)
                    }
                }
                let first = await image(at: index)
                if isSmall(first, at: index) {
                    let second = await image(at: index + 1)
                    if isSmall(second, at: index + 1) {
                        return Spread(indices: [index, index + 1], images: [first, second])
                    }
                }
                return Spread(indices: [index], images: [first])
            }
        }
        let first = await image(at: index)
        return Spread(indices: [index], images: [first])
    }

    // MARK: - ナビゲーション(仕様書 §4.3)

    /// 指追従の仮移動を取り消すための復元点。同じ番号への再ジャンプも
    /// 別操作なので、位置とナビゲーション世代を組にして照合する。
    struct NavigationCheckpoint {
        fileprivate let index: Int
        fileprivate let generation: Int
        fileprivate let explicitNavigationRevision: Int
        fileprivate let displayCount: Int
        fileprivate let forward: Bool
    }

    var navigationCheckpoint: NavigationCheckpoint {
        NavigationCheckpoint(index: currentIndex, generation: navigationGeneration,
                             explicitNavigationRevision: explicitNavigationRevision,
                             displayCount: lastDisplayCount, forward: lastMoveForward)
    }

    func isAtNavigationCheckpoint(_ checkpoint: NavigationCheckpoint) -> Bool {
        currentIndex == checkpoint.index && navigationGeneration == checkpoint.generation
    }

    /// 仮移動の後に別操作がなければ、表示枚数・先読み方向も同期で復元する。
    /// 逆方向へ再判定すると I/O 待機を挟み、後続入力を巻き戻すおそれがある。
    @discardableResult
    func restoreNavigation(_ origin: NavigationCheckpoint,
                           ifUnchanged destination: NavigationCheckpoint) -> Bool {
        guard isAtNavigationCheckpoint(destination) else { return false }
        goTo(index: origin.index)
        // 仮移動の取消しは読者の移動ではないため、保存位置を守る操作回数も戻す(設計書 §7.4)。
        explicitNavigationRevision = origin.explicitNavigationRevision
        lastDisplayCount = origin.displayCount
        lastMoveForward = origin.forward
        return true
    }

    func moveNext() -> MoveResult {
        invalidatePendingNavigation()
        guard !entries.isEmpty else { return .hitEnd }
        guard currentIndex + lastDisplayCount < entries.count else { return .hitEnd }
        explicitNavigationRevision &+= 1
        currentIndex += lastDisplayCount
        lastMoveForward = true
        return .moved
    }

    func movePrevious(ifUnchanged checkpoint: NavigationCheckpoint? = nil) async -> MoveResult {
        let generation = navigationGeneration
        while generation == navigationGeneration, !Task.isCancelled {
            if let checkpoint, !isAtNavigationCheckpoint(checkpoint) { return .superseded }
            let anchor = currentIndex
            guard !entries.isEmpty, anchor > 0 else { return .hitStart }
            guard let start = await precedingSpreadStart(before: anchor,
                                                         generation: generation) else {
                return .superseded
            }
            guard generation == navigationGeneration, !Task.isCancelled else {
                return .superseded
            }
            if let checkpoint, !isAtNavigationCheckpoint(checkpoint) { return .superseded }
            // 別の後退が先に完了した場合は、その位置からもう一度戻る。
            // ヘッダ待機中のキー連打を落とさず、負の位置への減算も防ぐ。
            guard anchor == currentIndex else { continue }
            explicitNavigationRevision &+= 1
            currentIndex = start
            lastMoveForward = false
            return .moved
        }
        return .superseded
    }

    /// 後退と巻末ジャンプは同じ「直前の最大2枚」の規則で判定する。
    /// 位置は引数で固定し、各 await 後に後発のジャンプ/設定変更を照合する。
    private func precedingSpreadStart(before end: Int, generation: Int) async -> Int? {
        guard generation == navigationGeneration, !Task.isCancelled else { return nil }
        guard readMode.isSpread, end >= 2 else { return end - 1 }
        let firstSmall = await isSmallFromIndex(at: end - 2)
        guard generation == navigationGeneration, !Task.isCancelled else { return nil }
        if firstSmall == false { return end - 1 }
        if let firstSmall {
            let secondSmall = await isSmallFromIndex(at: end - 1)
            guard generation == navigationGeneration, !Task.isCancelled else { return nil }
            if let secondSmall { return firstSmall && secondSmall ? end - 2 : end - 1 }
        }
        let first = await image(at: end - 2)
        guard generation == navigationGeneration, !Task.isCancelled else { return nil }
        let second = await image(at: end - 1)
        guard generation == navigationGeneration, !Task.isCancelled else { return nil }
        return isSmall(first, at: end - 2) && isSmall(second, at: end - 1)
            ? end - 2 : end - 1
    }

    /// 見開きから 1 ページだけ進む/戻る(仕様書 §5.5 action 2/3)
    func moveHalfNext() -> MoveResult {
        invalidatePendingNavigation()
        guard currentIndex + 1 < entries.count else { return .hitEnd }
        explicitNavigationRevision &+= 1
        currentIndex += 1
        lastMoveForward = true
        return .moved
    }

    func moveHalfPrevious() -> MoveResult {
        invalidatePendingNavigation()
        guard currentIndex > 0 else { return .hitStart }
        explicitNavigationRevision &+= 1
        currentIndex -= 1
        lastMoveForward = false
        return .moved
    }

    func goTo(index: Int) {
        invalidatePendingNavigation()
        guard !entries.isEmpty else { return }
        explicitNavigationRevision &+= 1
        currentIndex = min(max(0, index), entries.count - 1)
    }

    func goToFirst() {
        invalidatePendingNavigation()
        explicitNavigationRevision &+= 1
        currentIndex = 0
        lastMoveForward = true
    }

    /// 末尾へ。見開きなら最終 2 枚がペアになる場合 count-2 に着地(仕様書 §4.3.3)。
    @discardableResult
    func goToLast() async -> Bool {
        invalidatePendingNavigation()
        let generation = navigationGeneration
        guard !entries.isEmpty,
              let start = await precedingSpreadStart(before: entries.count,
                                                      generation: generation),
              generation == navigationGeneration, !Task.isCancelled else {
            return false
        }
        explicitNavigationRevision &+= 1
        currentIndex = start
        lastMoveForward = true
        return true
    }

    /// 現在位置を「先頭から組み直した見開き区分」に整列させる。
    /// ペア判定は仕様書 §4.2 どおり現在位置から局所的に決まるため、
    /// 表紙単ページや見開きしきい値の切替だけではページの区切り
    /// (偶奇)が変わらない。設定変更の瞬間はここで先頭起点の区分を
    /// 歩き直し、現在ページを含むスプレッドの先頭に着地させる。
    /// サイズ未取得のページは縦長(ペア可)とみなす(サムネイル一覧と
    /// 同じ収束方針)。強制指定(marks)は isSmall 側で常に優先される。
    @discardableResult
    func reanchorToLeadingPartition() async -> Bool {
        invalidatePendingNavigation()
        guard readMode.isSpread, currentIndex > 0 else { return true }
        let generation = navigationGeneration
        let target = currentIndex
        // サイズ未取得でも marks・表紙単ページの規則は適用したいので、
        // 不明なページは縦長サイズを仮定して通常判定に流す
        func assumedSmall(at index: Int) async -> Bool {
            // 再配置でも代理ページを隣の画像へ吸収させない(設計書 §7.4、§2.4)。
            if entries.indices.contains(index), entries[index].isStandalonePage {
                return false
            }
            let size = await pageSize(at: index) ?? CGSize(width: 70, height: 100)
            // comicSingleIndices を渡す(isSmallFromIndex/isSmall と対称に):
            // 再アンカーの歩き直しでも ComicInfo の DoublePage/FrontCover を尊重し、
            // 設定切替で現在ページを含まないスプレッド先頭に着地するズレを防ぐ
            return PageLayout.isSmall(size: size, index: index, marks: marks,
                                      singleSetting: singleSetting,
                                      coverSingle: coverSingleFirst,
                                      comicSingleIndices: comicSingleIndices)
        }
        var start = 0
        while start < target {
            var length = 1
            if start + 1 < entries.count,
               await assumedSmall(at: start),
               await assumedSmall(at: start + 1) {
                length = 2
            }
            guard generation == navigationGeneration, !Task.isCancelled else { return false }
            guard start + length <= target else { break }
            start += length
        }
        currentIndex = start
        return true
    }

    /// 次(forward)または前の方向へ、隣接するスプレッド列を予測する
    /// (合計 maxPages ページまで。現在位置は動かさない)。事前リサンプル用に
    /// ReaderWindowController が使う。ペア判定は moveNext/movePrevious と
    /// 同じ規則だが、サイズ索引で確定できない場合はデコードせず単ページと
    /// 予測する(先読みの完了後に確定するので外れても実害はない)。
    /// 途中のスプレッドを分割してまで maxPages に詰めることはしない。
    /// 端(次/前が無い)では空を返す
    func predictedAdjacentSpreads(forward: Bool, maxPages: Int) async -> [[Int]] {
        guard !entries.isEmpty, maxPages > 0 else { return [] }
        var result: [[Int]] = []
        var pages = 0
        if forward {
            var start = currentIndex + lastDisplayCount
            while start < entries.count, pages < maxPages {
                var spread = [start]
                if readMode.isSpread, start + 1 < entries.count,
                   await isSmallFromIndex(at: start) == true,
                   await isSmallFromIndex(at: start + 1) == true {
                    spread = [start, start + 1]
                }
                guard pages + spread.count <= maxPages else { break }
                result.append(spread)
                pages += spread.count
                start += spread.count
            }
        } else {
            var anchor = currentIndex
            while anchor > 0, pages < maxPages {
                var spread = [anchor - 1]
                if readMode.isSpread, anchor >= 2,
                   await isSmallFromIndex(at: anchor - 2) == true,
                   await isSmallFromIndex(at: anchor - 1) == true {
                    spread = [anchor - 2, anchor - 1]
                }
                guard pages + spread.count <= maxPages else { break }
                result.append(spread)
                pages += spread.count
                anchor = spread[0]
            }
        }
        return result
    }

    /// パーセントジャンプ(旧 goToPar)。上限クランプなしの旧仕様を維持し、
    /// 100% 以上は hitEnd を返す(仕様書 §13.3)。
    func goToPercent(_ percent: Double) -> MoveResult {
        guard !entries.isEmpty else { return .hitEnd }
        // percent が非有限・極端でも Int(Double) トラップしないよう安全変換。
        // 変換不能(巨大/NaN)は entries.count 扱い → 下の判定で hitEnd に落ちる
        let target = (Double(entries.count) * percent).safeInt ?? entries.count
        guard target < entries.count else { return .hitEnd }
        goTo(index: max(0, target))
        return .moved
    }

    /// スキップ(仕様書 §4.3.6 相当。value ページ分移動)
    func skip(by value: Int) {
        // 足す前に移動可能な範囲へ絞る。Int 全域の入力でも加算が溢れない。
        let delta = min(max(value, -currentIndex), max(0, pageCount - 1 - currentIndex))
        goTo(index: currentIndex + delta)
    }

    /// ソート変更。旧仕様通り先頭ページへ戻る(仕様書 §13.3 で「維持」判断)。
    /// モードは即時に確定し(連打で巡回が進む・保存が要求モードを記録する)、
    /// 並べ替え本体はメインアクター外で行う。完了までに別のモード変更が入って
    /// いたら古い結果は捨てる(sortGeneration。同じモードへ戻った場合も世代が
    /// 違えば捨てる)。どの並びからでも名前順に正規化してから適用するため、
    /// 途中の並びに依存せず最後のモードの結果になる。返す Task は並びが
    /// 適用されたかを返し、表示更新・初回描画はこれを待つ
    @discardableResult
    func setSortMode(_ mode: SortMode) -> Task<Bool, Never> {
        invalidatePendingNavigation()
        sortMode = mode
        sortGeneration &+= 1
        let generation = sortGeneration
        let snapshot = entries
        let sorter = sorter
        return Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                sorter.sorted(snapshot, mode: mode)
            }.value
            guard let self, !isClosed, !Task.isCancelled, generation == sortGeneration else { return false }
            invalidatePendingNavigation()
            entries = sorted
            // 並べ替えに伴う先頭への配置はページ移動の意思ではなく、明示移動には数えない(設計書 §7.4)。
            currentIndex = 0
            return true
        }
    }

    /// 並べ替え要求の世代。最後の要求の結果だけを採用する
    private var sortGeneration = 0

    /// 先読みを打ち切る(本の切替時に旧本の I/O・デコードを止める)
    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        declineQueuedPrefetchLoads()
    }

    private func declineQueuedPrefetchLoads() {
        for load in inFlightLoads.values where load.prefetch {
            load.promotion?.declineQueuedPrefetch()
        }
    }

    /// 取消し済みの親と独立デコードも待ち、破棄直後の参照解放を時刻に依存させない(設計書 §5、§7.3)。
    func waitForPrefetch() async {
        let tasks = Array(backgroundTasks.values)
        let decodes = Array(decodeTasks.values)
        for task in tasks { await task.value }
        for task in decodes { _ = await task.value }
    }

    /// 閉じた本は再計画・再合流させず、待機 I/O とデコードを取り消す。待機票は本を保持しない(設計書 §5、§7.3)。
    @discardableResult
    func close() -> Task<Void, Never> {
        isClosed = true
        invalidatePendingNavigation()
        for task in backgroundTasks.values { task.cancel() }
        for task in decodeTasks.values { task.cancel() }
        inFlightLoads.removeAll()
        let tasks = Array(backgroundTasks.values)
        let decodes = Array(decodeTasks.values)
        let bookKey = cacheKey
        return Task(priority: .utility) {
            for task in tasks { await task.value }
            for task in decodes { _ = await task.value }
            await ImageResampler.shared.removeStrongIntermediateRetention(bookKey: bookKey)
        }
    }

    deinit {
        prefetchTask?.cancel()
        for task in backgroundTasks.values { task.cancel() }
        for task in decodeTasks.values { task.cancel() }
    }

    private func invalidatePendingNavigation() {
        navigationGeneration &+= 1
        stateRevision &+= 1
        cancelPrefetch()
    }

    // MARK: - サブフォルダ移動(仕様書 §4.3.5: containerPath 単位で巡回)

    func nextSubFolderIndex() -> Int? {
        Self.nextSubFolderIndex(in: entries, from: currentIndex)
    }

    func previousSubFolderIndex() -> Int? {
        Self.previousSubFolderIndex(in: entries, from: currentIndex)
    }

    /// containerPath 単位で次の構成巻(サブフォルダ)先頭へ。合本内の EPUB 巻
    /// からも同じ規則で移動できるよう純関数として切り出す(監査 #7。テスト対象)
    static func nextSubFolderIndex(in entries: [PageEntry], from currentIndex: Int)
        -> Int? {
        guard entries.indices.contains(currentIndex) else { return nil }
        let current = entries[currentIndex].containerPath
        for offset in 1...entries.count {
            let index = (currentIndex + offset) % entries.count
            if entries[index].containerPath != current { return index }
        }
        return nil
    }

    static func previousSubFolderIndex(in entries: [PageEntry], from currentIndex: Int)
        -> Int? {
        guard entries.indices.contains(currentIndex) else { return nil }
        let current = entries[currentIndex].containerPath
        var index = currentIndex
        for _ in 1...entries.count {
            index = (index - 1 + entries.count) % entries.count
            if entries[index].containerPath != current {
                // 前グループの先頭へ(仕様書 §4.3.5)
                let target = entries[index].containerPath
                var first = index
                while first > 0, entries[first - 1].containerPath == target { first -= 1 }
                return first
            }
        }
        return nil
    }

    // MARK: - しおり移動

    func resolvedBookmarkIndex(_ bookmark: PageBookmark) -> Int? {
        if isPartial {
            return bookmark.pagePath.flatMap { path in entries.firstIndex { $0.pathInBook == path } }
        }
        return bookmark.pageIndex
    }

    var resolvedBookmarkIndices: [Int] { bookmarks.compactMap { resolvedBookmarkIndex($0) } }

    func nextBookmarkIndex() -> Int? {
        resolvedBookmarkIndices.filter { $0 > currentIndex }.min()
    }

    func previousBookmarkIndex() -> Int? {
        resolvedBookmarkIndices.filter { $0 < currentIndex }.max()
    }

    // MARK: - 先読み(仕様書 §4.5 の置換。設計書 §3.1)

    /// 現在ページ周辺の先読みを、現在の並列幅・深さ(mediaProfile / prefetchAhead 等)で
    /// やり直す。メディア速度プロファイルを後追い確定したとき等に使う(#1: 初回描画を
    /// プローブ待ちから切り離した後の再適用)。schedulePrefetch は旧タスクを cancel して
    /// 張り直すので再呼び出しは安全。
    func reschedulePrefetch() { schedulePrefetch() }

    static func prefetchTargets(currentIndex: Int, displayCount: Int, ahead: Int, behind: Int,
                                forward: Bool, count: Int, volumeKey: (Int) -> Int) -> [Int] {
        guard currentIndex >= 0, currentIndex < count else { return [] }
        let after = currentIndex + min(max(displayCount, 0), count - currentIndex)
        let aheadTargets = (0..<min(max(ahead, 0), count - after)).map { after + $0 }
        let behindTargets = (0..<min(max(behind, 0), currentIndex)).map { currentIndex - 1 - $0 }
            .filter { !forward || volumeKey($0) == volumeKey(currentIndex) }
        return forward ? aheadTargets + behindTargets : behindTargets + aheadTargets
    }

    static func serialOrder(_ targets: [(index: Int, id: Int, volume: Int)], aheadCount: Int) -> [Int] {
        var result: [Int] = []
        let boundary = min(max(0, aheadCount), targets.count)
        // 群と巻の順は保つ。外側 id は書庫 index、合本 id は子の entries() 順の offset
        // なので、同じ巻の id 昇順なら solid の巻き戻しを減らせる(仕様書 §4.5、設計書 §3.1)。
        for range in [0..<boundary, boundary..<targets.count] {
            var start = range.lowerBound
            while start < range.upperBound {
                var end = start + 1
                while end < range.upperBound, targets[end].volume == targets[start].volume { end += 1 }
                result.append(contentsOf: targets[start..<end].sorted { $0.id < $1.id }.map(\.index))
                start = end
            }
        }
        return result
    }

    private func schedulePrefetch() {
        cancelPrefetch()
        guard !isClosed else { return }
        // 同じ名前の source を宣言より前のクロージャで参照すると Xcode 26.6 のコンパイラが落ちる(ClosureLifetimeFixup)ため、クロージャより先にローカルへ取る。
        let source = source
        let entries = entries
        let targets = Self.prefetchTargets(currentIndex: currentIndex, displayCount: lastDisplayCount,
            ahead: prefetchAhead, behind: prefetchBehind, forward: lastMoveForward, count: entries.count,
            volumeKey: { source.prefetchVolumeKey(for: entries[$0]) })
        let captured = targets.map { (index: $0, id: entries[$0].id,
                                      volume: source.prefetchVolumeKey(for: entries[$0])) }
        let aheadCount = targets.filter { $0 > currentIndex }.count
        let leadingCount = lastMoveForward ? aheadCount : targets.count - aheadCount
        // 並列幅は置き場所の速度で決める(SSD=6 / HDD=1 / ネットワーク=2)
        let width = max(1, mediaProfile.bookPrefetchConcurrency)

        let targetIDs = targets.map { entries[$0].id }
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            // 非同期メソッドへの弱参照呼び出しも待機中は強参照になるため、所有者は同期登録時だけ借りる(設計書 §7.3)。
            await PageRequestIntent.$isPrefetch.withValue(true) {
                let parallel = await source.currentlySupportsParallelPageLoads(forEntryIDs: targetIDs)
                guard !Task.isCancelled else { return }
                if parallel {
                    await withTaskGroup(of: Void.self) { group in
                        var iterator = targets.makeIterator()
                        for _ in 0..<width {
                            if let target = iterator.next() {
                                let load = self?.beginPrefetchImageLoad(at: target)
                                group.addTask { _ = await load?.value }
                            }
                        }
                        while await group.next() != nil {
                            if Task.isCancelled { break }
                            if let target = iterator.next() {
                                let load = self?.beginPrefetchImageLoad(at: target)
                                group.addTask { _ = await load?.value }
                            }
                        }
                    }
                } else {
                    for target in Self.serialOrder(captured, aheadCount: leadingCount) {
                        guard !Task.isCancelled else { return }
                        let load = self?.beginPrefetchImageLoad(at: target)
                        _ = await load?.value
                    }
                }
            }
            self?.backgroundTasks[id] = nil
        }
        prefetchTask = task
        backgroundTasks[id] = task
    }

    /// 設計書 §5: 戻り読みの表示用完成画像を、復号先読みが元画像で埋め直すのを防ぐ。
    private func beginPrefetchImageLoad(at index: Int) -> Task<ImageLoadResult, Never>? {
        guard entries.indices.contains(index), !hasCachedResampleForEvictedOriginal(at: index) else { return nil }
        return beginImageLoad(at: index)
    }
}
