import AppKit
import Washi

/// 合本の実ページ・リフロー巻の往来と、全文ページ対応表の構築を担う。
extension ReaderWindowController {
    // MARK: - コレクション(合本)との往来

    /// 合本内のリフロー EPUB 代理ページに到達した(refreshDisplay から)。
    /// EPUB モードへ切り替える: 前進到達は先頭(または保存位置の復元。
    /// atFirst はループ再入場で復元をバイパス)、後退到達は末尾から。
    /// 開けない本(DRM 等)は静的な表紙ページに降格する
    @discardableResult
    func enterCollectionReflowEPUB(url: URL, entryIndex: Int, forward: Bool,
                                   atFirst: Bool = false,
                                   at explicitLocator: EPUBLocator? = nil,
                                   fromSlideshow: Bool = false) -> Task<Void, Never>? {
        guard let book else { return nil }
        let context = EPUBCollectionContext(
            folderURL: book.source.url,
            entryIndex: entryIndex,
            entryCount: book.pageCount,
            readsFromLeft: book.readMode.readsFromLeft,
            entries: book.entries,
            source: book.source,
            singleSetting: book.singleSetting,
            coverSingle: book.coverSingleFirst,
            bookmarkedPages: Set(book.bookmarks.map(\.pageIndex)))
        // 提示エポックを採番(await より前)。合本内移動は openGeneration を
        // 動かさないため、last-request-wins は epubPresentEpoch で担保する
        epubPresentEpoch += 1
        let presentEpoch = epubPresentEpoch
        let generation = openGeneration
        return Task { [weak self] in
            guard let self else { return }
            // cooViewer-oxr.42: 合本生成時に保持した publication を、ファイル
            // 同一性検証を通して再利用する（設計書 §2.4）。
            let preparsed = await book.source.preparsedReflowPublication(for: url)
            let publication = await self.epubParseCoalescer.publicationIfAvailable(
                at: url, preparsed: preparsed)
            // 解析中に別の本が開かれた/代理ページを離れたら何もしない
            // (openBookFlow の世代規則と同じ。book 同一性だけでは、新しい
            // オープンの途中(book 差し替え前)をすり抜ける)。
            // 一覧からの明示ジャンプは着地ページを問わない(現在ページが
            // 代理ページとは限らないため)。成功時の提示だけでなく、解析失敗の
            // 表紙降格も提示世代を照合する。旧失敗で後発ジャンプを巻き戻さない。
            guard self.openGeneration == generation,
                  self.epubPresentEpoch == presentEpoch,
                  self.book === book,
                  explicitLocator != nil || book.currentIndex == entryIndex
            else { return }
            guard let publication, !publication.isFixedLayout,
                  !EPUBImageOnlyHeuristic.qualifies(publication),
                  !publication.isDRMProtected else {
                if let publication {
                    // 確定降格(FXL/DRM): 以後ずっと静的表紙。恒久ブラックリストへ。
                    // 隣へ素通りさせると全滅フォルダ + ループ設定で openBook が無限
                    // 循環する。初回降格のときだけ DRM を説明する(合本内で無説明に
                    // 表紙へ化けると『なぜこの巻だけ読めないか』が分からない。監査 #9)
                    let inserted = self.collectionNavigation.recordPermanentFailure(for: url)
                    if inserted, publication.isDRMProtected {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "This book is protected by DRM.")
                        alert.informativeText = publication.drmSchemeName ?? ""
                        alert.runModal()
                    } else {
                        NSSound.beep()
                    }
                } else {
                    // 一過性の解析失敗(nil = 一時 I/O 失敗・壊れファイル): 恒久
                    // ブラックリストには入れない。今回の着地だけ代理表紙を出すため
                    // 消費式マーカーへ(そうしないと openBook→refreshDisplay→再入場 が
                    // 一時失敗ファイルで無限ループする)。次の意図的再着地では再解析する
                    self.collectionNavigation.recordTransientFailure(for: url)
                    NSSound.beep()
                }
                // 表紙降格は同一の合本ブックのまま静的表紙を再描画する。
                // openBook で作り直すと NestedUnlocker の解錠済み子・パスワード
                // キャンセル記憶が失われ再プロンプトになる(57t が塞ごうとして
                // 届かなかった経路 = 画像モードでは self.epubCollectionContext が
                // nil のためソース再利用が成立せず作り直していた。cooViewer-ari)。
                // ブラックリスト登録は上で済んでいるので、その場で再描画すれば
                // refreshDisplay の恒久失敗判定が
                // 入場せず表紙を出す。modal 中に状態が変わり得るので世代/本を再照合する
                guard self.openGeneration == generation,
                      self.epubPresentEpoch == presentEpoch, self.book === book else { return }
                book.goTo(index: entryIndex)
                await self.refreshDisplay()
                return
            }
            self.presentReflowableEPUB(
                publication, url: url,
                atPage: (explicitLocator == nil && atFirst) ? 0 : nil,
                atLastPage: explicitLocator == nil && !forward && !atFirst,
                atLocator: explicitLocator,
                collectionContext: context,
                epoch: presentEpoch,
                fromSlideshow: fromSlideshow)
        }
    }

    /// 一覧からの横断ジャンプ: 合本文脈のまま別の(または同じ)EPUB の
    /// 指定位置を開く(EPUB モード内から。book は無いので文脈から組む)。
    /// 合本内移動は openGeneration を動かさないため、提示エポックを採番して
    /// last-request-wins を保証する(連打で最後にクリックした巻だけが確定)
    func openCollectionEPUB(url: URL, entryIndex: Int,
                            locator: EPUBLocator,
                            context: EPUBCollectionContext) {
        let newContext = EPUBCollectionContext(
            folderURL: context.folderURL,
            entryIndex: entryIndex,
            entryCount: context.entryCount,
            readsFromLeft: context.readsFromLeft,
            entries: context.entries,
            source: context.source,
            singleSetting: context.singleSetting,
            coverSingle: context.coverSingle,
            bookmarkedPages: context.bookmarkedPages)
        // 提示エポックを採番(await より前。last-request-wins)
        epubPresentEpoch += 1
        let presentEpoch = epubPresentEpoch
        Task { [weak self] in
            guard let self else { return }
            // cooViewer-oxr.42: 代理ソースが保持する解析結果を EPUB 間移動にも
            // 引き継ぐ（設計書 §2.4）。
            let preparsed = await context.source.preparsedReflowPublication(for: url)
            let publication = await self.epubParseCoalescer.publicationIfAvailable(
                at: url, preparsed: preparsed)
            guard self.isEPUBMode,
                  self.epubPresentEpoch == presentEpoch,
                  self.epubCollectionContext?.folderURL == context.folderURL
            else { return }
            guard let publication, !publication.isFixedLayout,
                  !EPUBImageOnlyHeuristic.qualifies(publication),
                  !publication.isDRMProtected else {
                NSSound.beep()
                return
            }
            self.presentReflowableEPUB(publication, url: url,
                                       atLocator: locator,
                                       collectionContext: newContext,
                                       epoch: presentEpoch)
        }
    }

    /// 合本の指定エントリへ復帰する(EPUB の巻端・次/前の本から)。
    /// 範囲外は合本自体の巻端として仕様書 §4.9 / §4.3.4 のループ規則に従う。
    /// 文脈は消さない(オープン完了までの間に巻端イベントが再発しても
    /// 単体モード意味論へ落とさない — 抑止は collectionNavigation.returnPending)。
    /// fromSlideshow は再帰・巻端ラップ・openBook へ一時的に伝播する
    func openCollectionEntry(context: EPUBCollectionContext, at index: Int,
                             forward: Bool, atFirst: Bool = false,
                             fromSlideshow: Bool = false) {
        guard (0..<context.entryCount).contains(index) else {
            if forward {
                switch settings.loopCheck {
                case 0:
                    // 巻末ループは画像本の goToFirst と同じく「先頭から」
                    // (保存位置の復元は通さない)
                    openCollectionEntry(context: context, at: 0,
                                        forward: true, atFirst: true,
                                        fromSlideshow: fromSlideshow)
                case 1, 2:
                    collectionNavigation.returnPending = true
                    openAdjacentBook(forward: true, fromSlideshow: fromSlideshow)
                case 3:
                    if fromSlideshow { stopSlideshow() }
                default:
                    if fromSlideshow { stopSlideshow() }
                }
            } else {
                switch settings.loopCheck {
                case 0: openCollectionEntry(
                    context: context, at: context.entryCount - 1, forward: false,
                    fromSlideshow: fromSlideshow)
                case 1:
                    collectionNavigation.returnPending = true
                    openAdjacentBook(forward: false, fromSlideshow: fromSlideshow)
                case 2:
                    collectionNavigation.returnPending = true
                    openAdjacentBook(forward: false, openLast: true,
                                     fromSlideshow: fromSlideshow)
                default: break
                }
            }
            return
        }
        // 着地先が別の代理ページなら到達方向を引き継いで連続入場する
        collectionNavigation.arrivalForward = forward
        collectionNavigation.arrivalAtFirst = atFirst
        collectionNavigation.returnPending = true
        openBook(at: context.folderURL, atPage: index, fromSlideshow: fromSlideshow)
    }

    /// 次/前の本ナビ(キー/マウス)で合本ソース再利用の復帰フラグを立てる。
    /// **合本文脈のときだけ**立てる — 単体 EPUB には再利用先(合本)が無く、
    /// 立てると開きが失敗(隣が DRM 等)したとき openBookFlow を通らず残り、
    /// didReachBookEdge の復帰中ガードを恒久的に
    /// 塞いで巻端ナビが全滅する。フラグの生存は「復帰オープンが in-flight の間だけ」
    /// が不変条件(openBookFlow 末尾の defer と各終端で確実に消す。cooViewer-s7j)
    func markCollectionReturnForAdjacentBook() {
        if epubCollectionContext != nil { collectionNavigation.returnPending = true }
    }

    /// 現在巻と版面キーが一致するときだけ、Washi リーダーの実測値を返す。
    func openBookCensusSeed(for metricsKey: String) -> EPUBOpenBookCensusSeed? {
        guard let epubView, acceptsEPUBCallback(from: epubView) else { return nil }
        return EPUBOpenBookCensusSeed.make(
            requestedMetricsKey: metricsKey,
            viewMetricsKey: epubView.pageCensusMetricsKey,
            counts: epubView.pageCensus,
            pagesPerScreen: epubView.plannedPagesPerScreen,
            entryIndex: epubCollectionContext?.entryIndex)
    }

    // MARK: - 合本の全体ページマップ(ページバー等の全体基準化)

    /// 現在の文脈で有効な全体ページマップ(合本が対象で、census 構築済み、
    /// かつ**エントリ列が構築時と同一**。ソート・シャッフル・削除で並びが
    /// 変わった古いマップで番号やジャンプ先を出さない)
    func activeCollectionPageMap() -> CollectionPageMap? {
        guard let map = collectionPageMaps.current else { return nil }
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
            collectionPageMaps.reset()
            return
        }
        let placeholders = entries.enumerated().compactMap { index, entry in
            entry.reflowEPUBURL.map { (index: index, url: $0) }
        }
        guard !placeholders.isEmpty else {
            collectionPageMaps.reset()
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
        let requestKey = CollectionPageMapState.Key(
            folderPath: folderURL.path, metricsKey: key)
        if let map = collectionPageMaps.current, map.folderPath == folderURL.path,
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
                || collectionPageMaps.attemptCount(for: requestKey, entries: entries)
                    >= CollectionPageMapState.maximumAttempts {
                collectionPageMaps.cancel()
                return
            }
        }
        guard let request = collectionPageMaps.begin(key: requestKey, entries: entries)
        else { return }
        // 開いている本の census はリーダー実測を流用(**同一メトリクスの
        // 実測に限る** — 旧寸法の値を新キーのマップへ焼き込まない)
        var seededCounts: [Int: [Int]] = [:]
        if let openSeed {
            seededCounts[openSeed.entryIndex] = openSeed.counts
        }
        // 直前の未完マップで計測済みの巻(epubURL != nil の segment)はそのまま流用し、
        // 欠けた巻だけ測り直す(atlas LRU 退避で再測が要るときの二度手間を省く)
        if let old = collectionPageMaps.current, old.folderPath == folderURL.path,
           old.metricsKey == key, old.entries == entries {
            for segment in old.segments {
                if segment.epubURL != nil, let itemCounts = segment.itemCounts,
                   seededCounts[segment.entryIndex] == nil {
                    seededCounts[segment.entryIndex] = itemCounts
                }
            }
        }
        request.task = Task { [weak self, weak request] in
            guard let request else { return }
            defer { self?.collectionPageMaps.abandon(request) }
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
                  self.collectionPageMaps.owns(request) else { return }
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
            let map = CollectionPageMap.make(
                folderPath: folderURL.path, metricsKey: key,
                entries: entries, counts: counts)
            guard self.collectionPageMaps.publish(map, for: request) else { return }
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
        guard fraction.isFinite else { return }
        let page = Int((min(max(fraction, 0), 1)
            * Double(max(1, map.total - 1))).rounded())
        switch map.target(forGlobalPage: page) {
        case .bookPage(let index):
            if isEPUBMode {
                collectionNavigation.returnPending = true
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

}
