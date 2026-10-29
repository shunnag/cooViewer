import Foundation
import Washi

/// 合本のページ数は同一メトリクスの実測に限る。保存済み census もリーダーの
/// 復元と同じ版面・出版物・spine の条件で検証し、欠落巻だけを測る(設計書 §2.4)。
@MainActor
enum CollectionPageMapBuilder {
    static func counts(
        placeholders: [(index: Int, url: URL)],
        metrics: EPUBScreenMetrics,
        seededCounts: [Int: [Int]],
        collectionSource: any BookSource,
        history: BookHistoryStore,
        atlasStore: EPUBAtlasStore = .shared
    ) async -> [Int: [Int]] {
        var counts = seededCounts
        for placeholder in placeholders where counts[placeholder.index] == nil {
            guard !Task.isCancelled else { return counts }
            var publication = await collectionSource
                .preparsedReflowPublication(for: placeholder.url)
            guard !Task.isCancelled else { return counts }
            // 差替え等で解析済みの本が失効していても、保存値の照合には現在の版が
            // 必要。保存値がある巻だけ再解析し、WebKit を起こさずに検証する。
            if publication == nil,
               history.savedReflowCensus(forPath: placeholder.url.path) != nil {
                let url = placeholder.url
                publication = await Task.detached(priority: .userInitiated) {
                    try? await EPUBStagingArea.shared.openPublication(at: url)
                }.value
            }
            guard !Task.isCancelled else { return counts }
            if let publication,
               CanonicalPath.normalize(publication.url.path)
                == CanonicalPath.normalize(placeholder.url.path),
               let saved = savedCounts(
                for: publication, path: placeholder.url.path,
                metrics: metrics, history: history) {
                // 保存値で埋まる巻はアトラス自体を要求しない。screenPlan は
                // 内部キャッシュが空だと画面外 WebKit の census を起動する。
                counts[placeholder.index] = saved
            } else if let plan = await atlasStore.screenPlan(
                for: placeholder.url, metrics: metrics, preparsed: publication) {
                counts[placeholder.index] = plan.counts
            }
        }
        return counts
    }

    private static func savedCounts(
        for publication: EPUBPublication, path: String,
        metrics: EPUBScreenMetrics, history: BookHistoryStore
    ) -> [Int]? {
        guard !publication.isFixedLayout, !publication.isDRMProtected else { return nil }
        // EPUBReaderView / EPUBScreenAtlas と同じ文書既定の spread・flow を適用。
        // キー全体の一致でエンジン版・寸法・余白・フォント等もまとめて検証する。
        let key = metrics.applyingRenditionSpread(publication.metadata.rendition.spread)
            .applyingRenditionFlow(publication.metadata.rendition.layout == .roll
                ? .scrolledContinuous : publication.metadata.rendition.flow).cacheKey
        guard let saved = history.savedReflowCensus(forPath: path, metricsKey: key),
              saved.releaseIdentifier == publication.metadata.releaseIdentifier,
              saved.counts.count == publication.readingOrder.count,
              !saved.counts.isEmpty else { return nil }
        // importCensus と同じく、壊れた保存値をページ対応表へ持ち込まない。
        var total = 0
        for count in saved.counts {
            let sum = total.addingReportingOverflow(count)
            guard count > 0, !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return saved.counts
    }
}
