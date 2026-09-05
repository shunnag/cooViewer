import AppKit
import Washi

/// 開いている EPUB の実測 census を合本計画へ再利用する純粋な判定値
/// （cooViewer-oxr.65 / cooViewer-oxr.70、設計書 §2.4）。
struct EPUBOpenBookCensusSeed: Equatable, Sendable {
    let entryIndex: Int
    let counts: [Int]
    let pagesPerScreen: Int

    static func make(
        requestedMetricsKey: String,
        viewMetricsKey: String?,
        counts: [Int]?,
        pagesPerScreen: Int,
        entryIndex: Int?
    ) -> EPUBOpenBookCensusSeed? {
        guard viewMetricsKey == requestedMetricsKey,
              let counts, let entryIndex else { return nil }
        return EPUBOpenBookCensusSeed(
            entryIndex: entryIndex, counts: counts,
            pagesPerScreen: pagesPerScreen)
    }
}

/// EPUB サムネイルの描画条件をディスクキャッシュ名へ写像する
/// 純関数群（cooViewer-oxr.64 / cooViewer-oxr.63、設計書 §2.4 EPUB 対応）。
enum EPUBThumbnailCacheKey {
    /// Washi と同じテーマ解決規則。システム設定時だけウインドウ外観へ従う
    /// （cooViewer-oxr.63、設計書 §2.4 EPUB 対応）。
    static func effectiveIsDark(theme: Int, windowIsDark: Bool) -> Bool {
        switch theme {
        case 1: false
        case 2: true
        default: windowIsDark
        }
    }

    /// ページ割りが同じでも描画結果が変わる条件を分離する
    /// （cooViewer-oxr.64、設計書 §2.4 EPUB 対応）。
    static func renderingVariant(metricsKey: String, isDark: Bool,
                                 forcesReadableColors: Bool) -> String {
        "metrics:\(metricsKey)#theme:\(isDark ? "d" : "l")"
            + "#readable:\(forcesReadableColors ? "1" : "0")"
    }

    /// 単体 EPUB の画面サムネイル用キーを組み立てる
    /// （cooViewer-oxr.64、設計書 §2.4 EPUB 対応）。
    static func singleBook(path: String, totalPages: Int, pagesPerScreen: Int,
                           fontScale: Double, pageMargins: Int,
                           defaultFont: String, metricsKey: String,
                           isDark: Bool, forcesReadableColors: Bool) -> String {
        let variant = renderingVariant(
            metricsKey: metricsKey, isDark: isDark,
            forcesReadableColors: forcesReadableColors)
        return "epub:\(path)#\(totalPages)x\(pagesPerScreen)"
            + "#\(fontScale)#\(pageMargins)#\(defaultFont)"
            + "#\(variant)"
    }
}

/// サムネイルオーバーレイとリーダーの配線(仕様書 §4.8)。
/// 表示・非表示の切替と、表示中のページ送りキーの転用を担う。
extension ReaderWindowController {
    /// 現在巻と版面キーが一致するときだけ、Washi リーダーの実測値を返す。
    func openBookCensusSeed(for metricsKey: String) -> EPUBOpenBookCensusSeed? {
        guard let epubView,
              EPUBPersistencePolicy.shouldPersist(
                callbackPublication: epubView.publication,
                currentPublication: epubPublication) else { return nil }
        return EPUBOpenBookCensusSeed.make(
            requestedMetricsKey: metricsKey,
            viewMetricsKey: epubView.pageCensusMetricsKey,
            counts: epubView.pageCensus,
            pagesPerScreen: epubView.plannedPagesPerScreen,
            entryIndex: epubCollectionContext?.entryIndex)
    }

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
        presentEPUBThumbnailOverlay()
    }

    /// 表示中の EPUB 関連一覧を現在の版面・配色キーで組み直す
    /// (cooViewer-oxr.64 / cooViewer-oxr.63、設計書 §2.4 EPUB 対応)。
    func refreshVisibleEPUBThumbnailOverlay() {
        guard isThumbnailOverlayVisible else { return }
        if isEPUBMode {
            presentEPUBThumbnailOverlay()
            return
        }
        guard let book,
              book.entries.contains(where: { $0.reflowEPUBURL != nil }) else { return }
        presentThumbnailOverlay(for: book)
        revealThumbnailOverlay()
    }

    private func presentEPUBThumbnailOverlay() {
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
        let currentMetricsKey = EPUBScreenMetrics(
            viewportSize: window?.contentView?.bounds.size ?? .zero,
            settings: plannedEPUBSettings())
            .applyingRenditionSpread(epubPublication.metadata.rendition.spread)
            .cacheKey
        // 旧版面の census はセル位置にも使わない。新しい実測が届くまでは
        // 章単位へ戻し、新版面のキーへ旧番号の画像を保存しない(cooViewer-oxr.64)。
        let counts = epubView.pageCensusMetricsKey == currentMetricsKey
            ? (epubView.pageCensus
                ?? Array(repeating: 1, count: epubPublication.readingOrder.count))
            : Array(repeating: 1, count: epubPublication.readingOrder.count)
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
        // census の版面と配色条件をすべて分離し、同じ総ページ数でも古い画像を
        // 再利用しない（cooViewer-oxr.64、設計書 §2.4 EPUB 対応）。
        snapshot.bookKey = EPUBThumbnailCacheKey.singleBook(
            path: epubBookURL.path,
            totalPages: counts.reduce(0, +),
            pagesPerScreen: epubView.plannedPagesPerScreen,
            fontScale: settings.epubFontScale,
            pageMargins: settings.epubPageMargins,
            defaultFont: settings.epubDefaultFont,
            metricsKey: currentMetricsKey,
            isDark: isDarkWindowAppearance,
            forcesReadableColors: settings.epubForceReadableColors)
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
        let collectionSource: any BookSource
        if let context = epubCollectionContext {
            folderURL = context.folderURL
            entries = context.entries
            collectionSource = context.source
        } else if let book, book.source is NestedFolderSource {
            folderURL = book.source.url
            entries = book.entries
            collectionSource = book.source
        } else {
            collectionPageMapTask?.cancel()
            collectionPageMapPendingKey = nil
            collectionPageMap = nil
            collectionPageMapAttempts.removeAll()
            return
        }
        let placeholders = entries.enumerated().compactMap { index, entry in
            entry.reflowEPUBURL.map { (index: index, url: $0) }
        }
        guard !placeholders.isEmpty else {
            collectionPageMapTask?.cancel()
            collectionPageMapPendingKey = nil
            collectionPageMap = nil
            collectionPageMapAttempts.removeAll()
            return
        }
        let baseMetrics = EPUBScreenMetrics(
            viewportSize: window?.contentView?.bounds.size ?? .zero,
            settings: plannedEPUBSettings())
        let key = baseMetrics.cacheKey
        let openKey = epubPublication.map {
            baseMetrics.applyingRenditionSpread(
                $0.metadata.rendition.spread).cacheKey
        } ?? key
        let openSeed = openBookCensusSeed(for: openKey)
        let pendingKey = folderURL.path + "#" + key
        if let map = collectionPageMap, map.folderPath == folderURL.path,
           map.metricsKey == key, map.entries == entries {
            // 開いている巻がまさに欠落中で、同一メトリクスのリーダー census が
            // 出ているなら、上限後でもゼロコスト(atlas 呼び出しなし)で差し込む
            let canSelfHeal: Bool = {
                guard let openSeed else { return false }
                return map.missingEntries.contains(openSeed.entryIndex)
            }()
            // 完成済み or 再試行上限に達した未完マップはそのまま(毎ナビゲーション
            // 再解析しない)。自己回復できる場合だけ上限を無視して埋め直す
            if !canSelfHeal,
               map.isComplete
                || (collectionPageMapAttempts[pendingKey] ?? 0)
                    >= Self.collectionPageMapMaxAttempts {
                return
            }
        }
        if collectionPageMapPendingKey == pendingKey { return }
        collectionPageMapTask?.cancel()
        collectionPageMapPendingKey = pendingKey
        // 開いている本の census はリーダー実測を流用(**同一メトリクスの
        // 実測に限る** — 旧寸法の値を新キーのマップへ焼き込まない)
        var seededCounts: [Int: [Int]] = [:]
        if let openSeed {
            seededCounts[openSeed.entryIndex] = openSeed.counts
        }
        // 直前の未完マップで計測済みの巻(epubURL != nil の segment)はそのまま流用し、
        // 欠けた巻だけ測り直す(atlas LRU 退避で再測が要るときの二度手間を省く)
        if let old = collectionPageMap, old.folderPath == folderURL.path,
           old.metricsKey == key, old.entries == entries {
            for segment in old.segments {
                if segment.epubURL != nil, let itemCounts = segment.itemCounts,
                   seededCounts[segment.entryIndex] == nil {
                    seededCounts[segment.entryIndex] = itemCounts
                }
            }
        }
        collectionPageMapTask = Task { [weak self] in
            var counts = seededCounts
            for placeholder in placeholders where counts[placeholder.index] == nil {
                guard !Task.isCancelled else { return }
                let preparsed = await collectionSource
                    .preparsedReflowPublication(for: placeholder.url)
                if let plan = await EPUBAtlasStore.shared
                    .screenPlan(for: placeholder.url, metrics: baseMetrics,
                                preparsed: preparsed) {
                    counts[placeholder.index] = plan.counts
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
            // published が未完なら試行回数を加算(published のみ数える。
            // キャンセル/超越では加算しない)。上限で毎回の再解析を止める
            if let built = self.collectionPageMap, !built.isComplete {
                self.collectionPageMapAttempts[pendingKey, default: 0] += 1
            }
            // 表示へ即時反映
            if self.isEPUBMode {
                self.updateEPUBIndicators()
                // cooViewer-col: 合本ページマップ完成時は検索一覧の表示番号も
                // 個別 EPUB 基準から合本全体基準へ即時更新する。
                self.refreshEPUBSearchPageNumbers()
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

    /// EPUB の実効テーマがダークか（cooViewer-oxr.63、設計書 §2.4 EPUB 対応）。
    /// システムテーマ時だけウインドウ外観を参照し、固定テーマを優先する。
    var isDarkWindowAppearance: Bool {
        let windowIsDark = window?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return EPUBThumbnailCacheKey.effectiveIsDark(
            theme: settings.epubTheme, windowIsDark: windowIsDark)
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
        let openMetricsKey = epubPublication.map {
            metrics.applyingRenditionSpread(
                $0.metadata.rendition.spread).cacheKey
        } ?? metrics.cacheKey
        let openSeed = openBookCensusSeed(for: openMetricsKey)
        let collectionSource = book.source
        let isDark = isDarkWindowAppearance
        let forcesReadableColors = settings.epubForceReadableColors
        collectionOverlayTask = Task { [weak self, weak book] in
            var counts: [Int: [Int]] = [:]
            var perBookPagesPerScreen: [Int: Int] = [:]
            if let openSeed {
                counts[openSeed.entryIndex] = openSeed.counts
                perBookPagesPerScreen[openSeed.entryIndex] =
                    openSeed.pagesPerScreen
            }
            for placeholder in placeholders {
                guard !Task.isCancelled else { return }
                if counts[placeholder.index] != nil { continue }
                let preparsed = await collectionSource
                    .preparsedReflowPublication(for: placeholder.url)
                guard let screenPlan = await EPUBAtlasStore.shared
                    .screenPlan(for: placeholder.url, metrics: metrics,
                                preparsed: preparsed)
                else { continue }
                counts[placeholder.index] = screenPlan.counts
                perBookPagesPerScreen[placeholder.index] =
                    screenPlan.pagesPerScreen
            }
            guard let self, let book, book === self.book, !counts.isEmpty,
                  self.isThumbnailOverlayVisible, !Task.isCancelled else { return }
            let plan = CollectionThumbnailPlan.make(
                bookEntries: book.entries, counts: counts,
                perBookPagesPerScreen: perBookPagesPerScreen,
                metrics: metrics, isDark: isDark)
            self.presentExpandedCollectionOverlay(
                plan: plan, folderURL: book.source.url,
                baseSource: book.source, baseEntries: book.entries,
                currentCell: plan.overlayIndex(forBookPage: book.currentIndex),
                readsFromLeft: book.readMode.readsFromLeft,
                singleSetting: book.singleSetting,
                coverSingle: book.coverSingleFirst,
                bookmarkedBookPages: Set(book.bookmarks.map(\.pageIndex)),
                forcesReadableColors: forcesReadableColors,
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
        forcesReadableColors: Bool,
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
        // キャッシュキーは本別の画面内ページ数も含める。entries.count が
        // 同じ組合せでも spread の違うセルを再利用しない
        let pagesPerScreenKey = plan.perBookPagesPerScreen.keys.sorted().map {
            "\($0):\(plan.perBookPagesPerScreen[$0] ?? 1)"
        }.joined(separator: ",")
        let renderingVariant = EPUBThumbnailCacheKey.renderingVariant(
            metricsKey: plan.metrics.cacheKey, isDark: plan.isDark,
            forcesReadableColors: forcesReadableColors)
        snapshot.bookKey = "col:\(folderURL.path)#exp\(plan.entries.count)"
            + "#pps:\(pagesPerScreenKey)"
            + "#\(renderingVariant)"
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
        let openMetricsKey = epubPublication.map {
            metrics.applyingRenditionSpread(
                $0.metadata.rendition.spread).cacheKey
        } ?? metrics.cacheKey
        let openSeed = openBookCensusSeed(for: openMetricsKey)
        let isDark = isDarkWindowAppearance
        let forcesReadableColors = settings.epubForceReadableColors
        let placeholders = context.entries.enumerated().compactMap { index, entry in
            entry.reflowEPUBURL.map { (index: index, url: $0) }
        }
        collectionOverlayTask?.cancel()
        collectionOverlayTask = Task { [weak self] in
            var counts: [Int: [Int]] = [:]
            var perBookPagesPerScreen: [Int: Int] = [:]
            if let openSeed {
                counts[openSeed.entryIndex] = openSeed.counts
                perBookPagesPerScreen[openSeed.entryIndex] =
                    openSeed.pagesPerScreen
            }
            for placeholder in placeholders {
                guard !Task.isCancelled else { return }
                if counts[placeholder.index] != nil { continue }
                let preparsed = await context.source
                    .preparsedReflowPublication(for: placeholder.url)
                guard let screenPlan = await EPUBAtlasStore.shared
                    .screenPlan(for: placeholder.url, metrics: metrics,
                                preparsed: preparsed)
                else { continue }
                counts[placeholder.index] = screenPlan.counts
                perBookPagesPerScreen[placeholder.index] =
                    screenPlan.pagesPerScreen
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
                perBookPagesPerScreen: perBookPagesPerScreen,
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
                forcesReadableColors: forcesReadableColors,
                jumpContext: .epubMode(context))
        }
    }
}
