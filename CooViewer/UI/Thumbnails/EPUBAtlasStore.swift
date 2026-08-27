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
    /// 使用中のアトラス参照カウント(await 中に LRU 追い出しで invalidate されて
    /// 空セル+オフスクリーン蘇りを招かないよう、使っている間は退避しない)
    private var inUse: [String: Int] = [:]
    private let limit = 8

    /// 画面計画(項目別ページ数の実測)。アトラス参照は MainActor の
    /// このストア内に留める
    func screenCounts(for url: URL, metrics: EPUBScreenMetrics) async -> [Int]? {
        guard let (key, atlas) = await atlas(for: url) else { return nil }
        defer { release(key) }
        return await atlas.screenCounts(metrics: metrics)
    }

    /// 画面サムネイル(同上。EPUBScreenAtlas は NSWindow/WKWebView を抱える
    /// ため、非分離文脈に参照を渡して保持・解放させない)
    func thumbnail(for url: URL, spineIndex: Int, pageInItem: Int,
                   metrics: EPUBScreenMetrics, isDark: Bool,
                   width: CGFloat) async -> CGImage? {
        guard let (key, atlas) = await atlas(for: url) else { return nil }
        defer { release(key) }
        return await atlas.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            metrics: metrics, isDark: isDark, width: width)
    }

    /// リフロー EPUB のアトラス(解析失敗・FXL・DRM は nil)。同じ URL の並行
    /// 要求は解析に合流する。返す各経路で inUse を +1 する(呼び出し元での増分
    /// では atlas 取得〜使用開始の間に退避される窓が残るため、ここで増やす)。
    /// 呼び出し元は使い終えたら必ず release(key) すること
    private func atlas(for url: URL) async -> (key: String, atlas: EPUBScreenAtlas)? {
        let key = url.resolvingSymlinksInPath().path
        if let hit = atlases[key] {
            touch(key)
            inUse[key, default: 0] += 1
            return (key, hit)
        }
        if let running = loading[key] {
            // タスクの戻り値を直接使う(atlases[key] を再読すると、生成側が
            // 公開する前にこちらの継続が先に走ったとき偽 nil になる)
            guard let atlas = await running.value else { return nil }
            touch(key)
            inUse[key, default: 0] += 1
            return (key, atlas)
        }
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
        guard let atlas else { return nil }
        atlases[key] = atlas
        touch(key)
        // 生成直後の自分を退避しないよう、増分を evict の前に置く
        inUse[key, default: 0] += 1
        evictIfNeeded()
        return (key, atlas)
    }

    private func release(_ key: String) {
        if let n = inUse[key] { inUse[key] = n > 1 ? n - 1 : nil }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        var i = 0
        while order.count > limit && i < order.count {
            let key = order[i]
            // 使用中のアトラスは退避しない(一時的な上限超過は許容)。await 中の
            // screenCounts/thumbnail が nil を掴む・オフスクリーンが蘇るのを防ぐ
            if (inUse[key] ?? 0) > 0 { i += 1; continue }
            order.remove(at: i)
            // 進行中の実測・レンダーを止め、オフスクリーンの不可視ウインドウと
            // WebContent プロセスを確実に畳んでから手放す(Washi の契約)
            atlases[key]?.invalidate()
            atlases[key] = nil
        }
    }
}
