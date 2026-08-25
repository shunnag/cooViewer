import AppKit
import Washi

/// コレクション(合本)内から開いた EPUB の文脈。
/// 巻端・次/前の本で合本の隣接エントリへ復帰し、キー/マウスの綴じ方向解決
/// (readsFromLeft)は本の宣言ではなく**コレクションの readMode** に従う
/// (表示は宣言どおり — 混在方向のコレクションで操作系が本ごとに
/// 反転しないようにする。設計書 §2.4 EPUB 対応)
struct EPUBCollectionContext {
    /// 合本(コレクションフォルダ)の URL(復帰先・兄弟走査の基準)
    let folderURL: URL
    /// 合本内での代理ページの位置(復帰は前後の隣接エントリへ)
    let entryIndex: Int
    /// 合本の総エントリ数(巻端判定用)
    let entryCount: Int
    /// コレクションの readMode 由来の操作系綴じ方向
    let readsFromLeft: Bool
    /// 合本のエントリ列とソース(EPUB 内からもコレクション全体の
    /// サムネイル一覧を出すために持ち回る。ソースは参照なので軽い)
    let entries: [PageEntry]
    let source: any BookSource
    /// 一覧の見開きペア判定用(合本の設定を引き継ぐ)
    let singleSetting: Int
    let coverSingle: Bool
    /// しおり付きページ(合本の実ページ index)
    let bookmarkedPages: Set<Int>
}

/// リフロー EPUB の表示モード(設計書 §2.4 EPUB 対応)。
/// 独立ウインドウではなく**同じリーダーウインドウの表示切替**として実装する:
/// readerView(画像)と epubView(Washi)を入替表示し、開閉・ページ送り・
/// 次/前の本・メニュー・履歴の操作感を画像本(PDF 等)と揃える。
/// キーバインドは resolveKey/resolveMouse を共有し、実行だけを EPUB 用の
/// 縮小ディスパッチャで行う(仕様書 §5.3/§5.4 の switchAction も有効)
extension ReaderWindowController: EPUBReaderViewDelegate {
    var isEPUBMode: Bool { epubPublication != nil }

    /// 兄弟走査・Finder 表示などのための「現在の本」のファイル URL
    /// (画像本と EPUB の両モード対応)
    var currentBookFileURL: URL? { epubBookURL ?? book?.source.url }

    // MARK: - 表示切替

    /// リフロー EPUB を同じウインドウで表示する(openBookFlow から)。
    /// atPage: 検証用の明示 spine 指定(0 始まり)。atLastPage: 末尾から開く
    /// (ループ設定 2 の「前の本を末尾から」§4.3.4)。いずれも復元より優先
    func presentReflowableEPUB(_ publication: EPUBPublication, url: URL,
                               atPage: Int? = nil, atLastPage: Bool = false,
                               atLocator: EPUBLocator? = nil,
                               collectionContext: EPUBCollectionContext? = nil) {
        unloadImageBookForEPUB()
        saveEPUBState()  // EPUB → EPUB の切替でも前の本の位置を残す
        epubSaveDebounce?.cancel()

        epubCollectionContext = collectionContext
        epubCollectionReturnPending = false
        epubPublication = publication
        epubBookURL = url
        epubFlattenedToc = Self.flattenToc(publication.navigation.toc)

        let view = ensureEPUBView()
        // 退出中に変わった設定(applySettings は EPUB モード中しか流さない)へ
        // 追い付かせる(余白・フォント・ノンブル等)
        syncEPUBViewSettings()
        readerViewForInput.isHidden = true
        view.isHidden = false
        let epubTitle = publication.metadata.mainTitle ?? url.lastPathComponent
        if let collectionContext {
            // 合本内の巻に入ったとき、題名を子 EPUB 単独の題名にすると『合本を
            // 抜けた』ように見え「今どこにいるか」を失う。合本名を残して現在巻を
            // 併記する(画像巻へ戻れば openBookFlow が合本名へ戻す。監査 UX 提案)
            window?.title =
                "\(collectionContext.folderURL.lastPathComponent) — \(epubTitle)"
        } else {
            window?.title = epubTitle
        }
        window?.representedURL = url

        let spineCount = publication.readingOrder.count
        let locator: EPUBLocator?
        if let atLocator {
            // 一覧からの位置指定ジャンプ等(復元より優先)
            locator = EPUBLocator(
                spineIndex: min(max(0, atLocator.spineIndex), spineCount - 1),
                progression: atLocator.progression)
        } else if atLastPage {
            locator = EPUBLocator(spineIndex: max(0, spineCount - 1), progression: 1)
        } else if let atPage {
            locator = EPUBLocator(spineIndex: min(max(0, atPage), spineCount - 1),
                                  progression: 0)
        } else {
            locator = restoredEPUBLocator(for: url, publication: publication)
        }
        view.load(publication: publication, at: locator)
        // 保存済みの census を注入する。版・spine 数・メトリクスが一致すれば
        // Washi 側が採用し、同一寸法での再オープンで再実測を省く(整合検証は
        // importCensus 側。不一致なら無視され通常どおり再実測する)
        if let saved = BookHistoryStore.shared.savedReflowCensus(forPath: url.path) {
            view.importCensus(EPUBCensusRecord(
                metricsKey: saved.metricsKey, counts: saved.counts,
                releaseIdentifier: saved.releaseIdentifier))
        }
        // コレクション経由では「本」はコレクション自体(開いた時点で記録済み)。
        // 子 EPUB で最近使った本を埋めない
        if collectionContext == nil {
            BookHistoryStore.shared.noteOpened(path: url.path)
        }
        installEPUBKeyMonitorIfNeeded()
        installEPUBGestureMonitorIfNeeded()
        // フォーカスも EPUB ビューへ(隠れた ReaderView に残さない)
        window?.makeFirstResponder(view)
        // ページバー(仕様書 §3.4)は EPUB でも設定どおり出す。進捗は
        // 本全体の進行率(復元位置があればそこから)。以後は didMoveTo が更新
        let initial = locator.map {
            (Double($0.spineIndex) + $0.progression)
                / Double(max(1, publication.readingOrder.count))
        } ?? 0
        updateEPUBPageBar(progress: initial,
                          readsFromLeft: collectionContext?.readsFromLeft
                              ?? (publication.readingDirection != .rtl))
    }

    /// 前回位置の復元。保存側のゲート(§7.3)に加えて、画像本と同じ
    /// GoToLastPageMode(0=確認/1=自動/2=無効。§7.3)を通す。
    /// リフローに固定ページ番号は無いため、確認ダイアログは全体進行率で示す
    private func restoredEPUBLocator(for url: URL,
                                     publication: EPUBPublication) -> EPUBLocator? {
        guard settings.goToLastPageMode < 2,
              let saved = BookHistoryStore.shared.savedReflowPosition(forPath: url.path)
        else { return nil }
        let locator = EPUBLocator(spineIndex: saved.spineIndex,
                                  progression: saved.progression,
                                  idref: saved.idref)
        if settings.goToLastPageMode == 1 { return locator }
        let percent = Int(((Double(saved.spineIndex) + saved.progression)
            / Double(max(1, publication.readingOrder.count)) * 100).rounded())
        let position = "\(percent)%"
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Resume from the last position (\(position))?")
        alert.addButton(withTitle: String(localized: "Go"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? locator : nil
    }

    /// SettingsStore から Washi 設定を組む(リーダー・一覧展開の画面計画で
    /// 共通の唯一の構築点。ページ番号表示 ShowNumber はノンブル/柱に読み替え)
    func currentEPUBReaderSettings() -> EPUBReaderSettings {
        var epubSettings = EPUBReaderSettings()
        epubSettings.handlesKeyboardNavigation = false  // キーはアプリのバインドで
        epubSettings.pageTurnStyle = epubPageTurnStyle
        epubSettings.fontScale = settings.epubFontScale
        epubSettings.pinchAdjustsFontScale = settings.epubPinchFontScale
        epubSettings.showsPageFurniture = settings.showNumber
        epubSettings.insets = Self.epubInsets(forMargins: settings.epubPageMargins)
        epubSettings.defaultFontFamily =
            settings.epubDefaultFont.isEmpty ? nil : settings.epubDefaultFont
        // 背景(配色テーマ): システムに従う / ライト / ダーク
        epubSettings.theme = EPUBReaderTheme(rawValue: settings.epubTheme) ?? .system
        // 読みやすさ優先(既定 ON): 本が色を指定していてもテーマ文字色を強制し、
        // ダーク背景で黒文字がハードコードされた本でも読めるようにする
        epubSettings.forcesReadableColors = settings.epubForceReadableColors
        // 水平スワイプ/ホイールめくりを画像本と同じトグル・向きにそろえる
        // (Washi は既定で内部的にめくるため、SwipeToTurnPage/FlipSwipeDirection
        // やコレクションの綴じ方向が効かず非対称だった。監査 #2)
        epubSettings.horizontalWheelTurnsPages = settings.swipeToTurnPage
        epubSettings.reversesHorizontalWheelTurn = epubHorizontalWheelReversed
        return epubSettings
    }

    /// Washi の水平ホイールめくりを画像本のスワイプめくりと同じ論理方向へ
    /// そろえるための反転フラグ。画像側 f=「次」⟺(実効綴じ方向 != 反転設定)、
    /// Washi 側 g=「次」⟺ 本が RTL。両者が食い違うとき反転する(監査 #2。
    /// 混在方向コレクションでは Washi は本の宣言方向でめくるため、コレクション
    /// の readMode との差もここで吸収される)
    private var epubHorizontalWheelReversed: Bool {
        let bookRTL = epubPublication?.readingDirection == .rtl
        // 実効綴じ方向(コレクション文脈はコレクション設定、単体は本の宣言)
        let effReadsFromLeft = epubCollectionContext?.readsFromLeft ?? !bookRTL
        let gIsNext = bookRTL
        let fIsNext = effReadsFromLeft != settings.flipSwipeDirection
        return gIsNext != fIsNext
    }

    /// 実際に(次に)開いたときのリーダー設定。columnMode(s キーの単/見開き
    /// 切替)はビューのセッション状態なので、既存ビューがあれば引き継ぐ
    func plannedEPUBSettings() -> EPUBReaderSettings {
        var planned = currentEPUBReaderSettings()
        if let epubView {
            planned.columnMode = epubView.settings.columnMode
        }
        return planned
    }

    /// SettingsStore → Washi 設定の同期(applySettings と再入場時に使う)
    func syncEPUBViewSettings() {
        guard let epubView else { return }
        epubView.settings = plannedEPUBSettings()
    }

    func dismissEPUBMode() {
        guard isEPUBMode else { return }
        saveEPUBState()
        epubSaveDebounce?.cancel()
        epubView?.stopMediaOverlay()  // 退出したら音声ナレーションも止める
        epubView?.cancelPageCensus()  // 退出後のオフスクリーン計測を止める
        epubCollectionReturnPending = false
        hideThumbnailOverlay()  // EPUB の一覧を画像本に持ち越さない
        for host in epubCurlHosts { host.removeFromSuperview() }
        epubCurlHosts.removeAll()
        epubPublication = nil
        epubBookURL = nil
        epubFlattenedToc = []
        epubPageLabelText = nil
        epubCollectionContext = nil
        epubView?.isHidden = true
        readerViewForInput.isHidden = false
        // EPUB 中にクリックすると WKWebView が first responder を握る。
        // 隠した後もそのままだとキーイベントが隠れた WebView へ流れ、
        // ReaderView.keyDown が呼ばれずキー操作が全滅する(特に
        // 「表示できる画像がありません」の空の本はキーだけが頼りなので致命的)。
        // モードを戻すときに必ずフォーカスも戻す
        window?.makeFirstResponder(readerViewForInput)
    }

    // MARK: - コレクション(合本)との往来

    /// 合本内のリフロー EPUB 代理ページに到達した(refreshDisplay から)。
    /// EPUB モードへ切り替える: 前進到達は先頭(または保存位置の復元。
    /// atFirst はループ再入場で復元をバイパス)、後退到達は末尾から。
    /// 開けない本(DRM 等)は静的な表紙ページに降格する
    func enterCollectionReflowEPUB(url: URL, entryIndex: Int, forward: Bool,
                                   atFirst: Bool = false,
                                   at explicitLocator: EPUBLocator? = nil) {
        guard let book else { return }
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
        let generation = openGeneration
        Task { [weak self] in
            let publication = await Task.detached(priority: .userInitiated) {
                try? EPUBPublication(url: url)
            }.value
            // 解析中に別の本が開かれた/代理ページを離れたら何もしない
            // (openBookFlow の世代規則と同じ。book 同一性だけでは、新しい
            // オープンの途中(book 差し替え前)をすり抜ける)。
            // 一覧からの明示ジャンプは着地ページを問わない(現在ページが
            // 代理ページとは限らないため)
            guard let self, self.openGeneration == generation,
                  self.book === book,
                  explicitLocator != nil || book.currentIndex == entryIndex
            else { return }
            guard let publication, !publication.isFixedLayout,
                  !publication.isDRMProtected else {
                // 開けない本(DRM 等)は以後「静的な表紙ページ」に降格して
                // 同じ場所を再表示する(隣へ素通りさせると、全滅フォルダ +
                // ループ設定で openBook が無限循環する)。初回降格のときだけ、
                // DRM なら単体で開いた EPUB と同じ説明を出す(合本内で無説明に
                // 表紙へ化けると『なぜこの巻だけ読めないか』が分からない。監査 #9)
                let inserted = self.epubFailedPlaceholders.insert(url).inserted
                if inserted, let publication, publication.isDRMProtected {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "This book is protected by DRM.")
                    alert.informativeText = publication.drmSchemeName ?? ""
                    alert.runModal()
                } else {
                    NSSound.beep()
                }
                self.openBook(at: context.folderURL, atPage: entryIndex)
                return
            }
            self.presentReflowableEPUB(
                publication, url: url,
                atPage: (explicitLocator == nil && atFirst) ? 0 : nil,
                atLastPage: explicitLocator == nil && !forward && !atFirst,
                atLocator: explicitLocator,
                collectionContext: context)
        }
    }

    /// 一覧からの横断ジャンプ: 合本文脈のまま別の(または同じ)EPUB の
    /// 指定位置を開く(EPUB モード内から。book は無いので文脈から組む)
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
        Task { [weak self] in
            let publication = await Task.detached(priority: .userInitiated) {
                try? EPUBPublication(url: url)
            }.value
            guard let self, self.isEPUBMode,
                  self.epubCollectionContext?.folderURL == context.folderURL
            else { return }
            guard let publication, !publication.isFixedLayout,
                  !publication.isDRMProtected else {
                NSSound.beep()
                return
            }
            self.presentReflowableEPUB(publication, url: url,
                                       atLocator: locator,
                                       collectionContext: newContext)
        }
    }

    /// 合本の指定エントリへ復帰する(EPUB の巻端・次/前の本から)。
    /// 範囲外は合本自体の巻端として画像本と同じループ規則に従う(§4.3.4)。
    /// 文脈は消さない(オープン完了までの間に巻端イベントが再発しても
    /// 単体モード意味論へ落とさない — 抑止は epubCollectionReturnPending)
    func openCollectionEntry(context: EPUBCollectionContext, at index: Int,
                             forward: Bool, atFirst: Bool = false) {
        guard (0..<context.entryCount).contains(index) else {
            if forward {
                switch settings.loopCheck {
                case 0:
                    // 巻末ループは画像本の goToFirst と同じく「先頭から」
                    // (保存位置の復元は通さない)
                    openCollectionEntry(context: context, at: 0,
                                        forward: true, atFirst: true)
                case 1, 2:
                    epubCollectionReturnPending = true
                    openAdjacentBook(forward: true)
                default: break
                }
            } else {
                switch settings.loopCheck {
                case 0: openCollectionEntry(
                    context: context, at: context.entryCount - 1, forward: false)
                case 1:
                    epubCollectionReturnPending = true
                    openAdjacentBook(forward: false)
                case 2:
                    epubCollectionReturnPending = true
                    openAdjacentBook(forward: false, openLast: true)
                default: break
                }
            }
            return
        }
        // 着地先が別の代理ページなら到達方向を引き継いで連続入場する
        epubCollectionArrivalForward = forward
        epubCollectionArrivalAtFirst = atFirst
        epubCollectionReturnPending = true
        openBook(at: context.folderURL, atPage: index)
    }

    /// キー/マウスの綴じ方向解決に使う実効 readsFromLeft。
    /// 単体の EPUB は本の宣言(!isRTL)、コレクション文脈では
    /// コレクションの readMode(表示は宣言のまま、操作系だけ合わせる)
    var epubInputReadsFromLeft: Bool {
        epubCollectionContext?.readsFromLeft ?? !(epubView?.isRTL ?? false)
    }

    /// アプリの「ページめくり効果」→ Washi の内蔵スタイル。
    /// カールは delegate(animatePageTurn)が本物の PageCurlOverlay を駆動する
    /// ため、内蔵側は失敗時フォールバックのスライドにしておく
    var epubPageTurnStyle: EPUBPageTurnStyle {
        switch settings.pageTurnAnimation {
        case .none: .none
        case .fade, .zoomFade: .fade
        case .slide, .curl: .slide
        }
    }

    private func ensureEPUBView() -> EPUBReaderView {
        if let epubView { return epubView }
        let view = EPUBReaderView()
        view.settings = currentEPUBReaderSettings()
        view.delegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        // 自動隠しインジケータのためのマウス移動監視(owner に直接イベントが
        // 届く。WKWebView 上でも tracking area は独立して機能する)
        view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
        if let contentView = window?.contentView {
            // readerView と同じ全面配置。ページ番号等のオーバーレイより下、
            // readerView より上(入替表示なので実質どちらでもよい)
            contentView.addSubview(view, positioned: .above,
                                   relativeTo: readerViewForInput)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }
        epubView = view
        return view
    }

    // MARK: - 状態保存

    /// 現在の EPUB の読書位置を保存する(切替時・クローズ時・終了時)
    func saveEPUBState() {
        guard let epubBookURL, let epubView, isEPUBMode else { return }
        let locator = epubView.currentLocator
        BookHistoryStore.shared.noteClosedReflow(
            path: epubBookURL.path,
            spineIndex: locator.spineIndex,
            progression: locator.progression,
            // idref も保存し、配信本の改版(spine 並べ替え)を跨いで
            // 正しい章へ復元できるようにする(Washi の resolve が使う)
            idref: locator.idref,
            // 合本の子は recents に入れない設計のため、復元ゲートは
            // 書込時に通しておく(単体で開いた EPUB との復元非対称の防止)
            forceRememberBeyondRecents: epubCollectionContext != nil)
        // census が実測済みならクローズ時にも相乗り保存する(セッション中の
        // readerViewDidUpdatePageCensus が状態作成より前に走った場合の取りこぼし
        // を拾う。状態が無い本には noteReflowCensus 側が保存しない)
        if let record = epubView.exportCensus() {
            BookHistoryStore.shared.noteReflowCensus(
                path: epubBookURL.path, metricsKey: record.metricsKey,
                counts: record.counts, releaseIdentifier: record.releaseIdentifier)
        }
    }

    // MARK: - ナビゲーション(メニュー・キー・マウスから)

    func epubGoForward() { epubView?.goForward() }
    func epubGoBackward() { epubView?.goBackward() }
    func epubGoToFirst() { epubView?.goToBookStart() }
    func epubGoToLast() { epubView?.goToBookEnd() }

    /// ページバーのジャンプ(本全体の進行率 → 位置)。
    /// census(全文ページ数の実測)があれば画像本の jumpToPercent と同じ
    /// 「ページ番号」基準、未完了なら spine 単位の近似
    func epubJump(toBookFraction fraction: Double) {
        guard let epubPublication, let epubView else { return }
        // コレクション文脈では % もバーも「合本全体」基準(§3.4 の読み替え。
        // 画像ページへの復帰・別 EPUB への横断もここから起きる)。
        // リーダー census が未完の間は表示が本単位なので、ジャンプも
        // 本単位に合わせる(表示とジャンプの基準系を常に一致させる)
        if epubCollectionContext != nil,
           epubView.currentGlobalPageRange != nil,
           let map = activeCollectionPageMap() {
            jumpToCollectionFraction(fraction, map: map)
            return
        }
        let clamped = min(max(fraction, 0), 1)
        if let total = epubView.censusTotalPages, total > 0,
           let locator = epubView.censusLocator(
               forGlobalPage: Int((clamped * Double(total - 1)).rounded())) {
            epubView.go(to: locator)
            return
        }
        let count = epubPublication.readingOrder.count
        let scaled = min(clamped, 0.9999) * Double(count)
        let spine = min(count - 1, Int(scaled))
        epubView.go(to: EPUBLocator(spineIndex: spine,
                                    progression: scaled - Double(spine)))
    }

    /// ページバーとページ番号表示の更新。census 完了後はページ単位
    /// (「N/M (章題)」+ 既読率 = 表示ページ末尾/全ページ — 画像本の
    /// lastShown/pageCount と同じ意味論)、未完了は spine 単位の近似で
    /// バーのみ更新し番号は隠す(古いメトリクスの番号を出さない)
    func updateEPUBIndicators() {
        guard isEPUBMode, let epubView, let epubPublication else { return }
        let readsFromLeft = epubInputReadsFromLeft
        // コレクション文脈では「合本全体からの位置」で表す(書庫内 zip・
        // サブフォルダと同じ意味論。全体マップ+リーダー census が揃うまでは
        // 下の本単位表示に落ちる)
        if let context = epubCollectionContext {
            ensureCollectionPageMap()
            if let map = activeCollectionPageMap(),
               let range = epubView.currentGlobalPageRange {
                let start = map.globalStart(forEntry: context.entryIndex)
                let segmentPages = map.pageCount(forEntry: context.entryIndex)
                // map とリーダー census は同一メトリクス由来だが、境界は
                // 局所側をセグメント内にクランプして守る
                let first = start + min(range.lowerBound, segmentPages)
                let last = start + min(range.upperBound, segmentPages)
                updateEPUBPageBar(
                    progress: Double(last) / Double(map.total),
                    readsFromLeft: readsFromLeft)
                let numbers = last > first ? "\(first)-\(last)" : "\(first)"
                let title = epubPublication.chapterTitle(
                    forSpineIndex: epubView.currentLocator.spineIndex)
                epubPageLabelText = title.map { " \(numbers)/\(map.total) (\($0)) " }
                    ?? " \(numbers)/\(map.total) "
                pageLabel.stringValue = epubPageLabelText ?? ""
                updateIndicatorVisibility()
                return
            }
        }
        if let total = epubView.censusTotalPages, total > 0,
           let range = epubView.currentGlobalPageRange {
            updateEPUBPageBar(
                progress: Double(range.upperBound) / Double(total),
                readsFromLeft: readsFromLeft)
            let numbers = range.count > 1
                ? "\(range.lowerBound)-\(range.upperBound)"
                : "\(range.lowerBound)"
            let title = epubPublication.chapterTitle(
                forSpineIndex: epubView.currentLocator.spineIndex)
            // 画像本の updatePageIndicators と同じく前後に空白を入れて
            // ラベルの背景・枠線との余白を確保する
            epubPageLabelText = title.map { " \(numbers)/\(total) (\($0)) " }
                ?? " \(numbers)/\(total) "
        } else {
            let locator = epubView.currentLocator
            let inItem = Double(epubView.pageInItem + 1)
                / Double(max(1, epubView.pageCountInItem))
            let progress = (Double(locator.spineIndex) + inItem)
                / Double(max(1, epubPublication.readingOrder.count))
            updateEPUBPageBar(progress: progress, readsFromLeft: readsFromLeft)
            epubPageLabelText = nil
        }
        pageLabel.stringValue = epubPageLabelText ?? ""
        updateIndicatorVisibility()
    }

    /// EPUB ビュー上のマウス移動(tracking area の owner として受ける):
    /// 自動隠しインジケータの再表示とフルスクリーンのカーソル自動隠し
    override func mouseMoved(with event: NSEvent) {
        noteMouseMovedForIndicators()
        noteMouseMoved()
    }

    private func epubGoToAdjacentSpineItem(forward: Bool) {
        guard let epubPublication, let epubView else { return }
        let next = epubView.currentLocator.spineIndex + (forward ? 1 : -1)
        guard epubPublication.readingOrder.indices.contains(next) else {
            NSSound.beep()
            return
        }
        epubView.go(to: EPUBLocator(spineIndex: next))
    }

    /// 合本内の EPUB 巻から次/前の構成巻(サブフォルダ=containerPath 境界)へ。
    /// 画像巻の goToSubFolder(Book.*SubFolderIndex)と同じ巡回規則を合本の
    /// entries に対して使い、対称に動けるようにする。単体 EPUB には構成巻の
    /// 概念が無いので false を返して呼び出し側でビープ(監査 #7)
    private func epubGoToAdjacentSubFolder(forward: Bool) -> Bool {
        guard let context = epubCollectionContext else { return false }
        let target = forward
            ? Book.nextSubFolderIndex(in: context.entries, from: context.entryIndex)
            : Book.previousSubFolderIndex(in: context.entries, from: context.entryIndex)
        guard let target else { return false }
        // 次/前いずれも構成巻グループの先頭に着地する(画像巻と同じ)。対象が
        // 代理 EPUB でもその巻の先頭ページから開く(atFirst)
        openCollectionEntry(context: context, at: target, forward: true, atFirst: true)
        return true
    }

    // MARK: - キー入力(WKWebView がキーを食うためローカルモニタで捕捉)

    func installEPUBKeyMonitorIfNeeded() {
        guard epubKeyMonitor == nil else { return }
        epubKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.isEPUBMode, event.window === self.window,
                  self.window?.isKeyWindow == true else { return event }
            return self.handleEPUBKeyEvent(event) ? nil : event
        }
    }

    /// ハードウェアのスワイプ(3 本指の「ページ間スワイプ」)・回転ジェスチャは
    /// swipe(with:)/rotate(with:) を実装する ReaderView が EPUB モードでは
    /// 隠れているため届かない。キーと同じくローカルモニタで拾って画像本と同じ
    /// スワイプ仮想ボタンへ写像する(監査 #10。既定 swipeDown=次の本/
    /// swipeUp=前の本/水平=前後ページ、割当はカスタムも尊重)
    func installEPUBGestureMonitorIfNeeded() {
        guard epubGestureMonitor == nil else { return }
        epubGestureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.swipe, .rotate]) { [weak self] event in
            guard let self, self.isEPUBMode, event.window === self.window,
                  self.window?.isKeyWindow == true else { return event }
            return self.handleEPUBGestureEvent(event) ? nil : event
        }
    }

    /// swipe/rotate NSEvent を仮想ボタンへ写像して EPUB ジェスチャ処理へ。
    /// 写像は ReaderView.swipe(with:)/rotate(with:) と同一
    private func handleEPUBGestureEvent(_ event: NSEvent) -> Bool {
        let modifiers = LegacyModifier.encode(flags: event.modifierFlags)
        let leftHalf = epubLeftHalf(locationInWindow: event.locationInWindow)
        switch event.type {
        case .swipe:
            let button: Int
            if abs(event.deltaX) >= abs(event.deltaY) {
                button = event.deltaX > 0
                    ? VirtualButton.swipeLeft : VirtualButton.swipeRight
            } else {
                button = event.deltaY > 0
                    ? VirtualButton.swipeUp : VirtualButton.swipeDown
            }
            return handleEPUBGesture(virtualButton: button, modifiers: modifiers,
                                     leftHalf: leftHalf)
        case .rotate:
            if event.phase == .began { epubRotationSum = 0 }
            epubRotationSum += CGFloat(event.rotation)
            guard event.phase == .ended else { return true }  // 途中は消費のみ
            defer { epubRotationSum = 0 }
            guard abs(epubRotationSum) > 5 else { return false }
            let button = epubRotationSum > 0
                ? VirtualButton.rotateLeft : VirtualButton.rotateRight
            return handleEPUBGesture(virtualButton: button, modifiers: modifiers,
                                     leftHalf: leftHalf)
        default:
            return false
        }
    }

    /// スワイプ/回転の仮想ボタンを EPUB 用にディスパッチする。水平スワイプの
    /// ページ送りだけ SwipeToTurnPage/FlipSwipeDirection を適用する点も画像本の
    /// handleGesture と同じ(綴じ方向はコレクション文脈では合本の readMode)
    @discardableResult
    private func handleEPUBGesture(virtualButton: Int, modifiers: Int,
                                  leftHalf: Bool) -> Bool {
        var button = virtualButton
        if button == VirtualButton.swipeLeft || button == VirtualButton.swipeRight {
            let action = bindings.resolveMouse(
                button: button, modifiers: modifiers,
                fitMode: 0, readsFromLeft: epubInputReadsFromLeft)?.action
            if action == .nextPage || action == .previousPage {
                guard settings.swipeToTurnPage else { return true }
                if settings.flipSwipeDirection {
                    button = button == VirtualButton.swipeLeft
                        ? VirtualButton.swipeRight : VirtualButton.swipeLeft
                }
            }
        }
        guard let binding = bindings.resolveMouse(
            button: button, modifiers: modifiers,
            fitMode: 0, readsFromLeft: epubInputReadsFromLeft),
            let action = binding.action else { return false }
        return performEPUB(action, value: binding.value, leftHalf: leftHalf)
    }

    /// ジェスチャ位置が EPUB ビューの左半分か(positional 系アクション用)
    private func epubLeftHalf(locationInWindow: CGPoint) -> Bool {
        guard let epubView else { return true }
        return epubView.convert(locationInWindow, from: nil).x < epubView.bounds.midX
    }

    private func handleEPUBKeyEvent(_ event: NSEvent) -> Bool {
        // ⌘付きはメニューのキーイクイバレントに任せる(+Input.swift と同じ)
        guard !event.modifierFlags.contains(.command) else { return false }
        guard let character = event.charactersIgnoringModifiers?.first else {
            return false
        }
        // サムネイルオーバーレイ表示中の Esc は一覧を閉じる(画像本の
        // handleKeyEvent と同じ特例。Esc は未割当で resolveKey には載らないため
        // ここで先取りしないと WKWebView へ抜けてビープする。監査 #3)
        if isThumbnailOverlayVisible, character == "\u{1B}" {
            hideThumbnailOverlay()
            return true
        }
        let modifiers = LegacyModifier.encode(keyEvent: event)
        // EPUB にフィットモードの概念はない。探索順は [keyMode2, keyNormal]
        // (fitMode 1 と同じ): PageUp/PageDown/Home/End/↑↓ の既定バインドは
        // Mode2 側にしか無く、keyNormal だけでは一切届かない。スクロール
        // 閲覧系(Mode2)の割当がリフローの操作感に最も近い。
        // readsFromLeft は実効綴じ方向(コレクション文脈ではコレクション設定)
        guard let binding = bindings.resolveKey(
            character: character, modifiers: modifiers,
            fitMode: 1, readsFromLeft: epubInputReadsFromLeft),
            let action = binding.action else { return false }
        if performEPUB(action, value: binding.value, leftHalf: nil) { return true }
        // 割当はあるが EPUB では非対応: フォーカス位置(WKWebView か
        // コンテナか)で挙動が変わらないよう、ここでビープして消費する
        NSSound.beep()
        return true
    }

    /// EPUB で意味を持つアクションの縮小ディスパッチャ。
    /// value はバインドの付随値(goToPercent の % 等)。
    /// 対応しないアクションは false(キーはビープ、クリックは無視)
    @discardableResult
    func performEPUB(_ action: ReaderAction, value: Double? = nil,
                     leftHalf: Bool?) -> Bool {
        // サムネイルオーバーレイ表示中はページ送りを一覧の画面送りに転用する
        // (画像本の perform() と同じ §4.8 の規則)
        if isThumbnailOverlayVisible {
            switch action {
            case .nextPage, .pageDownOrNextPage, .halfNextPage:
                thumbnailOverlayTurnPage(forward: true)
                return true
            case .previousPage, .pageUpOrPreviousPage, .halfPreviousPage:
                thumbnailOverlayTurnPage(forward: false)
                return true
            case .positionalNextPrevPage, .positionalHalfNextPrev:
                guard let leftHalf else { return false }
                thumbnailOverlayTurnPage(forward: epubIsNextSide(leftHalf))
                return true
            case .showThumbnail:
                hideThumbnailOverlay()
                return true
            default:
                break
            }
        }
        switch action {
        case .showThumbnail:
            epubShowThumbnail()
        case .nextPage, .halfNextPage, .pageDownOrNextPage, .pageDown:
            epubGoForward()
        case .previousPage, .halfPreviousPage, .pageUpOrPreviousPage, .pageUp:
            epubGoBackward()
        case .goToFirstPage:
            epubGoToFirst()
        case .goToLastPage:
            epubGoToLast()
        case .skip:
            // スキップ=次のセクション。リフローに安定した「ページ枚数」が
            // 無いため、バインドの枚数 value は意図的に読まない
            epubGoToAdjacentSpineItem(forward: true)
        case .backSkip:
            epubGoToAdjacentSpineItem(forward: false)
        case .scrollToTop:
            // Mode2 の Home/End。スクロールの概念が無いので巻頭/巻末へ
            epubGoToFirst()
        case .scrollToEnd:
            epubGoToLast()
        case .scrollUp:
            // Mode2 の ↑/↓。Washi 内蔵キー操作(↑=前 ↓=次)と同じ読み替え
            epubGoBackward()
        case .scrollDown:
            epubGoForward()
        case .goToPercent:
            // 数字キー 0-9 の既定割当(value = 0〜90%)。画像本の
            // jumpToPercent と同じく本全体の進行率へ(ページバーと同じ換算)
            epubJump(toBookFraction: (value ?? 0) / 100.0)
        case .nextBook:
            openAdjacentBook(forward: true)
        case .previousBook:
            openAdjacentBook(forward: false)
        case .nextSubFolder:
            // 合本内の構成巻移動。画像巻の goToSubFolder と対称(監査 #7)
            return epubGoToAdjacentSubFolder(forward: true)
        case .previousSubFolder:
            return epubGoToAdjacentSubFolder(forward: false)
        case .positionalNextPrevSubFolder:
            guard let leftHalf else { return false }
            return epubGoToAdjacentSubFolder(forward: epubIsNextSide(leftHalf))
        case .positionalNextPrevPage, .positionalHalfNextPrev,
             .positionalPageUpDownTurn:
            // クリック位置の側へめくる(実効綴じ方向 — 単体では本の宣言と
            // 同値の物理方向、コレクション文脈ではコレクションの readMode)
            guard let leftHalf else { return false }
            epubIsNextSide(leftHalf) ? epubGoForward() : epubGoBackward()
        case .positionalLastTop:
            // クリック側→読書方向の変換は画像本と同じ(仕様書 §5.6:
            // 右綴じは左=次側、左綴じは鏡像)
            guard let leftHalf else { return false }
            epubIsNextSide(leftHalf) ? epubGoToLast() : epubGoToFirst()
        case .positionalSkipBack:
            guard let leftHalf else { return false }
            epubGoToAdjacentSpineItem(forward: epubIsNextSide(leftHalf))
        case .positionalNextPrevBook:
            guard let leftHalf else { return false }
            openAdjacentBook(forward: epubIsNextSide(leftHalf))
        case .toggleShowPageBar:
            // 画像本と同じトグル。applySettings 経由の
            // updateIndicatorVisibility が EPUB のページバーにも効く
            settings.showPageBar.toggle()
        case .toggleShowNumber:
            // 画像本のページ番号に相当するのは Washi のノンブル/柱。
            // applySettings が showsPageFurniture へ橋渡しする
            settings.showNumber.toggle()
        case .switchSingleSpread:
            // 単ページ⇔見開き。EPUB では columnMode(auto/single/double)が
            // 担うため、いま見えている画面数を基準に固定値へトグルする
            // (進行率は Washi の settings didSet が保って再ページ割り)
            guard let epubView else { return false }
            var epubSettings = epubView.settings
            epubSettings.columnMode = epubView.pagesPerScreen >= 2
                ? .single : .double
            epubView.settings = epubSettings
        case .openLastPage:
            openTheLastBook()
        case .showInFinderRight, .showInFinderLeft, .positionalShowInFinder:
            // EPUB にページ単位のファイルは無いので本体を表示
            // (メニューの showInFinderMenu と同じ。書庫/PDF の §4.13 と同型)
            guard let epubBookURL else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([epubBookURL])
        case .enlargeViewMode:
            // EPUB では「表示の拡大」=フォント倍率(ピンチと同じ)
            epubView?.adjustFontScale(by: 0.1)
        case .reduceViewMode:
            epubView?.adjustFontScale(by: -0.1)
        case .closeWindow:
            window?.performClose(nil)
        case .toggleFullscreen:
            window?.toggleFullScreen(nil)
        case .minimizeWindow:
            window?.performMiniaturize(nil)
        default:
            return false
        }
        return true
    }

    /// クリック側が「次」方向か(+Input.swift の isNextSide と同じ式)。
    /// 実効綴じ方向を使うため、コレクション文脈では表示(本の宣言)ではなく
    /// コレクションの readMode で判定される
    private func epubIsNextSide(_ leftHalf: Bool) -> Bool {
        leftHalf == !epubInputReadsFromLeft
    }

    // MARK: - 章メニュー(移動 > 章へ移動)

    @objc func goToEPUBChapterItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              epubFlattenedToc.indices.contains(index) else { return }
        epubView?.go(to: epubFlattenedToc[index].item)
    }

    static func flattenToc(_ items: [EPUBNavItem], indent: Int = 0)
        -> [(title: String, indent: Int, item: EPUBNavItem)] {
        var result: [(String, Int, EPUBNavItem)] = []
        for item in items {
            if item.href != nil, !item.title.isEmpty {
                result.append((item.title, indent, item))
            }
            result.append(contentsOf: flattenToc(item.children, indent: indent + 1))
        }
        return result
    }

    // MARK: - 検証用

    /// スナップショット CLI(--snapshot)から使う合成画像
    /// (ページバー等の contentView オーバーレイも合成する)
    func epubDebugSnapshot() async -> NSImage? {
        guard isEPUBMode, let epubView,
              let base = try? await epubView.snapshot() else { return nil }
        var overlays = debugIndicatorOverlays()
        // サムネイルオーバーレイ表示中はそれも合成(--show-thumbnails 検証用)
        if let host = thumbnailHostingView, !host.isHidden,
           host.bounds.width > 0,
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(rep)
            overlays.append((image: image, frame: host.frame))
        }
        guard !overlays.isEmpty else { return base }
        let size = epubView.bounds.size
        return NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: size))
            for overlay in overlays {
                overlay.image.draw(in: overlay.frame)
            }
            return true
        }
    }

    // MARK: - EPUBReaderViewDelegate

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        updateEPUBIndicators()
        // 位置は 2 秒デバウンスで保存(ページ送りのたびの書き込みを避ける)
        epubSaveDebounce?.cancel()
        epubSaveDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveEPUBState()
        }
    }

    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {
        // 復帰オープン中の重複イベント(巻端でのキーリピート等)は無視する
        // (二重復帰や、文脈なし分岐への誤爆=単体モード意味論での兄弟
        // オープン・保存位置の巻末上書きを防ぐ)
        guard !epubCollectionReturnPending else { return }
        // コレクション(合本)内の EPUB は、巻端で合本の隣接エントリへ
        // シームレスに復帰する(合本自体の巻端は openCollectionEntry が
        // ループ規則 §4.3.4 で処理)
        if let context = epubCollectionContext {
            openCollectionEntry(context: context,
                                at: context.entryIndex + (forward ? 1 : -1),
                                forward: forward)
            return
        }
        // 巻末/巻頭超えは画像本と同じループ設定に従う(仕様書 §4.3.4)
        if forward {
            switch settings.loopCheck {
            case 0: view.goToBookStart()
            case 1, 2: openAdjacentBook(forward: true)
            default: break
            }
        } else {
            switch settings.loopCheck {
            case 0: view.goToBookEnd()
            case 1: openAdjacentBook(forward: false)
            case 2: openAdjacentBook(forward: false, openLast: true)
            default: break
            }
        }
    }

    func readerView(_ view: EPUBReaderView, didClick event: EPUBClickEvent) -> Bool {
        // マウス割当を画像本と同じ解決順で引く(仕様書 §5.3)。
        // 左・中・サイドボタン+修飾キー(Shift/Option/Control)に対応
        // (右クリックは Washi が WebKit のメニューに委ねるため届かない)。
        // 未割当なら false → Washi の既定(修飾なし左の左右端タップめくり)
        var modifiers = 0
        if event.shift { modifiers += LegacyModifier.shift }
        if event.option { modifiers += LegacyModifier.option }
        if event.control { modifiers += LegacyModifier.control }
        guard let binding = bindings.resolveMouse(
            button: event.button, modifiers: modifiers,
            fitMode: 0, readsFromLeft: epubInputReadsFromLeft),
            let action = binding.action else { return false }
        performEPUB(action, value: binding.value, leftHalf: event.x < 0.5)
        return true
    }

    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool {
        // 画像本と同じ「ドロップで開く」(ReaderView の D&D と同等)
        openBook(at: url)
        return true
    }

    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        // 画像本と同じエラー黙殺方針(仕様書 §4.17)
        NSSound.beep()
    }

    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {
        // 全文ページ数の実測が完了/無効化された(フォントサイズ・寸法の
        // 変更に追従)。ページ番号とバーをページ単位へ切替え/差し戻す
        updateEPUBIndicators()
        // 実測が完了したら永続化する。次回同一メトリクスで開くとき注入して
        // オフスクリーン再実測を省き、N/M・ページバーを即出す
        if let url = epubBookURL, let record = view.exportCensus() {
            BookHistoryStore.shared.noteReflowCensus(
                path: url.path, metricsKey: record.metricsKey,
                counts: record.counts, releaseIdentifier: record.releaseIdentifier)
        }
    }

    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {
        // ローカルモニタが扱わなかったキーの WKWebView からの転送=未割当キー。
        // 画像本はレスポンダチェーン経由でビープするので、フォーカスが
        // WKWebView にあっても同じフィードバックにする。修飾キー単独の
        // keydown と、WebKit 自身が処理しうる ⌘ 系(コピー等)は除外
        guard !event.command else { return }
        let bareModifiers: Set<String> = [
            "Shift", "Control", "Alt", "Meta", "CapsLock", "NumLock",
            "Fn", "FnLock", "Hyper", "Super", "Symbol", "Dead", "Process",
        ]
        if !bareModifiers.contains(event.key) { NSSound.beep() }
    }

    /// ピンチ/キーで変わったフォント倍率を永続化(全 EPUB 共通のグローバル設定。
    /// defaults 変更 → applySettings で同値が書き戻るが equality ガードで無害)
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double) {
        settings.epubFontScale = scale
    }

    /// ページめくり効果が「ページカール」のとき、画像本と同じ
    /// PageCurlOverlay(帯×ストリップの 3D カール+幾何追従の影)を
    /// EPUB のページ領域で駆動する。Washi は旧ページのカバーを被せた状態で
    /// このメソッドを呼ぶので、オーバーレイを同期的に載せて true を返せば
    /// シームなく演出へ引き継がれる
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool {
        guard settings.pageTurnAnimation == .curl,
              let oldContent = oldPage.cgImage(forProposedRect: nil, context: nil,
                                               hints: nil),
              let newContent = newPage.cgImage(forProposedRect: nil, context: nil,
                                               hints: nil) else { return false }
        // 進行中のカールは畳む(連打時に残骸が重ならないように)
        for host in epubCurlHosts { host.removeFromSuperview() }
        epubCurlHosts.removeAll()

        // PageCurlOverlay は flipped 座標系(ReaderView)前提のため、
        // flipped なホストビューをページ領域に重ねてその layer で駆動する
        let host = EPUBCurlHostView(frame: pageRect)
        host.wantsLayer = true
        view.addSubview(host)
        epubCurlHosts.append(host)

        let configuration = PageCurlOverlay.Configuration(
            bounds: CGRect(origin: .zero, size: pageRect.size),
            leafOnLeft: PageTurnAnimation.entersFromLeft(
                forward: forward, readsFromLeft: !view.isRTL),
            oldContent: oldContent,
            newContent: newContent)
        guard let overlay = PageCurlOverlay.makeAnimated(configuration) else {
            host.removeFromSuperview()
            epubCurlHosts.removeAll { $0 === host }
            return false
        }
        host.layer?.addSublayer(overlay)
        Task { [weak self, weak host] in
            try? await Task.sleep(for: .seconds(configuration.duration + 0.05))
            guard let host else { return }
            host.removeFromSuperview()
            self?.epubCurlHosts.removeAll { $0 === host }
        }
        return true
    }
}

/// EPUB のカール演出ホスト(PageCurlOverlay の幾何は flipped 前提)
final class EPUBCurlHostView: NSView {
    override var isFlipped: Bool { true }
}
