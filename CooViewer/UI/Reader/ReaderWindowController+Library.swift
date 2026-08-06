import AppKit

/// 付随機能: しおり・本の状態保存/復元・同フォルダ移動・スライドショー・
/// ゴミ箱・Finder 表示・原寸表示(仕様書 §4.7-§4.13, §7)。
extension ReaderWindowController {
    // MARK: - 状態の保存と復元(仕様書 §7)

    /// 現在の本の状態を保存する(切替時・クローズ時・終了時。§7.7 の穴も塞ぐ)
    func saveCurrentBookState() {
        guard let book else { return }
        let path = book.source.url.path
        BookHistoryStore.shared.noteClosed(path: path, pageIndex: book.currentIndex)
        BookHistoryStore.shared.save(
            displayName: book.displayName, path: path,
            settings: .init(readMode: book.readMode, sortMode: book.sortMode,
                            marks: book.marks, bookmarks: book.bookmarks))
    }

    /// 開いた本に保存済み設定を適用する(§4.1.2 手順 6-7, §7.1)
    func restoreBookState(for book: Book, skipPageRestore: Bool) async {
        let store = BookHistoryStore.shared
        let path = book.source.url.path
        if let saved = store.settings(displayName: book.displayName, path: path) {
            if let readMode = saved.readMode { book.readMode = readMode }
            if let sortMode = saved.sortMode, sortMode != book.sortMode {
                book.setSortMode(sortMode)
            }
            book.marks = saved.marks
            book.bookmarks = saved.bookmarks
        }
        store.noteOpened(path: path)

        // 最終ページ復元(GoToLastPage: 0=確認/1=自動/2=無効。§7.3)
        guard !skipPageRestore, settings.goToLastPageMode < 2,
              let page = store.savedPage(forPath: path), page > 0,
              page < book.pageCount else { return }
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
                  let image = await book.image(at: index) else { return }
            presentOriginalSizePanel(image: image, title: book.entries[index].name)
        }
    }

    private func displayedIndex(in spread: Book.Spread, leftSide: Bool?) -> Int? {
        guard let first = spread.indices.first else { return nil }
        guard spread.indices.count == 2, let leftSide else { return first }
        let readsFromLeft = book?.readMode.readsFromLeft ?? false
        return leftSide == readsFromLeft ? spread.indices[0] : spread.indices[1]
    }

    /// 原寸表示パネル(旧 FullImagePanel §4.13 の簡易版。キーを失うと閉じる)
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

    // MARK: - 最後に開いた本(仕様書 §4.1.1 #1)

    func openTheLastBook() {
        guard let recent = BookHistoryStore.shared.mostRecentBook() else { return }
        openBook(at: URL(fileURLWithPath: recent.path))
    }

    // MARK: - メニュー用アクション

    @objc func addRemoveBookmarkMenu(_ sender: Any?) { toggleBookmark() }
    @objc func nextBookmarkMenu(_ sender: Any?) { goToBookmark(next: true) }
    @objc func previousBookmarkMenu(_ sender: Any?) { goToBookmark(next: false) }
    @objc func nextBookMenu(_ sender: Any?) { openAdjacentBook(forward: true) }
    @objc func previousBookMenu(_ sender: Any?) { openAdjacentBook(forward: false) }
    @objc func openLastBookMenu(_ sender: Any?) { openTheLastBook() }
    @objc func toggleSlideshowMenu(_ sender: Any?) { toggleSlideshow() }
}

/// Open Recent サブメニューを開くたびに履歴から再構築する(仕様書 §7.2)
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
