import CoreGraphics
import Foundation
import Washi

/// リーダー外で EPUB の画面計画・サムネイルを引くためのアトラス共有
/// (コレクションの一覧展開用。設計書 §2.4 EPUB 対応)。
/// 本の解析(EPUBPublication)と census は重いので、正規化パスをキーに
/// 少数を LRU 保持して同じフォルダの開き直しを速くする
@MainActor
final class EPUBAtlasStore {
    static let shared = EPUBAtlasStore()

    private var atlases: [String: EPUBScreenAtlas] = [:]
    private var order: [String] = []
    private var loading: [String: Task<EPUBScreenAtlas?, Never>] = [:]
    private let limit = 8

    /// 画面計画(項目別ページ数の実測)。アトラス参照は MainActor の
    /// このストア内に留める
    func screenCounts(for url: URL, metrics: EPUBScreenMetrics) async -> [Int]? {
        guard let atlas = await atlas(for: url) else { return nil }
        return await atlas.screenCounts(metrics: metrics)
    }

    /// 画面サムネイル(同上。EPUBScreenAtlas は NSWindow/WKWebView を抱える
    /// ため、非分離文脈に参照を渡して保持・解放させない)
    func thumbnail(for url: URL, spineIndex: Int, pageInItem: Int,
                   metrics: EPUBScreenMetrics, isDark: Bool,
                   width: CGFloat) async -> CGImage? {
        guard let atlas = await atlas(for: url) else { return nil }
        return await atlas.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            metrics: metrics, isDark: isDark, width: width)
    }

    /// リフロー EPUB のアトラス(解析失敗・FXL・DRM は nil)。
    /// 同じ URL の並行要求は解析に合流する
    private func atlas(for url: URL) async -> EPUBScreenAtlas? {
        let key = url.resolvingSymlinksInPath().path
        if let hit = atlases[key] {
            touch(key)
            return hit
        }
        if let running = loading[key] { return await running.value }
        let task = Task { () -> EPUBScreenAtlas? in
            let publication = await Task.detached(priority: .userInitiated) {
                try? EPUBPublication(url: url)
            }.value
            guard let publication, !publication.isFixedLayout,
                  !publication.isDRMProtected else { return nil }
            return EPUBScreenAtlas(publication: publication)
        }
        loading[key] = task
        let atlas = await task.value
        loading[key] = nil
        if let atlas {
            atlases[key] = atlas
            touch(key)
            evictIfNeeded()
        }
        return atlas
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > limit {
            let evicted = order.removeFirst()
            // 進行中の実測・レンダーを止め、オフスクリーンの不可視ウインドウと
            // WebContent プロセスを確実に畳んでから手放す(Washi の契約)
            atlases[evicted]?.invalidate()
            atlases[evicted] = nil
        }
    }
}
