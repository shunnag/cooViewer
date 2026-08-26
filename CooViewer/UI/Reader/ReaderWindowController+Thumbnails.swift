import AppKit
import Washi

/// サムネイルオーバーレイとリーダーの配線(仕様書 §4.8)。
/// 表示・非表示の切替と、表示中のページ送りキーの転用を担う。
extension ReaderWindowController {
    /// サムネイルオーバーレイのトグル。本が無ければ何もしない
    func showThumbnail() {
        guard let book else { return }
        if isThumbnailOverlayVisible {
            hideThumbnailOverlay()
            return
        }
        presentThumbnailOverlay(for: book)
        revealThumbnailOverlay()
    }

    /// オーバーレイを表示する。表示前にレイアウトを確定させ、グリッド領域の
    /// 実寸(onGeometryChange)が最初の可視フレームより先にモデルへ届くように
    /// する — 非表示中のウインドウリサイズ後などに古いビューポートのグリッドが
    /// 一瞬見えてから組み替わるチラつきを防ぐ
    private func revealThumbnailOverlay() {
        thumbnailHostingView?.layoutSubtreeIfNeeded()
        thumbnailHostingView?.isHidden = false
    }

    /// オーバーレイの内容を book で組み直す(表示中の本の切替時にも使う)
    func presentThumbnailOverlay(for book: Book) {
        thumbnailOverlayModel.onJump = { [weak self, weak book] index in
            // 本の入替の最中(オーバーレイがまだ旧 Book の内容のうち)は
            // クリックを無視する。入替完了時に openBookFlow 側が新しい本で
            // 一覧を組み直すので、そこで正しいジャンプができるようになる
            guard let self, let book, book === self.book else { return }
            self.hideThumbnailOverlay()
            book.goTo(index: index)
            self.refreshAfterJump()
        }
        thumbnailOverlayModel.onClose = { [weak self] in
            self?.hideThumbnailOverlay()
        }
        activeCollectionOverlay = nil  // ここからは未展開の一覧
        thumbnailOverlayModel.present(book: book,
                                      displayedIndices: lastSpreadIndices)
        // 代理ページ(リフロー EPUB)を含む合本は、census が揃い次第
        // 「全ページ展開」した一覧へ差し替える(他形式との差異をなくす)
        scheduleCollectionOverlayExpansion(for: book)
    }

    func hideThumbnailOverlay() {
        thumbnailHostingView?.isHidden = true
        // 閉じた後のサムネイル先読みはページ表示と帯域を奪い合うだけなので止める
        thumbnailOverlayModel.pausePrefetch()
        collectionOverlayTask?.cancel()
        activeCollectionOverlay = nil
    }

    var isThumbnailOverlayVisible: Bool {
        thumbnailHostingView?.isHidden == false
    }

    /// オーバーレイ表示中のページ送りキーはサムネイル画面の送りに転用する
    /// (旧来のページ単位閲覧 §4.8)
    func thumbnailOverlayTurnPage(forward: Bool) {
        thumbnailOverlayModel.moveScreen(by: forward ? 1 : -1)
    }

    @objc func showThumbnailsMenu(_ sender: Any?) {
        toggleThumbnailOverlay()
    }

    /// モード対応のトグル(メニュー・--show-thumbnails 検証フラグから)
    func toggleThumbnailOverlay() {
        if isEPUBMode {
            epubShowThumbnail()
        } else {
            showThumbnail()
        }
    }

    /// リフロー EPUB のサムネイル一覧(仕様書 §4.8 の EPUB 読み替え。
    /// 設計書 §2.4 EPUB 対応)。セルは表示と同じ「画面」単位
    /// (単ページ/見開きの 1 面)で、census のページ割り・全文ページ番号に
    /// 一致する。census 未完了時は章単位(1 項目 1 セル)にフォールバック
    func epubShowThumbnail() {
        if isThumbnailOverlayVisible {
            hideThumbnailOverlay()
            return
        }
        // コレクション文脈では「合本全体」の一覧(画像ページ+各 EPUB の
        // 全ページ展開)を出す — 合本の画像モードと同じ体験にする
        if let context = epubCollectionContext {
            epubShowCollectionThumbnail(context: context)
            return
        }
        guard let epubView, let epubPublication, let epubBookURL else {
            NSSound.beep()
            return
        }
        let counts = epubView.pageCensus
            ?? Array(repeating: 1, count: epubPublication.readingOrder.count)
        let screens = EPUBScreenThumbnailSource.makeScreens(
            counts: counts, pagesPerScreen: epubView.plannedPagesPerScreen)
        guard !screens.isEmpty else {
            NSSound.beep()
            return
        }
        let source = EPUBScreenThumbnailSource(url: epubBookURL,
                                               screens: screens, view: epubView)
        // 現在位置を含む画面(spine・項目内ページで最後に一致するセル)
        let locator = epubView.currentLocator
        let pageInItem = epubView.pageInItem
        let currentScreen = screens.lastIndex {
            $0.spineIndex < locator.spineIndex
                || ($0.spineIndex == locator.spineIndex
                    && $0.pageInItem <= pageInItem)
        } ?? 0
        thumbnailOverlayModel.onJump = { [weak self] index in
            guard let self, self.isEPUBMode,
                  screens.indices.contains(index) else { return }
            self.hideThumbnailOverlay()
            let screen = screens[index]
            let count = counts.indices.contains(screen.spineIndex)
                ? counts[screen.spineIndex] : 1
            let progression = count <= 1
                ? 0.0 : Double(screen.pageInItem) / Double(count - 1)
            self.epubView?.go(to: EPUBLocator(spineIndex: screen.spineIndex,
                                              progression: progression))
        }
        thumbnailOverlayModel.onClose = { [weak self] in
            self?.hideThumbnailOverlay()
        }
        var snapshot = ThumbnailOverlayModel.Snapshot()
        snapshot.entries = source.pageEntries
        snapshot.source = source
        // キャッシュキーはページ割りが変わる要素(寸法・フォント・余白)込み
        // (使い回すと旧メトリクスのサムネイルが同じ番号で出てしまう)
        snapshot.bookKey = "epub:\(epubBookURL.path)#\(counts.reduce(0, +))"
            + "x\(epubView.plannedPagesPerScreen)"
            + "#\(settings.epubFontScale)#\(settings.epubPageMargins)"
            + "#\(settings.epubDefaultFont)"
            + "#\(isDarkWindowAppearance ? "d" : "l")"
        snapshot.currentIndex = currentScreen
        snapshot.displayedIndices = [currentScreen]
        snapshot.readsFromLeft = epubInputReadsFromLeft
        // 1 画面 = 1 セル(グリッド側のペア合成はしない): しきい値 0 で
        // 計測済みセルはすべて「横長=単独」扱いになる
        snapshot.singleSetting = 0
        activeCollectionOverlay = nil  // 単体一覧は展開計画ではない
        thumbnailOverlayModel.present(snapshot: snapshot)
        revealThumbnailOverlay()
    }

    // MARK: - 合本の全体ページマップ(ページバー等の全体基準化)

    /// 現在の文脈で有効な全体ページマップ(合本が対象で、census 構築済み、
    /// かつ**エントリ列が構築時と同一**。ソート・シャッフル・削除で並びが
    /// 変わった古いマップで番号やジャンプ先を出さない)
    func activeCollectionPageMap() -> CollectionPageMap? {
        guard let map = collectionPageMap else { return nil }
        if let context = epubCollectionContext {
            return map.folderPath == context.folderURL.path
                && map.entries == context.entries ? map : nil
        }
        if let book, book.source.url.path == map.folderPath,
           map.entries == book.entries {
            return map
        }
        return nil
    }

    /// 全体ページマップを(必要なら)非同期で組み直す。folder+メトリクスが
    /// 一致していれば何もしない(インジケータ更新のたびに呼んで安全)。
    /// 開いている EPUB の census はリーダーから流用して再実測を省く
    func ensureCollectionPageMap() {
        let folderURL: URL
        let entries: [PageEntry]
        if let context = epubCollectionContext {
            folderURL = context.folderURL
            entries = context.entries
        } else if let book, book.source is NestedFolderSource {
            folderURL = book.source.url
            entries = book.entries
        } else {
            collectionPageMapTask?.cancel()
            collectionPageMapPendingKey = nil
            collectionPageMap = nil
            return
        }
        let placeholders = entries.enumerated().compactMap { index, entry in
            entry.reflowEPUBURL.map { (index: index, url: $0) }
        }
        guard !placeholders.isEmpty else {
            collectionPageMapTask?.cancel()
            collectionPageMapPendingKey = nil
            collectionPageMap = nil
            return
        }
        let metrics = EPUBScreenMetrics(
            viewportSize: window?.contentView?.bounds.size ?? .zero,
            settings: plannedEPUBSettings())
        let key = metrics.cacheKey
        if let map = collectionPageMap, map.folderPath == folderURL.path,
           map.metricsKey == key, map.entries == entries {
            return
        }
        let pendingKey = folderURL.path + "#" + key
        if collectionPageMapPendingKey == pendingKey { return }
        collectionPageMapTask?.cancel()
        collectionPageMapPendingKey = pendingKey
        // 開いている本の census はリーダー実測を流用(**同一メトリクスの
        // 実測に限る** — 旧寸法の値を新キーのマップへ焼き込まない)
        var seededCounts: [Int: [Int]] = [:]
        if let context = epubCollectionContext, let epubView,
           epubView.pageCensusMetricsKey == key,
           let counts = epubView.pageCensus {
            seededCounts[context.entryIndex] = counts
        }
        collectionPageMapTask = Task { [weak self] in
            var counts = seededCounts
            for placeholder in placeholders where counts[placeholder.index] == nil {
                guard !Task.isCancelled else { return }
                if let itemCounts = await EPUBAtlasStore.shared
                    .screenCounts(for: placeholder.url, metrics: metrics) {
                    counts[placeholder.index] = itemCounts
                }
            }
            guard let self, !Task.isCancelled,
                  self.collectionPageMapPendingKey == pendingKey else { return }
            self.collectionPageMapPendingKey = nil
            // 対象が変わっていたら捨てる(合本切替・退場・構築中のソート)
            let stillSame: Bool = {
                if let context = self.epubCollectionContext {
                    return context.folderURL == folderURL
                        && context.entries == entries
                }
                return self.book?.source.url == folderURL
                    && self.book?.entries == entries
            }()
            guard stillSame else { return }
            self.collectionPageMap = CollectionPageMap.make(
                folderPath: folderURL.path, metricsKey: key,
                entries: entries, counts: counts)
            // 表示へ即時反映
            if self.isEPUBMode {
                self.updateEPUBIndicators()
            } else {
                self.updatePageIndicators(indices: self.lastSpreadIndices)
            }
        }
    }

    /// 全体ページマップに基づくジャンプ(ページバードラッグ・0-9 の %)。
    /// 画像ページ / いまの EPUB 内 / 別 EPUB を全体基準で振り分ける
    func jumpToCollectionFraction(_ fraction: Double, map: CollectionPageMap) {
        let page = Int((min(max(fraction, 0), 1)
            * Double(max(1, map.total - 1))).rounded())
        switch map.target(forGlobalPage: page) {
        case .bookPage(let index):
            if isEPUBMode {
                epubCollectionReturnPending = true
                openBook(at: URL(fileURLWithPath: map.folderPath), atPage: index)
            } else if let book {
                book.goTo(index: index)
                refreshAfterJump()
            }
        case .epubPage(let url, let entryIndex, let spineIndex,
                       let pageInItem, let countInItem):
            let progression = countInItem <= 1
                ? 0.0 : Double(pageInItem) / Double(countInItem - 1)
            let locator = EPUBLocator(spineIndex: spineIndex,
                                      progression: progression)
            if isEPUBMode {
                if url == epubBookURL {
                    epubView?.go(to: locator)
                } else if let context = epubCollectionContext {
                    openCollectionEPUB(url: url, entryIndex: entryIndex,
                                       locator: locator, context: context)
                }
            } else {
                enterCollectionReflowEPUB(url: url, entryIndex: entryIndex,
                                          forward: true, at: locator)
            }
        }
    }

    // MARK: - コレクションの「全ページ展開」一覧(設計書 §2.4 EPUB 対応)

    /// ウインドウの実効外観がダークか(展開サムネイル・ホバーバブルの配色用)
    var isDarkWindowAppearance: Bool {
        window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 合本内の代理ページの census を集め、揃ったら展開一覧へ差し替える。
    /// census は EPUBAtlasStore にキャッシュされるので 2 回目からは即時
    private func scheduleCollectionOverlayExpansion(for book: Book) {
        collectionOverlayTask?.cancel()
        let placeholders = book.entries.enumerated().compactMap { index, entry in
            entry.reflowEPUBURL.map { (index: index, url: $0) }
        }
        guard !placeholders.isEmpty else { return }
        let metrics = EPUBScreenMetrics(
            viewportSize: window?.contentView?.bounds.size ?? .zero,
            settings: plannedEPUBSettings())
        let isDark = isDarkWindowAppearance
        collectionOverlayTask = Task { [weak self, weak book] in
            var counts: [Int: [Int]] = [:]
            for placeholder in placeholders {
                guard !Task.isCancelled else { return }
                guard let itemCounts = await EPUBAtlasStore.shared
                    .screenCounts(for: placeholder.url, metrics: metrics)
                else { continue }
                counts[placeholder.index] = itemCounts
            }
            guard let self, let book, book === self.book, !counts.isEmpty,
                  self.isThumbnailOverlayVisible, !Task.isCancelled else { return }
            let plan = CollectionThumbnailPlan.make(
                bookEntries: book.entries, counts: counts,
                metrics: metrics, isDark: isDark)
            self.presentExpandedCollectionOverlay(
                plan: plan, folderURL: book.source.url,
                baseSource: book.source, baseEntries: book.entries,
                currentCell: plan.overlayIndex(forBookPage: book.currentIndex),
                readsFromLeft: book.readMode.readsFromLeft,
                singleSetting: book.singleSetting,
                coverSingle: book.coverSingleFirst,
                bookmarkedBookPages: Set(book.bookmarks.map(\.pageIndex)),
                jumpContext: .imageBook(book))
        }
    }

    /// 展開一覧のジャンプ元(どのモードから開いたか)
    private enum ExpandedOverlayContext {
        case imageBook(Book)
        case epubMode(EPUBCollectionContext)
    }

    /// 展開一覧を提示する(画像モード・EPUB モード共通)。
    /// セルのジャンプ先はモードに応じて 実ページ移動 / EPUB 入場 /
    /// 合本復帰 / 横断ジャンプ に振り分ける
    private func presentExpandedCollectionOverlay(
        plan: CollectionThumbnailPlan, folderURL: URL,
        baseSource: any BookSource, baseEntries: [PageEntry],
        currentCell: Int, readsFromLeft: Bool,
        singleSetting: Int, coverSingle: Bool,
        bookmarkedBookPages: Set<Int>,
        jumpContext: ExpandedOverlayContext) {
        thumbnailOverlayModel.onJump = { [weak self] cell in
            guard let self, plan.targets.indices.contains(cell) else { return }
            self.hideThumbnailOverlay()
            switch (plan.targets[cell], jumpContext) {
            case (.bookPage(let index), .imageBook(let book)):
                guard book === self.book else { return }
                book.goTo(index: index)
                self.refreshAfterJump()
            case (.bookPage(let index), .epubMode(let context)):
                // 合本の実ページへ復帰(巻端復帰と同じ抑止フラグで)
                self.epubCollectionReturnPending = true
                self.openBook(at: context.folderURL, atPage: index)
            case (.epubScreen(let url, let entryIndex, let spine,
                              let page, let count), .imageBook(let book)):
                guard book === self.book else { return }
                let progression = count <= 1
                    ? 0.0 : Double(page) / Double(count - 1)
                self.enterCollectionReflowEPUB(
                    url: url, entryIndex: entryIndex, forward: true,
                    at: EPUBLocator(spineIndex: spine, progression: progression))
            case (.epubScreen(let url, let entryIndex, let spine,
                              let page, let count), .epubMode(let context)):
                let progression = count <= 1
                    ? 0.0 : Double(page) / Double(count - 1)
                let locator = EPUBLocator(spineIndex: spine,
                                          progression: progression)
                if url == self.epubBookURL {
                    self.epubView?.go(to: locator)
                } else {
                    self.openCollectionEPUB(url: url, entryIndex: entryIndex,
                                            locator: locator, context: context)
                }
            }
        }
        thumbnailOverlayModel.onClose = { [weak self] in
            self?.hideThumbnailOverlay()
        }
        activeCollectionOverlay = ActiveCollectionOverlay(
            plan: plan, baseEntries: baseEntries)
        var snapshot = ThumbnailOverlayModel.Snapshot()
        snapshot.entries = plan.entries
        snapshot.source = CollectionThumbnailSource(
            url: folderURL, plan: plan,
            base: baseSource, baseEntries: baseEntries)
        // キャッシュキーはページ割りが変わる要素込み(旧メトリクスの
        // サムネイルが同じ番号で出ないように)
        snapshot.bookKey = "col:\(folderURL.path)#exp\(plan.entries.count)"
            + "x\(plan.metrics.pagesPerScreen)#\(settings.epubFontScale)"
            + "#\(settings.epubPageMargins)#\(settings.epubDefaultFont)"
            + "#\(Int(plan.metrics.contentSize.width))x\(Int(plan.metrics.contentSize.height))"
            + "#\(plan.isDark ? "d" : "l")"
        snapshot.currentIndex = currentCell
        snapshot.displayedIndices = [currentCell]
        snapshot.readsFromLeft = readsFromLeft
        snapshot.singleSetting = singleSetting
        snapshot.coverSingle = coverSingle
        // しおりは合本の実ページ基準 → 展開後のセルへ写像
        snapshot.bookmarkedPages = Set(bookmarkedBookPages.map {
            plan.overlayIndex(forBookPage: $0)
        })
        thumbnailOverlayModel.present(snapshot: snapshot)
        revealThumbnailOverlay()
    }

    /// EPUB モード(コレクション文脈)からの合本全体の一覧。
    /// **未展開(代理ページ=表紙 1 セル)の一覧を即時表示**し、census が
    /// 揃い次第展開版へ差し替える(census 完了までトグルも効かない
    /// 「無反応」を作らない — 画像モード側と同じ二段構え)。
    /// 開いている本の census はリーダー側で実測済みのことが多く、
    /// アトラス側もメトリクスキーでキャッシュするので体感は速い
    private func epubShowCollectionThumbnail(context: EPUBCollectionContext) {
        guard epubView != nil, epubBookURL != nil else {
            NSSound.beep()
            return
        }
        // まず未展開の合本一覧を即時表示
        activeCollectionOverlay = nil
        thumbnailOverlayModel.onJump = { [weak self] cell in
            guard let self, context.entries.indices.contains(cell) else { return }
            self.hideThumbnailOverlay()
            if let url = context.entries[cell].reflowEPUBURL {
                guard url != self.epubBookURL else { return }  // いまの本
                self.openCollectionEPUB(url: url, entryIndex: cell,
                                        locator: EPUBLocator(spineIndex: 0),
                                        context: context)
            } else {
                self.epubCollectionReturnPending = true
                self.openBook(at: context.folderURL, atPage: cell)
            }
        }
        thumbnailOverlayModel.onClose = { [weak self] in
            self?.hideThumbnailOverlay()
        }
        var initial = ThumbnailOverlayModel.Snapshot()
        initial.entries = context.entries
        initial.source = context.source
        initial.bookKey = "col:\(context.folderURL.path)#raw\(context.entries.count)"
        initial.currentIndex = context.entryIndex
        initial.displayedIndices = [context.entryIndex]
        initial.readsFromLeft = epubInputReadsFromLeft
        initial.singleSetting = context.singleSetting
        initial.coverSingle = context.coverSingle
        initial.bookmarkedPages = context.bookmarkedPages
        thumbnailOverlayModel.present(snapshot: initial)
        revealThumbnailOverlay()

        // census が揃い次第、展開版へ差し替える
        let metrics = EPUBScreenMetrics(
            viewportSize: window?.contentView?.bounds.size ?? .zero,
            settings: plannedEPUBSettings())
        let isDark = isDarkWindowAppearance
        let placeholders = context.entries.enumerated().compactMap { index, entry in
            entry.reflowEPUBURL.map { (index: index, url: $0) }
        }
        collectionOverlayTask?.cancel()
        collectionOverlayTask = Task { [weak self] in
            var counts: [Int: [Int]] = [:]
            for placeholder in placeholders {
                guard !Task.isCancelled else { return }
                guard let itemCounts = await EPUBAtlasStore.shared
                    .screenCounts(for: placeholder.url, metrics: metrics)
                else { continue }
                counts[placeholder.index] = itemCounts
            }
            // 差し替えは「一覧がまだ開いていて、同じ合本の文脈」のときだけ。
            // 現在位置は差し替え時点の実位置から計算し直す(実測待ちの間に
            // 読み進んでいても正しいセルを強調する)
            guard let self, !Task.isCancelled, self.isEPUBMode,
                  self.isThumbnailOverlayVisible, !counts.isEmpty,
                  self.epubCollectionContext?.folderURL == context.folderURL,
                  let currentURL = self.epubBookURL, let view = self.epubView
            else { return }
            let plan = CollectionThumbnailPlan.make(
                bookEntries: context.entries, counts: counts,
                metrics: metrics, isDark: isDark)
            let currentCell = plan.overlayIndex(
                forEPUB: currentURL,
                spineIndex: view.currentLocator.spineIndex,
                pageInItem: view.pageInItem)
                ?? plan.overlayIndex(forBookPage:
                    self.epubCollectionContext?.entryIndex ?? context.entryIndex)
            self.presentExpandedCollectionOverlay(
                plan: plan, folderURL: context.folderURL,
                baseSource: context.source, baseEntries: context.entries,
                currentCell: currentCell,
                readsFromLeft: self.epubInputReadsFromLeft,
                singleSetting: context.singleSetting,
                coverSingle: context.coverSingle,
                bookmarkedBookPages: context.bookmarkedPages,
                jumpContext: .epubMode(context))
        }
    }
}
