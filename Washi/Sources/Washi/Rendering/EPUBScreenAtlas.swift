import AppKit
import Foundation

/// リーダーを開かずに EPUB の画面計画(項目別ページ数の実測)と
/// 画面サムネイルを得る公開ファサード。コレクション(合本)の一覧で
/// リフロー EPUB を「全ページ展開」するために使う。
/// census・レンダラはリーダー内と同一実装(EPUBScreenMetrics が単一の正)
/// なので、後でその本を開いたときのページ割りと必ず一致する。
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

    /// オフスクリーンリソース(census とレンダラの不可視ウインドウ・
    /// WebContent プロセス)を明示的に畳む。**アトラスを手放すとき
    /// (キャッシュからの追い出し等)は必ず呼ぶ** — 進行中の実測・レンダーを
    /// 止め、プロセスをホストの寿命まで生かさないため。呼んだ後の
    /// このインスタンスは再利用しない
    public func invalidate() {
        for task in measuring.values { task.cancel() }
        measuring.removeAll()
        newestRequestedKey = nil
        census.invalidate()
        renderer?.invalidate()
        renderer = nil
    }

    /// 各 spine 項目のページ数(実測。metrics ごとにキャッシュ)。
    /// 失敗(タイムアウト・WebContent 死)は nil
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

    /// 指定画面のサムネイル(失敗時 nil)
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
