import CoreGraphics
import Foundation
import Washi

/// コレクション(合本)のサムネイル一覧で、リフロー EPUB の代理ページを
/// census の画面セル列へ「全ページ展開」した計画(設計書 §2.4 EPUB 対応)。
/// セルの並び・ジャンプ先・サムネイル供給の対応表で、画像本と EPUB の
/// 一覧体験の差をなくす(他形式はもともと全ページが並ぶ)
struct CollectionThumbnailPlan: Sendable {
    /// セルのジャンプ先
    enum Target: Sendable, Equatable {
        /// 合本の実ページ(画像・FXL 統合ページ)へ
        case bookPage(index: Int)
        /// 展開した EPUB の画面へ(entryIndex は合本内の代理ページ位置)
        case epubScreen(url: URL, entryIndex: Int,
                        spineIndex: Int, pageInItem: Int, countInItem: Int)
    }

    let entries: [PageEntry]
    let targets: [Target]
    let metrics: EPUBScreenMetrics
    let isDark: Bool

    /// 展開込みの一覧を組む。counts は「代理ページの合本内 index → その EPUB の
    /// 項目別ページ数」。counts に無い代理ページ(census 失敗・DRM)は
    /// 従来どおり表紙 1 セルのまま合本ページとして残す
    static func make(bookEntries: [PageEntry],
                     counts: [Int: [Int]],
                     metrics: EPUBScreenMetrics,
                     isDark: Bool) -> CollectionThumbnailPlan {
        var entries: [PageEntry] = []
        var targets: [Target] = []
        for (index, entry) in bookEntries.enumerated() {
            if let url = entry.reflowEPUBURL, let itemCounts = counts[index] {
                let screens = EPUBScreenThumbnailSource.makeScreens(
                    counts: itemCounts, pagesPerScreen: metrics.pagesPerScreen)
                for screen in screens {
                    let count = itemCounts.indices.contains(screen.spineIndex)
                        ? itemCounts[screen.spineIndex] : 1
                    targets.append(.epubScreen(
                        url: url, entryIndex: index,
                        spineIndex: screen.spineIndex,
                        pageInItem: screen.pageInItem, countInItem: count))
                    entries.append(PageEntry(
                        id: entries.count,
                        name: screen.label,
                        pathInBook: entry.pathInBook + "#\(screen.label)",
                        fileURL: nil, creationDate: nil, modificationDate: nil))
                }
            } else {
                targets.append(.bookPage(index: index))
                entries.append(PageEntry(
                    id: entries.count,
                    name: entry.name,
                    pathInBook: entry.pathInBook,
                    fileURL: entry.fileURL,
                    creationDate: entry.creationDate,
                    modificationDate: entry.modificationDate))
            }
        }
        return CollectionThumbnailPlan(entries: entries, targets: targets,
                                       metrics: metrics, isDark: isDark)
    }

    /// 合本の実ページ index → セル index(展開された EPUB はその先頭セル)
    func overlayIndex(forBookPage index: Int) -> Int {
        for (cell, target) in targets.enumerated() {
            switch target {
            case .bookPage(let i) where i == index:
                return cell
            case .epubScreen(_, let entryIndex, _, _, _) where entryIndex == index:
                return cell
            default:
                continue
            }
        }
        return 0
    }

    /// EPUB 内の現在位置 → セル index(その位置を含む最後の画面セル)
    func overlayIndex(forEPUB url: URL, spineIndex: Int,
                      pageInItem: Int) -> Int? {
        var best: Int?
        for (cell, target) in targets.enumerated() {
            if case .epubScreen(let u, _, let s, let p, _) = target, u == url,
               s < spineIndex || (s == spineIndex && p <= pageInItem) {
                best = cell
            }
        }
        return best
    }
}

/// 表示中の展開済み一覧(controller が保持し、refreshDisplay の追従が
/// 未展開一覧へ巻き戻さないようにする)
struct ActiveCollectionOverlay {
    let plan: CollectionThumbnailPlan
    let baseEntries: [PageEntry]
}

/// 展開計画のサムネイル供給: 実ページは合本ソースへ、EPUB 画面は
/// アトラス(リーダー外の画面レンダラ)へ振り分ける
struct CollectionThumbnailSource: BookSource {
    let url: URL
    let plan: CollectionThumbnailPlan
    let base: any BookSource
    let baseEntries: [PageEntry]

    var supportsDateSort: Bool { false }

    // 保護コンテンツ判定は合本ソースへ転送する(ThumbnailCache が
    // ディスク書き込みをこの判定で抑止している — 転送しないと復号済み
    // 書庫ページのサムネイルが平文 HEIC で残る。CWE-312)
    func isEncrypted() async -> Bool { await base.isEncrypted() }
    func containsProtectedContent() async -> Bool {
        await base.containsProtectedContent()
    }

    func entries() async throws -> [PageEntry] { plan.entries }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()
        guard plan.targets.indices.contains(entry.id) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        switch plan.targets[entry.id] {
        case .bookPage(let index):
            guard baseEntries.indices.contains(index) else {
                throw BookSourceError.pageLoadFailed(entry.name)
            }
            return try await base.image(for: baseEntries[index],
                                        maxPixelSize: maxPixelSize)
        case .epubScreen(let url, _, let spineIndex, let pageInItem, _):
            // アトラス参照はストア(MainActor)内に留める — NSWindow/WKWebView
            // を抱えるオブジェクトを非分離文脈で保持・解放させない
            guard let image = await EPUBAtlasStore.shared.thumbnail(
                for: url, spineIndex: spineIndex, pageInItem: pageInItem,
                metrics: plan.metrics, isDark: plan.isDark,
                width: CGFloat(maxPixelSize ?? 320))
            else {
                throw BookSourceError.pageLoadFailed(entry.name)
            }
            return image
        }
    }
}
