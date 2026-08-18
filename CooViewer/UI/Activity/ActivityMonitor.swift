import AppKit
import Foundation

/// アクティビティ窓に映す、ある時点の実態スナップショット(値型)。
/// 表示する値はすべて実在の内部状態から取得したもので、取れないもの
/// (ヒット率・ML タイル進捗等)は持たない(捏造しない。設計書 §2.4)
struct ActivitySnapshot: Sendable, Equatable {
    struct BookInfo: Sendable, Equatable {
        let name: String
        let kind: String
        let media: String
        let pageCount: Int
        let currentPage: Int      // 1 始まり
        let encrypted: Bool
    }
    struct Loading: Sendable, Equatable {
        let planAhead: Int        // 計画: 設定
        let planBehind: Int
        let actualAhead: Int      // 実態: 媒体で注入された実効値
        let actualBehind: Int
        let concurrency: Int      // 計画: 媒体別の並列度
        let inFlightDecodes: Int  // 実態
        let displayCount: Int     // 実態: 表示中スプレッド枚数
    }
    struct Resample: Sendable, Equatable {
        let interpolation: String // 計画
        let noiseLevel: String    // 計画
        let displayActive: Bool   // 実態: 表示中リサンプル進行
        let inFlightRequests: Int // 実態
        let completed: Int        // 実態: 完成枚数(最大 displayCount)
        let prefetchActive: Int   // 実態: 先読みリサンプル進行中
        let prefetchRemaining: Int // 実態: 先読みリサンプルの残りページ数
        let prefetchPlanned: Int   // 実態: 先読みリサンプルの計画ページ数
        let processingEntryID: Int? // 実態: 先読み処理中のページID
    }
    struct LRU: Sendable, Equatable {
        let count: Int
        let usedBytes: Int
        let limitBytes: Int
    }
    struct PrefetchPlan: Sendable, Equatable {
        let pageBudget: Int       // 計画: PreresamplePolicy 再計算
        let byteBudget: Int
    }
    struct Spool: Sendable, Equatable {
        let spooled: Int
        let total: Int
        let bytes: Int64
        let limitBytes: Int64     // 計画
        let active: Bool
    }
    struct ML: Sendable, Equatable {
        let noiseState: String
        let superResState: String
        let diskCount: Int
        let diskBytes: Int64
        let encrypted: Bool
    }
    struct Memory: Sendable, Equatable {
        let physical: Int64
        let resident: Int64?      // 取れないときは nil(行を出さない)
        let pageCacheCount: Int
        let pageCacheBytes: Int
        let pageCacheLimit: Int
        let displayCap: Int?      // 実態(最後に適用された値)
        let zoomScale: Double
    }

    var book: BookInfo?
    var loading: Loading?
    var resample: Resample?
    var lru: LRU?
    var prefetchPlan: PrefetchPlan?
    var spool: Spool?
    var ml: ML
    var memory: Memory?

    /// 本を開いていない時の空スナップショット(ML の導入状態だけは常に映す)
    static func empty(ml: ML) -> ActivitySnapshot {
        ActivitySnapshot(book: nil, loading: nil, resample: nil, lru: nil,
                         prefetchPlan: nil, spool: nil, ml: ml, memory: nil)
    }
}

/// アクティビティ窓のデータ供給。窓が開いている間だけ ~0.7s 間隔で
/// スナップショットを更新し、閉じたら停止する(actor への query を止める)。
/// Timer で Task を積み上げず、単一の逐次ループで重なりを防ぐ
@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var snapshot: ActivitySnapshot

    private weak var controller: ReaderWindowController?
    private var refreshTask: Task<Void, Never>?

    init(controller: ReaderWindowController?) {
        self.controller = controller
        snapshot = .empty(ml: Self.mlSnapshot(encrypted: false))
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let next = await self.makeSnapshot()
                if next != self.snapshot { self.snapshot = next }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - スナップショット構築

    private static func mlSnapshot(encrypted: Bool) -> ActivitySnapshot.ML {
        let disk = MLSuperResolver.diskCacheStats()
        return ActivitySnapshot.ML(
            noiseState: describe(MLModelInstallStatus.noise.state),
            superResState: describe(MLModelInstallStatus.superResolution.state),
            diskCount: disk.count, diskBytes: disk.bytes, encrypted: encrypted)
    }

    private static func describe(_ state: MLModelInstallStatus.State) -> String {
        switch state {
        case .notInstalled: String(localized: "Not installed")
        case .downloading: String(localized: "Downloading…")
        case .ready: String(localized: "Ready")
        case .failed: String(localized: "Unavailable")
        }
    }

    private func makeSnapshot() async -> ActivitySnapshot {
        let encrypted = controller?.currentBookIsEncrypted ?? false
        let ml = Self.mlSnapshot(encrypted: encrypted)
        guard let controller, let book = controller.book, book.pageCount > 0 else {
            return .empty(ml: ml)
        }
        let view = controller.readerViewForInput
        let settings = SettingsStore()
        let physical = Int64(clamping: ProcessInfo.processInfo.physicalMemory)

        let bookInfo = ActivitySnapshot.BookInfo(
            name: book.displayName,
            kind: Self.kind(of: book.source),
            media: Self.media(book.mediaProfile),
            pageCount: book.pageCount,
            currentPage: book.currentPageIndex + 1,
            encrypted: encrypted)

        let loading = ActivitySnapshot.Loading(
            planAhead: settings.prefetchAheadCount,
            planBehind: settings.prefetchBehindCount,
            actualAhead: book.prefetchAhead,
            actualBehind: book.prefetchBehind,
            concurrency: book.mediaProfile.bookPrefetchConcurrency,
            inFlightDecodes: book.inFlightLoadCount,
            displayCount: book.displayedPageCount)

        let resample = ActivitySnapshot.Resample(
            interpolation: Self.interpolationName(view.interpolation),
            noiseLevel: Self.noiseLevelName(view.noiseReductionLevel),
            displayActive: controller.displayResampleActiveValue,
            inFlightRequests: view.resampleInFlightCount,
            completed: view.resampledCompletedCount,
            prefetchActive: controller.prefetchResampleActiveCount,
            prefetchRemaining: controller.prefetchRemainingPageCount,
            prefetchPlanned: controller.prefetchPlannedPageCount,
            processingEntryID: controller.preresamplingEntryIDValue)

        let stats = await ImageResampler.shared.stats()
        let lru = ActivitySnapshot.LRU(count: stats.count, usedBytes: stats.usedBytes,
                                       limitBytes: stats.limitBytes)

        let prefetchPlan = ActivitySnapshot.PrefetchPlan(
            pageBudget: PreresamplePolicy.maxPages,
            byteBudget: PreresamplePolicy.byteBudget(
                physicalMemory: ProcessInfo.processInfo.physicalMemory))

        var spool: ActivitySnapshot.Spool?
        if let archive = controller.currentArchiveSource {
            let s = await archive.spoolStats()
            spool = ActivitySnapshot.Spool(
                spooled: s.spooled, total: s.total, bytes: s.bytes,
                limitBytes: settings.archiveSpoolSizeLimit, active: s.active)
        }

        let cacheStats = await book.pageCacheStats()
        let memory = ActivitySnapshot.Memory(
            physical: physical,
            resident: MemoryFootprint.residentBytes(),
            pageCacheCount: cacheStats.count,
            pageCacheBytes: cacheStats.cost,
            pageCacheLimit: settings.pageCacheByteLimit,
            displayCap: book.displayPixelCap,
            zoomScale: Double(view.currentZoomScale))

        return ActivitySnapshot(book: bookInfo, loading: loading, resample: resample,
                                lru: lru, prefetchPlan: prefetchPlan, spool: spool,
                                ml: ml, memory: memory)
    }

    // MARK: - 表示名の整形

    private static func kind(of source: any BookSource) -> String {
        switch source {
        case is FolderSource: String(localized: "Folder")
        case is NestedFolderSource: String(localized: "Collection folder")
        case is ArchiveSource: String(localized: "Archive")
        case is PDFSource: String(localized: "PDF")
        default: String(localized: "Book")
        }
    }

    private static func media(_ profile: MediaProfile) -> String {
        switch profile.mediaClass {
        case .fastLocal: String(localized: "SSD / fast local")
        case .slowLocal: String(localized: "HDD / slow local")
        case .network: String(localized: "Network")
        case .unknown: String(localized: "Unknown")
        }
    }

    private static func interpolationName(_ i: ReaderView.Interpolation) -> String {
        switch i {
        case .none: String(localized: "None")
        case .low: String(localized: "Low")
        case .systemDefault: String(localized: "Standard")
        case .high: String(localized: "High (MetalFX)")
        }
    }

    private static func noiseLevelName(_ l: NoiseReductionLevel) -> String {
        switch l {
        case .none: String(localized: "Off")
        case .light: String(localized: "Weak")
        case .medium: String(localized: "Medium")
        case .strong: String(localized: "Very High (ML)")
        case .maximum: String(localized: "Maximum (×4 ML)")
        }
    }
}
