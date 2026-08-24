import AppKit
import Foundation

/// Public facade for obtaining an EPUB's screen plan (measured per-item page
/// counts) and screen thumbnails without opening the reader. Used to fully
/// expand a reflowable EPUB into all of its pages within a collection (merged
/// book) listing.
/// The census and renderer share the exact same implementation used inside the
/// reader (EPUBScreenMetrics is the single source of truth), so the pagination
/// is guaranteed to match what you get when the book is later opened.
@MainActor
public final class EPUBScreenAtlas {
    public let publication: EPUBPublication
    private let census = EPUBPaginationCensus()
    private var renderer: EPUBScreenThumbnailRenderer?
    /// メトリクスキー → 項目別ページ数
    private var countsCache: [String: [Int]] = [:]
    /// 実測中の合流(同一メトリクスの並行要求で census を二重に走らせない)
    private var measuring: [String: Task<[Int]?, Never>] = [:]
    /// 異なるメトリクスキー間の FIFO 直列化(census は共有 WKWebView を使う
    /// ため、並走するとナビゲーションイベントの取り違えで失敗や
    /// 「1 項目ずれた実測値」のキャッシュ汚染が起きる — レンダラと同方式)
    private var lastMeasure: Task<Void, Never>?
    /// 最後に要求されたキー(リサイズ連打等で放棄された古いキーの
    /// 積み残し実測を、開始前に no-op で捨てるためのゲート)
    private var newestRequestedKey: String?

    public init(publication: EPUBPublication) {
        self.publication = publication
    }

    /// Explicitly tears down the offscreen resources (the invisible windows and
    /// WebContent processes of the census and renderer). **Always call this when
    /// releasing the atlas (e.g. on eviction from a cache)** — it stops any
    /// in-progress measurement or render so the processes are not kept alive for
    /// the host's entire lifetime. Do not reuse this instance after calling it.
    public func invalidate() {
        for task in measuring.values { task.cancel() }
        measuring.removeAll()
        newestRequestedKey = nil
        census.invalidate()
        renderer?.invalidate()
        renderer = nil
    }

    /// Page count of each spine item (measured; cached per metrics).
    /// Returns nil on failure (timeout or WebContent death).
    public func screenCounts(metrics: EPUBScreenMetrics) async -> [Int]? {
        let key = metrics.censusOptionsJSON
        if let cached = countsCache[key] { return cached }
        if let running = measuring[key] { return await running.value }
        // 優先度は明示 userInitiated(低 QoS 継承だと WebKit への JS 実行が
        // 応答しない — EPUBScreenThumbnailRenderer で実測した逆転)
        newestRequestedKey = key
        let previous = lastMeasure
        let task = Task(priority: .userInitiated) {
            [census, publication, weak self] () -> [Int]? in
            _ = await previous?.value  // 先行キーの実測完了を待つ(FIFO)
            // 待っている間により新しいキーが要求されていたら、この古い
            // キーの実測は始めない(リサイズ連打での無駄な全項目実測防止)
            guard self?.newestRequestedKey == key else { return nil }
            return await census.measure(publication: publication, optionsJSON: key,
                                        contentSize: metrics.contentSize)
        }
        measuring[key] = task
        lastMeasure = Task(priority: .userInitiated) { _ = await task.value }
        let counts = await task.value
        measuring[key] = nil
        if let counts { countsCache[key] = counts }
        return counts
    }

    /// Thumbnail for the given screen (nil on failure).
    public func thumbnail(spineIndex: Int, pageInItem: Int,
                          metrics: EPUBScreenMetrics, isDark: Bool,
                          width: CGFloat) async -> CGImage? {
        let renderer = self.renderer
            ?? EPUBScreenThumbnailRenderer(publication: publication)
        self.renderer = renderer
        return await renderer.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            optionsJSON: metrics.themedOptionsJSON(isDark: isDark),
            contentSize: metrics.contentSize, snapshotWidth: width)
    }
}
