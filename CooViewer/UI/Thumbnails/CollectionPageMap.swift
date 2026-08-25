import Foundation
import Washi

/// コレクション(合本)の「全体ページ」対応表(設計書 §2.4 EPUB 対応)。
/// 画像・FXL 統合ページは 1 ページ、リフロー EPUB は census の全ページ数
/// として通しで数え、ページバー・ページ番号・%ジャンプを書庫内 zip や
/// サブフォルダと同じ「合本全体からの位置」にする(仕様書 §3.4 の読み替え)。
/// census が取れない本(DRM 等)は従来どおり 1 ページ(代理表紙)扱い
struct CollectionPageMap: Sendable {
    struct Segment: Sendable {
        let entryIndex: Int
        /// リフロー EPUB のときその URL(画像・FXL 統合ページは nil)
        let epubURL: URL?
        /// EPUB の項目別ページ数(全体ページ → spine 位置の逆引きに使う)
        let itemCounts: [Int]?
        let pageCount: Int
        /// 全体ページでの開始位置(0 始まり)
        let globalStart: Int
    }

    enum Target: Sendable, Equatable {
        case bookPage(index: Int)
        case epubPage(url: URL, entryIndex: Int,
                      spineIndex: Int, pageInItem: Int, countInItem: Int)
    }

    let segments: [Segment]
    let total: Int
    let metricsKey: String
    let folderPath: String
    /// 構築時のエントリ列(ソート・シャッフル・削除で並びが変わったら
    /// マップは無効 — 消費側が同一性を比較する)
    let entries: [PageEntry]

    static func make(folderPath: String, metricsKey: String,
                     entries: [PageEntry],
                     counts: [Int: [Int]]) -> CollectionPageMap {
        var segments: [Segment] = []
        var offset = 0
        for (index, entry) in entries.enumerated() {
            if let url = entry.reflowEPUBURL, let itemCounts = counts[index],
               !itemCounts.isEmpty {
                let pages = itemCounts.reduce(0) { $0 + max(1, $1) }
                segments.append(Segment(
                    entryIndex: index, epubURL: url, itemCounts: itemCounts,
                    pageCount: max(1, pages), globalStart: offset))
                offset += max(1, pages)
            } else {
                segments.append(Segment(
                    entryIndex: index, epubURL: nil, itemCounts: nil,
                    pageCount: 1, globalStart: offset))
                offset += 1
            }
        }
        return CollectionPageMap(segments: segments, total: max(1, offset),
                                 metricsKey: metricsKey, folderPath: folderPath,
                                 entries: entries)
    }

    /// 合本の実ページ index → 全体ページの開始位置(0 始まり)
    func globalStart(forEntry index: Int) -> Int {
        segments.indices.contains(index) ? segments[index].globalStart : 0
    }

    /// 合本の実ページ index のページ数(EPUB は census 合計)
    func pageCount(forEntry index: Int) -> Int {
        segments.indices.contains(index) ? segments[index].pageCount : 1
    }

    /// 全体ページ(0 始まり)→ ジャンプ先
    func target(forGlobalPage page: Int) -> Target {
        let clamped = min(max(0, page), total - 1)
        var found = segments.first
        for segment in segments where segment.globalStart <= clamped {
            found = segment
        }
        guard let segment = found else { return .bookPage(index: 0) }
        guard let url = segment.epubURL, let itemCounts = segment.itemCounts
        else {
            return .bookPage(index: segment.entryIndex)
        }
        var remaining = clamped - segment.globalStart
        for (item, count) in itemCounts.enumerated() {
            let pages = max(1, count)
            if remaining < pages {
                return .epubPage(url: url, entryIndex: segment.entryIndex,
                                 spineIndex: item, pageInItem: remaining,
                                 countInItem: pages)
            }
            remaining -= pages
        }
        let lastCount = max(1, itemCounts.last ?? 1)
        return .epubPage(url: url, entryIndex: segment.entryIndex,
                         spineIndex: max(0, itemCounts.count - 1),
                         pageInItem: lastCount - 1, countInItem: lastCount)
    }
}
