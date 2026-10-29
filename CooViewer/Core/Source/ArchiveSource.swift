import CoreGraphics
import CryptoKit
import Foundation
import KaitoKit
import os
import PDFKit
import Washi

/// 書庫(zip/rar/7z 等)を本として読む(仕様書 §2.4, §4.17)。
/// 書庫エンジンはスレッド安全でないため actor で直列化する。
/// 読み込みと名前の文字コード自動判定は KaitoKit のみを使う(設計書 §2.4)。
///
/// ネットワークドライブや solid 書庫でも快適に読めるよう、開いた後に
/// バックグラウンドで全ページをローカル一時領域へ逐次展開する(スプール。
/// 設計書「キャッシュ・先読み設計」)。スプール済みページはローカル読みになる。
///
/// 書庫内の書庫/PDF/固定レイアウト EPUB は一時領域へ展開して**子ソース**
/// (ArchiveSource/PDFSource/EPUBSource)を生成し、そのページを同じ本に取り込む
/// (仕様書 §2.4 のネスト COImageLoader 相当)。ページの相対パスは
/// 「書庫内パス/子の相対パス」になる。
actor ArchiveSource: BookSource {
    nonisolated let url: URL
    private var archive: any ArchiveEngine
    /// このソースを実際に開いた実装。ファイル情報と診断表示に使う。
    nonisolated let archiveEngineKind: ArchiveEngineKind
    /// ネスト子と展開係も同じエンジンで生成する。
    private let preferredEngine: ArchiveEngineKind
    private let engineFactory: ArchiveEngineFactory
    private let retryPolicy: AssemblyRetryPolicy
    private let powerState: any PowerStateProviding
    private let extractorPoolSizing: @Sendable (Bool) -> Int
    /// メモリ背景(暗号化親のネスト子)。非 nil のとき disk を読まず、
    /// 展開プールもこの共有 NSData から再オープンする(平文を temp に置かない)
    private let sourceData: Data?
    private let hasSyntheticURL: Bool
    /// この本の内容が暗号化された祖先由来か(nest 子の平文 temp 回避を子孫へ伝播)
    private let contentIsSensitive: Bool
    /// ルートの ComicInfo.xml エントリ(あれば。cooViewer-4fi.2)
    private let comicInfoEntryIndex: Int32?
    /// ネスト段数(0=最上位)。zip 爆弾対策で 3 段目以降は展開しない
    private let nestingDepth: Int

    /// 最上位書庫の画像エントリ(id=書庫エントリ番号。init で確定)
    private let outerImages: [PageEntry]
    /// ネスト候補(書庫/PDF エントリ。entries() で展開する)
    private let nestedCandidates: [(index: Int32, path: String)]

    /// ページの所在: 最上位書庫のエントリ番号、または子ソースのページ
    private enum PageLocation {
        case outer(entryIndex: Int32)
        case child(sourceIndex: Int, entry: PageEntry)
    }

    /// entries() の組み立て結果(actor 再入で二重構築しないよう Task で共有)
    private var buildTask: (task: Task<[PageEntry], any Error>, id: UUID)?
    private struct AssemblyLifetime {
        var abandoned = false
        var task: Task<[PageEntry], any Error>?
    }
    // actor が同期 I/O 中でも取消しを伝えるため、構築 Task の参照だけはロックで共有する(設計書 §2.4、§7.4)。
    private nonisolated let assemblyLifetime = OSAllocatedUnfairLock(initialState: AssemblyLifetime())
    private var locations: [Int: PageLocation] = [:]
    private var children: [any BookSource] = []
    private var excludedCount = 0

    private var nestedRoots: [URL] = []
    private var nestedTempBytes: Int64 = 0
    // 実在する合本は数十〜数百巻。自動展開が百万件へ膨らむのを防ぐ。
    static let maxNestedChildren = 1_024
    @TaskLocal static var testingNestedAvailableCapacity: (@Sendable (URL) -> Int64?)?
    private var nestedRootCleanup: Task<Void, Never>?
    private var password: String?
    /// ネスト書庫/PDF のロック解除係(本の全ネスト階層で共有)
    private let unlocker: NestedUnlocker
    /// 保存パスワードのキー(実ファイルの正規化パス、ネストは親キー+書庫内パス)
    private let persistenceKey: PasswordVault.Key
    /// 置き場所の速度プロファイル(スプール方針に使う。既定=従来動作)
    private var mediaProfile: MediaProfile = .unknown
    private var mediaProfileApplied = false
    private var spoolSettingsConfigured = false

    private var spoolDirectory: URL?
    private var spooledIDs: Set<Int> = []
    /// 暗号化書庫のスプールを暗号化するか(beginSpooling 時に確定)
    private var spoolEncrypted = false
    /// スプール暗号鍵(メモリのみの使い捨て。CWE-312 対策のプロセス限定鍵)
    private let spoolKey = SymmetricKey(size: .bits256)
    /// 完了済みと未開始を区別し、完了 Task を稼働中と数えたり再実行したりしない。
    private enum SpoolState: Sendable {
        case idle
        case running(Task<Void, Never>)
        case paused
        case finished
    }
    private var spoolState: SpoolState = .idle
    /// 全書庫を同時に復号すると、FD 以外に solid 辞書・先行復号も冊数分常駐する。
    /// 表示の準備は対話枠を待たずに取得できた場合だけ開始する。
    static let interactiveSpoolGate = SourceReadGate(limit: 2)
    @TaskLocal static var testingInteractiveSpoolGate: SourceReadGate?
    /// 予算停止で走査を抜けてから終了処理までの隙間を、テストで決定的に再現する。
    @TaskLocal static var testingAfterSpoolBudgetStop: (@Sendable () async -> Void)?
    static let backgroundSpoolGate = SourceReadGate(limit: ProcessInfo.processInfo.physicalMemory < 12 << 30 ? 1 : 2)
    private var spoolIsActive = false
    private var spoolInteractive = false
    private var spoolSizeLimit = ArchiveSource.defaultSpoolSizeLimit
    /// ゲート取得中の serial スプールだけが所有する独立した復号器(設計書 §5、cooViewer-r1t2)。
    private var spoolWorker: ArchiveSpoolWorker?
    private var spoolGeneration = UUID()
    private var retiredSpoolTask: Task<Void, Never>?
    private var spoolOrder: [Int] = []
    private var spoolOrderOffsets: [Int: Int] = [:]
    private var spoolCosts: [Int64] = []
    private var spoolUnknownCosts: [Int] = []
    private var spoolOrderPosition = 0
    private var spoolTailCount = 0
    private var spoolBudget: Int64 = 0
    private struct SpoolReservation {
        var generation: UUID?
        var task: Task<Void, Never>?
        var bytes: Int64 = 0
        var inFlight: Int64 = 0
        var budget: Int64 = 0
        var interactive = false
        var finished = false
        var hasGate = false
        var cancelled = false
    }
    private nonisolated let spoolReservation = OSAllocatedUnfairLock(initialState: SpoolReservation())

    /// 合本の表示側は別の子 actor を待たず、取消し済みの書き込み分まで予約する。
    nonisolated var reservedSpoolBytes: Int64 {
        spoolReservation.withLock {
            let used = $0.bytes + $0.inFlight
            return !$0.cancelled && $0.task?.isCancelled == false ? max(used, $0.budget) : used
        }
    }

    nonisolated var hasFinishedSpool: Bool { spoolReservation.withLock { $0.finished } }

    nonisolated var hasRunningSpool: Bool {
        spoolReservation.withLock { !$0.cancelled && $0.task?.isCancelled == false }
    }

    nonisolated var usedSpoolBytes: Int64 {
        spoolReservation.withLock { $0.bytes + $0.inFlight }
    }

    nonisolated var needsInteractiveSpoolPreparation: Bool {
        spoolReservation.withLock { !$0.finished && ($0.cancelled || $0.task == nil || $0.task!.isCancelled || !$0.interactive) }
    }

    nonisolated func cancelSpoolingForWindow() {
        spoolReservation.withLock { $0.cancelled = true; $0.task?.cancel() }
    }
    private var primaryCursor: Int?
    private var skippedSpoolIDs: Set<Int> = []
    private nonisolated let spoolWaiters = ArchiveSpoolWaiters()
    nonisolated var spoolWaitersForTesting: ArchiveSpoolWaiters { spoolWaiters }
    var spoolWaiterCount: Int { spoolWaiters.count }
    var spoolDirectoryForTesting: URL? { spoolDirectory }
    var nestedArchivesForTesting: [ArchiveSource] { children.compactMap { $0 as? ArchiveSource } }
    private var recentRawData: [(id: Int, data: Data)] = []
    private var primaryHasDecodedState = false
    private var isBuilding = false

    private static let logger = Logger(
        subsystem: "jp.coo.cooViewer", category: "archive")

    /// スプールする合計バイト数の上限。超過する書庫は先頭部分だけ保持する(設計書 §5)。
    static let defaultSpoolSizeLimit: Int64 = 4 << 30

    /// ネスト展開 1 エントリの展開後サイズ上限(zip 爆弾対策)。
    /// build() → appendNestedPages() → nestedChildData() は開いた瞬間に
    /// 自動展開される経路なので、展開後サイズが判るエントリは全展開する前に
    /// ここで弾く。実在するネスト書庫/PDF は数十〜数百 MB、極端な長編でも
    /// ~1GB 程度なので、2GiB を天井にすれば正規のコンテナは通しつつ多 GB の
    /// 展開爆弾を拒否できる。判定は 64bit の uncompressedSizeOfEntry: を使う
    /// (32bit の sizeOfEntry: は ~2.1GB 超で桁溢れし、爆弾が申告する巨大サイズを
    /// 検出できないため上限判定には使えない)。off_t の上限は ~9.2EB なので
    /// この 2GiB は実効的な閾値として働く(超過は確実に弾かれる)
    private static let nestedEntrySizeLimit: Int64 = 2 << 30

    /// 暗号化祖先由来のネスト子をメモリで開く上限(cooViewer-6ax)。書庫/PDF は
    /// 超過時に平文 temp へフォールバックするが、EPUB は c6s.23 により平文 temp
    /// を禁じてスキップする。実在するネスト書庫/PDF/EPUB の大半はこの 256MiB
    /// 以下でメモリ経由=平文を disk に置かずに開ける
    static let nestedInMemoryLimit: Int64 = 256 << 20

    /// ComicInfo.xml の展開後サイズ上限(zip 爆弾対策)。標準のメタデータは
    /// 数 KB〜、巨大な Pages 列でも 1MB 未満。16MiB を天井にする(cooViewer-4fi.2)
    private static let comicInfoSizeLimit: Int64 = 16 << 20

    /// ネストページの id 基数(最上位のエントリ番号と衝突しない大きさ)
    private static let nestedIDStride = 1_000_000

    nonisolated func prefetchVolumeKey(for entry: PageEntry) -> Int { entry.id / Self.nestedIDStride }

    nonisolated var supportsDateSort: Bool { false }
    /// エントリ独立圧縮の形式(構造を調べるまでもなく常にエントリ独立)
    private static let nonSolidExtensions: Set<String> = ["zip", "cbz"]

    /// 並列展開の粒度(init で書庫構造から確定。cooViewer-7ni)。
    /// zip 系は無条件にエントリ独立。それ以外は書庫エンジンの solid グループ
    /// 情報(solidGroupOfEntry)で判定する: 全エントリが独立なら perEntry
    /// (非 solid の 7z/rar/lha が該当し、zip と同じ並列プールが解禁される)、
    /// 複数エントリを束ねるグループがあるが分割されていれば byGroup
    /// (ブロック分割 solid 7z: グループ内直列・グループ間並列で実測 5.3 倍)、
    /// 実質単一グループ(完全 solid)は従来どおり serial
    private enum ParallelMode {
        case serial
        case perEntry
        /// エントリ id → グループ序数(複数メンバーのグループのみ登録。
        /// 載っていないエントリは独立 = 空き係でよい)
        case byGroup([Int: Int])
    }
    private let parallelMode: ParallelMode
    /// byGroup: グループ序数 → 割り当て済み展開係 index。同じグループの要求を
    /// 同じ係(actor)へ寄せて solid ストリームを前進で読み続けるための親和性
    private var groupExtractorAssignment: [Int: Int] = [:]

    /// 書庫構造から並列粒度を決める(init 専用の純関数)
    private static func computeParallelMode(archive: any ArchiveEngine,
                                            images: [PageEntry],
                                            fileExtension ext: String) -> ParallelMode {
        if nonSolidExtensions.contains(ext.lowercased()) { return .perEntry }
        guard !images.isEmpty else { return .serial }
        var ordinalOf: [Int: Int] = [:]  // solidGroup 値 → 序数
        var members: [[Int]] = []        // 序数 → エントリ id 列
        var independents = 0
        for entry in images {
            guard let index = Int32(exactly: entry.id) else { return .serial }
            let group = Int(archive.solidGroup(ofEntry: index))
            if group >= 0 {
                if let ordinal = ordinalOf[group] {
                    members[ordinal].append(entry.id)
                } else {
                    ordinalOf[group] = members.count
                    members.append([entry.id])
                }
            } else {
                independents += 1
            }
        }
        let multi = members.filter { $0.count > 1 }
        if multi.isEmpty { return .perEntry }
        // 並列の受け皿が単一グループしかない(=完全 solid)なら従来どおり直列
        if multi.count == 1 && independents == 0 && members.count == 1 { return .serial }
        var map: [Int: Int] = [:]
        for (ordinal, ids) in multi.enumerated() {
            for id in ids { map[id] = ordinal }
        }
        return .byGroup(map)
    }

    /// 展開プール(エントリ独立圧縮の形式のみ。PDFSource のレンダラープールと
    /// 同型)。書庫エンジンは非スレッド安全なので actor 毎に独立の書庫を開き、
    /// 未スプールのページ展開をエントリ間で並列化する(上限はコア数に連動)。
    /// 空きの再利用が最優先で、**全員使用中のときだけ**成長する:
    /// 直列読み(HDD プロファイル等)では 1 つのままで余計に開かない。
    /// 作成失敗(差し替え・削除)やエントリ数不一致は成長を恒久停止し、
    /// 既存の係に相乗りする(係がなければメイン書庫で直列展開する)。
    /// キャンセルによる失敗はその要求だけの相乗りに留め、以後の成長を妨げない
    private var extractors: [ArchiveEntryExtractor] = []
    private var extractorBusyCounts: [Int] = []
    private var extractorGrowthDisabled = false
    /// 展開係プールの上限。従来は固定 3。各係は独立した書庫の再オープン
    /// (ファイルハンドル + 中央ディレクトリ解析)を伴うので、コア数に応じて
    /// 控えめに増やす(3〜6)。deflate 書庫の並列展開と高速めくりで効く。
    static func extractorPoolSize(conserveEnergy: Bool,
                                  processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        let normal = min(max(3, processorCount / 2), 6)
        // 省エネ時も最低 2 係を保ち、表示要求が先読みに塞がれないようにする(設計書 §5)。
        return conserveEnergy ? max(2, normal / 2) : normal
    }

    /// いまの状態での並列可否: 全ページスプール済み(ローカル読みのみ)か、
    /// エントリ独立圧縮の形式のみ true。solid 書庫(rar/7z 等)は順不同展開で
    /// ストリームが巻き戻るため、未スプールの間は従来どおり直列
    /// 宣言は要件と同じ async(同期宣言だと async 文脈の直接呼び出しが
    /// プロトコル拡張の既定実装に解決される罠がある。PDFSource 参照)
    func currentlySupportsParallelPageLoads() async -> Bool {
        if !outerImages.isEmpty, spooledIDs.count >= outerImages.count {
            return true
        }
        // perEntry は自由並列、byGroup はグループ内が係 actor 上で自然に直列化
        // されるため並列要求を受けてよい。
        switch parallelMode {
        case .perEntry, .byGroup: return true
        case .serial:
            // 直接画像を持たず子ソース(ネスト書庫/PDF)だけの書庫は、外側書庫が
            // .serial(images.isEmpty 由来)でも並列可否を子に委ねる。子データは
            // 開いた瞬間に全展開済み(nestedChildData の自動展開)で、各子は独自の
            // 抽出器/レンダラを持つため外側ソリッドストリームを跨がない(cbz 等の
            // 既圧縮子は外側で格納され直接シークになる=実測: cooViewer-dua)。
            // 全子が並列可なら並列してよい(NestedFolderSource と同型。cooViewer-k7b)。
            // 直接画像がある solid はストリーム巻き戻しを避けるため従来どおり不可
            guard outerImages.isEmpty, !children.isEmpty else { return false }
            for child in children where await !child.currentlySupportsParallelPageLoads() {
                return false
            }
            return true
        }
    }

    /// スプールの置き場所。<pid>-<uuid> のサブディレクトリを掘る
    /// (起動時掃除で生存プロセスのものを残すため。仕様書 §4.17 の残骸問題への対策)。
    nonisolated static func spoolRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cooViewer-spool")
    }

    /// 起動時掃除: 生きている cooViewer の pid で始まらないスプール残骸(書庫
    /// スプール・ネスト temp・EPUB ステージング)を消す(設計書 §5 後始末)。
    /// 生存判定を kill(pid,0)==0 だけで行うと、OS の pid 再利用で無関係な同一
    /// ユーザープロセスがその pid を握っているときに『生存』と誤判定し、暗号化
    /// 祖先由来の復号済み平文スプールが回収されず残留する(監査 #4)。そのため
    /// 呼び出し側が実在する cooViewer の pid 集合を渡す
    nonisolated static func removeStaleSpoolDirectories(in root: URL, livePids: Set<pid_t>) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        for child in children {
            let pid = child.lastPathComponent.split(separator: "-").first
                .flatMap { pid_t($0) }
            if let pid, livePids.contains(pid) { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    /// persistenceKey: 保存パスワードのキー(必ず実ファイルの正規化パス、
    /// またはネストなら親キー由来で組む。デフォルト値を持たせないのは、
    /// 一時展開パス(url が temp)から作った無意味なキーが静かに紛れ込むのを
    /// コンパイル時に防ぐため)
    init(url: URL, nestingDepth: Int = 0, unlocker: NestedUnlocker? = nil,
         persistenceKey: PasswordVault.Key, sensitive: Bool = false,
         preferredEngine: ArchiveEngineKind = .kaitokit,
         engineFactory: ArchiveEngineFactory = .live,
         retryPolicy: AssemblyRetryPolicy = .default,
         powerState: any PowerStateProviding = PowerStateMonitor.shared,
         extractorPoolSizing: @escaping @Sendable (Bool) -> Int = {
             ArchiveSource.extractorPoolSize(conserveEnergy: $0)
         }) throws {
        self.url = url
        self.hasSyntheticURL = false
        self.contentIsSensitive = sensitive
        self.nestingDepth = nestingDepth
        self.unlocker = unlocker ?? NestedUnlocker()
        self.persistenceKey = persistenceKey
        self.preferredEngine = preferredEngine
        self.engineFactory = engineFactory
        self.retryPolicy = retryPolicy
        self.powerState = powerState
        self.extractorPoolSizing = extractorPoolSizing
        // ローカル固定ボリュームの単一ファイル書庫は mmap 経由で開く(open+全列挙が
        // 実測 −30%: 中央ディレクトリ走査の syscall・stdio シーク破棄が消える。
        // cooViewer-01h)。sourceData に載せることで展開プールも同じマップを共有し
        // 再オープンの I/O も消える。マップ中の切り詰めは SIGBUS になり得る残余
        // リスク(mappedIfSafe+ローカル限定が緩和策。エントリ数一致検証は従来通り)。
        // マップ不可ならファイル経路を使い、解析不能なら診断を記録して一度再試行する
        let opened = try Self.open(
            url: url, nestingDepth: nestingDepth,
            preferredEngine: preferredEngine, factory: engineFactory)
        self.archive = opened.archive
        self.archiveEngineKind = opened.kind
        self.sourceData = opened.sourceData
        self.outerImages = opened.enumerated.images
        self.nestedCandidates = opened.enumerated.candidates
        self.comicInfoEntryIndex = opened.enumerated.comicInfo
        self.parallelMode = Self.computeParallelMode(
            archive: opened.archive, images: opened.enumerated.images,
            fileExtension: url.pathExtension)
    }

    /// mmap で開いてよい書庫か(cooViewer-01h)。条件は保守的に:
    /// (1) 拡張子がボリューム跨ぎのない単一ファイル形式(zip 系・7z)のみ。
    ///     rar は分割書庫(part1/rNN)の兄弟探索がファイル名ベースで data: 経路では
    ///     働かないため除外。分割 zip(.z01 兄弟)も同じ理由で除外する。
    ///     KaitoKit の兄弟探索は file: 入口でのみ働く。
    /// (2) ローカルかつ非リムーバブルのボリューム(ネットワークは mappedIfSafe が
    ///     実コピーになり利点消失、リムーバブルは取り外しで SIGBUS)。
    static func shouldMemoryMap(url: URL) -> Bool {
        let mappable: Set<String> = ["zip", "cbz", "7z", "cb7"]
        let ext = url.pathExtension.lowercased()
        guard mappable.contains(ext) else { return false }
        // ネットワークボリュームでは mmap しないため、高コストな分割 zip の兄弟探索より先に除外する。
        // EPUB と同じ安全性判定を使い、属性不明時も SIGBUS 回避を優先する(cooViewer-oxr.39)。
        guard VolumeMappingPolicy.isSafeForMemoryMapping(url: url) else { return false }
        if ext == "zip" || ext == "cbz" {
            let spanned = url.deletingPathExtension().appendingPathExtension("z01")
            if FileManager.default.fileExists(atPath: spanned.path) { return false }
        }
        return true
    }

    /// 暗号化親のネスト子をメモリから開く(復号済みバイトを disk に置かない。
    /// cooViewer-6ax)。name は書庫内パス: 合成 url の拡張子がプール判定/型判定に
    /// 使われる(disk は決して読まない)。sensitive は常に true(暗号化祖先由来)
    init(data: Data, name: String, nestingDepth: Int, unlocker: NestedUnlocker,
         persistenceKey: PasswordVault.Key, sensitive: Bool = true,
         preferredEngine: ArchiveEngineKind = .kaitokit,
         engineFactory: ArchiveEngineFactory = .live,
         retryPolicy: AssemblyRetryPolicy = .default,
         powerState: any PowerStateProviding = PowerStateMonitor.shared,
         extractorPoolSizing: @escaping @Sendable (Bool) -> Int = {
             ArchiveSource.extractorPoolSize(conserveEnergy: $0)
         }) throws {
        self.url = URL(fileURLWithPath: name)
        self.hasSyntheticURL = true
        self.contentIsSensitive = sensitive
        self.nestingDepth = nestingDepth
        self.unlocker = unlocker
        self.persistenceKey = persistenceKey
        self.preferredEngine = preferredEngine
        self.engineFactory = engineFactory
        self.retryPolicy = retryPolicy
        self.powerState = powerState
        self.extractorPoolSizing = extractorPoolSizing
        let opened = try Self.open(
            data: data, name: name, nestingDepth: nestingDepth,
            preferredEngine: preferredEngine, factory: engineFactory)
        self.archive = opened.archive
        self.archiveEngineKind = opened.kind
        self.sourceData = opened.sourceData
        self.outerImages = opened.enumerated.images
        self.nestedCandidates = opened.enumerated.candidates
        self.comicInfoEntryIndex = opened.enumerated.comicInfo
        self.parallelMode = Self.computeParallelMode(
            archive: opened.archive, images: opened.enumerated.images,
            fileExtension: URL(fileURLWithPath: name).pathExtension)
    }

    private typealias EnumeratedEntries = (
        images: [PageEntry], candidates: [(index: Int32, path: String)],
        comicInfo: Int32?
    )

    private struct OpenedArchive {
        let archive: any ArchiveEngine
        let kind: ArchiveEngineKind
        let sourceData: Data?
        let enumerated: EnumeratedEntries
    }

    private enum EngineOpenError: Error, CustomStringConvertible {
        case returnedNil(ArchiveEngineKind, String)
        case threw(ArchiveEngineKind, String, String)
        case invalidEntryCount(ArchiveEngineKind, Int32)
        case missingEntryName(ArchiveEngineKind, Int32)

        var description: String {
            switch self {
            case .returnedNil(let kind, let route):
                "\(kind.displayName) が \(route) から書庫を開けませんでした"
            case .threw(let kind, let route, let message):
                "\(kind.displayName) の \(route) オープンに失敗しました: \(message)"
            case .invalidEntryCount(let kind, let count):
                "\(kind.displayName) が不正なエントリ数 \(count) を返しました"
            case .missingEntryName(let kind, let index):
                "\(kind.displayName) がエントリ \(index) を列挙できませんでした"
            }
        }
    }

    /// ファイル入力を KaitoKit で開き、生成・列挙失敗は unreadable にする(設計書 §2.4)。
    private static func open(url: URL, nestingDepth: Int,
                             preferredEngine: ArchiveEngineKind,
                             factory: ArchiveEngineFactory) throws -> OpenedArchive {
        let mapped: Data?
        if shouldMemoryMap(url: url) {
            mapped = try? Data(contentsOf: url, options: .mappedIfSafe)
        } else {
            mapped = nil
        }
        do {
            return try attemptOpen(
                url: url, mappedData: mapped, nestingDepth: nestingDepth,
                kind: preferredEngine, factory: factory)
        } catch {
            // 互換 API はキャンセルも nil にするため、診断へ記録する前に区別する。
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if SourceReadFailure.mustPropagate(error) { throw error }
            let message = "\(url.path): \(String(describing: error))"
            ArchiveEngineDiagnostics.recordError(message: message)
            logger.error("Archive open failed: \(message)")
            throw BookSourceError.unreadable(url)
        }
    }

    /// メモリ入力を開く。実ファイルを持たないため file 再試行はせず、暗号化祖先の平文を disk へ戻さない。
    private static func open(data: Data, name: String, nestingDepth: Int,
                             preferredEngine: ArchiveEngineKind,
                             factory: ArchiveEngineFactory) throws -> OpenedArchive {
        let displayURL = URL(fileURLWithPath: name)
        do {
            return try attemptOpen(
                data: data, nestingDepth: nestingDepth,
                kind: preferredEngine, factory: factory)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if SourceReadFailure.mustPropagate(error) { throw error }
            let message = "\(name): \(String(describing: error))"
            ArchiveEngineDiagnostics.recordError(message: message)
            logger.error("Archive open failed: \(message)")
            throw BookSourceError.unreadable(displayURL)
        }
    }

    private static func attemptOpen(
        url: URL, mappedData: Data?, nestingDepth: Int,
        kind: ArchiveEngineKind, factory: ArchiveEngineFactory
    ) throws -> OpenedArchive {
        let archive: any ArchiveEngine
        let retainedData: Data?
        if let mappedData {
            do {
                archive = try open(data: mappedData, kind: kind, factory: factory)
                retainedData = mappedData
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // エンジンに関係なく mmap の解析失敗だけを file: で一度再試行する。
                // 列挙はこの catch の外で行い、列挙失敗では再試行しない(設計書 §2.4)。
                let message = "\(url.path): \(String(describing: error))"
                ArchiveEngineDiagnostics.recordRetry(message: message)
                logger.info(
                    "\(kind.displayName, privacy: .public) mmap open failed; retrying file once: \(message)")
                archive = try open(file: url.path, kind: kind, factory: factory)
                retainedData = nil
            }
        } else {
            archive = try open(file: url.path, kind: kind, factory: factory)
            retainedData = nil
        }
        let enumerated = try enumerateEntries(
            archive, nestingDepth: nestingDepth, kind: kind,
            requireCompleteNames: false)
        return OpenedArchive(
            archive: archive, kind: kind, sourceData: retainedData,
            enumerated: enumerated)
    }

    private static func attemptOpen(
        data: Data, nestingDepth: Int, kind: ArchiveEngineKind,
        factory: ArchiveEngineFactory
    ) throws -> OpenedArchive {
        let archive = try open(data: data, kind: kind, factory: factory)
        let enumerated = try enumerateEntries(
            archive, nestingDepth: nestingDepth, kind: kind,
            requireCompleteNames: false)
        return OpenedArchive(
            archive: archive, kind: kind, sourceData: data,
            enumerated: enumerated)
    }

    private static func open(file path: String, kind: ArchiveEngineKind,
                             factory: ArchiveEngineFactory) throws
        -> any ArchiveEngine {
        do {
            guard let archive = try factory.openFile(kind, path, .primary) else {
                throw EngineOpenError.returnedNil(kind, "file")
            }
            return archive
        } catch let error as EngineOpenError {
            throw error
        } catch {
            if SourceReadFailure.mustPropagate(error) { throw error }
            throw EngineOpenError.threw(kind, "file", String(describing: error))
        }
    }

    private static func open(data: Data, kind: ArchiveEngineKind,
                             factory: ArchiveEngineFactory) throws
        -> any ArchiveEngine {
        do {
            guard let archive = try factory.openData(kind, data, .primary) else {
                throw EngineOpenError.returnedNil(kind, "data")
            }
            return archive
        } catch let error as EngineOpenError {
            throw error
        } catch {
            if SourceReadFailure.mustPropagate(error) { throw error }
            throw EngineOpenError.threw(kind, "data", String(describing: error))
        }
    }

    /// 書庫のエントリを画像/ネスト候補へ振り分ける(両 init 共通)。
    /// 旧実装(XADWrapper)同様、ディレクトリとサイズ 0 のエントリを除外し、
    /// 画像以外のファイルと macOS メタデータ(__MACOSX/、._*)も除外する。
    private static func enumerateEntries(
        _ archive: any ArchiveEngine, nestingDepth: Int,
        kind: ArchiveEngineKind, requireCompleteNames: Bool
    ) throws -> EnumeratedEntries {
        var images: [PageEntry] = []
        var candidates: [(index: Int32, path: String)] = []
        var comicInfo: Int32?
        let count = archive.numberOfEntries()
        guard count >= 0 else { throw EngineOpenError.invalidEntryCount(kind, count) }
        for index in 0..<count {
            guard let name = archive.name(ofEntry: index) else {
                if requireCompleteNames {
                    throw EngineOpenError.missingEntryName(kind, index)
                }
                // 名前を取得できないエントリだけを除外し、残りのページを残す(設計書 §2.4)。
                logger.warning(
                    "\(kind.displayName, privacy: .public) skipped entry \(index) with no name")
                continue
            }
            // 空判定はサイズ申告がある場合だけ 64bit 値で行う。未知サイズを 0 と
            // 表す互換実装でも正規エントリを空扱いしない。32bit の size(ofEntry:)
            // は真サイズが 4GiB の倍数のとき 0 に桁溢れするため使わない
            // (cooViewer-0jt)。ディレクトリは entryIsDirectory が拾う。
            guard !archive.entryIsDirectory(index),
                  !archive.entryHasSize(index)
                    || archive.uncompressedSize(ofEntry: index) != 0 else {
                continue
            }
            let lastComponent = (name as NSString).lastPathComponent
            guard !lastComponent.hasPrefix("."), !name.hasPrefix("__MACOSX") else {
                continue
            }
            // ルート直下の ComicInfo.xml(標準メタデータ)を控える(cooViewer-4fi.2)
            if comicInfo == nil, name.lowercased() == "comicinfo.xml" {
                comicInfo = index
                continue
            }
            // ネスト id 域(1M 刻み)との衝突を防ぐ。100 万エントリ超の書庫は
            // 病的ケースなので以降を切り捨てる
            guard index < Int32(Self.nestedIDStride) else { break }
            if SupportedTypes.isImageFile(lastComponent) {
                images.append(PageEntry(
                    id: Int(index),
                    name: lastComponent,
                    pathInBook: name,
                    fileURL: nil,
                    creationDate: nil,
                    modificationDate: nil
                ))
            } else if nestingDepth < 2,
                      SupportedTypes.isBookFile(URL(fileURLWithPath: lastComponent)) {
                // 固定レイアウト EPUB は合本へ取り込む。リフロー EPUB は
                // appendNestedPages で従来どおり黙って除外する(仕様書 §4.17)。
                // 暗号化祖先下の FXL は c6s.23 のメモリ経路だけで取り込む
                candidates.append((index: index, path: name))
            }
        }
        return (images, candidates, comicInfo)
    }

    deinit {
        if case .running(let task) = spoolState { task.cancel() }
        spoolWaiters.resume()
        // スプール Task は弱参照だけを持ち、専用復号器もこの actor とともに解放する(設計書 §5)。
        let directories = [spoolDirectory].compactMap(\.self) + nestedRoots
        if !directories.isEmpty {
            Task.detached(priority: .utility) {
                for directory in directories {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
    }

    func entries() async throws -> [PageEntry] {
        try await buildIfNeeded()
    }

    /// 試行専有の子を捨てる場合だけ呼び、共有の entries() の取消しでは構築を止めない(設計書 §2.4、§7.4)。
    nonisolated func abandonAssembly() {
        // entries() より先に取消し通知が到着しても、後から入力依頼を始めさせない(設計書 §7.4)。
        let task = assemblyLifetime.withLock {
            $0.abandoned = true
            return $0.task
        }
        task?.cancel()
        // 復号器の破棄は所有 actor 上で行う。同期 I/O 中の次の項目も abandoned で止める(設計書 §5)。
        Task { await pauseSpooling() }
    }

    @discardableResult
    private func buildIfNeeded() async throws -> [PageEntry] {
        guard !assemblyLifetime.withLock({ $0.abandoned }) else { throw CancellationError() }
        let running: (task: Task<[PageEntry], any Error>, id: UUID)
        if let buildTask { running = buildTask }
        else {
            running = (Task { try await build() }, UUID())
            let abandoned = assemblyLifetime.withLock {
                if $0.abandoned { return true }
                $0.task = running.task
                return false
            }
            if abandoned { running.task.cancel(); throw CancellationError() }
            buildTask = running
        }
        do {
            let pages = try await running.task.value
            await touchDecodedState()
            return pages
        }
        catch {
            if buildTask?.id == running.id {
                buildTask = nil
                assemblyLifetime.withLock { $0.task = nil }
                locations.removeAll()
                children.removeAll()
            }
            await touchDecodedState()
            throw error
        }
    }

    /// 準備は期限付きで行い、登録だけを列挙順に確定する(設計書 §2.4、§7.4)。
    private func build() async throws -> [PageEntry] {
        isBuilding = true
        defer { isBuilding = false }
        let candidates = Array(nestedCandidates.prefix(Self.maxNestedChildren))
        excludedCount = nestedCandidates.count - candidates.count
        let root = nestedTempRoot()
        // 準備係は detached Task で走るため、注入値をここで捕まえて渡す。
        let availableCapacity: @Sendable (URL) -> Int64? = Self.testingNestedAvailableCapacity ?? { directory in
            (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
        let context = NestedPreparationContext(
            depth: nestingDepth, sensitive: contentIsSensitive || archive.isEncrypted(),
            unlocker: unlocker, persistenceKey: persistenceKey, engine: preferredEngine,
            factory: engineFactory, policy: retryPolicy, powerState: powerState,
            poolSizing: extractorPoolSizing, writeTemp: { candidate, data in
                try await self.writeNestedTemp(candidate, data: data, root: root, availableCapacity: availableCapacity)
            })
        await nestedRootCleanup?.value
        let prepared = try await AssemblyPreparation.run(
            candidates: candidates.enumerated().map {
                AssemblyCandidate(ordinal: $0.offset, relativePath: $0.element.path,
                                  url: url.appendingPathComponent($0.element.path))
            }, total: candidates.count, sourceURL: url, lanes: 1, policy: retryPolicy,
            // mmap の実ファイルと違い、メモリ専用の合成 URL には到達性を問えない(設計書 §2.4、§7.4)。
            probeSource: !hasSyntheticURL) { candidate in
                try await self.prepareNestedChild(candidates[candidate.ordinal], context: context)
            }
        var result: [PageEntry] = []
        var imageIterator = outerImages.makeIterator()
        var pendingImage = imageIterator.next()
        var candidateCursor = 0
        var idOrdinal = 0
        for index in 0..<archive.numberOfEntries() {
            try Task.checkCancellation()
            if let image = pendingImage, image.id == Int(index) {
                locations[image.id] = .outer(entryIndex: index)
                result.append(image)
                pendingImage = imageIterator.next()
                continue
            }
            guard candidateCursor < candidates.count, candidates[candidateCursor].index == index else { continue }
            let candidate = candidates[candidateCursor]
            let preparation = prepared[candidateCursor]
            candidateCursor += 1
            let appended: Bool
            switch preparation {
            case .ready(let child):
                appendNestedPages(child, candidate: candidate, ordinal: idOrdinal + 1, into: &result)
                appended = true
            case .excluded:
                excludedCount += 1
                appended = false
            default:
                appended = false
            }
            // 棄却 EPUB は序数を消費せず、従来の書庫 id を保つ(cooViewer-id8、設計書 §2.4)。
            if !SupportedTypes.isEPUB(URL(fileURLWithPath: candidate.path)) || appended { idOrdinal += 1 }
        }
        return result
    }

    private func appendNestedPages(_ prepared: AssemblyPreparedChild,
                                   candidate: (index: Int32, path: String), ordinal: Int,
                                   into result: inout [PageEntry]) {
        let child = prepared.source
        let childEntries = prepared.entries
        excludedCount += prepared.excludedCount
        children.append(child)
        let sourceIndex = children.count - 1
        let idBase = ordinal * Self.nestedIDStride
        for (offset, childEntry) in childEntries.enumerated() {
            // 子のページ数が id 域(1M)を超えたら以降を切り捨てる。
            // 溢れると次のネスト候補の id と衝突し、locations の上書きで
            // 別ページの画像が表示されてしまう(外側の 1M ガードと同じ方針)
            guard offset < Self.nestedIDStride else { break }
            let id = idBase + offset
            locations[id] = .child(sourceIndex: sourceIndex, entry: childEntry)
            result.append(PageEntry(
                id: id,
                name: childEntry.name,
                pathInBook: candidate.path + "/" + childEntry.pathInBook,
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil
            ))
        }
    }

    private struct NestedPreparationContext: Sendable {
        let depth: Int
        let sensitive: Bool
        let unlocker: NestedUnlocker
        let persistenceKey: PasswordVault.Key
        let engine: ArchiveEngineKind
        let factory: ArchiveEngineFactory
        let policy: AssemblyRetryPolicy
        let powerState: any PowerStateProviding
        let poolSizing: @Sendable (Bool) -> Int
        let writeTemp: @Sendable ((index: Int32, path: String), Data) async throws -> URL?
    }

    private func prepareNestedChild(_ candidate: (index: Int32, path: String),
                                    context: NestedPreparationContext) async throws -> AssemblyChildPreparation {
        try Task.checkCancellation()
        let isEPUB = SupportedTypes.isEPUB(URL(fileURLWithPath: candidate.path))
        if isEPUB, context.sensitive, archive.entryHasSize(candidate.index),
           archive.uncompressedSize(ofEntry: candidate.index) > Self.nestedInMemoryLimit {
            return .skipped
        }
        // 展開の同期 read が親 actor を占有すると、停止したマウントから戻るまで
        // build の期限切れ応答も遅れる。子の非同期準備だけが期限で待機を打ち切れる(設計書 §2.4、§7.4)。
        guard let data = try nestedChildData(candidate) else { return .skipped }
        let prepared = try await Self.prepareReadableNestedChild(candidate, data: data, context: context)
        if case .ready(let child) = prepared {
            if spoolSettingsConfigured { await child.source.configureSpooling(sizeLimit: spoolSizeLimit) }
            if mediaProfileApplied { await child.source.applyMediaProfile(mediaProfile) }
        }
        return prepared
    }

    private static func prepareReadableNestedChild(_ candidate: (index: Int32, path: String),
                                                  data: Data, context: NestedPreparationContext)
        async throws -> AssemblyChildPreparation {
        let isEPUB = SupportedTypes.isEPUB(URL(fileURLWithPath: candidate.path))
        let sensitive = context.sensitive
        let unlocker = context.unlocker
        let persistenceKey = context.persistenceKey
        let nestingDepth = context.depth
        let preferredEngine = context.engine
        let engineFactory = context.factory
        let retryPolicy = context.policy
        let powerState = context.powerState
        let extractorPoolSizing = context.poolSizing
        // 子のキーは一時展開パス(fileURL)ではなく親キー+書庫内パスで組む
        // (temp パスは起動ごとに変わり保存キーとして無意味になるため)
        let childKey = persistenceKey.nested(entryPath: candidate.path)
        // 暗号化祖先由来の子は復号済み平文を disk に置かずメモリから開く。ただし
        // RAM 常駐(プールで共有/複製)が重い大きな書庫/PDF は現行の平文 temp へ
        // フォールバックする(EPUB は 6ax/c6s.23 によりスキップ)。非機微な子は
        // 従来どおり temp 経由で挙動・性能を変えず、機微性は子孫へ伝播する
        let useMemory = sensitive && Int64(data.count) <= Self.nestedInMemoryLimit
        let isPDF = SupportedTypes.isPDF(URL(fileURLWithPath: candidate.path))
        let child: any BookSource
        if isEPUB {
            // cooViewer-cj2/oxr.44: 通常のリフロー/DRM/破損 EPUB はメモリ上の
            // OCF 解析で先に棄却し、採用しない全データを平文 temp へ書き出さない。
            let probe = try EPUBPublication(data: data, displayURL: URL(fileURLWithPath: candidate.path))
            guard !probe.isDRMProtected else { return .skipped }
            // rendition:layout がなくても全 spine が単一画像なら画像本として採用し、
            // 判定で得たページ情報を子へ渡す(cooViewer-oxr.44、設計書 §2.4)。
            let imageOnlyPageInfos = probe.isFixedLayout
                ? nil : EPUBImageOnlyHeuristic.imageOnlyPageInfos(probe)
            guard probe.isFixedLayout || imageOnlyPageInfos != nil else { return .skipped }
            if sensitive {
                // c6s.23: probe が OCF の Data を保持するため、そのまま子へ渡せば
                // 6ax の平文 temp 禁止を守れる。実サイズが上限超なら temp へ
                // フォールバックせずスキップする(PDF/書庫との非対称は意図的)
                guard useMemory else { return .skipped }
                child = try EPUBSource(publication: probe, url: URL(fileURLWithPath: candidate.path),
                                       precomputedImageOnlyPageInfos: imageOnlyPageInfos)
            } else {
                // 非機微 EPUB は data 経路へ統一しない。従来の temp+mmap なら
                // 退避可能な展開バイトが、常駐ヒープへ変わるメモリ退行を避ける
                guard let fileURL = try await context.writeTemp(candidate, data) else { return .skipped }
                do {
                    let filePublication = try await EPUBStagingArea.shared.openPublication(at: fileURL)
                    child = try EPUBSource(
                        publication: filePublication, url: fileURL,
                        precomputedImageOnlyPageInfos: imageOnlyPageInfos)
                } catch {
                    try? FileManager.default.removeItem(at: fileURL)
                    throw error
                }
            }
            // EPUBSource は FXL または画像のみの非 DRM に限る。通常のリフロー・
            // DRM・破損は仕様書 §4.17 に従い黙って除外し、unlocker には渡さない
        } else if isPDF {
            if useMemory {
                child = try PDFSource(data: data)
            } else {
                guard let fileURL = try await context.writeTemp(candidate, data) else { return .skipped }
                do { child = try PDFSource(url: fileURL) }
                catch {
                    try? FileManager.default.removeItem(at: fileURL)
                    throw error
                }
            }
        } else if useMemory {
            let nested = try ArchiveSource(
                data: data, name: candidate.path, nestingDepth: nestingDepth + 1,
                unlocker: unlocker, persistenceKey: childKey, sensitive: true,
                preferredEngine: preferredEngine, engineFactory: engineFactory, retryPolicy: retryPolicy, powerState: powerState,
                extractorPoolSizing: extractorPoolSizing)
            child = nested
        } else {
            guard let fileURL = try await context.writeTemp(candidate, data) else { return .skipped }
            do {
                child = try ArchiveSource(
                    url: fileURL, nestingDepth: nestingDepth + 1,
                    unlocker: unlocker, persistenceKey: childKey, sensitive: sensitive,
                    preferredEngine: preferredEngine, engineFactory: engineFactory, retryPolicy: retryPolicy, powerState: powerState,
                    extractorPoolSizing: extractorPoolSizing)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        }
        // 暗号化された子は共有アンロッカーで解除する(保存済み→既知→入力依頼)。
        // 解除できない/キャンセルされた子は本から外す(§4.17 の黙殺方針。
        // 恒久的な空セルとして残すより一覧が正直になる)
        let encrypted: Bool
        if isEPUB { encrypted = false }
        else { encrypted = await child.isEncrypted() }
        try Task.checkCancellation()
        if encrypted {
            let name = (candidate.path as NSString).lastPathComponent
            try Task.checkCancellation()
            guard try await unlocker.unlockForAssembly(child, name: name,
                                        persistenceKey: childKey) else { return .excluded }
        }
        let childEntries = try await AssemblyPreparation.entriesForOwnedChild(child)
        let exclusions = await child.excludedChildCount()
        guard !childEntries.isEmpty else { return exclusions > 0 ? .excluded : .skipped }
        return .ready(AssemblyPreparedChild(source: child, entries: childEntries, excludedCount: exclusions))
    }

    /// ネスト候補の展開後バイト(zip 爆弾ガード付き、temp には書かない)。
    /// zip 爆弾対策: この経路は開いた瞬間に自動展開されるため、展開後サイズが
    /// 判るエントリは contents(ofEntry:) で全展開する前に上限で弾く。判定は
    /// 64bit の uncompressedSizeOfEntry: を使う(sizeOfEntry: は 32bit で桁溢れ
    /// するため爆弾検出に使えない)。サイズ不明(entryHasSize: が false)の形式は
    /// ストリーミング展開 API が無く事前判定できないので通す — 既知の残存リスク。
    /// サイズ未申告で 0 等が返っても上限以下として通し、正規エントリは弾かない
    private func primaryContents(ofEntry index: Int32) -> Data? {
        primaryHasDecodedState = true
        primaryCursor = Int(index) + 1
        return archive.contents(ofEntry: index)
    }

    private func touchDecodedState() async {
        // スプール済みの子も生データを持つ間は解放対象にし、最大 64 MiB を寿命まで保持しない(cooViewer-wlwp)。
        guard primaryHasDecodedState || !extractors.isEmpty || !recentRawData.isEmpty else { return }
        // 解放候補の別の子が同期展開中でも、表示完了をその actor の後ろに並べない。
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await ArchiveDecodedStateCache.shared.recordUse(self)
        }
    }

    // solid の巻き戻しを避けるため、表示後のアニメ判定へ渡す生データを短期間保持する(cooViewer-wlwp)。
    private func rememberRawData(id: Int, data: Data) {
        guard data.count <= 32 << 20 else { return }
        recentRawData.removeAll { $0.id == id }
        recentRawData.insert((id, data), at: 0)
        var bytes = recentRawData.reduce(0) { $0 + $1.data.count }
        while recentRawData.count > 8 || bytes > 64 << 20 {
            bytes -= recentRawData.removeLast().data.count
        }
    }

    private func rememberedRawData(id: Int) -> Data? {
        guard let index = recentRawData.firstIndex(where: { $0.id == id }) else { return nil }
        let value = recentRawData.remove(at: index)
        recentRawData.insert(value, at: 0)
        return value.data
    }

    private func nestedChildData(_ candidate: (index: Int32, path: String)) throws -> Data? {
        if archive.entryHasSize(candidate.index) {
            let uncompressedSize = archive.uncompressedSize(ofEntry: candidate.index)
            guard uncompressedSize <= Self.nestedEntrySizeLimit else { return nil }
        }
        primaryHasDecodedState = true
        return try archive.readContents(ofEntry: candidate.index)
    }

    /// ネスト子を一時領域へ書き出す(<pid>-<uuid>-nested/)。非機微な子、または
    /// 上限超でメモリ経由を諦めた機微な書庫/PDF に使う。暗号化祖先由来の EPUB は
    /// 6ax/c6s.23 によりここへ渡さない。残る平文 temp は KaitoKit/PDFKit がパスを
    /// 直読みするため暗号化不可(設計書 §2.4 の残余リスク)なので、権限を所有者限定にする
    private func nestedTempRoot() -> URL {
        // 打ち切った子が後から戻っても、新しい構築の一時ファイルを上書きさせない(設計書 §7.4)。
        nestedTempBytes = 0
        let retiredRoots = nestedRoots
        nestedRootCleanup = Task.detached(priority: .utility) {
            // 世代ごとの隔離は残し、再構築のたびに大きな展開ファイルを蓄積させない(設計書 §2.4、§7.4)。
            for root in retiredRoots { try? FileManager.default.removeItem(at: root) }
        }
        let root = Self.spoolRoot().appendingPathComponent(
            "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)-nested")
        nestedRoots.append(root)
        return root
    }

    /// 空き容量と累計の判定は注入可能な純関数にまとめる。
    static func nestedTempHasRoom(size: Int, usedBytes: Int64, availableCapacity: Int64?) -> Bool {
        // 既定スプールと同じ 4 GiB を本ごとの上限にし、空きの 1/10 と 256 MiB の余裕も守る。
        EPUBStagingArea.SpacePolicy(totalCap: defaultSpoolSizeLimit).hasRoom(
            forFileOfSize: size, liveBytes: usedBytes, availableCapacity: availableCapacity)
    }

    private func writeNestedTemp(_ candidate: (index: Int32, path: String),
                                 data: Data, root: URL, availableCapacity: @Sendable (URL) -> Int64?) throws -> URL? {
        try Task.checkCancellation()
        guard nestedRoots.last == root else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory
        let available = availableCapacity(directory)
        guard Self.nestedTempHasRoom(size: data.count, usedBytes: nestedTempBytes,
                                     availableCapacity: available) else { return nil }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fileURL = root.appendingPathComponent(
            "\(candidate.index)-" + String((candidate.path as NSString).lastPathComponent.suffix(200)))
        try data.write(to: fileURL, options: .atomic)
        nestedTempBytes += Int64(data.count)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
        return fileURL
    }

    func imageData(for entry: PageEntry) async -> Data? {
        let data = await loadedImageData(for: entry)
        await touchDecodedState()
        return data
    }

    private func loadedImageData(for entry: PageEntry) async -> Data? {
        switch locations[entry.id] {
        case .child(let sourceIndex, let childEntry):
            return await children[sourceIndex].imageData(for: childEntry)
        case .outer(let index):
            if let data = rememberedRawData(id: entry.id) { return data }
            do { if let data = try await spooledOrWaitingData(for: entry.id) { return data } }
            catch { return nil }
            guard !Task.isCancelled else { return nil }
            // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開しない
            guard !exceedsPerPageDecodeLimit(index) else { return nil }
            return primaryContents(ofEntry: index)
        case nil:
            // 一覧構築(build)前に呼ばれた場合の逃げ道。最上位書庫の
            // エントリ番号としてそのまま解釈する(ネスト id 域は 1M 以上
            // なので Int32 変換の失敗で自然に弾かれる)
            guard let index = Int32(exactly: entry.id) else { return nil }
            if let data = rememberedRawData(id: entry.id) { return data }
            do { if let data = try await spooledOrWaitingData(for: entry.id) { return data } }
            catch { return nil }
            guard !Task.isCancelled else { return nil }
            // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開しない
            guard !exceedsPerPageDecodeLimit(index) else { return nil }
            return primaryContents(ofEntry: index)
        }
    }

    nonisolated func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let result: Result<CGImage, any Error>
        do { result = .success(try await renderImage(for: entry, maxPixelSize: maxPixelSize)) }
        catch { result = .failure(error) }
        await touchDecodedState()
        return try result.get()
    }

    private nonisolated func renderImage(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        switch try await pageContent(for: entry) {
        case .child(let child, let childEntry):
            return try await child.image(for: childEntry, maxPixelSize: maxPixelSize)
        case .data(let data):
            if AnimatedImage.candidateExtensions.contains((entry.name as NSString).pathExtension.lowercased()) {
                await rememberRawData(id: entry.id, data: data)
            }
            // nonisolated async はグローバル実行系で走るため、このデコードは
            // actor の外。展開・スプールと画像デコードが並行できる
            return try await PrefetchDecodeGate.run {
                try ImageDecoding.decode(data, maxPixelSize: maxPixelSize,
                                        displayTarget: PageRequestIntent.displayColorTarget)
            }
        case .pooled(let poolIndex, let extractor, let entryIndex):
            // 展開は貸し出された係の隔離で走る(本 actor と他の係に対して並列)
            let data = await extractor.contents(ofEntry: entryIndex)
            await releaseExtractor(poolIndex)
            guard let data else {
                try Task.checkCancellation()
                throw BookSourceError.pageLoadFailed(entry.name)
            }
            if AnimatedImage.candidateExtensions.contains((entry.name as NSString).pathExtension.lowercased()) {
                await rememberRawData(id: entry.id, data: data)
            }
            return try await PrefetchDecodeGate.run {
                try ImageDecoding.decode(data, maxPixelSize: maxPixelSize,
                                        displayTarget: PageRequestIntent.displayColorTarget)
            }
        }
    }

    /// ページ寸法: スプール済みならヘッダ読み、子は委譲。未スプールの書庫
    /// エントリは全展開が必要なので nil(呼び出し側がデコード判定へ)
    func imageSize(for entry: PageEntry) async -> CGSize? {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return await children[sourceIndex].imageSize(for: childEntry)
        }
        // 暗号化スプールはシール済みバイト列なのでヘッダ直読みできない
        // (nil で従来の取得経路へ)
        guard spooledIDs.contains(entry.id), !spoolEncrypted,
              let directory = spoolDirectory else {
            return nil
        }
        return ImageDecoding.imageSize(
            at: directory.appendingPathComponent(String(entry.id)))
    }

    /// ページの中身の取り出し方(actor 内で決定する)。
    /// pooled はプールの展開係を貸し出し、実際の展開は actor の外
    /// (extractor 自身の隔離)で行う — 展開どうし・スプールと並列になる
    private enum PageContent {
        case data(Data)
        case child(any BookSource, PageEntry)
        case pooled(poolIndex: Int, extractor: ArchiveEntryExtractor, entryIndex: Int32)
    }

    /// 1 ページ分のオンデマンド展開サイズの上限(先読み/サムネイル/オンデマンド
    /// のどの経路でも、この宣言サイズを超えるエントリは展開しない。zip 爆弾対策)。
    /// 2 GiB は現実的な単一ページ画像ファイル(超高解像度の無圧縮 TIFF/BMP や
    /// レイヤー付き PSD でも)を確実に上回る一方、展開爆弾が宣言する数 GB〜の
    /// 塊は依然として弾ける。サイズ不明のエントリ(entryHasSize=false)は
    /// 判定できないため通す(残存リスクとして許容)
    static let perPageDecodeSizeLimit: Int64 = 2 << 30

    /// エントリの宣言展開サイズが上限を超えるか。サイズ不明なら false(=通す)。
    /// 32bit の size(ofEntry:) ではなく 64bit の uncompressedSize(ofEntry:) を使う
    private func exceedsPerPageDecodeLimit(_ index: Int32) -> Bool {
        guard archive.entryHasSize(index) else { return false }
        return archive.uncompressedSize(ofEntry: index) > Self.perPageDecodeSizeLimit
    }

    private func pageContent(for entry: PageEntry) async throws -> PageContent {
        // actor の順番待ちの間に取り消された要求は、展開係の生成や展開に進まない
        // KaitoKit の open が取消しを検査する前にも、不要な係の生成をここで抑える(設計書 §3.1)。
        try Task.checkCancellation()
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return .child(children[sourceIndex], childEntry)
        }
        if let data = try await spooledOrWaitingData(for: entry.id) { return .data(data) }
        try Task.checkCancellation()
        guard let index = Int32(exactly: entry.id) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        // 主展開で actor を塞ぐ前に断り、表示とスプールの開始を待たせない(CV4-1)。
        if shouldDeclinePrefetch(entry.id) { throw BookSourceError.temporarilyUnavailable(url) }
        if let (poolIndex, extractor) = acquireExtractor(for: entry.id) {
            return .pooled(poolIndex: poolIndex, extractor: extractor,
                           entryIndex: index)
        }
        // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開しない
        guard !exceedsPerPageDecodeLimit(index) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        guard let extracted = primaryContents(ofEntry: index) else {
            try Task.checkCancellation()
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return .data(extracted)
    }

    /// 展開係の貸し出し。perEntry は空き優先、byGroup は同一グループを同じ係へ
    /// 寄せる(グループ内直列・グループ間並列)。serial は貸し出さない
    private func acquireExtractor(for entryID: Int) -> (Int, ArchiveEntryExtractor)? {
        let poolSize = extractorPoolSizing(powerState.shouldConserveEnergy)
        switch parallelMode {
        case .serial:
            return nil
        case .perEntry:
            return acquireIdleOrGrownExtractor(poolSize: poolSize)
        case .byGroup(let groupOf):
            guard let group = groupOf[entryID] else {
                // 独立エントリはどの係でもよい
                return acquireIdleOrGrownExtractor(poolSize: poolSize)
            }
            if let assigned = groupExtractorAssignment[group], assigned < poolSize,
               extractorBusyCounts.indices.contains(assigned) {
                extractorBusyCounts[assigned] += 1
                return (assigned, extractors[assigned])
            }
            // 未割り当てグループに係を紐付ける。プールがグループ数より少ない
            // ときは相乗りになり、その係上で 2 グループが交互になると block 頭
            // からの再展開が起き得る(従来の全体巻き戻しより常に軽い)
            guard let (index, extractor) = acquireIdleOrGrownExtractor(poolSize: poolSize) else { return nil }
            // キャンセル時の一時的な相乗り先をグループの恒久割当へ残さない。
            if !Task.isCancelled { groupExtractorAssignment[group] = index }
            return (index, extractor)
        }
    }

    /// 空き優先・全員使用中のときだけ成長・成長不能時はいちばん空いている係に相乗り
    private func acquireIdleOrGrownExtractor(poolSize: Int) -> (Int, ArchiveEntryExtractor)? {
        // 電力変更で縮んだ枠の外の reader は保持し、実行中要求の完了後は貸し出さない。
        // 復帰時は再利用でき、既存 reader の並列設定は変えない(設計書 §5)。
        let available = extractorBusyCounts.indices.prefix(poolSize)
        if let idle = available.first(
            where: { extractorBusyCounts[$0] == 0 }) {
            extractorBusyCounts[idle] += 1
            return (idle, extractors[idle])
        }
        if !extractorGrowthDisabled, extractors.count < poolSize {
            // エントリ数の一致を検証してから採用する(開いた後にファイルが
            // 差し替えられた場合、一覧と食い違う内容を展開しないため)。
            // メモリ背景(暗号化親のネスト子)は共有 NSData から再オープンし、
            // 平文を disk に置かずに並列展開を保つ(cooViewer-6ax)
            let expected = archive.numberOfEntries()
            do {
                let grown: ArchiveEntryExtractor
                // 主 reader の操作と reopen を同じ actor の同期区間に閉じ込める(設計書 §7.3)。
                // 対応形式では一覧・文字コード判定を共有する。複製失敗時だけ元の入口で開く。
                if let reopened = try? archive.reopened(role: .extractor(poolSize: poolSize)) {
                    grown = try ArchiveEntryExtractor(archive: reopened, password: password,
                        expectedEntryCount: expected)
                } else if let sourceData {
                    grown = try ArchiveEntryExtractor(data: sourceData, password: password,
                        expectedEntryCount: expected, engineKind: archiveEngineKind,
                        factory: engineFactory, poolSize: poolSize)
                } else {
                    grown = try ArchiveEntryExtractor(url: url, password: password,
                        expectedEntryCount: expected, engineKind: archiveEngineKind,
                        factory: engineFactory, poolSize: poolSize)
                }
                extractors.append(grown)
                extractorBusyCounts.append(1)
                return (extractors.count - 1, grown)
            } catch {
                if !Task.isCancelled, !SourceReadFailure.mustPropagate(error) {
                    extractorGrowthDisabled = true
                }
            }
        }
        guard !extractors.isEmpty else { return nil }
        var index = 0
        for i in available
            where extractorBusyCounts[i] < extractorBusyCounts[index] { index = i }
        extractorBusyCounts[index] += 1
        return (index, extractors[index])
    }

    private func releaseExtractor(_ index: Int) {
        if extractorBusyCounts.indices.contains(index) {
            extractorBusyCounts[index] -= 1
        }
        releaseFinishedExtractorsIfIdle()
    }

    private func releaseFinishedExtractorsIfIdle() {
        guard case .finished = spoolState, !extractors.isEmpty,
              spooledIDs.count + skippedSpoolIDs.count >= outerImages.count,
              extractorBusyCounts.allSatisfy({ $0 == 0 }) else { return }
        extractors.removeAll()
        extractorBusyCounts.removeAll()
        groupExtractorAssignment.removeAll()
    }

    /// テスト用: 生成済みの展開係の数
    var extractorCount: Int { extractors.count }

    /// テスト用: mmap(メモリ背景)経由で開いたか(cooViewer-01h)
    var isMemoryMapped: Bool { sourceData != nil }

    /// テスト用: 並列粒度の名前(cooViewer-7ni)
    var parallelGranularityForTesting: String {
        switch parallelMode {
        case .serial: "serial"
        case .perEntry: "perEntry"
        case .byGroup: "byGroup"
        }
    }

    /// ファイル情報・診断表示へ、現在ページを実際に供給した書庫実装を返す。
    /// ネスト PDF/EPUB は親書庫から抽出されているため親の実装を表示する。
    func archiveEngineKind(for entry: PageEntry) async -> ArchiveEngineKind? {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return await children[sourceIndex].archiveEngineKind(for: childEntry)
                ?? archiveEngineKind
        }
        return archiveEngineKind
    }

    /// ルーペ用。ネストした PDF はベクトルから倍率連動で描き直せるよう子へ委譲する
    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return try await children[sourceIndex].loupeImage(
                for: childEntry, pixelScale: pixelScale)
        }
        return try await image(for: entry, maxPixelSize: nil)
    }

    func isEncrypted() async -> Bool {
        archive.isEncrypted()
    }

    /// ルートの ComicInfo.xml を読んで解析する(cooViewer-4fi.2)。暗号化書庫では
    /// 解錠後のみ読める(未解錠は contents が nil で自然に nil)。zip 爆弾対策で
    /// 展開後サイズが判るなら小さな上限で弾く(メタデータは通常数 KB)
    func metadata() async -> ComicInfo? {
        guard let index = comicInfoEntryIndex else { return nil }
        if archive.entryHasSize(index),
           archive.uncompressedSize(ofEntry: index) > Self.comicInfoSizeLimit {
            return nil
        }
        let data = primaryContents(ofEntry: index)
        let result = data.flatMap { ComicInfo.parse($0) }
        await touchDecodedState()
        return result
    }

    /// 最上位書庫が暗号化されている、または組み立て時にネストの暗号化書庫/PDF を
    /// 解除して束ねていれば、復号済み保護コンテンツを含む本(CWE-312)。
    /// ネストの解除は build 後に確定するため buildIfNeeded を待ってから判定する
    func containsProtectedContent() async -> Bool {
        guard (try? await buildIfNeeded()) != nil else { return true }
        if archive.isEncrypted() { return true }
        return await unlocker.sawUnlockedChild
    }

    func excludedChildCount() async -> Int { excludedCount }

    func hasSkippedLockedContent() async -> Bool {
        await unlocker.sawSkippedChild
    }

    func attachNestedPasswordProvider(_ provider: NestedPasswordProvider?) async {
        await unlocker.setProvider(provider)
    }

    func notePasswordSaveConsent(_ password: String) async {
        // 最上位ダイアログの保存同意をネスト子へ引き継ぐ(同一パスワードの
        // 子が解錠されたとき、その子のキーへも保存される)
        await unlocker.noteSaveConsent(password)
    }

    func applyMediaProfile(_ profile: MediaProfile) async {
        mediaProfile = profile
        mediaProfileApplied = true
        let independent = if case .perEntry = parallelMode { true } else { false }
        if !profile.shouldSpoolArchive(fileExtension: url.pathExtension, independentEntries: independent) {
            pauseSpooling()
        }
        for child in children {
            guard mediaProfile == profile, !Task.isCancelled else { return }
            await child.applyMediaProfile(profile)
        }
    }

    func configureSpooling(sizeLimit: Int64) async {
        await configureSpooling(sizeLimit: sizeLimit, adjustsRunningSpool: true)
    }

    /// 合本の子は合本が子ごとの予算を配るため、設定の総上限を稼働中のスプールへ入れない(CV3-1)。
    func configureSpooling(sizeLimit: Int64, adjustsRunningSpool: Bool) async {
        spoolSettingsConfigured = true
        let keepsRunningBudget = if !adjustsRunningSpool, case .running = spoolState { true } else { false }
        if !keepsRunningBudget { updateSpoolLimit(sizeLimit) }
        for child in children {
            guard keepsRunningBudget || spoolSizeLimit == sizeLimit, !Task.isCancelled else { return }
            await child.configureSpooling(sizeLimit: sizeLimit)
        }
    }

    /// 稼働中のスプールの上限だけをその場で変える。開始・停止・昇格はしない(CV3-4)。
    func adjustRunningSpoolLimit(_ sizeLimit: Int64) {
        guard case .running(let task) = spoolState, !task.isCancelled else { return }
        updateSpoolLimit(sizeLimit)
    }

    private func updateSpoolLimit(_ sizeLimit: Int64) {
        guard spoolSizeLimit != sizeLimit else { return }
        spoolSizeLimit = sizeLimit
        if case .running = spoolState {
            spoolBudget = SpoolSpacePolicy.totalBudget(sizeLimit: sizeLimit)
            diskSpoolLimit = nil
            lastSpaceCheckBytes = spooledBytes
            let budget = spoolBudget
            spoolReservation.withLock { $0.budget = budget }
        }
    }

    /// パスワードを設定し、先頭エントリの展開を試して検証する(仕様書 §4.1.3)。
    /// 画像がなくネスト書庫だけの本でも検証できるよう候補もプローブに使う。
    func checkAndSetPassword(_ password: String) async -> PasswordCheck {
        // プローブは「暗号化されているエントリ」を優先する。旧実装相当の
        // 「先頭エントリで検証」(仕様書 §4.1.3)だと、先頭が非暗号化の混在
        // 書庫で任意のパスワードが「成功」してしまい、保存パスワードの
        // 自動試行では誤値が無音で確定・永続化される(設計書 §2.4 の強化点)
        // zip 爆弾対策: 保存パスワードの自動試行では無人でプローブ展開が走る
        // ため、宣言サイズが上限内のエントリを優先する(全滅時のみ従来どおり)
        let candidates = outerImages.map { Int32($0.id) } + nestedCandidates.map(\.index)
        let safe = candidates.filter { !exceedsPerPageDecodeLimit($0) }
        let pool = safe.isEmpty ? candidates : safe
        let probe = pool.first(where: { archive.entryIsEncrypted($0) }) ?? pool.first
        // 画像も書庫/PDF もない書庫は検証しようがない(=本としては空)。
        // 拒否すると正しいパスワードでも「試行超過」になってしまうため通す
        guard let probe else { recentRawData.removeAll(); return .accepted }
        archive.setPassword(password)
        do {
            primaryHasDecodedState = true
            primaryCursor = Int(probe) + 1
            _ = try archive.readContents(ofEntry: probe)
        } catch {
            return PasswordCheck.classifyProbeFailure(error)
        }
        self.password = password
        recentRawData.removeAll()
        // ネストした子の解除でも再利用できるよう記録する
        await unlocker.addKnown(password)
        return .accepted
    }

    // MARK: - スプール

    /// 全ページのローカル展開を開始する(パスワード解除後に呼ぶこと)。
    /// 書庫順=エントリ順の逐次展開なので、ネットワーク越しでも solid 書庫でも
    /// 最速のアクセスパターンになる。表示も稼働中の逐次展開へ合流する(設計書 §5)。
    /// ネスト分は展開時点でローカルファイルになっているため対象外。
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async {
        guard (try? await buildIfNeeded()) != nil else { return }
        await configureSpooling(sizeLimit: spoolSizeLimit)
        beginSpooling(sizeLimit: spoolSizeLimit, interactive: Task.currentPriority >= .userInitiated)
    }

    /// 窓の準備係が旧巻を止める前に、開始経路と同じ方針・最小予算を確認する。
    func canBeginSpooling(sizeLimit: Int64) -> Bool {
        guard !Task.isCancelled, !assemblyLifetime.withLock({ $0.abandoned }) else { return false }
        if case .finished = spoolState { return false }
        return budgetForSpoolStart(sizeLimit: sizeLimit) != nil
    }

    private func budgetForSpoolStart(sizeLimit: Int64) -> Int64? {
        let independent = if case .perEntry = parallelMode { true } else { false }
        guard mediaProfile.shouldSpoolArchive(fileExtension: url.pathExtension, independentEntries: independent) else { return nil }
        let pending = outerImages.filter { !spooledIDs.contains($0.id) && !skippedSpoolIDs.contains($0.id) && !exceedsPerPageDecodeLimit(Int32($0.id)) }
        let cursor = if case .serial = parallelMode { primaryCursor ?? 0 } else { 0 }
        guard let first = pending.first(where: { $0.id >= cursor }) ?? pending.first else { return nil }
        let index = Int32(first.id)
        let encrypted = spoolEncrypted || archive.isEncrypted() || password != nil || contentIsSensitive
        let minimum = archive.entryHasSize(index)
            ? max(0, archive.uncompressedSize(ofEntry: index)) + (encrypted ? 28 : 0) : 64 << 20
        let budget = SpoolSpacePolicy.totalBudget(sizeLimit: sizeLimit)
        // マイクロスプールでゲートと回線を奪わない(cooViewer-tg48、設計書 §5)。
        guard budget >= spooledBytes, minimum <= budget - spooledBytes else { return nil }
        return budget
    }

    /// 対話枠を先に所有し、開始が確定してから合本の旧窓を取り消す。
    func beginSpoolingForDisplay(sizeLimit: Int64, onStart: @Sendable () -> Bool = { true }) async -> Bool {
        guard mediaProfileApplied, spoolSettingsConfigured, !Task.isCancelled else { return false }
        if case .running(let task) = spoolState, !task.isCancelled, spoolInteractive,
           spoolIsActive || spoolReservation.withLock({ $0.hasGate }) {
            guard onStart() else { return false }
            updateSpoolLimit(sizeLimit)
            return true
        }
        let generation = spoolGeneration
        let gate = Self.testingInteractiveSpoolGate ?? Self.interactiveSpoolGate
        guard await gate.tryAcquire() else {
            // 対話枠が埋まった場合は背景走査を止め、表示の主展開と二重に走らせない。
            if case .running = spoolState, !spoolInteractive { pauseSpooling() }
            return false
        }
        // 枠取得の await 中に別の表示が開始・破棄した場合は、その所有権に触れない。
        guard generation == spoolGeneration else {
            await gate.release()
            return false
        }
        if case .running(let task) = spoolState, !task.isCancelled, spoolInteractive {
            let ownsGate = spoolReservation.withLock { $0.generation == generation && $0.hasGate }
            if ownsGate {
                await gate.release()
                guard onStart() else { return false }
                updateSpoolLimit(sizeLimit)
                return true
            }
            pauseSpooling()
        }
        // 昇格の排出と新世代の登録は await を挟まない。既存の先読みも新世代へ合流できる。
        let started = beginSpooling(sizeLimit: sizeLimit, interactive: true,
                                   acquiredInteractiveSlot: true, onStart: onStart)
        if !started { await gate.release() }
        return started
    }

    @discardableResult
    func beginSpooling(sizeLimit: Int64, interactive: Bool = true,
                       acquiredInteractiveSlot: Bool = false, onStart: @Sendable () -> Bool = { true }) -> Bool {
        guard !Task.isCancelled, !assemblyLifetime.withLock({ $0.abandoned }), !outerImages.isEmpty else { return false }
        spoolSettingsConfigured = true
        // 初表示で対話枠を得た後の設定通知では背景優先度へ戻さない。
        let interactive = if case .running = spoolState { interactive || spoolInteractive } else { interactive }
        // 予算不足で開始できない場合も、直後の表示要求へ同じ上限を引き継ぐ。
        updateSpoolLimit(sizeLimit)
        switch spoolState {
        case .running(let task):
            guard task.isCancelled || interactive && !spoolInteractive else { return true }
            pauseSpooling()
        case .finished: return false
        case .idle, .paused: break
        }
        guard let limit = budgetForSpoolStart(sizeLimit: sizeLimit) else { return false }
        if spoolDirectory == nil { spoolEncrypted = archive.isEncrypted() || password != nil || contentIsSensitive }
        if spoolDirectory == nil {
            let directory = Self.spoolRoot().appendingPathComponent(
                "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil else { return false }
            spoolDirectory = directory
        }
        guard onStart() else { return false }
        diskSpoolLimit = nil
        lastSpaceCheckBytes = spooledBytes
        let generation = UUID()
        spoolGeneration = generation
        spoolInteractive = interactive
        spoolSizeLimit = sizeLimit
        spoolBudget = limit
        prepareSpoolOrder(startingAt: primaryCursor ?? 0)
        let gate = interactive ? (Self.testingInteractiveSpoolGate ?? Self.interactiveSpoolGate) : Self.backgroundSpoolGate
        let retired = retiredSpoolTask
        let reservation = spoolReservation
        // タスクが枠を取るより先に世代を記録する。取得済みの対話枠も同じ台帳で扱う。
        spoolReservation.withLock {
            $0.generation = generation
            $0.budget = limit
            $0.interactive = interactive
            $0.finished = false
            $0.hasGate = acquiredInteractiveSlot
            $0.cancelled = false
        }
        let task = Task<Void, Never>(priority: interactive ? .userInitiated : .utility) { [weak self] in
            // 同じ子をすぐ再開しても、取消し中の復号器と二重に動かさない(設計書 §5)。
            await retired?.value
            let acquired = if acquiredInteractiveSlot { true } else { await gate.acquire(interactive: interactive) }
            guard acquired else {
                await self?.finishSpooling(generation)
                return
            }
            reservation.withLock { if $0.generation == generation { $0.hasGate = true } }
            var order: [Int]?
            if !Task.isCancelled { order = await self?.markSpoolingActive(generation) }
            if order == nil { await self?.finishSpooling(generation) }
            while let ids = order {
                var budgetStopped = false
                spoolLoop: for id in ids {
                    guard !Task.isCancelled else { break }
                    guard let step = await self?.willSpool(id, generation: generation) else { break }
                    switch step {
                    case .skip: continue
                    case .budget:
                        budgetStopped = true
                        break spoolLoop
                    case .extract(let worker, let key, let file, let remaining):
                        let outcome = await worker.extract(Int32(id), key: key, to: file, byteLimit: remaining)
                        guard await self?.didSpool(id, outcome: outcome, generation: generation, directory: file.deletingLastPathComponent()) == true else { break spoolLoop }
                    case .primary:
                        guard await self?.spoolPrimary(id, generation: generation) == true else { break spoolLoop }
                    }
                    await Task.yield()
                }
                if budgetStopped, let hook = ArchiveSource.testingAfterSpoolBudgetStop { await hook() }
                // 予算停止の後に上限がその場で上がっていれば、同じ復号器のまま続きを走査する。
                order = await self?.continueOrFinishSpooling(generation, budgetStopped: budgetStopped)
            }
            await self?.touchDecodedState()
            await gate.release()
        }
        spoolState = .running(task)
        spoolReservation.withLock {
            $0.task = task
            if $0.cancelled { task.cancel() }
        }
        return true
    }

    private func markSpoolingActive(_ generation: UUID) -> [Int]? {
        guard generation == spoolGeneration, !Task.isCancelled,
              !assemblyLifetime.withLock({ $0.abandoned }) else { return nil }
        spoolIsActive = true
        if case .serial = parallelMode, let engine = archive.reopened() {
            if let primaryCursor, primaryCursor > 0 {
                // 位置付きの実体を移し、主 actor には独立した新しい実体だけを残す。
                let positioned = archive
                archive = engine
                self.primaryCursor = nil
                primaryHasDecodedState = false
                spoolWorker = ArchiveSpoolWorker(adopting: ArchiveEngineHandoff(positioned))
                prepareSpoolOrder(startingAt: primaryCursor)
            } else {
                spoolWorker = ArchiveSpoolWorker(archive: engine)
                prepareSpoolOrder(startingAt: 0)
            }
        } else {
            prepareSpoolOrder(startingAt: 0)
        }
        // 待機中に主側が前進した場合も、順序変更後に届かなくなった票を残さない。
        for id in spoolWaiters.entryIDs where spoolWorker == nil || !spoolWillReach(id) {
            spoolWaiters.resume(id)
        }
        return spoolOrder
    }

    private func prepareSpoolOrder(startingAt cursor: Int) {
        let pending = outerImages.map(\.id).filter { !spooledIDs.contains($0) && !skippedSpoolIDs.contains($0) }
        // 引き渡した位置から末尾まで進み、その後で未保存の先頭部分を補う。
        let tail = pending.filter { $0 >= cursor }
        spoolTailCount = tail.count
        spoolOrder = tail + pending.filter { $0 < cursor }
        spoolOrderOffsets = Dictionary(uniqueKeysWithValues: spoolOrder.enumerated().map { ($0.element, $0.offset) })
        spoolOrderPosition = 0
        spoolCosts = [0]
        spoolUnknownCosts = [0]
        for id in spoolOrder {
            let index = Int32(id)
            let size = archive.uncompressedSize(ofEntry: index)
            let skipped = exceedsPerPageDecodeLimit(index)
            let known = archive.entryHasSize(index) && size >= 0
            let cost = skipped || !known ? 0 : size + (spoolEncrypted ? 28 : 0)
            let sum = spoolCosts.last!.addingReportingOverflow(cost)
            spoolCosts.append(sum.overflow ? .max : sum.partialValue)
            spoolUnknownCosts.append(spoolUnknownCosts.last! + (!skipped && (!known || sum.overflow) ? 1 : 0))
        }
    }

    private func spoolWillReach(_ id: Int) -> Bool {
        guard let offset = spoolOrderOffsets[id], offset >= spoolOrderPosition,
              !(spoolOrderPosition < spoolTailCount && offset >= spoolTailCount),
              !skippedSpoolIDs.contains(id), !exceedsPerPageDecodeLimit(Int32(id)),
              spoolUnknownCosts[offset + 1] == spoolUnknownCosts[spoolOrderPosition] else { return false }
        let cost = spoolCosts[offset + 1] - spoolCosts[spoolOrderPosition]
        let remaining = max(0, min(spoolBudget, diskSpoolLimit ?? spoolBudget) - spooledBytes)
        return cost <= remaining
    }

    private enum SpoolStep: Sendable {
        case skip
        /// 残予算に収まらないため、このエントリの境界で止める。
        case budget
        case primary
        case extract(ArchiveSpoolWorker, SymmetricKey?, URL, Int64)
    }

    private func willSpool(_ id: Int, generation: UUID) -> SpoolStep? {
        guard generation == spoolGeneration, spoolIsActive, !Task.isCancelled,
              !assemblyLifetime.withLock({ $0.abandoned }), let directory = spoolDirectory else { return nil }
        if spooledIDs.contains(id) || skippedSpoolIDs.contains(id) { return .skip }
        spoolOrderPosition = spoolOrderOffsets[id] ?? spoolOrderPosition
        if exceedsPerPageDecodeLimit(Int32(id)) {
            skippedSpoolIDs.insert(id)
            spoolWaiters.resume(id)
            return .skip
        }
        // 空き容量は開始前と 64 MiB ごとに再評価し、未知サイズも書き込み前に実サイズで止める。
        if spooledBytes - lastSpaceCheckBytes >= 64 << 20 {
            diskSpoolLimit = SpoolSpacePolicy.totalBudget(sizeLimit: spoolSizeLimit)
            lastSpaceCheckBytes = spooledBytes
        }
        let remaining = max(0, min(spoolBudget, diskSpoolLimit ?? spoolBudget) - spooledBytes)
        let overhead: Int64 = spoolEncrypted ? 28 : 0
        guard spoolEntryFits(id, remaining: remaining) else { return .budget }
        let reservation = archive.entryHasSize(Int32(id))
            ? archive.uncompressedSize(ofEntry: Int32(id)) + overhead : remaining
        let reserved = spoolReservation.withLock { state in
            // 窓移動の取消しと予約を同じロックで直列化し、集計後の新規書き込みを防ぐ。
            guard !Task.isCancelled else { return false }
            state.inFlight = reservation
            return true
        }
        guard reserved else { return nil }
        if let spoolWorker {
            return .extract(spoolWorker, spoolEncrypted ? spoolKey : nil,
                            directory.appendingPathComponent(String(id), isDirectory: false), remaining)
        }
        return .primary
    }
    private var lastSpaceCheckBytes: Int64 = 0
    private var diskSpoolLimit: Int64?

    /// 宣言サイズのあるエントリが残予算に収まるか。未知サイズは書き込み時の上限で止める。
    private func spoolEntryFits(_ id: Int, remaining: Int64) -> Bool {
        guard archive.entryHasSize(Int32(id)) else { return true }
        let size = archive.uncompressedSize(ofEntry: Int32(id))
        let overhead: Int64 = spoolEncrypted ? 28 : 0
        return size >= 0 && remaining >= overhead && size <= remaining - overhead
    }

    /// 予算停止から終了処理までの間に上限がその場で上がった場合は、終了せずに続きの順序を返す。
    /// 判定と終了を同じ actor 区間で行い、上限の引き上げを読み落として停止したままにしない(CV3-4)。
    private func continueOrFinishSpooling(_ generation: UUID, budgetStopped: Bool) -> [Int]? {
        if budgetStopped, generation == spoolGeneration, spoolIsActive, !Task.isCancelled,
           !assemblyLifetime.withLock({ $0.abandoned }), spoolDirectory != nil,
           spoolOrder.indices.contains(spoolOrderPosition) {
            let id = spoolOrder[spoolOrderPosition]
            let remaining = max(0, min(spoolBudget, diskSpoolLimit ?? spoolBudget) - spooledBytes)
            if spoolEntryFits(id, remaining: remaining) { return Array(spoolOrder[spoolOrderPosition...]) }
        }
        finishSpooling(generation)
        return nil
    }

    private func spoolPrimary(_ id: Int, generation: UUID) -> Bool {
        guard generation == spoolGeneration, !Task.isCancelled, let directory = spoolDirectory else { return false }
        let outcome: SpoolOutcome
        if let data = primaryContents(ofEntry: Int32(id)) {
            outcome = ArchiveSpoolWorker.store(data, key: spoolEncrypted ? spoolKey : nil,
                to: directory.appendingPathComponent(String(id), isDirectory: false),
                byteLimit: max(0, min(spoolBudget, diskSpoolLimit ?? spoolBudget) - spooledBytes))
        } else { outcome = .skipped }
        return didSpool(id, outcome: outcome, generation: generation, directory: directory)
    }

    private func didSpool(_ id: Int, outcome: SpoolOutcome, generation: UUID, directory: URL) -> Bool {
        // pause と atomic write 完了が競争しても、同じディレクトリの実バイトを台帳から落とさない。
        // discard 後の古い結果だけは、新しいスプールへ書き戻さない(設計書 §5)。
        guard directory == spoolDirectory else { return false }
        let active = generation == spoolGeneration && spoolIsActive && !Task.isCancelled
        if case .stored(_, let bytes) = outcome, spooledIDs.insert(id).inserted { spooledBytes += bytes }
        let storedBytes = spooledBytes
        spoolReservation.withLock { $0.bytes = storedBytes; $0.inFlight = 0 }
        guard active else { return false }
        switch outcome {
        case .stored(let data, _):
            spoolWaiters.resume(id, data: data)
        case .skipped:
            skippedSpoolIDs.insert(id)
            spoolWaiters.resume(id)
        case .failed:
            spoolWaiters.resume(id)
            return false
        }
        spoolOrderPosition += 1
        return true
    }

    func pauseSpooling() {
        guard case .running(let task) = spoolState else { return }
        task.cancel()
        retiredSpoolTask = task
        spoolGeneration = UUID()
        spoolIsActive = false
        spoolWorker = nil
        spoolState = .paused
        spoolWaiters.resume()
    }

    func discardSpool() async {
        pauseSpooling()
        let retired = retiredSpoolTask
        let directory = spoolDirectory
        spoolDirectory = nil
        spooledIDs.removeAll()
        skippedSpoolIDs.removeAll()
        spooledBytes = 0
        spoolReservation.withLock { $0.bytes = 0; $0.finished = false }
        recentRawData.removeAll()
        spoolState = .idle
        // 取消し直前の atomic write も終わってからディレクトリを消す(設計書 §5)。
        let cleanup = Task.detached(priority: .utility) {
            await retired?.value
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        retiredSpoolTask = cleanup
        await cleanup.value
    }

    private func finishSpooling(_ generation: UUID) {
        spoolReservation.withLock {
            if $0.generation == generation { $0.task = nil; $0.budget = 0; $0.inFlight = 0; $0.hasGate = false }
        }
        guard generation == spoolGeneration else { return }
        spoolWorker = nil
        spoolIsActive = false
        if spooledIDs.count + skippedSpoolIDs.count == outerImages.count {
            archive.discardDecodedState()
            primaryCursor = nil
            primaryHasDecodedState = false
            spoolState = .finished
            spoolReservation.withLock { $0.finished = true }
            releaseFinishedExtractorsIfIdle()
        } else { spoolState = .paused }
        spoolWaiters.resume()
    }

    private func spooledOrWaitingData(for id: Int) async throws -> Data? {
        if let data = spooledData(for: id) { return data }
        guard !spooledIDs.contains(id) else { return nil }
        if PageRequestIntent.isDisplay, case .serial = parallelMode {
            if case .idle = spoolState {
                _ = await beginSpoolingForDisplay(sizeLimit: spoolSizeLimit)
            } else if case .running = spoolState, !spoolInteractive {
                guard await beginSpoolingForDisplay(sizeLimit: spoolSizeLimit) else { return nil }
            }
        }
        if let data = spooledData(for: id) { return data }
        let generation = spoolGeneration
        let ownsGate = spoolReservation.withLock { $0.generation == generation && $0.hasGate }
        guard case .serial = parallelMode, case .running(let task) = spoolState, !task.isCancelled,
              (spoolIsActive && spoolWorker != nil || !spoolIsActive && spoolInteractive && ownsGate),
              spoolWillReach(id) else { return nil }
        // 登録までは同じ actor 上で行い、完了と登録の隙間を作らない(設計書 §5)。
        let waitingGeneration = spoolGeneration
        let data = try await spoolWaiters.wait(for: id)
        try Task.checkCancellation()
        if data == nil, waitingGeneration != spoolGeneration, case .running = spoolState {
            // 昇格で排出された先読みも新しい走査へ合流し、主側で TIFF を読み直さない。
            return try await spooledOrWaitingData(for: id)
        }
        return data ?? spooledData(for: id)
    }

    /// 先読みが solid の主展開を始めてよいか。スプールの開始が見込まれる間は断る(CV4-1、設計書 §5)。
    /// 未開始・ゲート待ちの走査と、末尾走査中に後で届く先頭部分を断る。方針「しない」・予算外・
    /// 停止中は従来どおり主書庫で読み、稼働中の走査が届く id は spooledOrWaitingData が待つ。
    private func shouldDeclinePrefetch(_ id: Int) -> Bool {
        guard PageRequestIntent.isPrefetch, !PageRequestIntent.isDisplay, case .serial = parallelMode,
              mediaProfileApplied, spoolSettingsConfigured,
              !spooledIDs.contains(id), !skippedSpoolIDs.contains(id),
              !exceedsPerPageDecodeLimit(Int32(id)),
              !assemblyLifetime.withLock({ $0.abandoned }) else { return false }
        switch spoolState {
        case .idle:
            return budgetForSpoolStart(sizeLimit: spoolSizeLimit) != nil
        case .running(let task):
            guard !task.isCancelled else { return false }
            let generation = spoolGeneration
            let ownsGate = spoolReservation.withLock { $0.generation == generation && $0.hasGate }
            // 枠待ちでは待機票を登録できないため、主展開へ進まず予算内の先読みを断る(CV5-1)。
            if !spoolIsActive && !ownsGate && spoolWillReach(id) { return true }
            guard spoolOrderPosition < spoolTailCount,
                  let offset = spoolOrderOffsets[id], offset >= spoolTailCount else { return false }
            return spoolWillReachAfterTail(offset)
        case .paused, .finished:
            return false
        }
    }

    /// 末尾走査の後で先頭部分のこの位置まで予算内に届くか(spoolWillReach の末尾条件を除いた判定)。
    private func spoolWillReachAfterTail(_ offset: Int) -> Bool {
        guard spoolCosts.indices.contains(offset + 1), spoolCosts.indices.contains(spoolOrderPosition),
              spoolUnknownCosts[offset + 1] == spoolUnknownCosts[spoolOrderPosition] else { return false }
        let cost = spoolCosts[offset + 1] - spoolCosts[spoolOrderPosition]
        let remaining = max(0, min(spoolBudget, diskSpoolLimit ?? spoolBudget) - spooledBytes)
        return cost <= remaining
    }

    func spoolDemandBytes() -> Int64? {
        var result: Int64 = 0
        for entry in outerImages where !spooledIDs.contains(entry.id) && !skippedSpoolIDs.contains(entry.id) {
            let index = Int32(entry.id)
            guard archive.entryHasSize(index) else { return nil }
            let size = archive.uncompressedSize(ofEntry: index)
            guard size >= 0, size <= Int64.max - result else { return nil }
            result += size
        }
        return result
    }

    /// スプール完了を待つ(テスト・診断用)。一時停止時も取消し中の復号器の終了まで待つ。
    func waitForSpoolCompletion() async {
        if case .running(let task) = spoolState { await task.value }
        else { await retiredSpoolTask?.value }
    }

    var spooledEntryCount: Int { spooledIDs.count }
    private var spooledBytes: Int64 = 0

    struct SpoolStats: Sendable, Equatable {
        let spooled: Int
        let total: Int
        let bytes: Int64
        let active: Bool
        let paused: Bool
    }
    func spoolStats() -> SpoolStats {
        let active = if case .running = spoolState { true } else { false }
        let paused = if case .paused = spoolState { true } else { false }
        return SpoolStats(spooled: spooledIDs.count, total: outerImages.count,
                          bytes: spooledBytes, active: active, paused: paused)
    }

    private func spooledData(for id: Int) -> Data? {
        guard spooledIDs.contains(id), let directory = spoolDirectory else { return nil }
        // スプールファイルは書き切り後は不変(アプリ所有)なのでマップ読みが安全。
        // 大きなページのコピーを 1 回分省く
        let raw = try? Data(contentsOf: directory.appendingPathComponent(String(id)),
                            options: .mappedIfSafe)
        guard let raw else { return nil }
        guard spoolEncrypted else { return raw }
        return SuperResCacheCrypto.open(raw, using: spoolKey)
    }
}

/// 書庫エントリの展開係(独立した書庫エンジンを actor で直列化)。
/// ArchiveSource がプールとして複数持ち、エントリ独立圧縮の形式(zip 系)で
/// エントリ間の並列展開を実現する(PDFPageRenderer と同型)
actor ArchiveEntryExtractor {
    private let archive: any ArchiveEngine

    /// 複製した reader も件数を照合する。拒否されたプローブが主 reader のパスワードを変えても、
    /// 展開係には受理済みの値を渡す従来の生成経路に揃える(設計書 §2.4、§5)。
    init(archive: sending any ArchiveEngine, password: String?, expectedEntryCount: Int32) throws {
        if let password { archive.setPassword(password) }
        guard archive.numberOfEntries() == expectedEntryCount else {
            throw KaitoError.malformed("extractor entry count changed")
        }
        self.archive = archive
    }

    /// expectedEntryCount: メイン書庫のエントリ数。開いた後にファイルが
    /// 差し替えられていた場合に、一覧と食い違う内容を展開しないための検証
    /// (エントリ数が同じ差し替えまでは検出しない割り切り。PDF 側と同じ)
    init(url: URL, password: String?, expectedEntryCount: Int32,
         engineKind: ArchiveEngineKind, factory: ArchiveEngineFactory, poolSize: Int) throws {
        guard let archive = try factory.openFile(engineKind, url.path, .extractor(poolSize: poolSize)) else {
            throw KaitoError.malformed("extractor open failed")
        }
        if let password { archive.setPassword(password) }
        guard archive.numberOfEntries() == expectedEntryCount else {
            throw KaitoError.malformed("extractor entry count changed")
        }
        self.archive = archive
    }

    /// メモリ背景版。平文を disk に置かず、共有 NSData から独立した係を作る。
    init(data: Data, password: String?, expectedEntryCount: Int32,
         engineKind: ArchiveEngineKind, factory: ArchiveEngineFactory, poolSize: Int) throws {
        guard let archive = try factory.openData(engineKind, data, .extractor(poolSize: poolSize)) else {
            throw KaitoError.malformed("extractor open failed")
        }
        if let password { archive.setPassword(password) }
        guard archive.numberOfEntries() == expectedEntryCount else {
            throw KaitoError.malformed("extractor entry count changed")
        }
        self.archive = archive
    }

    func contents(ofEntry index: Int32) -> Data? {
        // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開しない。
        // 独立書庫なので ArchiveSource と同じ判定をここでも行う
        // (サイズ不明なら通す。32bit の size(ofEntry:) は使わない)
        if archive.entryHasSize(index),
           archive.uncompressedSize(ofEntry: index) > ArchiveSource.perPageDecodeSizeLimit {
            return nil
        }
        return archive.contents(ofEntry: index)
    }
}


extension ArchiveSource: ArchiveDecodedStateOwner {
    func releaseIdleDecodedState() -> Bool {
        recentRawData.removeAll()
        guard !isBuilding, !spoolIsActive,
              extractorBusyCounts.allSatisfy({ $0 == 0 }) else { return false }
        archive.discardDecodedState()
        primaryCursor = nil
        primaryHasDecodedState = false
        extractors.removeAll()
        extractorBusyCounts.removeAll()
        groupExtractorAssignment.removeAll()
        return true
    }
}
