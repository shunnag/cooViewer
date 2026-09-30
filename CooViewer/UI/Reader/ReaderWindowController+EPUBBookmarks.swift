import AppKit
import SwiftUI
import Washi

/// リフローしおりの表示・移動・編集。位置判定は EPUBBookmarkLogic に委譲する。
extension ReaderWindowController {
    /// 現在画面のしおりを追加/削除する(仕様書 §4.7.1)。census 完了時は
    /// ページ空間で同一画面を判定し、未完時だけ progression 近似へ落とす
    func toggleEPUBBookmark() {
        guard let session = epubSession else { return }
        guard let epubView, let epubPublication else { return }
        let current = epubView.currentLocator
        if let index = EPUBBookmarkLogic.matchingIndex(
            in: session.bookmarks, current: current,
            currentPageRange: epubView.currentGlobalPageRange,
            pageCountInItem: epubView.pageCountInItem,
            globalPage: { epubView.censusGlobalPage(for: $0) }) {
            session.bookmarks.remove(at: index)
        } else {
            let name = epubPublication.chapterTitle(forSpineIndex: current.spineIndex)
                ?? "bookmark\(session.bookmarks.count + 1)"
            session.bookmarks.append((name, current))
        }
        saveEPUBBookmarks()
        BookmarkListMenuDelegate.shared.rebuild()
    }

    /// 次/前のしおりへ移動する。現在の見開きより外側だけを候補にし、配列順に
    /// 依存せず最も近いページを選ぶ(画像本 nextBookmarkIndex と同義 §4.7.1)
    func goToEPUBBookmark(next: Bool) {
        guard let session = epubSession else { return }
        guard let epubView else { return }
        guard let index = EPUBBookmarkLogic.targetIndex(
            in: session.bookmarks, current: epubView.currentLocator,
            currentPageRange: epubView.currentGlobalPageRange,
            pageCountInItem: epubView.pageCountInItem, next: next,
            globalPage: { epubView.censusGlobalPage(for: $0) }) else {
            NSSound.beep()
            return
        }
        epubView.go(to: session.bookmarks[index].locator)
    }

    /// しおり一覧メニューからのジャンプ(representedObject = 配列 index)
    @objc func goToEPUBBookmarkListItem(_ sender: NSMenuItem) {
        guard let session = epubSession else { return }
        guard let epubView, let index = sender.representedObject as? Int,
              session.bookmarks.indices.contains(index) else { return }
        epubView.go(to: session.bookmarks[index].locator)
    }

    /// locator の表示ページ番号。合本文脈で全体マップが有効なら合本全体、
    /// それ以外は個別 EPUB の 1 始まり番号へ揃える(設計書 §2.4)
    func epubBookmarkPageNumber(for locator: EPUBLocator) -> Int? {
        guard let localPage = epubView?.censusGlobalPage(for: locator) else { return nil }
        if let context = epubCollectionContext,
           let map = activeCollectionPageMap() {
            return EPUBBookmarkLogic.collectionPageNumber(
                globalStart: map.globalStart(forEntry: context.entryIndex),
                localPage: localPage,
                segmentPageCount: map.pageCount(forEntry: context.entryIndex))
        }
        return localPage + 1
    }

    private func epubBookmarkPositionText(for locator: EPUBLocator) -> String {
        let pageText: String
        if let page = epubBookmarkPageNumber(for: locator),
           let total = epubCurrentTotalPages {
            pageText = "\(page)/\(total)"
        } else {
            pageText = "—"
        }
        if let title = epubPublication?.chapterTitle(
            forSpineIndex: locator.spineIndex) {
            return "\(pageText) (\(title))"
        }
        return pageText
    }

    /// リフロー専用編集シート。census 完了時はページ番号も
    /// コピー上で編集し、OK 時にだけ確定する(仕様書 §4.7.2、§13.3)
    func editEPUBBookmarks() {
        guard let session = epubSession else { return }
        guard isEPUBMode, let targetURL = epubBookURL, let epubView, let window,
              bookmarkEditorWindow == nil else { return }
        let pageBase: Int
        let pageRange: ClosedRange<Int>?
        let segmentPageCount: Int?
        if let total = epubView.censusTotalPages, total > 0 {
            if let context = epubCollectionContext,
               let map = activeCollectionPageMap() {
                let start = map.globalStart(forEntry: context.entryIndex)
                let count = map.pageCount(forEntry: context.entryIndex)
                pageBase = start
                pageRange = (start + 1)...(start + count)
                segmentPageCount = count
            } else {
                pageBase = 0
                pageRange = 1...total
                segmentPageCount = nil
            }
        } else {
            pageBase = 0
            pageRange = nil
            segmentPageCount = nil
        }
        let pageNumber: (EPUBLocator) -> Int? = { locator in
            guard let localPage = epubView.censusGlobalPage(for: locator) else {
                return nil
            }
            if let segmentPageCount {
                return EPUBBookmarkLogic.collectionPageNumber(
                    globalStart: pageBase, localPage: localPage,
                    segmentPageCount: segmentPageCount)
            }
            return localPage + 1
        }
        let positions = session.bookmarks.map {
            epubBookmarkPositionText(for: $0.locator)
        }
        let pageNumbers = session.bookmarks.map {
            pageNumber($0.locator)
        }
        let editor = NSWindow(contentViewController: NSHostingController(
            rootView: EPUBBookmarkEditorView(
                bookmarks: session.bookmarks, positions: positions,
                pageNumbers: pageNumbers, pageRange: pageRange,
                onSave: { [weak self, weak session] bookmarks in
                    guard let self else { return }
                    let canResolvePages = session.map { self.ownsEPUBSession($0) } ?? false
                    let resolved = EPUBBookmarkLogic.resolvedBookmarks(
                        bookmarks, canResolvePageEdits: canResolvePages,
                        originalPage: { pageNumber($0) },
                        range: pageRange, base: pageBase,
                        locatorForLocalPage: { epubView.censusLocator(forGlobalPage: $0) })
                    // 同じ URL を開き直した場合も、確定した名前・並び・削除を
                    // 現セッションへ反映する。ページ再計算とは別の条件にしないと、
                    // 次の状態保存で編集結果が古い配列に上書きされる。
                    if let current = self.epubSession, current.url == targetURL {
                        current.bookmarks = resolved
                        self.saveEPUBBookmarks()
                        BookmarkListMenuDelegate.shared.rebuild()
                    } else {
                        // シート表示中に別の本へ切り替わった場合、編集対象の EPUB へ
                        // 名前・並び替え・削除のみ適用する(ページ編集は原 locator を
                        // 保持。cooViewer-rxj)
                        self.history.noteReflowBookmarks(
                            path: targetURL.path,
                            bookmarks: resolved.map {
                                ($0.name, $0.locator.spineIndex,
                                 $0.locator.progression, $0.locator.idref)
                            })
                    }
                },
                onClose: { [weak self] in
                    guard let self, let sheet = self.bookmarkEditorWindow else { return }
                    self.window?.endSheet(sheet)
                    self.bookmarkEditorWindow = nil
                })))
        bookmarkEditorWindow = editor
        window.beginSheet(editor)
    }

}
