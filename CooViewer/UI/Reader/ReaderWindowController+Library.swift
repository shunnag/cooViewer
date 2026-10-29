import AppKit
import SwiftUI
import Washi

/// 付随機能: しおり・本の状態保存/復元・同フォルダ移動・スライドショー・
/// ゴミ箱・Finder 表示・原寸表示(仕様書 §4.7-§4.13, §7)。
extension ReaderWindowController {
    struct ImageBookPersistence {
        let bookID: ObjectIdentifier
        let complete: Bool
        let navigationRevision: Int
        let missingPage: (index: Int, path: String?)?
        let landedOnCardAnchor: String?
    }

    // MARK: - 状態の保存と復元(仕様書 §7)

    /// 現在の本の状態を保存する(切替時・クローズ時・終了時。§7.7 の穴も塞ぐ)
    func saveCurrentBookState() {
        // 開けなかった本(空のプレースホルダ)は履歴・設定に記録しない
        guard let book, book.pageCount > 0, !book.isSyntheticPreview else { return }
        let path = book.source.url.path
        let persistence = imageBookPersistence.flatMap { $0.bookID == ObjectIdentifier(book) ? $0 : nil }
        // ページ番号に加えて「どのファイルか」も添える(新規キー)。次回開いたとき
        // エントリ列が変わっていても(ネスト展開の失敗・並び替え)照合できる
        func pagePath(_ index: Int) -> String? {
            book.entries.indices.contains(index) ? book.entries[index].pathInBook : nil
        }
        let bookmarks = book.bookmarks.map { bookmark in
            // 除外がある一覧では旧しおりの番号と実ファイルの対応を確定できない(設計書 §7.4)。
            if bookmark.pagePath == nil, persistence?.complete != true { return bookmark }
            // 記録済みパスのページが今回の本に存在しない(ネスト展開の失敗等で
            // 照合できなかった)場合は元の記録を保つ。今回の位置で上書きすると、
            // 次回そのページが戻ってきたときに照合できなくなる
            if let stored = bookmark.pagePath,
               !book.entries.contains(where: { $0.pathInBook == stored }) {
                return bookmark
            }
            return PageBookmark(
                name: bookmark.name, pageIndex: bookmark.pageIndex,
                pagePath: pagePath(bookmark.pageIndex) ?? bookmark.pagePath)
        }
        var pageIndex = book.currentIndex
        var currentPagePath = pagePath(pageIndex)
        if let persistence, let missing = persistence.missingPage,
           book.explicitNavigationRevision == persistence.navigationRevision {
            // 見開きの再配置は移動に数えず、明示移動までは欠落した元の錨を守る(設計書 §7.4)。
            pageIndex = missing.index
            currentPagePath = missing.path
        }
        history.saveImageBook(
            path: path, snapshot: .init(
                displayName: book.displayName, pageIndex: pageIndex,
                pagePath: currentPagePath,
                settings: .init(readMode: book.readMode, sortMode: book.sortMode,
                                marks: book.marks, bookmarks: bookmarks),
                isPartial: book.isPartial,
                isUnreadableVolume: book.entries[book.currentIndex].unreadableVolume != nil))
    }

    /// 開いた本に保存済み設定を適用する(§4.1.2 手順 6-7, §7.1)。
    /// 保存された並び順への並べ替えはメインアクター外で行われるので、初回描画が
    /// 復元後の並びになるよう完了を待つ。待つ間に後発のオープンが始まっていたら
    /// 以降(特に「前回のページへ?」の確認ダイアログ)は行わない
    func restoreBookState(for book: Book, skipPageRestore: Bool, generation: Int) async -> ImageBookPersistence? {
        let store = history
        let path = book.source.url.path
        let complete = await book.source.excludedChildCount() == 0 && !book.isPartial
        guard generation == openGeneration else { return nil }
        // 復元ゲートで移動しない設定でも、欠落した保存位置の保護は必要(設計書 §7.4)。
        let storedPage = store.savedPage(forPath: path, inRecents: true, pathOnly: book.isPartial,
                                         includingIndexOnly: book.isPartial)
        let missingPage: (index: Int, path: String?)?
        if let storedPage,
           (book.isPartial && storedPage.pagePath == nil)
            || storedPage.pagePath.map({ path in !book.entries.contains { $0.pathInBook == path } }) == true {
            missingPage = (storedPage.page, storedPage.pagePath)
        } else { missingPage = nil }
        var landedOnCardAnchor: String?
        func snapshot() -> ImageBookPersistence {
            ImageBookPersistence(bookID: ObjectIdentifier(book), complete: complete,
                                 navigationRevision: book.explicitNavigationRevision, missingPage: missingPage,
                                 landedOnCardAnchor: landedOnCardAnchor)
        }
        if let saved = store.settings(displayName: book.displayName, path: path) {
            if let readMode = saved.readMode { book.readMode = readMode }
            if let sortMode = saved.sortMode, sortMode != book.sortMode {
                _ = await book.setSortMode(sortMode).value
                guard generation == openGeneration else { return nil }
            }
            if !book.isPartial { book.marks = saved.marks }
            // しおりは保存時のページパスで照合し直す(エントリ列の変化に追従)
            book.bookmarks = saved.bookmarks.map { bookmark in
                if book.isPartial {
                    var resolved = bookmark
                    resolved.pageIndex = bookmark.pagePath.flatMap { path in
                        book.entries.firstIndex { $0.pathInBook == path }
                    } ?? -1
                    return resolved
                }
                // 欠落を含む番号列では旧しおりの clamp も確定位置にできない(設計書 §7.4)。
                if bookmark.pagePath == nil, !complete { return bookmark }
                var resolved = bookmark
                resolved.pageIndex = BookHistoryStore.reconciledIndex(
                    saved: bookmark.pageIndex, pagePath: bookmark.pagePath,
                    entries: book.entries)
                return resolved
            }
        }
        // 復元ページは履歴を更新する前に読む(仕様書 §4.1.2: 手順 7 → 8 の順)。
        // 復元ゲートの実在確認はメインアクター外(上限内なら I/O なし)
        let inRecents = await store.isWithinRecentLimit(path: path)
        guard generation == openGeneration else { return nil }
        let restorePage = store.savedPage(forPath: path, inRecents: inRecents, pathOnly: book.isPartial)

        // 最終ページ復元(GoToLastPage: 0=確認/1=自動/2=無効。§7.3)。
        // ページパスが記録されていれば同じファイルのページへ照合し直す
        guard !skipPageRestore, settings.goToLastPageMode < 2,
              let restorePage else { return snapshot() }
        // 部分本では旧番号への代替と番号だけの確認を禁止する(設計書 §7.4、仕様書 §4.17)。
        let page: Int
        if book.isPartial {
            guard let path = restorePage.pagePath,
                  let index = book.entries.firstIndex(where: { $0.pathInBook == path })
                    ?? book.entries.firstIndex(where: {
                        $0.unreadableVolume.map { path.hasPrefix($0.relativePath + "/") } == true
                    }) else { return snapshot() }
            page = index
        } else {
            page = BookHistoryStore.reconciledIndex(
                saved: restorePage.page, pagePath: restorePage.pagePath,
                entries: book.entries)
        }
        guard book.entries.indices.contains(page) else { return snapshot() }
        func recordCardAnchor() {
            // 保存保護とは別に実際の復元先を記録し、未復元の錨へ再読込後に飛ばさない(設計書 §7.4、§2.4)。
            if book.isPartial, let path = restorePage.pagePath,
               let marker = book.entries[page].unreadableVolume,
               path.hasPrefix(marker.relativePath + "/") {
                landedOnCardAnchor = path
            }
        }
        guard page > 0 else {
            // 先頭のカードは移動や確認を要さないが、巻内の元の位置は完全版への復帰に必要(設計書 §7.4、§2.4)。
            recordCardAnchor()
            return snapshot()
        }
        if settings.goToLastPageMode == 1 || confirmLastPageRestore(page) {
            book.goTo(index: page)
            recordCardAnchor()
        }
        return snapshot()
    }

    // MARK: - しおり(仕様書 §4.7)

    func toggleBookmark() {
        if isEPUBMode {
            toggleEPUBBookmark()
            return
        }
        guard let book else { return }
        guard allowIndexStateEdit(for: book, bookmarks: true) else { return }
        let page = book.currentIndex
        if let index = book.bookmarks.firstIndex(where: { $0.pageIndex == page }) {
            book.bookmarks.remove(at: index)
        } else {
            let name = book.entries.indices.contains(page) ? book.entries[page].name : ""
            let pagePath = book.entries.indices.contains(page) ? book.entries[page].pathInBook : nil
            book.bookmarks.append(.init(name: name, pageIndex: page, pagePath: pagePath))
        }
        saveCurrentBookState()
        // サムネイル表示中はしおりバッジ/絞り込みへ即時反映
        if isThumbnailOverlayVisible {
            presentThumbnailOverlay(for: book)
        }
    }

    /// しおり編集シート(§4.7.2。コピー編集のため Cancel が有効 §13.3)
    func editBookmarks() {
        if isEPUBMode {
            editEPUBBookmarks()
            return
        }
        guard let book, book.pageCount > 0, let window,
              bookmarkEditorWindow == nil else { return }
        let editor = NSWindow(contentViewController: NSHostingController(
            rootView: BookmarkEditorView(
                bookmarks: book.bookmarks, pageCount: book.pageCount,
                bookIsComplete: imageBookPersistence.flatMap {
                    $0.bookID == ObjectIdentifier(book) ? $0.complete : nil
                } ?? false,
                pagePath: { [weak book] index in
                    guard let book, book.entries.indices.contains(index) else { return nil }
                    return book.entries[index].pathInBook
                },
                onSave: { [weak self, weak book] bookmarks in
                    guard let self, let book else { return }
                    self.saveEditedBookmarks(bookmarks, for: book)
                },
                onClose: { [weak self] in
                    guard let self, let sheet = self.bookmarkEditorWindow else { return }
                    self.window?.endSheet(sheet)
                    self.bookmarkEditorWindow = nil
                })))
        bookmarkEditorWindow = editor
        window.beginSheet(editor)
    }

    /// OK の確定もキー操作と同じ保存規則を通し、番号のずれを持ち込ませない(設計書 §7.4、仕様書 §4.17)。
    @discardableResult
    func saveEditedBookmarks(_ bookmarks: [PageBookmark], for book: Book) -> Bool {
        guard allowIndexStateEdit(for: book, bookmarks: true) else { return false }
        book.bookmarks = bookmarks
        if book === self.book {
            saveCurrentBookState()
            if isThumbnailOverlayVisible { presentThumbnailOverlay(for: book) }
        } else {
            // シート中の本切替でも、同意した編集対象だけに書き戻す(仕様書 §4.7.2)。
            history.save(displayName: book.displayName, path: book.source.url.path,
                settings: .init(readMode: book.readMode, sortMode: book.sortMode,
                                marks: book.marks, bookmarks: book.bookmarks))
        }
        return true
    }

    /// しおり一覧メニューからのジャンプ(representedObject = 0 始まり index)
    @objc func goToBookmarkListItem(_ sender: NSMenuItem) {
        guard let book, let index = sender.representedObject as? Int,
              book.entries.indices.contains(index) else { return }
        book.goTo(index: index)
        refreshAfterJump()
    }

    /// ComicInfo の章(目次)メニューからのジャンプ(cooViewer-4fi.6)
    @objc func goToChapterListItem(_ sender: NSMenuItem) {
        guard let book, let index = sender.representedObject as? Int,
              book.entries.indices.contains(index) else { return }
        book.goTo(index: index)
        refreshAfterJump()
    }

    func goToBookmark(next: Bool) {
        if isEPUBMode {
            goToEPUBBookmark(next: next)
            return
        }
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
    @discardableResult
    func switchSingleSpread() -> Task<Void, Never>? {
        guard let book else { return nil }
        guard allowIndexStateEdit(for: book, bookmarks: false) else { return nil }
        let checkpoint = book.navigationCheckpoint
        return Task {
            let spread = await book.currentSpread()
            guard book === self.book, book.isAtNavigationCheckpoint(checkpoint),
                  !Task.isCancelled else { return }
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

    /// 部分本の番号編集を入口で拒否し、保存規則と同じ判断に揃える(設計書 §7.4、§2.4)。
    func allowIndexStateEdit(for book: Book, bookmarks: Bool) -> Bool {
        guard book.isPartial else { return true }
        showReaderNotice(bookmarks
            ? String(localized: "Bookmarks cannot be changed while volumes are missing")
            : String(localized: "Spread adjustments cannot be saved while volumes are missing"))
        return false
    }

    // MARK: - 同フォルダの次/前の本(仕様書 §4.1.4, §4.3.4)

    /// 親フォルダ内の「本」一覧(名前順、隠しファイル除外。SiblingBooks.scan)。
    /// 巻末付近では毎ページ表示ごとに呼ばれる(次の本の事前準備)ため 5 秒間
    /// キャッシュし、ミス時の走査はメインアクター外で行う(NAS では stat 1 回が
    /// 数 ms、死んだマウントでは SMB タイムアウトまで止まる)。キャッシュ命中は
    /// 中断点なしに同期で返り、進行中の走査には合流する(設計書 §7.3)
    func siblingBooks(of currentURL: URL) async -> [String] {
        // EPUB モードでも同じ兄弟走査を使う(次/前の本の操作感を揃える)
        let parent = currentURL.deletingLastPathComponent()
        if let cached = cachedSiblings, cached.parent == parent.path,
           Date().timeIntervalSince1970 - cached.timestamp < 5 {
            return cached.paths
        }
        if let scan = siblingScan, scan.parent == parent.path {
            return await scan.task.value
        }
        let probe = fileSystemProbe
        let startedAt = Date().timeIntervalSince1970
        let task = Task.detached(priority: .userInitiated) {
            await SiblingBooks.scan(parent: parent, probe: probe)
        }
        siblingScan = (parent.path, task)
        let paths = await task.value
        // 自分の走査だけを畳む(別フォルダの走査は結果を親パス付きで持つので
        // 混ざらない)。走査開始後に別フォルダの一覧がキャッシュされていたら
        // (遅い旧フォルダの結果が後から届いた)、新しい方を上書きしない。
        // 呼び出し側は本・世代の照合で古い一覧を使わない
        if siblingScan?.task == task { siblingScan = nil }
        if (cachedSiblings?.timestamp ?? 0) <= startedAt {
            cachedSiblings = (parent.path, paths, Date().timeIntervalSince1970)
        }
        return paths
    }

    /// 次/前の本へ(端でラップアラウンド。§4.3.4)。openLast=前の本を末尾から開く。
    /// コレクション(合本)内から開いた EPUB では「本」はコレクション自体
    /// なので、基準をコレクションフォルダへ読み替える(設計書 §2.4 EPUB 対応)。
    /// fromSlideshow は openBookFlow まで一時的に伝播し、タイマーを維持する。
    /// 兄弟一覧の取得を待つ間に別のオープンが始まったり基準の本が変わったら、
    /// 古い一覧で開かない。合本内の EPUB→EPUB 移動は openGeneration を動かさず
    /// folderURL も変わらないため、提示エポックも併せて照合する
    @discardableResult
    func openAdjacentBook(forward: Bool, openLast: Bool = false,
                          fromSlideshow: Bool = false) -> Task<Void, Never>? {
        guard let currentURL =
            epubCollectionContext?.folderURL ?? currentBookFileURL else {
            // 復帰オープンが不成立。この終端は openBook(→openBookFlow の defer)を
            // 通らないため、ここで復帰フラグを消さないと残って didReachBookEdge の
            // ガードを恒久的に塞ぐ(cooViewer-s7j)
            collectionNavigation.returnPending = false
            return nil
        }
        let generation = openGeneration
        let epoch = epubPresentEpoch
        adjacentBookRequest &+= 1
        let request = adjacentBookRequest
        // 呼び出し元(巻端の openCollectionEntry 等)がこの要求のために立てた復帰
        // フラグか。要求時に false なら、後から立った分は別の所有者のもの
        let ownsReturn = collectionNavigation.returnPending
        return Task {
            let siblings = await siblingBooks(of: currentURL)
            guard generation == openGeneration, epoch == epubPresentEpoch,
                  (epubCollectionContext?.folderURL ?? currentBookFileURL) == currentURL
            else {
                // 失効した要求は openBookFlow を通らないので、自分の復帰フラグは自分で
                // 畳む。ただし後発の所有者がいるときは触らない(cooViewer-s7j の不変条件):
                // 世代が進んだ(後発オープンの defer が畳む)、番号が進んだ(後発の
                // 次/前の本要求が要る)、isOpeningBook(openBook は世代を即時に進めるが
                // エポックは Task 内で isOpeningBook = true と同じ同期区間で進める。
                // その隙で失効したなら in-flight のフローが所有し、自身の後片付けで畳む)
                if ownsReturn, generation == openGeneration,
                   request == adjacentBookRequest, !isOpeningBook {
                    collectionNavigation.returnPending = false
                }
                return
            }
            openAdjacentBook(from: currentURL, siblings: siblings, forward: forward,
                             openLast: openLast, fromSlideshow: fromSlideshow)
        }
    }

    private func openAdjacentBook(from currentURL: URL, siblings: [String],
                                  forward: Bool, openLast: Bool, fromSlideshow: Bool) {
        guard !siblings.isEmpty,
              let current = siblings.firstIndex(of: currentURL.path) else {
            // 兄弟が無い/現在の本が一覧に見つからない(読書中の外部改名・移動、
            // 親フォルダの列挙失敗、現在の本自身がドットファイル)ときは無反応に
            // せず、失敗ナビの慣習どおり音で「これ以上進めない」を返す
            // (goToBookmark と同じフィードバック。監査 #6)。復帰フラグも消す
            // (openBookFlow を通らない終端。cooViewer-s7j)
            collectionNavigation.returnPending = false
            NSSound.beep()
            return
        }
        let target = (current + (forward ? 1 : -1) + siblings.count) % siblings.count
        // ナビゲーションではコレクションフォルダへ潜らない: フォルダ自身に
        // 着地して階層を保つ(潜ると以後の次/前の本が中の階層の兄弟を走査し、
        // 元の階層へ戻れなくなる)。画像ゼロなら「画像がありません」を表示
        openBook(at: URL(fileURLWithPath: siblings[target]), atLastPage: openLast,
                 allowCollectionDrill: false, fromSlideshow: fromSlideshow)
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
        if isOpeningBook { return }
        // EPUB(リフロー)は book が nil。Washi が自前でめくり演出を張るため
        // pendingTurnForward / refreshAfterJump は通さない。巻末到達での停止は
        // didReachBookEdge 側で扱う。仕様書 §4.9 / §4.3.4 に従い、0 は本内
        // ループ、1/2 は次の本へ継続、3 のみ停止する(cooViewer-7hj/mji)
        if isEPUBMode {
            epubGoForward()
            return
        }
        guard let book else {
            stopSlideshow()
            return
        }
        if book.moveNext() == .hitEnd {
            switch settings.loopCheck {
            case 0:
                book.goToFirst()
            case 1, 2:
                openAdjacentBook(forward: true, fromSlideshow: true)
                return
            case 3:
                stopSlideshow()
                return
            default:
                stopSlideshow()
                return
            }
        }
        pendingTurnForward = true  // スライドショーもページ送りとしてめくり効果を付ける
        refreshAfterJump()
    }

    // MARK: - ゴミ箱(仕様書 §4.12。AppleScript フォールバックは廃止)

    /// 表示中ページをゴミ箱へ。side は画面の左右(readMode で実ページに解決)。
    func trashDisplayedPage(leftSide: Bool) {
        guard let book else { return }
        let checkpoint = book.navigationCheckpoint
        Task {
            let spread = await book.currentSpread()
            guard book === self.book, book.isAtNavigationCheckpoint(checkpoint),
                  !spread.indices.isEmpty else { return }
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
            guard alert.runModal() == .alertFirstButtonReturn,
                  book === self.book, book.isAtNavigationCheckpoint(checkpoint) else { return }
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
        let checkpoint = book.navigationCheckpoint
        Task {
            let spread = await book.currentSpread()
            guard book === self.book, book.isAtNavigationCheckpoint(checkpoint) else { return }
            // ページの実体ファイルを選択表示: 単体画像はその画像、
            // 書庫/PDF 内のページは書庫/PDF 本体(仕様書 §4.13)
            let url: URL
            if let index = displayedIndex(in: spread, book: book, leftSide: leftSide) {
                url = await book.source.containerFileURL(for: book.entries[index])
            } else {
                url = book.source.url
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 見開きのもう一方(読み順で 2 枚目)のページを Finder で表示する
    /// (File メニューで Option を押すと現れる代替項目。単ページ表示では
    /// 「もう一方」が無いのでビープ)
    func showOtherPageInFinder() {
        guard let book else { return }
        let checkpoint = book.navigationCheckpoint
        Task {
            let spread = await book.currentSpread()
            guard book === self.book, book.isAtNavigationCheckpoint(checkpoint) else { return }
            guard spread.indices.count >= 2,
                  book.entries.indices.contains(spread.indices[1]) else {
                NSSound.beep()
                return
            }
            let url = await book.source.containerFileURL(
                for: book.entries[spread.indices[1]])
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 現在のページのファイル情報パネルを表示する(新規機能。開いていれば
    /// 内容を現在ページで更新する)。見開き時は両ページ分を用意し、
    /// パネル上部のセグメントで左右を切り替える(既定は読み順の先頭)
    func showFileInfo() {
        fileInfoGeneration &+= 1
        let generation = fileInfoGeneration
        // リフロー EPUB は画像 Book を降ろしているため、Washi の現在
        // publication から直接構成する(cooViewer-oxr.37、設計書 §2.4)。
        if let publication = epubPublication, let url = epubBookURL {
            let page = reflowEPUBFileInfoPage(publication: publication, url: url)
            presentFileInfoPanel(pages: [page], initialIndex: 0)
            return
        }
        guard let book else { return }
        let checkpoint = book.navigationCheckpoint
        Task {
            let spread = await book.currentSpread()
            guard generation == fileInfoGeneration, book === self.book,
                  book.isAtNavigationCheckpoint(checkpoint) else { return }
            let readingOrder = spread.indices.filter {
                book.entries.indices.contains($0)
            }
            guard !readingOrder.isEmpty else {
                NSSound.beep()
                return
            }
            // 画面上の左→右の並びに直す(右→左読みでは読み順が反転する)
            let (ordered, initialPosition) = PageFileInfo.physicalOrder(
                readingOrderIndices: readingOrder,
                readsFromLeft: book.readMode.readsFromLeft)
            let sideLabels = ordered.count == 2
                ? [String(localized: "Left Page"), String(localized: "Right Page")]
                : [""]
            // 以降の I/O 中にソートが変わっても全ページを同じ並びから収集する。
            let entries = ordered.map { book.entries[$0] }
            let comicInfo = await book.comicInfo()  // 本メタデータ(4fi.5)
            guard generation == fileInfoGeneration else { return }
            // FXL EPUB は EPUBSource が publication を保持する。各ページの
            // 情報へ出版物全体のメタデータを付ける(cooViewer-oxr.37、
            // 設計書 §2.4)。
            let epubAccessibility = (book.source as? EPUBSource)?
                .publication.metadata.accessibility
            var pages: [FileInfoPage] = []
            for (position, index) in ordered.enumerated() {
                pages.append(await fileInfoPage(
                    for: entries[position], index: index, in: book,
                    sideLabel: sideLabels[position],
                    comicInfo: comicInfo,
                    epubAccessibility: epubAccessibility))
                guard generation == fileInfoGeneration else { return }
            }
            presentFileInfoPanel(pages: pages, initialIndex: initialPosition)
        }
    }

    /// リフロー EPUB の現在 spine 項目と出版物メタデータを
    /// ファイル情報用の 1 ページへまとめる。
    private func reflowEPUBFileInfoPage(publication: EPUBPublication,
                                        url: URL) -> FileInfoPage {
        let requestedIndex = epubView?.currentLocator.spineIndex ?? 0
        let index = min(max(0, requestedIndex),
                        max(0, publication.readingOrder.count - 1))
        let path = publication.readingOrder.indices.contains(index)
            ? publication.readingOrder[index].containerPath
            : url.lastPathComponent
        let name = (path as NSString).lastPathComponent
        let details = PageFileInfo.details(
            entryName: name,
            pathInBook: path,
            containerURL: url,
            pageNumber: index + 1,
            pageCount: max(1, publication.readingOrder.count),
            imageData: nil,
            fallbackPixelSize: nil,
            epubAccessibility: publication.metadata.accessibility)
        return FileInfoPage(title: name, sideLabel: "", details: details)
    }

    /// 1 ページ分のファイル情報を収集する
    private func fileInfoPage(for entry: PageEntry, index: Int, in book: Book,
                              sideLabel: String,
                              comicInfo: ComicInfo?,
                              epubAccessibility: EPUBAccessibility?) async
        -> FileInfoPage {
        let containerURL = await book.source.containerFileURL(for: entry)
        let data = await book.source.imageData(for: entry)
        let fallback = data == nil ? await book.source.imageSize(for: entry) : nil
        let archiveEngineName = await book.source
            .archiveEngineKind(for: entry)?.displayName
        let details = PageFileInfo.details(
            entryName: entry.name,
            pathInBook: entry.pathInBook,
            containerURL: containerURL,
            pageNumber: index + 1,
            pageCount: book.pageCount,
            imageData: data,
            fallbackPixelSize: fallback,
            comicInfo: comicInfo,
            epubAccessibility: epubAccessibility,
            archiveEngineName: archiveEngineName)
        return FileInfoPage(title: entry.name, sideLabel: sideLabel,
                            details: details)
    }

    private func presentFileInfoPanel(pages: [FileInfoPage], initialIndex: Int) {
        guard pages.indices.contains(initialIndex) else { return }
        fileInfoDebugDetails = pages[initialIndex].details
        // パネルの高さは内容の自然サイズに合わせる(画面の 85% まで。
        // スクロールは内容が収まらないときだけ生きる)。見開きは左右の
        // 切替でパネルが伸縮しないよう、大きい方のページに合わせる
        let contentHeight = pages.map { page in
            NSHostingView(rootView: FileInfoContent(details: page.details)
                .frame(width: FileInfoView.contentWidth)).fittingSize.height
        }.max() ?? 300
        let segmentHeight = pages.count > 1 ? FileInfoView.segmentHeight : 0
        let heightLimit = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let size = NSSize(width: FileInfoView.contentWidth,
                          height: min(contentHeight + segmentHeight, heightLimit))

        let view = FileInfoView(pages: pages, initialIndex: initialIndex) {
            [weak self] page in
            self?.fileInfoPanel?.title = page.title
        }
        let hosting = NSHostingController(rootView: view)

        if let panel = fileInfoPanel {
            // 開いたまま再実行されたら内容だけ差し替える(パネルは 1 枚)
            panel.title = pages[initialIndex].title
            panel.contentViewController = hosting
            panel.setContentSize(size)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        panel.title = pages[initialIndex].title
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.setContentSize(size)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        fileInfoPanel = panel
    }

    func viewOriginal(leftSide: Bool?) {
        guard let book else { return }
        let checkpoint = book.navigationCheckpoint
        let reduction = settings.noiseReductionScope.includesOriginalSize
            ? settings.noiseReductionLevel : .none
        let relativePath = settings.showRelativePaths
        Task {
            let spread = await book.currentSpread()
            guard book === self.book, book.isAtNavigationCheckpoint(checkpoint),
                  let index = displayedIndex(in: spread, book: book, leftSide: leftSide)
            else { return }
            let entry = book.entries[index]
            // 原寸画像とタイトルを同じ Entry に固定し、ソート後の index を読み直さない。
            guard var image = try? await book.source.image(for: entry, maxPixelSize: nil)
            else { return }
            // ML 高画質化(適用範囲が原寸表示を含むとき。全ページ対象)
            if reduction != .none {
                image = await ImageResampler.shared.reduceNoise(
                    image, level: reduction)
            }
            presentOriginalSizePanel(
                image: image,
                title: entry.displayTitle(relativePath: relativePath))
        }
    }

    private func displayedIndex(in spread: Book.Spread, book: Book, leftSide: Bool?) -> Int? {
        guard let first = spread.indices.first else { return nil }
        guard spread.indices.count == 2, let leftSide else { return first }
        let readsFromLeft = book.readMode.readsFromLeft
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

    // MARK: - 次の本の事前スプール(設計書 §5 キャッシュ・先読み)

    /// 巻末が近づいたら同フォルダの次の書庫をバックグラウンドで開いて
    /// ローカル展開を始める。開く際に openBookFlow が再利用する。
    @discardableResult
    func maybePrepareNextBook() -> Task<Void, Never>? {
        let threshold = settings.prepareNextBookPages  // 0 は無効(設定「高度」)
        guard threshold > 0, let book, book.pageCount > 0,
              book.currentIndex >= book.pageCount - threshold,
              let currentURL = currentBookFileURL else { return nil }
        return Task { [weak self, weak book] in
            // 兄弟走査は応答しない媒体で長引くため、現在の本を待機中に保持しない(設計書 §5、§7.3)。
            let siblings = await self?.siblingBooks(of: currentURL)
            guard let self, let book, let siblings, book === self.book, !Task.isCancelled else { return }
            prepareNextBook(for: book, siblings: siblings)
        }
    }

    /// 兄弟一覧が揃った後の準備本体。await を含まないので、同じ一覧へ合流した
    /// 複数回の呼び出しが preparingNextBookPath の照合をすり抜けて二重に
    /// 準備を始めることはない
    private func prepareNextBook(for book: Book, siblings: [String]) {
        guard siblings.count > 1,
              let current = siblings.firstIndex(of: book.source.url.path) else { return }
        let nextPath = siblings[(current + 1) % siblings.count]
        guard nextPath != book.source.url.path,
              preparingNextBookPath != nextPath else { return }
        let nextURL = URL(fileURLWithPath: nextPath)
        if SupportedTypes.isEPUB(nextURL) {
            guard preparedNextEPUB?.path != nextPath else { return }
            preparingNextBookPath = nextPath
            // cooViewer-oxr.45: 次巻 EPUB は utility で publication だけを先に
            // 解析し、表示要求では同じインスタンスを再利用する（設計書 §2.4）。
            Task(priority: .utility) { [weak self, weak book] in
                defer { self?.preparingNextBookPath = nil }
                let publication = await Task.detached(priority: .utility) {
                    try? await EPUBStagingArea.shared.openPublication(at: nextURL)
                }.value
                guard let publication, let self, let book, self.book === book else { return }
                preparedNextEPUB = (nextPath, publication)
            }
            return
        }
        let archiveEngine = settings.effectiveArchiveEngine
        guard preparedNextBook?.path != nextPath
                || preparedNextBook?.archiveEngine != archiveEngine,
              SupportedTypes.isArchive(nextURL) else { return }
        preparingNextBookPath = nextPath
        // 準備対象は「今の本の次の兄弟」。準備中に別の本へ切り替わったら、古い
        // フォルダの隣接書庫をスロットに入れない(スプール済み一時データが居座る
        // リーク+古いスロットの再導入を防ぐ。監査 #11)
        let readSubFolders = settings.readSubFolder
        let spoolLimit = settings.archiveSpoolSizeLimit
        // 次の本の事前準備は best-effort の背面作業。明示的に utility へ落として
        // 現在の本のページ読み込みと同一ボリュームで競合させない(内側の
        // buildTask/spoolTask はこの優先度を継承する)。現在の本の準備
        // (openBookFlow 側の Task→beginBackgroundPreparation)は別ソース・別 Task で
        // 意図的に高優先のまま — この変更の影響を受けない
        Task(priority: .utility) { [weak self, weak book] in
            defer { self?.preparingNextBookPath = nil }
            guard let source = try? await BookSourceFactory.make(
                for: nextURL,
                readSubFolders: readSubFolders,
                archiveEngine: archiveEngine) else { return }
            guard book != nil, self?.book === book else { return }
            // パスワード書庫は解除 UI が必要なため展開はしない(開く時に通常フロー)
            if await !source.isEncrypted() {
                // 実効プロファイル(自動判定+高度設定の明示上書き)を適用してから展開
                guard let profile = await self?.effectiveMediaProfile(for: nextURL), book != nil else { return }
                await source.applyMediaProfile(profile)
                await source.beginBackgroundPreparation(spoolSizeLimit: spoolLimit)
            }
            guard let self, let book, self.book === book else { return }
            preparedNextBook = (nextPath, source, archiveEngine)
        }
    }

    // MARK: - 最後に開いた本(仕様書 §4.1.1 #1)

    /// 実在判定は履歴側がメインアクター外で行う(消えた本を飛ばす旧挙動のまま)。
    /// 待つ間に別の本が開かれていたら、古い要求で置き換えない
    @discardableResult
    func openTheLastBook() -> Task<Void, Never> {
        let generation = openGeneration
        return Task {
            guard let recent = await history.mostRecentExistingBook(),
                  generation == openGeneration else { return }
            openBook(at: URL(fileURLWithPath: recent.path))
        }
    }

    // MARK: - メニュー用アクション

    @objc func addRemoveBookmarkMenu(_ sender: Any?) { toggleBookmark() }
    @objc func editBookmarksMenu(_ sender: Any?) { editBookmarks() }
    @objc func nextBookmarkMenu(_ sender: Any?) { goToBookmark(next: true) }
    @objc func previousBookmarkMenu(_ sender: Any?) { goToBookmark(next: false) }
    @objc func epubGoBackMenu(_ sender: Any?) {
        _ = performEPUB(.epubGoBack, leftHalf: nil)
    }
    @objc func nextBookMenu(_ sender: Any?) { openAdjacentBook(forward: true) }
    @objc func previousBookMenu(_ sender: Any?) { openAdjacentBook(forward: false) }
    @objc func openLastBookMenu(_ sender: Any?) { openTheLastBook() }
    @objc func showInFinderMenu(_ sender: Any?) {
        if isEPUBMode, let epubBookURL {
            NSWorkspace.shared.activateFileViewerSelecting([epubBookURL])
            return
        }
        showInFinder(leftSide: nil)
    }
    @objc func showOtherPageInFinderMenu(_ sender: Any?) { showOtherPageInFinder() }
    @objc func showFileInfoMenu(_ sender: Any?) { showFileInfo() }
    @objc func toggleSlideshowMenu(_ sender: Any?) { toggleSlideshow() }
}

/// しおりサブメニューを開くたびに現在の本のしおりで再構築する(仕様書 §4.7.1)
@MainActor
final class BookmarkListMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = BookmarkListMenuDelegate()
    private weak var attachedMenu: NSMenu?
    private weak var providedController: ReaderWindowController?

    init(controller: ReaderWindowController? = nil) {
        providedController = controller
        super.init()
    }

    func attach(_ menu: NSMenu) {
        attachedMenu = menu
    }

    /// キー経路でしおりを変更した場合も、次に開く前からサブメニュー内容を
    /// 現在状態へ揃える(仕様書 §4.7.1)
    func rebuild() {
        guard let attachedMenu else { return }
        menuNeedsUpdate(attachedMenu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = providedController ?? NSApp.windows
            .compactMap { $0.windowController as? ReaderWindowController }.first
        if let controller, controller.isEPUBMode {
            for (index, bookmark) in (controller.epubSession?.bookmarks ?? []).enumerated() {
                let page = controller.epubBookmarkPageNumber(for: bookmark.locator)
                    .map { "  (p.\($0))" } ?? ""
                let item = menu.addItem(
                    withTitle: bookmark.name + page,
                    action: #selector(
                        ReaderWindowController.goToEPUBBookmarkListItem(_:)),
                    keyEquivalent: "")
                item.representedObject = index
            }
            if (controller.epubSession?.bookmarks ?? []).isEmpty {
                let empty = menu.addItem(
                    withTitle: String(localized: "No Bookmarks"),
                    action: nil, keyEquivalent: "")
                empty.isEnabled = false
            }
            return
        }
        let bookmarks = controller?.book?.bookmarks ?? []
        for bookmark in bookmarks {
            let unresolved = controller?.book?.isPartial == true && bookmark.pageIndex < 0
            let label = unresolved ? String(localized: "(Missing volume)") : "(p.\(bookmark.pageIndex + 1))"
            let title = "\(bookmark.name)  \(label)"
            let item = menu.addItem(
                withTitle: title,
                action: #selector(ReaderWindowController.goToBookmarkListItem(_:)),
                keyEquivalent: "")
            let index = controller?.book?.resolvedBookmarkIndex(bookmark)
            item.representedObject = index
            item.isEnabled = index != nil
        }
        if bookmarks.isEmpty {
            let empty = menu.addItem(withTitle: String(localized: "No Bookmarks"),
                                     action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
    }
}

/// 章(目次)サブメニューを開くたびに現在の本の ComicInfo 章で再構築する
/// (cooViewer-4fi.6。メニューのみ提供)
@MainActor
final class ChapterListMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ChapterListMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.windows
            .compactMap { $0.windowController as? ReaderWindowController }.first
        // EPUB モードでは目次(nav)を章メニューとして出す(操作感の統一)
        if let controller, controller.isEPUBMode {
            for (index, entry) in (controller.epubSession?.flattenedToc ?? []).enumerated() {
                let item = menu.addItem(
                    withTitle: entry.title,
                    action: #selector(ReaderWindowController.goToEPUBChapterItem(_:)),
                    keyEquivalent: "")
                item.indentationLevel = entry.indent
                item.representedObject = index
            }
            if (controller.epubSession?.flattenedToc ?? []).isEmpty {
                let empty = menu.addItem(withTitle: String(localized: "No Chapters"),
                                         action: nil, keyEquivalent: "")
                empty.isEnabled = false
            }
            return
        }
        let chapters = controller?.book?.chapterMarks ?? []
        for chapter in chapters {
            let item = menu.addItem(
                withTitle: "\(chapter.name)  (p.\(chapter.page + 1))",
                action: #selector(ReaderWindowController.goToChapterListItem(_:)),
                keyEquivalent: "")
            item.representedObject = chapter.page
        }
        if chapters.isEmpty {
            let empty = menu.addItem(withTitle: String(localized: "No Chapters"),
                                     action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
    }
}

/// Open Recent サブメニューを開くたびに履歴から再構築する(仕様書 §7.2)。
/// menuNeedsUpdate は同期で項目を要求されるため、まず前回判明している実在
/// 状態で埋め(未判定は一覧どおり表示)、実在の再確認はメインアクター外で
/// 行って終わったら項目を差し替える。死んだマウントでもメニューが止まらない
@MainActor
final class RecentBooksMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentBooksMenuDelegate()
    private let store: BookHistoryStore
    /// 再確認の世代。古い再確認が新しい表示を上書きしないため
    private var refreshGeneration = 0

    init(store: BookHistoryStore = .shared) {
        self.store = store
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let shown = store.recentBookPaths()
        fill(menu, with: shown)
        refreshGeneration &+= 1
        let generation = refreshGeneration
        Task {
            let fresh = await store.existingRecentBookPaths()
            guard generation == refreshGeneration, fresh != shown else { return }
            fill(menu, with: fresh)
        }
    }

    private func fill(_ menu: NSMenu, with paths: [String]) {
        menu.removeAllItems()
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
