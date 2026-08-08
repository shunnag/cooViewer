import AppKit
import SwiftUI

/// 付随機能: しおり・本の状態保存/復元・同フォルダ移動・スライドショー・
/// ゴミ箱・Finder 表示・原寸表示(仕様書 §4.7-§4.13, §7)。
/// EN: Companion features: bookmarks, state save/restore, sibling books,
/// EN: slideshow, trash, Show in Finder, and original-size view.
extension ReaderWindowController {
    // MARK: - 状態の保存と復元(仕様書 §7)

    /// 現在の本の状態を保存する(切替時・クローズ時・終了時。§7.7 の穴も塞ぐ)
    /// EN: Persist page position, per-book settings, and bookmarks.
    func saveCurrentBookState() {
        // 開けなかった本(空のプレースホルダ)は履歴・設定に記録しない
        guard let book, book.pageCount > 0 else { return }
        let path = book.source.url.path
        // ページ番号に加えて「どのファイルか」も添える(新規キー)。次回開いたとき
        // エントリ列が変わっていても(ネスト展開の失敗・並び替え)照合できる
        // EN: Record the page's in-book path next to the index so a changed
        // EN: entry list (failed nested expansion, re-sort) can be re-resolved.
        func pagePath(_ index: Int) -> String? {
            book.entries.indices.contains(index) ? book.entries[index].pathInBook : nil
        }
        BookHistoryStore.shared.noteClosed(
            path: path, pageIndex: book.currentIndex,
            pagePath: pagePath(book.currentIndex))
        let bookmarks = book.bookmarks.map { bookmark in
            // 記録済みパスのページが今回の本に存在しない(ネスト展開の失敗等で
            // 照合できなかった)場合は元の記録を保つ。今回の位置で上書きすると、
            // 次回そのページが戻ってきたときに照合できなくなる
            // EN: Keep the stored path when its page is absent this session
            // EN: (failed reconciliation); overwriting would lose the target.
            if let stored = bookmark.pagePath,
               !book.entries.contains(where: { $0.pathInBook == stored }) {
                return bookmark
            }
            return BookHistoryStore.Bookmark(
                name: bookmark.name, pageIndex: bookmark.pageIndex,
                pagePath: pagePath(bookmark.pageIndex) ?? bookmark.pagePath)
        }
        BookHistoryStore.shared.save(
            displayName: book.displayName, path: path,
            settings: .init(readMode: book.readMode, sortMode: book.sortMode,
                            marks: book.marks, bookmarks: bookmarks))
    }

    /// 開いた本に保存済み設定を適用する(§4.1.2 手順 6-7, §7.1)
    /// EN: Apply saved per-book settings and optionally restore the last page.
    func restoreBookState(for book: Book, skipPageRestore: Bool) async {
        let store = BookHistoryStore.shared
        let path = book.source.url.path
        if let saved = store.settings(displayName: book.displayName, path: path) {
            if let readMode = saved.readMode { book.readMode = readMode }
            if let sortMode = saved.sortMode, sortMode != book.sortMode {
                book.setSortMode(sortMode)
            }
            book.marks = saved.marks
            // しおりは保存時のページパスで照合し直す(エントリ列の変化に追従)
            // EN: Re-resolve bookmarks via their recorded page paths.
            book.bookmarks = saved.bookmarks.map { bookmark in
                var resolved = bookmark
                resolved.pageIndex = BookHistoryStore.reconciledIndex(
                    saved: bookmark.pageIndex, pagePath: bookmark.pagePath,
                    entries: book.entries)
                return resolved
            }
        }
        // 復元ページは履歴を更新する前に読む(仕様書 §4.1.2: 手順 7 → 8 の順)
        let restorePage = store.savedPage(forPath: path)
        store.noteOpened(path: path)

        // 最終ページ復元(GoToLastPage: 0=確認/1=自動/2=無効。§7.3)。
        // ページパスが記録されていれば同じファイルのページへ照合し直す
        guard !skipPageRestore, settings.goToLastPageMode < 2,
              let restorePage else { return }
        let page = BookHistoryStore.reconciledIndex(
            saved: restorePage.page, pagePath: restorePage.pagePath,
            entries: book.entries)
        guard page > 0, page < book.pageCount else { return }
        if settings.goToLastPageMode == 1 {
            book.goTo(index: page)
        } else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "Go to page \(page + 1)?")
            alert.addButton(withTitle: String(localized: "Go"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                book.goTo(index: page)
            }
        }
    }

    // MARK: - しおり(仕様書 §4.7)

    func toggleBookmark() {
        guard let book else { return }
        let page = book.currentIndex
        if let index = book.bookmarks.firstIndex(where: { $0.pageIndex == page }) {
            book.bookmarks.remove(at: index)
        } else {
            let name = book.entries.indices.contains(page) ? book.entries[page].name : ""
            book.bookmarks.append(.init(name: name, pageIndex: page))
        }
        saveCurrentBookState()
        // サムネイル表示中はしおりバッジ/絞り込みへ即時反映
        // EN: Keep the visible thumbnail overlay's bookmark state in sync.
        if isThumbnailOverlayVisible {
            presentThumbnailOverlay(for: book)
        }
    }

    /// しおり編集シート(§4.7.2。コピー編集のため Cancel が有効 §13.3)
    /// EN: Bookmark editor sheet; edits a copy so Cancel really discards.
    func editBookmarks() {
        guard let book, book.pageCount > 0, let window,
              bookmarkEditorWindow == nil else { return }
        let editor = NSWindow(contentViewController: NSHostingController(
            rootView: BookmarkEditorView(
                bookmarks: book.bookmarks, pageCount: book.pageCount,
                onSave: { [weak self, weak book] bookmarks in
                    guard let book else { return }
                    book.bookmarks = bookmarks
                    guard let self else { return }
                    if book === self.book {
                        self.saveCurrentBookState()
                        // サムネイル表示中はしおりバッジへ即時反映
                        // EN: Refresh the visible overlay's bookmark badges.
                        if self.isThumbnailOverlayVisible {
                            self.presentThumbnailOverlay(for: book)
                        }
                    } else {
                        // シート中に本が切り替わっても編集対象の本へ保存する
                        // EN: Persist to the edited book even if the current
                        // EN: book changed while the sheet was open.
                        BookHistoryStore.shared.save(
                            displayName: book.displayName,
                            path: book.source.url.path,
                            settings: .init(readMode: book.readMode,
                                            sortMode: book.sortMode,
                                            marks: book.marks,
                                            bookmarks: book.bookmarks))
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

    /// しおり一覧メニューからのジャンプ(representedObject = 0 始まり index)
    @objc func goToBookmarkListItem(_ sender: NSMenuItem) {
        guard let book, let index = sender.representedObject as? Int,
              book.entries.indices.contains(index) else { return }
        book.goTo(index: index)
        refreshAfterJump()
    }

    func goToBookmark(next: Bool) {
        guard let book else { return }
        let target = next ? book.nextBookmarkIndex() : book.previousBookmarkIndex()
        guard let target else {
            NSSound.beep()
            return
        }
        book.goTo(index: target)
        refreshAfterJump()
    }

    /// 単ページ⇔見開きの強制切替(仕様書 §5.5 action 11、marks 更新)
    func switchSingleSpread() {
        guard let book else { return }
        Task {
            let spread = await book.currentSpread()
            if spread.indices.count == 2 {
                book.marks.setForcedSingle(spread.indices[0])
            } else if let first = spread.indices.first, first + 1 < book.pageCount {
                book.marks.removeMark(containing: first)
                book.marks.setForcedPair(firstIndex: first)
            }
            saveCurrentBookState()
            await refreshDisplay()
        }
    }

    // MARK: - 同フォルダの次/前の本(仕様書 §4.1.4, §4.3.4)

    /// 親フォルダ内の「本」一覧(名前順、隠しファイル除外)
    /// EN: Book candidates in the parent folder, name-sorted.
    private func siblingBooks() -> [String] {
        guard let book else { return [] }
        let parent = book.source.url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path)
        else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                let url = parent.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return isDirectory.boolValue || SupportedTypes.isBookFile(url)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { parent.appendingPathComponent($0).path }
    }

    /// 次/前の本へ(端でラップアラウンド。§4.3.4)。openLast=前の本を末尾から開く。
    func openAdjacentBook(forward: Bool, openLast: Bool = false) {
        guard let book else { return }
        let siblings = siblingBooks()
        guard !siblings.isEmpty,
              let current = siblings.firstIndex(of: book.source.url.path) else { return }
        let target = (current + (forward ? 1 : -1) + siblings.count) % siblings.count
        openBook(at: URL(fileURLWithPath: siblings[target]), atLastPage: openLast)
    }

    // MARK: - スライドショー(仕様書 §4.9)

    func toggleSlideshow() {
        if slideshowTimer != nil {
            stopSlideshow()
            return
        }
        let delay = max(0.05, settings.slideshowDelay)
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.slideshowTick()
            }
        }
    }

    func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    private func slideshowTick() {
        guard let book else {
            stopSlideshow()
            return
        }
        if book.moveNext() == .hitEnd {
            if settings.loopCheck == 0 {
                book.goToFirst()
            } else {
                stopSlideshow()  // スライドショーは端で停止(§4.3.4)
                return
            }
        }
        refreshAfterJump()
    }

    // MARK: - ゴミ箱(仕様書 §4.12。AppleScript フォールバックは廃止)

    /// 表示中ページをゴミ箱へ。side は画面の左右(readMode で実ページに解決)。
    /// EN: Trash the displayed page (folder books only), then reopen in place.
    func trashDisplayedPage(leftSide: Bool) {
        guard let book else { return }
        Task {
            let spread = await book.currentSpread()
            guard !spread.indices.isEmpty else { return }
            let index: Int
            if spread.indices.count == 2 {
                // 読み順先頭ページは、右→左読みなら右側(§4.2.5)
                let readsFromLeft = book.readMode.readsFromLeft
                index = leftSide == readsFromLeft ? spread.indices[0] : spread.indices[1]
            } else {
                index = spread.indices[0]
            }
            guard let fileURL = book.entries[index].fileURL else {
                NSSound.beep()  // 書庫/PDF 内は削除不可(旧仕様同様フォルダの本のみ)
                return
            }
            let alert = NSAlert()
            alert.messageText = String(
                localized: "Move \"\(fileURL.lastPathComponent)\" to Trash?")
            alert.addButton(withTitle: String(localized: "Move to Trash"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            } catch {
                NSSound.beep()
                return
            }
            // 削除後はローダを再構築して同位置を表示(§12.1 #13 の修正)
            let page = min(index, max(0, book.pageCount - 2))
            openBook(at: book.source.url, atPage: page)
        }
    }

    // MARK: - Finder 表示・原寸表示(仕様書 §4.13)

    func showInFinder(leftSide: Bool?) {
        guard let book else { return }
        Task {
            let spread = await book.currentSpread()
            let index = displayedIndex(in: spread, leftSide: leftSide)
            let url = index.flatMap { book.entries[$0].fileURL } ?? book.source.url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func viewOriginal(leftSide: Bool?) {
        guard let book else { return }
        Task {
            let spread = await book.currentSpread()
            guard let index = displayedIndex(in: spread, leftSide: leftSide),
                  // 原寸表示は表示上限(displayPixelCap)を介さないフル解像度で
                  let image = await book.fullResolutionImage(at: index) else { return }
            presentOriginalSizePanel(
                image: image,
                title: book.entries[index].displayTitle(
                    relativePath: settings.showRelativePaths))
        }
    }

    private func displayedIndex(in spread: Book.Spread, leftSide: Bool?) -> Int? {
        guard let first = spread.indices.first else { return nil }
        guard spread.indices.count == 2, let leftSide else { return first }
        let readsFromLeft = book?.readMode.readsFromLeft ?? false
        return leftSide == readsFromLeft ? spread.indices[0] : spread.indices[1]
    }

    /// 原寸表示パネル(旧 FullImagePanel §4.13 の簡易版。キーを失うと閉じる)
    /// EN: Utility panel showing the page at full resolution in a scroll view.
    private func presentOriginalSizePanel(image: CGImage, title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = title
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        let imageView = NSImageView()
        imageView.image = NSImage(cgImage: image,
                                  size: NSSize(width: image.width, height: image.height))
        imageView.frame = NSRect(x: 0, y: 0, width: image.width, height: image.height)
        let scrollView = NSScrollView()
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        panel.contentView = scrollView

        if let screen = NSScreen.main {
            let size = NSSize(
                width: min(CGFloat(image.width), screen.visibleFrame.width * 0.9),
                height: min(CGFloat(image.height), screen.visibleFrame.height * 0.9))
            panel.setContentSize(size)
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        originalSizePanel = panel
    }

    // MARK: - サブフォルダ移動

    func goToSubFolder(next: Bool) {
        guard let book else { return }
        let target = next ? book.nextSubFolderIndex() : book.previousSubFolderIndex()
        guard let target else {
            NSSound.beep()
            return
        }
        book.goTo(index: target)
        refreshAfterJump()
    }

    // MARK: - 次の本の事前スプール(設計書 §5 キャッシュ・先読み)

    /// 巻末が近づいたら同フォルダの次の書庫をバックグラウンドで開いて
    /// ローカル展開を始める。開く際に openBookFlow が再利用する。
    /// EN: Near the end of a book, pre-open and spool the next sibling archive
    /// EN: so switching to it is instant.
    func maybePrepareNextBook() {
        let threshold = settings.prepareNextBookPages  // 0 は無効(設定「高度」)
        guard threshold > 0, let book, book.pageCount > 0,
              book.currentIndex >= book.pageCount - threshold else { return }
        let siblings = siblingBooks()
        guard siblings.count > 1,
              let current = siblings.firstIndex(of: book.source.url.path) else { return }
        let nextPath = siblings[(current + 1) % siblings.count]
        guard nextPath != book.source.url.path,
              preparedNextBook?.path != nextPath,
              preparingNextBookPath != nextPath,
              SupportedTypes.isArchive(URL(fileURLWithPath: nextPath)) else { return }
        preparingNextBookPath = nextPath
        Task {
            defer { preparingNextBookPath = nil }
            guard let source = try? await BookSourceFactory.make(
                for: URL(fileURLWithPath: nextPath),
                readSubFolders: settings.readSubFolder) else { return }
            // パスワード書庫は解除 UI が必要なため展開はしない(開く時に通常フロー)
            if await !source.isEncrypted() {
                // 置き場所の速度プロファイルを適用してから展開(スプール方針)
                // EN: Apply the volume-speed profile before spooling starts.
                if settings.adaptiveMediaTuning {
                    let profile = await MediaSpeedProbe.profile(
                        for: URL(fileURLWithPath: nextPath))
                    await source.applyMediaProfile(profile)
                }
                await source.beginBackgroundPreparation(
                    spoolSizeLimit: settings.archiveSpoolSizeLimit)
            }
            preparedNextBook = (nextPath, source)
        }
    }

    // MARK: - 最後に開いた本(仕様書 §4.1.1 #1)

    func openTheLastBook() {
        guard let recent = BookHistoryStore.shared.mostRecentBook() else { return }
        openBook(at: URL(fileURLWithPath: recent.path))
    }

    // MARK: - メニュー用アクション

    @objc func addRemoveBookmarkMenu(_ sender: Any?) { toggleBookmark() }
    @objc func editBookmarksMenu(_ sender: Any?) { editBookmarks() }
    @objc func nextBookmarkMenu(_ sender: Any?) { goToBookmark(next: true) }
    @objc func previousBookmarkMenu(_ sender: Any?) { goToBookmark(next: false) }
    @objc func nextBookMenu(_ sender: Any?) { openAdjacentBook(forward: true) }
    @objc func previousBookMenu(_ sender: Any?) { openAdjacentBook(forward: false) }
    @objc func openLastBookMenu(_ sender: Any?) { openTheLastBook() }
    @objc func toggleSlideshowMenu(_ sender: Any?) { toggleSlideshow() }
}

/// しおりサブメニューを開くたびに現在の本のしおりで再構築する(仕様書 §4.7.1)
/// EN: Rebuilds the bookmark jump submenu from the current book on every open.
@MainActor
final class BookmarkListMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = BookmarkListMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.windows
            .compactMap { $0.windowController as? ReaderWindowController }.first
        let bookmarks = controller?.book?.bookmarks ?? []
        for bookmark in bookmarks {
            let title = "\(bookmark.name)  (p.\(bookmark.pageIndex + 1))"
            let item = menu.addItem(
                withTitle: title,
                action: #selector(ReaderWindowController.goToBookmarkListItem(_:)),
                keyEquivalent: "")
            item.representedObject = bookmark.pageIndex
        }
        if bookmarks.isEmpty {
            let empty = menu.addItem(withTitle: String(localized: "No Bookmarks"),
                                     action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
    }
}

/// Open Recent サブメニューを開くたびに履歴から再構築する(仕様書 §7.2)
/// EN: Rebuilds the Open Recent submenu from history on every open.
@MainActor
final class RecentBooksMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentBooksMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paths = BookHistoryStore.shared.recentBookPaths()
        for path in paths {
            let item = menu.addItem(withTitle: (path as NSString).lastPathComponent,
                                    action: #selector(AppDelegate.openRecentBook(_:)),
                                    keyEquivalent: "")
            item.representedObject = path
        }
        if paths.isEmpty {
            let empty = menu.addItem(withTitle: String(localized: "No Recent Books"),
                                     action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
    }
}
