import CoreGraphics
import Foundation
import Washi

/// リフロー EPUB の「画面単位」サムネイルを既存のサムネイルオーバーレイへ
/// 供給するアダプタ(設計書 §2.4 EPUB 対応)。
/// entries は census のページ割りに一致する画面(単ページ/見開きの 1 面)
/// ごとで、ラベルは全文ページ番号(N / N-M)。描画は EPUBReaderView の
/// 画面外レンダラに委譲する(本番と同一メトリクス+現在テーマの配色)
struct EPUBScreenThumbnailSource: BookSource {
    /// 一覧の 1 セル = 表示の 1 画面
    struct Screen: Sendable, Equatable {
        let spineIndex: Int
        let pageInItem: Int
        let label: String
    }

    let url: URL
    let screens: [Screen]
    /// 描画委譲先。NSView 派生のため Sendable ではないが、ここでは参照を
    /// 保持するだけで、触るのは常に await 越しの @MainActor メソッド
    /// (screenThumbnail)のみ — 実質安全なので検査をオプトアウトする
    nonisolated(unsafe) let view: EPUBReaderView

    var supportsDateSort: Bool { false }

    /// census の項目別ページ数(未完了時は全項目 1=章単位)と画面あたりの
    /// ページ数から画面一覧を組む。ラベルは全文ページ番号
    static func makeScreens(counts: [Int], pagesPerScreen: Int) -> [Screen] {
        var screens: [Screen] = []
        var globalBase = 0
        for (item, count) in counts.enumerated() {
            // 画像 1 枚の項目(表紙等)は実行時も常に単独画面
            let step = count <= 1 ? 1 : max(1, pagesPerScreen)
            var page = 0
            while page < count {
                let first = globalBase + page + 1
                let last = globalBase + min(page + step, count)
                let label = last > first ? "\(first)-\(last)" : "\(first)"
                screens.append(Screen(spineIndex: item, pageInItem: page,
                                      label: label))
                page += step
            }
            globalBase += max(1, count)
        }
        return screens
    }

    var pageEntries: [PageEntry] {
        screens.enumerated().map { index, screen in
            PageEntry(id: index, name: screen.label, pathInBook: screen.label,
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func entries() async throws -> [PageEntry] { pageEntries }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()
        guard screens.indices.contains(entry.id) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        let screen = screens[entry.id]
        guard let image = await view.screenThumbnail(
            spineIndex: screen.spineIndex, pageInItem: screen.pageInItem,
            width: CGFloat(maxPixelSize ?? 320))
        else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return image
    }
}
