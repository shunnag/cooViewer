import Foundation
import Washi

/// リフローしおりの一致・次前選択を UI から分離した決定論ロジック。
/// census がある間は 0 始まりページを 1 始まり表示範囲へ変換し、未完時だけ
/// spine + progression の近似へ落とす(仕様書 §4.7、設計書 §2.4)
@MainActor
enum EPUBBookmarkLogic {
    static let fallbackProgressionEpsilon = 0.02

    static func collectionPageNumber(globalStart: Int, localPage: Int,
                                     segmentPageCount: Int) -> Int {
        // cooViewer-h1b: 0 始まりの局所ページを 1 始まりへ変換してから、
        // 合本マップの当該セグメント終端へクランプする。
        globalStart + min(localPage + 1, segmentPageCount)
    }

    static func localPage(forDisplayed page: Int, base: Int) -> Int {
        page - base - 1
    }

    static func resolvedLocator(
        original: EPUBLocator,
        editedPage: Int?,
        originalPage: Int?,
        range: ClosedRange<Int>?,
        base: Int,
        locatorForLocalPage: (Int) -> EPUBLocator?
    ) -> EPUBLocator {
        // 仕様書 §4.7.2: 未変更の locator は再量子化せず、範囲外や
        // census 変換失敗も従来の黙殺方針で元の位置を保持する。
        guard let editedPage, editedPage != originalPage,
              let range, range.contains(editedPage) else {
            return original
        }
        return locatorForLocalPage(
            localPage(forDisplayed: editedPage, base: base)) ?? original
    }

    /// しおり編集シートの保存内容を確定する。同じ読書セッションの census を
    /// 使える間だけ、ページ番号の編集を locator へ解決する。それ以外では
    /// 名前・並び替え・削除を適用し、原 locator を保持する(cooViewer-rxj)。
    /// canResolvePageEdits=false では位置変換のクロージャを一切評価しない。
    static func resolvedBookmarks(
        _ edited: [(name: String, locator: EPUBLocator, pageNumber: Int?)],
        canResolvePageEdits: Bool,
        originalPage: (EPUBLocator) -> Int?,
        range: ClosedRange<Int>?,
        base: Int,
        locatorForLocalPage: (Int) -> EPUBLocator?
    ) -> [(name: String, locator: EPUBLocator)] {
        edited.map { bookmark in
            guard canResolvePageEdits else {
                return (name: bookmark.name, locator: bookmark.locator)
            }
            let locator = resolvedLocator(
                original: bookmark.locator,
                editedPage: bookmark.pageNumber,
                originalPage: originalPage(bookmark.locator),
                range: range, base: base,
                locatorForLocalPage: locatorForLocalPage)
            return (name: bookmark.name, locator: locator)
        }
    }

    static func matchingIndex(
        in bookmarks: [(name: String, locator: EPUBLocator)],
        current: EPUBLocator,
        currentPageRange: ClosedRange<Int>?,
        pageCountInItem: Int,
        globalPage: (EPUBLocator) -> Int?
    ) -> Int? {
        if let currentPageRange {
            return bookmarks.firstIndex { bookmark in
                guard let page = globalPage(bookmark.locator) else { return false }
                return currentPageRange.contains(page + 1)
            }
        }
        return bookmarks.firstIndex { bookmark in
            isSameFallbackPage(bookmark.locator, current,
                               pageCountInItem: pageCountInItem)
        }
    }

    static func targetIndex(
        in bookmarks: [(name: String, locator: EPUBLocator)],
        current: EPUBLocator,
        currentPageRange: ClosedRange<Int>?,
        pageCountInItem: Int,
        next: Bool,
        globalPage: (EPUBLocator) -> Int?
    ) -> Int? {
        if let currentPageRange {
            let candidates = bookmarks.enumerated().compactMap { index, bookmark
                -> (index: Int, page: Int)? in
                guard let page = globalPage(bookmark.locator) else { return nil }
                return (index, page + 1)
            }
            if next {
                return candidates.filter { $0.page > currentPageRange.upperBound }
                    .min { lhs, rhs in
                        lhs.page == rhs.page ? lhs.index < rhs.index : lhs.page < rhs.page
                    }?.index
            }
            return candidates.filter { $0.page < currentPageRange.lowerBound }
                .max { lhs, rhs in
                    lhs.page == rhs.page ? lhs.index > rhs.index : lhs.page < rhs.page
                }?.index
        }

        let candidates = bookmarks.enumerated().filter { _, bookmark in
            guard !isSameFallbackPage(bookmark.locator, current,
                                      pageCountInItem: pageCountInItem) else {
                return false
            }
            return next ? isAfter(bookmark.locator, current)
                        : isAfter(current, bookmark.locator)
        }
        if next {
            return candidates.min { lhs, rhs in
                isAfter(rhs.element.locator, lhs.element.locator)
            }?.offset
        }
        return candidates.max { lhs, rhs in
            isAfter(rhs.element.locator, lhs.element.locator)
        }?.offset
    }

    private static func isSameFallbackPage(
        _ bookmark: EPUBLocator,
        _ current: EPUBLocator,
        pageCountInItem: Int
    ) -> Bool {
        guard bookmark.spineIndex == current.spineIndex else { return false }
        guard pageCountInItem > 1 else {
            return abs(bookmark.progression - current.progression)
                <= fallbackProgressionEpsilon
        }
        // cooViewer-92n: census 未完でも現在 spine のページ数が分かるため、
        // progression の固定幅ではなく離散ページへ丸めて同一画面を判定する。
        let lastPage = Double(pageCountInItem - 1)
        return round(bookmark.progression * lastPage)
            == round(current.progression * lastPage)
    }

    private static func isAfter(_ lhs: EPUBLocator, _ rhs: EPUBLocator) -> Bool {
        lhs.spineIndex != rhs.spineIndex
            ? lhs.spineIndex > rhs.spineIndex
            : lhs.progression > rhs.progression
    }
}
