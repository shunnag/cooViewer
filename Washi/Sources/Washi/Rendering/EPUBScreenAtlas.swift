import AppKit
import Foundation

/// テスト差替用のシーム: 制御可能な fake census を注入できるようにする
/// (実 census は WKWebView を駆動し XCTest では決定論的に動かないため)。
/// 本番は常に `EPUBPaginationCensus` を使う
@MainActor
protocol ScreenPageCensusing {
    func measure(publication: EPUBPublication, optionsJSON: String,
                 contentSize: NSSize) async -> [Int]?
    func invalidate()
}

extension EPUBPaginationCensus: ScreenPageCensusing {}

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
    private let census: any ScreenPageCensusing
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
    /// invalidate 後は新規計測/描画を受け付けない(EPUBPageRasterizer・
    /// EPUBScreenThumbnailRenderer と同じ契約)。これがないと、LRU 追い出しで
    /// invalidate したあとに残った呼び出し元が census.measure / 新しい renderer を
    /// 起動し、不可視ウインドウ・WebContent プロセスを蘇らせてしまう(誰も畳まない)
    private var isInvalidated = false

    public init(publication: EPUBPublication) {
        self.publication = publication
        self.census = EPUBPaginationCensus()
    }

    /// テスト用: fake census を注入するイニシャライザ
    init(publication: EPUBPublication, census: any ScreenPageCensusing) {
        self.publication = publication
        self.census = census
    }

    /// テスト用: 実測中(合流対象)のメトリクスキー集合。並行要求の登録を
    /// 決定論的に待つため
    func inFlightMeasureKeys() -> Set<String> { Set(measuring.keys) }

    /// Explicitly tears down the offscreen resources (the invisible windows and
    /// WebContent processes of the census and renderer). **Always call this when
    /// releasing the atlas (e.g. on eviction from a cache)** — it stops any
    /// in-progress measurement or render so the processes are not kept alive for
    /// the host's entire lifetime. After this call the atlas refuses further work
    /// (`screenCounts`/`thumbnail` return nil); do not reuse this instance.
    public func invalidate() {
        isInvalidated = true
        for task in measuring.values { task.cancel() }
        measuring.removeAll()
        newestRequestedKey = nil
        census.invalidate()
        renderer?.invalidate()
        renderer = nil
    }

    /// Page count of each spine item (measured; cached per metrics).
    /// Returns nil on failure (timeout or WebContent death) or after `invalidate()`.
    public func screenCounts(metrics: EPUBScreenMetrics) async -> [Int]? {
        guard !isInvalidated else { return nil }
        let key = metrics.censusOptionsJSON
        if let cached = countsCache[key] { return cached }
        // 合流の前に newestRequestedKey を更新する。実行待ち(FIFO)の古いキーが
        // 要求し直されたとき newest を戻さないと、running タスクの guard
        // (newestRequestedKey==key)が外れて表示中メトリクスなのに nil を返す。
        // キャッシュ命中(上の分岐)では触らない — 進行中のより新しい計測を
        // 誤って中断しないため
        newestRequestedKey = key
        if let running = measuring[key] { return await running.value }
        // 優先度は明示 userInitiated(低 QoS 継承だと WebKit への JS 実行が
        // 応答しない — EPUBScreenThumbnailRenderer で実測した逆転)
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
        // 完了したのが「今この key に載っているタスク」のときだけ外す(タスク
        // 同一性)。invalidate 後に別タスクが再登録される経路は isInvalidated で
        // 構造的に閉じるが、辞書の取り違え(完了済み task が後発の別 task を消す)を
        // 防ぐ保険として同一性を照合する
        if measuring[key] == task { measuring[key] = nil }
        if let counts { countsCache[key] = counts }
        return counts
    }

    /// Thumbnail for the given screen (nil on failure or after `invalidate()`).
    public func thumbnail(spineIndex: Int, pageInItem: Int,
                          metrics: EPUBScreenMetrics, isDark: Bool,
                          width: CGFloat) async -> CGImage? {
        guard !isInvalidated else { return nil }
        let renderer = self.renderer
            ?? EPUBScreenThumbnailRenderer(publication: publication)
        self.renderer = renderer
        return await renderer.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            optionsJSON: metrics.themedOptionsJSON(isDark: isDark),
            contentSize: metrics.contentSize, snapshotWidth: width)
    }
}
