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
        didSet { entriesGeneration &+= 1 }
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
        didSet { if readMode != oldValue { invalidatePendingNavigation() } }
    }
    var marks = PageMarks() {
        didSet { if marks != oldValue { invalidatePendingNavigation() } }
    }
    var singleSetting = PageLayout.defaultSingleSetting {
        didSet { if singleSetting != oldValue { invalidatePendingNavigation() } }
    }
    /// 見開きモードで先頭ページ(表紙)を単ページにする(新機能・既定オフ)。
    /// marks の強制ペア指定(§4.2.1)はこれより優先される
    var coverSingleFirst = false {
        didSet { if coverSingleFirst != oldValue { invalidatePendingNavigation() } }
    }
    var bookmarks: [PageBookmark] = []

    /// 表示用デコードの長辺上限(px)。原寸表示は fullResolutionImage(at:) を使う
    /// (設計書「キャッシュ・先読み設計」)。nil で無制限。
    private(set) var displayPixelCap: Int? = ReadingResourceDefaults.displayPixelCap

    /// サムネイル等のディスクキャッシュ用の同一性キー(パス+更新日時+サイズ由来)
    let cacheKey: String

    private let cache: PageCache
    private let sorter: any PageSorting
    private var prefetchTask: Task<Void, Never>?
    private var lastDisplayCount = 1
    private var lastReadingPosition: (volume: Int, forward: Bool, generation: Int)?
    // 復旧後の別 Book も同じソースを使うため、通知の連番はプロセス全体で共有する。
    private static var readingPositionSequence: UInt64 = 0
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
    }

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
         sorter: any PageSorting = StandardPageSorter()) {
        self.source = source
        self.sortMode = sortMode
        self.entries = prepared.sortedEntries
        self.missingVolumeCount = prepared.sortedEntries.filter { $0.unreadableVolume != nil }.count
        self.cache = PageCache(byteLimit: cacheByteLimit)
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
    /// エントリ側のダイジェストは順序非依存(ソート・シャッフルの影響なし)
    nonisolated static func makeCacheKey(for url: URL, entries: [PageEntry],
                                         identity: BookFileIdentity) -> String {
        let seed = "\(url.path)|\(identity.modified)|\(identity.size)"
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
        didSet { if comicSingleIndices != oldValue { invalidatePendingNavigation() } }
    }

    /// open 時に ComicInfo 由来の状態(章メニュー・見開き補助)をまとめて構築する。
    /// image は 0 始まりページとして実ページへ写像し、範囲外は捨てる
    /// (PageCount と実ページ数のズレ耐性)
    func loadComicInfoState(useLayoutHints: Bool) async {
        let info = isPartial ? nil : await comicInfo()
        let count = pageCount
        chapterMarks = (info?.chapters ?? []).compactMap { chapter in
            guard chapter.image >= 0, chapter.image < count else { return nil }
            return (page: chapter.image, name: chapter.name)
        }
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

    /// 進行中のデコード(entry.id → タスク)。表示要求が先読みの進行中
    /// デコードに合流し、同じページを二重にデコードしないための単一飛行
    private var inFlightLoads: [Int: (token: Int, task: Task<CGImage?, Never>)] = [:]
    private var inFlightToken = 0

    func image(at index: Int) async -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        let key = entry.id
        if let hit = cache.image(for: key) { return hit }
        if let running = inFlightLoads[key] {
            return await running.task.value
        }
        // detached: 先読みのキャンセルが、合流している表示要求まで
        // 巻き込まないように独立タスクで走らせる
        let source = source
        let cap = displayPixelCap
        let display = PageRequestIntent.isDisplay
        let task = Task<CGImage?, Never>.detached(priority: .userInitiated) {
            await PageRequestIntent.$isDisplay.withValue(display) {
                try? await source.image(for: entry, maxPixelSize: cap)
            }
        }
        inFlightToken &+= 1
        let token = inFlightToken
        inFlightLoads[key] = (token, task)
        let image = await task.value
        // 上限の値が一周しても旧要求は復活させない。失効と登録を同じ
        // MainActor で完結させ、古い小画像が新しい大画像を上書きするのを防ぐ。
        guard inFlightLoads[key]?.token == token else { return image }
        inFlightLoads[key] = nil
        if let image {
            // 上限を下げただけなら大画像を活かす。上げた場合は上の世代照合で除外される。
            cache.insert(image, for: key)
            if pageSizeCache[key] == nil {
                // キャップ付きデコードでも縦横比は保たれるため判定に使える
                pageSizeCache[key] = CGSize(width: image.width, height: image.height)
            }
        }
        return image
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
        if let hit = cache.image(for: key) {
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
            // 旧キャップで進行中のデコードには合流させない(新規要求は
            // 新キャップで作り直す。旧タスクの結果は登録世代の照合で捨てられる)
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
        while !entries.isEmpty, !Task.isCancelled {
            let revision = stateRevision
            noteReadingPositionIfNeeded()
            let spread = await PageRequestIntent.$isDisplay.withValue(true) {
                await loadSpread(at: currentIndex)
            }
            // 旧ページの取得中に位置/ソート/見開き条件が変わったら再計算する。
            // 画像と番号の対応、次ページの送り幅を同じ状態で確定するため。
            guard revision == stateRevision else { continue }
            lastDisplayCount = spread.indices.count
            schedulePrefetch()
            return spread
        }
        return Spread(indices: [], images: [])
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
        Task { await source.noteReadingPosition(current: current, next: next, previous: previous, forward: forward, sequence: sequence) }
    }

    private func loadSpread(at index: Int) async -> Spread {
        // サイズ索引(ヘッダ寸法)でペアが確定するなら、両ページを並列取得する
        // (従来はまず 1 枚目をデコードしないと 2 枚目に着手できなかった)。
        // 壊れページ(デコード失敗)は従来どおり単ページへ落とす
        if readMode.isSpread, index + 1 < entries.count,
           let firstSmall = await isSmallFromIndex(at: index),
           firstSmall,
           let secondSmall = await isSmallFromIndex(at: index + 1) {
            if secondSmall {
                async let firstTask = image(at: index)
                async let secondTask = image(at: index + 1)
                let (first, second) = await (firstTask, secondTask)
                if first != nil, second != nil {
                    return Spread(indices: [index, index + 1],
                                  images: [first, second])
                }
                // 片方が壊れていたら従来規則(単ページ)へ
                return Spread(indices: [index], images: [first])
            } else {
                // ヘッダで 2 枚目が非小(ワイド)と確定 → 単ページ。表示用に必要な
                // 1 枚目だけをデコードし、ワイドな 2 枚目はデコードしない
                // (negative なヘッダ判定は movePrevious/goToLast も同様に信頼する。
                // 従来はここで slow path へ落ちて 2 枚目を直列デコードし表示遅延を
                // 倍化していた。cooViewer-utz)
                let first = await image(at: index)
                return Spread(indices: [index], images: [first])
            }
        }

        let first = await image(at: index)
        var indices = [index]
        var images: [CGImage?] = [first]

        if readMode.isSpread, index + 1 < entries.count, isSmall(first, at: index) {
            let second = await image(at: index + 1)
            if isSmall(second, at: index + 1) {
                indices.append(index + 1)
                images.append(second)
            }
        }

        return Spread(indices: indices, images: images)
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
        return Task {
            let sorted = await Task.detached(priority: .userInitiated) {
                sorter.sorted(snapshot, mode: mode)
            }.value
            guard generation == sortGeneration else { return false }
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
    }

    /// キャッシュの寿命を、実時間の待機なしで検証する(設計書 §7.4)。
    func waitForPrefetch() async { await prefetchTask?.value }

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
        prefetchTask?.cancel()
        let targets = Self.prefetchTargets(currentIndex: currentIndex, displayCount: lastDisplayCount,
            ahead: prefetchAhead, behind: prefetchBehind, forward: lastMoveForward, count: entries.count,
            volumeKey: { source.prefetchVolumeKey(for: entries[$0]) })
        let captured = targets.map { (index: $0, id: entries[$0].id,
                                      volume: source.prefetchVolumeKey(for: entries[$0])) }
        let aheadCount = targets.filter { $0 > currentIndex }.count
        let leadingCount = lastMoveForward ? aheadCount : targets.count - aheadCount
        // 並列幅は置き場所の速度で決める(SSD=6 / HDD=1 / ネットワーク=2)
        let width = max(1, mediaProfile.bookPrefetchConcurrency)
        let source = source

        let targetIDs = targets.map { entries[$0].id }
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            // solid 書庫のストリーム巻き戻しを避けるため、並列可否は
            // ソースの「現在の状態」(スプール完了・形式)で判断する
            let parallel = await source.currentlySupportsParallelPageLoads(forEntryIDs: targetIDs)
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
                for target in Self.serialOrder(captured, aheadCount: leadingCount) {
                    if Task.isCancelled { return }
                    _ = await self.image(at: target)
                }
            }
        }
    }
}
