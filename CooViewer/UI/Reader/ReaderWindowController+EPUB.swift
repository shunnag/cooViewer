import AppKit
import SwiftUI
import Washi

/// バックグラウンド検索から MainActor へ渡す値だけを束ねる。
private struct EPUBSearchComputation: Sendable {
    let hits: [SearchHit]
    let isTruncated: Bool
}

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
                               collectionContext: EPUBCollectionContext? = nil,
                               epoch: Int) {
        // 入口: この提示が最後に要求されたものでなければ旧本の teardown を始めない
        // (合本内 EPUB↔EPUB の横断連打で last-request-wins を保証。openGeneration は
        // 合本内移動で動かないため専用の epubPresentEpoch で照合する)
        guard epubPresentEpoch == epoch else { return }
        clearEPUBSearchHighlight()
        // cooViewer-1p7: EPUB 間の切替は dismissEPUBMode を通らないため、旧本の
        // 検索結果・パネル・実行中 task を publication の差替え前に破棄する。
        if epubPublication != nil {
            teardownEPUBSearch()
        }
        unloadImageBookForEPUB()
        saveEPUBState()  // EPUB → EPUB の切替でも前の本の位置を残す
        epubSaveDebounce?.cancel()

        epubCollectionContext = collectionContext
        epubCollectionReturnPending = false
        epubPublication = publication
        epubContentLoaded = false
        epubBookURL = url
        // 永続層は Washi 非依存のタプルを返すため、復元位置と同じく境界で
        // EPUBLocator を直接構築する(matchingLocator 経路は導入しない)
        epubBookmarks = BookHistoryStore.shared.savedReflowBookmarks(forPath: url.path)
            .map { bookmark in
                (bookmark.name, EPUBLocator(
                    spineIndex: bookmark.spineIndex,
                    progression: bookmark.progression,
                    idref: bookmark.idref))
            }
        epubFlattenedToc = Self.flattenToc(publication.navigation.toc)

        let view = ensureEPUBView()
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
        // モーダル後の再照合: restoredEPUBLocator の確認ダイアログ(runModal)が
        // run loop を回す間に別 EPUB が提示され得る。ここで最新要求か確かめてから
        // 実際の読み込みへ進む
        guard epubPresentEpoch == epoch else { return }
        // 設定同期と columnMode 復元は modal(restoredEPUBLocator)より後・
        // load 直前に行う。modal 中に旧本(切替元)のビューへ設定を書くと再ページ
        // 割りが走り、その pageChanged が既に切替先 URL になった epubBookURL で
        // 保存して位置が混線するため(Codex レビュー指摘)。まず退出中に変わった
        // 設定(余白・フォント・ノンブル等)へ追い付かせ、続けて単/見開き固定
        // (s キー = columnMode)を本ごとの保存から復元する。census の metricsKey は
        // columnMode(由来の spread)を含むため load / importCensus より前に反映
        // する(順序が崩れると census 不一致で再実測)。保存が無ければ
        // plannedEPUBSettings のセッション引き継ぎ値を残す(cooViewer-0dh)
        syncEPUBViewSettings()
        if let saved = BookHistoryStore.shared.savedReflowColumnMode(forPath: url.path),
           let mode = EPUBColumnMode(rawValue: saved) {
            var restored = view.settings
            restored.columnMode = mode
            view.settings = restored
        }
        // cooViewer-t4e: 再構築される webView の旧スナップショットを保持した
        // ルーペを、次の publication の load より先に必ず無効化する。
        disableEPUBLoupe()
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
        installEPUBScrollMonitorIfNeeded()
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

    /// EPUB のノンブル(下部中央の素の番号)を出すか。下配置(2/3)ではホストの
    /// N/M ラベルと帯が重なるため抑止する(純関数=決定論テスト用)
    nonisolated static func epubShowsFolio(showNumber: Bool, pageNumPosition: Int) -> Bool {
        showNumber && pageNumPosition < 2
    }

    /// SettingsStore から Washi 設定を組む(リーダー・一覧展開の画面計画で
    /// 共通の唯一の構築点。ページ番号表示 ShowNumber は下部中央のノンブルに
    /// 読み替え、下配置ではラベルとの重なりを避けて抑止する=epubShowsFolio)
    func currentEPUBReaderSettings() -> EPUBReaderSettings {
        var epubSettings = EPUBReaderSettings()
        epubSettings.handlesKeyboardNavigation = false  // キーはアプリのバインドで
        epubSettings.pageTurnStyle = epubPageTurnStyle
        epubSettings.fontScale = settings.epubFontScale
        epubSettings.pinchAdjustsFontScale = settings.epubPinchFontScale
        // 下配置(PageNumPosition 2/3)ではホストの N/M(章題)ラベル(不透明帯)が
        // Washi の下部中央ノンブルを覆うため、下配置時はノンブルを抑止しラベル一本に
        // する(上配置 0/1 は上隅ラベル + 下中央ノンブルで両立=非衝突)。設計書 §2.4
        epubSettings.showsPageFurniture =
            Self.epubShowsFolio(showNumber: settings.showNumber,
                                pageNumPosition: settings.pageNumPosition)
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

    /// EPUB ルーペを現在のマウス位置で切り替える。検証時だけ初期位置を固定できる
    func toggleEPUBLoupe(at initialPoint: CGPoint? = nil) {
        guard isEPUBMode, let epubView else { return }
        if epubLoupeHost != nil {
            disableEPUBLoupe()
            return
        }

        let host = EPUBLoupeHostView(frame: epubView.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = CGColor(gray: 0, alpha: 0)
        epubView.addSubview(host)
        epubLoupeHost = host

        let loupe = LoupeController()
        loupe.size = settings.loupeSize
        loupe.rate = settings.loupeRate
        epubLoupe = loupe
        let point = initialPoint ?? window.map {
            host.convert($0.mouseLocationOutsideOfEventStream, from: nil)
        } ?? CGPoint(x: host.bounds.midX, y: host.bounds.midY)

        Task { [weak self, weak epubView, weak host, weak loupe] in
            guard let self, let epubView, let host, let loupe,
                  self.isEPUBMode, self.epubView === epubView,
                  self.epubLoupeHost === host, self.epubLoupe === loupe,
                  let hostLayer = host.layer else { return }
            guard let content = await self.makeEPUBLoupeContent(for: epubView)
            else {
                if self.epubLoupeHost === host, self.epubLoupe === loupe {
                    self.disableEPUBLoupe()
                }
                return
            }
            guard self.isEPUBMode, self.epubView === epubView,
                  self.epubLoupeHost === host, self.epubLoupe === loupe else { return }
            loupe.enable(in: hostLayer, at: point, content: content)
        }
    }

    /// EPUB ルーペを無効化し、WebKit 上の透明ホストも破棄する
    func disableEPUBLoupe() {
        epubLoupe?.disable()
        epubLoupe = nil
        epubLoupeHost?.removeFromSuperview()
        epubLoupeHost = nil
    }

    /// ルーペ有効中だけ現在の WebKit 描画を backing scale で取り直す
    func refreshEPUBLoupeSnapshot() {
        guard isEPUBMode, let epubView, let host = epubLoupeHost,
              let loupe = epubLoupe, loupe.isEnabled else { return }
        Task { [weak self, weak epubView, weak host, weak loupe] in
            guard let self, let epubView, let host, let loupe,
                  let content = await self.makeEPUBLoupeContent(for: epubView),
                  self.isEPUBMode, self.epubView === epubView,
                  self.epubLoupeHost === host, self.epubLoupe === loupe,
                  loupe.isEnabled else { return }
            loupe.update(content: content)
        }
    }

    /// EPUB ルーペ倍率を設定へ保存し、現在内容を取り直す
    func adjustEPUBLoupeRate(by delta: Double) {
        let rate = max(1.0, settings.loupeRate + delta)
        settings.loupeRate = rate
        epubLoupe?.rate = rate
        refreshEPUBLoupeSnapshot()
    }

    /// Washi の raw スナップショットを既存 LoupeController の座標系へ詰める
    private func makeEPUBLoupeContent(for view: EPUBReaderView) async
        -> LoupeController.Content? {
        // cooViewer-hnt: WKWebView は実表示幅を超える snapshotWidth をクランプ
        // するため、backing scale の原寸だけを取得する。倍率 > 2 の滲みは
        // epubDebugSnapshot にも記した Core Animation 拡大の限界と同じ。
        guard let snapshot = try? await view.contentSnapshot(scale: 1),
              let image = snapshot.image.cgImage(
                forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return LoupeController.Content(
            containerBounds: view.bounds,
            containerPosition: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            containerTransform: .identity,
            pages: [LoupeController.Page(frame: snapshot.frame, image: image)],
            backgroundColor: view.layer?.backgroundColor)
    }

    func dismissEPUBMode() {
        teardownEPUBSearch()
        guard isEPUBMode else { return }
        disableEPUBLoupe()
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
        epubBookmarks = []
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
        // 提示エポックを採番(await より前)。合本内移動は openGeneration を
        // 動かさないため、last-request-wins は epubPresentEpoch で担保する
        epubPresentEpoch += 1
        let presentEpoch = epubPresentEpoch
        let generation = openGeneration
        Task { [weak self] in
            guard let self else { return }
            let publication = await self.epubParseCoalescer.publication(at: url)
            // 解析中に別の本が開かれた/代理ページを離れたら何もしない
            // (openBookFlow の世代規則と同じ。book 同一性だけでは、新しい
            // オープンの途中(book 差し替え前)をすり抜ける)。
            // 一覧からの明示ジャンプは着地ページを問わない(現在ページが
            // 代理ページとは限らないため)。提示の連打は presentReflowableEPUB 内の
            // epubPresentEpoch 照合が守る
            guard self.openGeneration == generation,
                  self.book === book,
                  explicitLocator != nil || book.currentIndex == entryIndex
            else { return }
            guard let publication, !publication.isFixedLayout,
                  !publication.isDRMProtected else {
                if let publication {
                    // 確定降格(FXL/DRM): 以後ずっと静的表紙。恒久ブラックリストへ。
                    // 隣へ素通りさせると全滅フォルダ + ループ設定で openBook が無限
                    // 循環する。初回降格のときだけ DRM を説明する(合本内で無説明に
                    // 表紙へ化けると『なぜこの巻だけ読めないか』が分からない。監査 #9)
                    let inserted = self.epubFailedPlaceholders.insert(url).inserted
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
                    self.epubTransientFailedPlaceholders.insert(url)
                    NSSound.beep()
                }
                // 表紙降格は同一の合本ブックのまま静的表紙を再描画する。
                // openBook で作り直すと NestedUnlocker の解錠済み子・パスワード
                // キャンセル記憶が失われ再プロンプトになる(57t が塞ごうとして
                // 届かなかった経路 = 画像モードでは self.epubCollectionContext が
                // nil のため :908 の再利用条件が成立せず作り直していた。cooViewer-ari)。
                // ブラックリスト登録は上で済んでいるので、その場で再描画すれば
                // refreshDisplay の代理判定(:reflowEPUBURL & !epubFailedPlaceholders)が
                // 入場せず表紙を出す。modal 中に状態が変わり得るので世代/本を再照合する
                guard self.openGeneration == generation, self.book === book else { return }
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
                epoch: presentEpoch)
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
            let publication = await self.epubParseCoalescer.publication(at: url)
            guard self.isEPUBMode,
                  self.epubCollectionContext?.folderURL == context.folderURL
            else { return }
            guard let publication, !publication.isFixedLayout,
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

    /// 次/前の本ナビ(キー/マウス)で合本ソース再利用の復帰フラグを立てる。
    /// **合本文脈のときだけ**立てる — 単体 EPUB には再利用先(合本)が無く、
    /// 立てると開きが失敗(隣が DRM 等)したとき openBookFlow を通らず残り、
    /// didReachBookEdge のガード(:guard !epubCollectionReturnPending)を恒久的に
    /// 塞いで巻端ナビが全滅する。フラグの生存は「復帰オープンが in-flight の間だけ」
    /// が不変条件(openBookFlow 末尾の defer と各終端で確実に消す。cooViewer-s7j)
    private func markCollectionReturnForAdjacentBook() {
        if epubCollectionContext != nil { epubCollectionReturnPending = true }
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
        // 単/見開き固定もクローズ時に保存する。s トグル時の即時保存に加え、
        // RememberBookSettings を OFF にしてから s を押さずに終了した場合でも
        // 既存値を確実に消すため(画像本の marks/readMode が save() のクローズ時
        // 書込で OFF なら消えるのと同型。noteReflowColumnMode 側が Remember を
        // 判定して保存/消去する。cooViewer-0dh, Codex レビュー指摘)
        BookHistoryStore.shared.noteReflowColumnMode(
            path: epubBookURL.path, columnMode: epubView.settings.columnMode.rawValue)
        saveEPUBBookmarks()
    }

    /// 表示中 EPUB のしおりを Washi 非依存のタプルへ変換して保存する
    func saveEPUBBookmarks() {
        guard let epubBookURL else { return }
        BookHistoryStore.shared.noteReflowBookmarks(
            path: epubBookURL.path,
            bookmarks: epubBookmarks.map { bookmark in
                (bookmark.name, bookmark.locator.spineIndex,
                 bookmark.locator.progression, bookmark.locator.idref)
            })
    }

    // MARK: - 本文検索

    /// リフロー EPUB 専用のフローティング検索パネルを開く。
    @objc func showEPUBSearchMenu(_ sender: Any?) {
        guard isEPUBMode, let window else { return }
        if let panel = epubSearchPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let model = EPUBSearchModel()
        let searchView = EPUBSearchView(
            model: model,
            onQueryChange: { [weak self] query in
                self?.startEPUBSearch(query: query, debounce: true)
            },
            onSearchNow: { [weak self] query in
                self?.startEPUBSearch(query: query, debounce: false)
            },
            onSelect: { [weak self] index in
                self?.selectEPUBSearchHit(at: index)
            },
            onNext: { [weak self] in
                self?.goToEPUBSearchHit(forward: true)
            },
            onPrevious: { [weak self] in
                self?.goToEPUBSearchHit(forward: false)
            },
            onClose: { [weak self] in
                self?.epubSearchPanel?.performClose(nil)
            })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: searchView))
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        panel.title = String(localized: "Search")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.setContentSize(NSSize(width: 480, height: 500))
        panel.delegate = self
        // パネルがキーウインドウでも ⌘F/⌘G をリーダーの responder へ渡す。
        panel.nextResponder = self

        epubSearchModel = model
        epubSearchPanel = panel
        let parentFrame = window.frame
        let x = parentFrame.maxX - panel.frame.width - 24
        let y = parentFrame.maxY - panel.frame.height - 48
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    /// ⌘G と検索パネルのボタンから次のヒットへ移動する。
    @objc func findNextEPUBMenu(_ sender: Any?) {
        goToEPUBSearchHit(forward: true)
    }

    /// ⇧⌘G と検索パネルのボタンから前のヒットへ移動する。
    @objc func findPreviousEPUBMenu(_ sender: Any?) {
        goToEPUBSearchHit(forward: false)
    }

    /// 入力連打をデバウンスし、Washi の同期検索を MainActor の外で実行する。
    private func startEPUBSearch(query: String, debounce: Bool) {
        // CLI の即時検索後に届く同一の SwiftUI 変更通知は二重実行しない。
        if debounce, epubSearchModel?.pendingQuery == query { return }
        clearEPUBSearchHighlight()
        epubSearchTask?.cancel()
        epubSearchEpoch += 1
        let epoch = epubSearchEpoch
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            epubSearchModel?.clearResults()
            epubSearchTask = nil
            return
        }
        guard let publication = epubPublication,
              let model = epubSearchModel else { return }
        model.beginSearch(query: query)

        epubSearchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard self?.epubSearchEpoch == epoch,
                  self?.epubPublication === publication,
                  self?.epubSearchModel === model else {
                // cooViewer-1p7: 現世代の task だけは検索中状態を取り残さない。
                if let self, self.epubSearchEpoch == epoch {
                    self.epubSearchTask = nil
                    model.clearResults()
                }
                return
            }

            let worker = Task.detached(priority: .userInitiated) {
                () -> EPUBSearchComputation? in
                let allHits = publication.search(query)
                guard !Task.isCancelled else { return nil }
                let limited = EPUBSearchLogic.limited(allHits)
                var itemTexts: [Int: String] = [:]
                for hit in limited.values where itemTexts[hit.spineIndex] == nil {
                    guard !Task.isCancelled else { return nil }
                    itemTexts[hit.spineIndex] = (try? publication.extractText(
                        forSpineIndex: hit.spineIndex)) ?? ""
                }
                let hits = limited.values.map { hit in
                    let text = itemTexts[hit.spineIndex] ?? ""
                    // 想定外の抽出/範囲失敗でも一覧から落とさず、長さ 0 により
                    // Washi の nil → 従来 locator のフォールバックへ接続する。
                    let utf16Range = EPUBSearchLogic.utf16Range(
                        characterOffset: hit.characterOffset,
                        length: hit.length, in: text) ?? (0, 0)
                    return SearchHit(
                        spineIndex: hit.spineIndex,
                        progression: EPUBSearchLogic.progression(
                            characterOffset: hit.characterOffset,
                            itemTextLength: text.count),
                        utf16Offset: utf16Range.utf16Offset,
                        utf16Length: utf16Range.utf16Length,
                        snippet: hit.snippet)
                }
                return EPUBSearchComputation(
                    hits: hits, isTruncated: limited.isTruncated)
            }
            let computation = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let computation, let self,
                  self.epubSearchEpoch == epoch,
                  self.epubPublication === publication,
                  self.epubSearchModel === model else {
                // cooViewer-1p7: publication/model の不一致でも現世代を確実に収束させる。
                if let self, self.epubSearchEpoch == epoch {
                    self.epubSearchTask = nil
                    model.clearResults()
                }
                return
            }

            let pages = computation.hits.map { self.epubSearchPageNumber(for: $0) }
            model.finishSearch(query: query, hits: computation.hits,
                               pageNumbers: pages,
                               isTruncated: computation.isTruncated)
            self.epubSearchTask = nil
        }
    }

    /// ページ番号表示とジャンプ先で共有する唯一の近似 locator 生成経路。
    private func epubSearchLocator(for hit: SearchHit) -> EPUBLocator {
        EPUBLocator(spineIndex: hit.spineIndex, progression: hit.progression)
    }

    private func epubSearchPageNumber(for hit: SearchHit) -> Int? {
        epubBookmarkPageNumber(for: epubSearchLocator(for: hit))
    }

    /// census の完了・無効化に合わせて検索一覧のページ番号も更新する。
    func refreshEPUBSearchPageNumbers() {
        guard let model = epubSearchModel else { return }
        model.updatePageNumbers(model.hits.map { epubSearchPageNumber(for: $0) })
    }

    private func selectEPUBSearchHit(at index: Int) {
        guard let model = epubSearchModel, model.hits.indices.contains(index),
              let epubView else { return }
        let hit = model.hits[index]
        let locator = epubSearchLocator(for: hit)
        model.select(index)
        clearEPUBSearchHighlight()
        let token = epubSearchLandingEpoch
        epubSearchLandingTask = Task { [weak self, weak epubView, weak model] in
            guard let self, let epubView, let model else { return }
            defer {
                if self.epubSearchLandingEpoch == token {
                    self.epubSearchLandingTask = nil
                }
            }
            guard !Task.isCancelled, self.epubSearchLandingEpoch == token,
                  self.epubView === epubView, self.epubSearchModel === model
            else { return }
            // 着地由来の移動を待つ印(整定判定用)と、待機中に別の移動が起きたかを
            // 判定するための通算回数を控える
            self.pendingSearchLanding = token
            let movesBefore = self.epubMoveCount
            let landing = await epubView.go(
                to: locator,
                textRange: (utf16Offset: hit.utf16Offset,
                            utf16Length: hit.utf16Length))
            guard !Task.isCancelled, self.epubSearchLandingEpoch == token,
                  self.epubView === epubView, self.epubSearchModel === model
            else { return }
            guard let landing else {
                // 待機中に別の移動(目次・しおり・利用者のページ送り等)が起きて Washi が
                // nil を返した場合、その移動を近似ジャンプで上書きしない(cooViewer-rso)
                guard self.epubMoveCount == movesBefore else {
                    self.pendingSearchLanding = nil
                    return
                }
                // 移動が無ければ地図が解決できない項目なので従来の近似位置へ。
                // pendingSearchLanding はその移動の didMoveTo まで保持し、検証の
                // 整定判定が早まらないようにする(cooViewer-lsq)
                epubView.go(to: locator)
                return
            }
            self.lastEPUBSearchLanding = landing
            self.showEPUBSearchHighlight(rects: landing.rects, in: epubView)
        }
    }

    /// 古い矩形と進行中の厳密着地を同時に無効化する。
    /// リサイズ・設定変更・本切替の後から旧タスクが戻っても再表示させない。
    func clearEPUBSearchHighlight() {
        epubSearchLandingEpoch &+= 1
        pendingSearchLanding = nil
        epubSearchLandingTask?.cancel()
        epubSearchLandingTask = nil
        lastEPUBSearchLanding = nil
        epubSearchHighlightHost?.removeFromSuperview()
        epubSearchHighlightHost = nil
    }

    private func showEPUBSearchHighlight(rects: [CGRect], in view: EPUBReaderView) {
        epubSearchHighlightHost?.removeFromSuperview()
        let host = EPUBSearchHighlightHostView(frame: view.bounds)
        host.show(rects: rects)
        // ルーペ表示中はレンズの下に置く(ハイライトがレンズ枠の上に描かれないように。
        // cooViewer-532)
        if let loupeHost = epubLoupeHost, loupeHost.superview === view {
            view.addSubview(host, positioned: .below, relativeTo: loupeHost)
        } else {
            view.addSubview(host)
        }
        epubSearchHighlightHost = host
    }

    private func goToEPUBSearchHit(forward: Bool) {
        guard let model = epubSearchModel,
              let index = EPUBSearchLogic.selectionIndex(
                current: model.selectedIndex, count: model.hits.count,
                forward: forward) else {
            NSSound.beep()
            return
        }
        selectEPUBSearchHit(at: index)
    }

    /// Esc・モード切替・親窓終了の全経路から同じ状態を破棄する。
    func teardownEPUBSearch(closePanel: Bool = true) {
        clearEPUBSearchHighlight()
        epubSearchEpoch += 1
        epubSearchTask?.cancel()
        epubSearchTask = nil
        epubSearchModel?.clearResults()
        epubSearchModel = nil
        guard let panel = epubSearchPanel else { return }
        epubSearchPanel = nil
        panel.delegate = nil
        panel.nextResponder = nil
        panel.parent?.removeChildWindow(panel)
        if closePanel {
            panel.orderOut(nil)
            panel.close()
        }
    }

    /// スナップショット CLI から検索を開始する。
    func debugSearchEPUB(_ query: String) {
        showEPUBSearchMenu(nil)
        epubSearchModel?.query = query
        startEPUBSearch(query: query, debounce: false)
    }

    /// CLI 検証用: 実際の N/M ラベルと厳密着地の結果を一行へ整形する。
    func debugEPUBSearchLandingOutput() -> String? {
        let displayedPage = epubPageLabelText?
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? "\(epubView.map { $0.pageInItem + 1 } ?? 0)/\(max(1, epubView?.pageCountInItem ?? 1))"
        guard epubSearchHighlightHost != nil, let landing = lastEPUBSearchLanding else {
            // 厳密着地しなかった(近似フォールバックまたは移動なし)場合も実表示を出す
            return "[search-landing] exact=false page=\(displayedPage) "
                + "moves=\(epubMoveCount) pending=\(pendingSearchLanding != nil)"
        }
        return "[search-landing] exact=true page=\(displayedPage) "
            + "rects=\(landing.rects.count) text=\(landing.text)"
    }

    // MARK: - ナビゲーション(メニュー・キー・マウスから)

    func epubGoForward() { epubView?.goForward() }
    func epubGoBackward() { epubView?.goBackward() }
    func epubGoToFirst() { epubView?.goToBookStart() }
    func epubGoToLast() { epubView?.goToBookEnd() }

    /// 現在画面のしおりを追加/削除する(仕様書 §4.7.1)。census 完了時は
    /// ページ空間で同一画面を判定し、未完時だけ progression 近似へ落とす
    func toggleEPUBBookmark() {
        guard let epubView, let epubPublication else { return }
        let current = epubView.currentLocator
        if let index = EPUBBookmarkLogic.matchingIndex(
            in: epubBookmarks, current: current,
            currentPageRange: epubView.currentGlobalPageRange,
            pageCountInItem: epubView.pageCountInItem,
            globalPage: { epubView.censusGlobalPage(for: $0) }) {
            epubBookmarks.remove(at: index)
        } else {
            let name = epubPublication.chapterTitle(forSpineIndex: current.spineIndex)
                ?? "bookmark\(epubBookmarks.count + 1)"
            epubBookmarks.append((name, current))
        }
        saveEPUBBookmarks()
        BookmarkListMenuDelegate.shared.rebuild()
    }

    /// 次/前のしおりへ移動する。現在の見開きより外側だけを候補にし、配列順に
    /// 依存せず最も近いページを選ぶ(画像本 nextBookmarkIndex と同義 §4.7.1)
    func goToEPUBBookmark(next: Bool) {
        guard let epubView else { return }
        guard let index = EPUBBookmarkLogic.targetIndex(
            in: epubBookmarks, current: epubView.currentLocator,
            currentPageRange: epubView.currentGlobalPageRange,
            pageCountInItem: epubView.pageCountInItem, next: next,
            globalPage: { epubView.censusGlobalPage(for: $0) }) else {
            NSSound.beep()
            return
        }
        epubView.go(to: epubBookmarks[index].locator)
    }

    /// しおり一覧メニューからのジャンプ(representedObject = 配列 index)
    @objc func goToEPUBBookmarkListItem(_ sender: NSMenuItem) {
        guard let epubView, let index = sender.representedObject as? Int,
              epubBookmarks.indices.contains(index) else { return }
        epubView.go(to: epubBookmarks[index].locator)
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
        let positions = epubBookmarks.map {
            epubBookmarkPositionText(for: $0.locator)
        }
        let pageNumbers = epubBookmarks.map {
            pageNumber($0.locator)
        }
        let editor = NSWindow(contentViewController: NSHostingController(
            rootView: EPUBBookmarkEditorView(
                bookmarks: epubBookmarks, positions: positions,
                pageNumbers: pageNumbers, pageRange: pageRange,
                onSave: { [weak self] bookmarks in
                    guard let self else { return }
                    let resolved = bookmarks.map { bookmark in
                        let locator = EPUBBookmarkLogic.resolvedLocator(
                            original: bookmark.locator,
                            editedPage: bookmark.pageNumber,
                            originalPage: pageNumber(bookmark.locator),
                            range: pageRange,
                            base: pageBase,
                            locatorForLocalPage: {
                                epubView.censusLocator(forGlobalPage: $0)
                            })
                        return (name: bookmark.name, locator: locator)
                    }
                    if self.isEPUBMode, self.epubBookURL == targetURL {
                        self.epubBookmarks = resolved
                        self.saveEPUBBookmarks()
                        BookmarkListMenuDelegate.shared.rebuild()
                    } else {
                        // シート中に本が切り替わっても編集対象の EPUB へ保存する
                        BookHistoryStore.shared.noteReflowBookmarks(
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

    /// goToPage 用の「現在の総ページ数」。表示(updateEPUBIndicators)と
    /// ジャンプ(epubJump)が使う総数に一致させる — census 未完・page map 未完
    /// では番号系が本単位近似になるため nil(番号ジャンプ不可)を返す
    var epubCurrentTotalPages: Int? {
        guard isEPUBMode, let epubView else { return nil }
        // epubJump のコレクション分岐と同じ条件(全体マップ+リーダー census)
        if epubCollectionContext != nil,
           epubView.currentGlobalPageRange != nil,
           let map = activeCollectionPageMap() {
            return map.total
        }
        if let total = epubView.censusTotalPages, total > 0 { return total }
        return nil
    }

    /// ページ番号ダイアログ(§5.8 pageMover の EPUB 版。c6s.21 ⑩)。
    /// 入力した 1 始まりページを比率へ換算して epubJump へ渡す — 単体・
    /// コレクションのどちらも Int((fraction*(total-1)).rounded()) が
    /// page-1 に丸め戻るため、goToPercent と同じ経路で正確なページ着地になる。
    /// census 未完で総ページ不明なら操作不能としてビープ
    private func promptEPUBGoToPage() {
        guard let total = epubCurrentTotalPages, total > 0 else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Go to Page")
        alert.addButton(withTitle: String(localized: "Go"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "1-\(total)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let page = Int(field.stringValue) else { return }
        epubGoToPage(page)
    }

    /// 1 始まりページ番号へジャンプ(promptEPUBGoToPage と検証フラグから使う)。
    /// 総ページへクランプし比率換算で epubJump へ渡す。census 未完はビープ
    func epubGoToPage(_ page: Int) {
        guard let total = epubCurrentTotalPages, total > 0 else {
            NSSound.beep()
            return
        }
        let clamped = min(max(page, 1), total)
        let fraction = total > 1 ? Double(clamped - 1) / Double(total - 1) : 0
        epubJump(toBookFraction: fraction)
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
        if let host = epubLoupeHost, epubLoupe?.isEnabled == true {
            epubLoupe?.move(to: host.convert(event.locationInWindow, from: nil))
        }
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

    /// 2 本指スクロールの水平スワイプは Washi がめくりに消費し resolveMouse を
    /// 通らないため(3 本指と非対称。cooViewer-xsw)、EPUB モードでローカルモニタで
    /// 捕捉する。横スワイプにカスタム(非ページめくり)割当があるときだけ横取りして
    /// handleEPUBGesture へ回し、割当が無い水平めくり・縦スクロールは Washi へ
    /// 素通しする(既定挙動は無変更)。
    func installEPUBScrollMonitorIfNeeded() {
        guard epubScrollMonitor == nil else { return }
        epubScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self, self.isEPUBMode, event.window === self.window,
                  self.window?.isKeyWindow == true,
                  let epubView = self.epubView else { return event }
            // EPUB ビュー上のスクロールのみ対象にし、サムネイル等の上は素通しする
            let point = epubView.convert(event.locationInWindow, from: nil)
            guard epubView.bounds.contains(point) else { return event }
            let decision = self.epubScrollGesture.feed(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas,
                timestamp: event.timestamp,
                interceptHorizontalIfNew: self.epubHasCustomSwipeBinding())
            switch decision {
            case .passThrough:
                return event
            case .consume:
                return nil
            case .turn(let positive):
                // 画像側 scrollWheel と同符号: scrollingDeltaX>0 → swipeRight。
                // handleEPUBGesture 内で flipSwipeDirection / readsFromLeft を適用する
                let button = positive ? VirtualButton.swipeRight : VirtualButton.swipeLeft
                let modifiers = LegacyModifier.encode(flags: event.modifierFlags)
                let leftHalf = self.epubLeftHalf(
                    locationInWindow: event.locationInWindow)
                _ = self.handleEPUBGesture(virtualButton: button,
                                           modifiers: modifiers,
                                           leftHalf: leftHalf)
                return nil
            }
        }
    }

    /// 水平スワイプのいずれかに非ページめくりのカスタム割当があるか。
    /// あるときだけ scrollWheel を横取りする。
    private func epubHasCustomSwipeBinding() -> Bool {
        for button in [VirtualButton.swipeLeft, VirtualButton.swipeRight] {
            if let action = bindings.resolveMouse(
                button: button, modifiers: 0,
                fitMode: 0, readsFromLeft: epubInputReadsFromLeft)?.action,
                action != .nextPage, action != .previousPage {
                return true
            }
        }
        return false
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
        case .goToPage:
            // ページ番号ダイアログ(§5.8)。census 完了時のみ番号ジャンプ可能
            promptEPUBGoToPage()
        case .addRemoveBookmark:
            toggleEPUBBookmark()
        case .nextBookmark:
            goToEPUBBookmark(next: true)
        case .previousBookmark:
            goToEPUBBookmark(next: false)
        case .positionalNextPrevBookmark:
            guard let leftHalf else { return false }
            goToEPUBBookmark(next: epubIsNextSide(leftHalf))
        case .nextBook:
            // 単一合本の親でのラップアラウンド復帰でも合本ソースを使い回す
            // (openCollectionEntry の巻端ラップと対称。cooViewer-57t)
            markCollectionReturnForAdjacentBook()
            openAdjacentBook(forward: true)
        case .previousBook:
            markCollectionReturnForAdjacentBook()
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
            // .nextBook/.previousBook と対称に合本ソース再利用フラグを立てる
            // (57t の hole(1) 取りこぼし。cooViewer-ari)
            markCollectionReturnForAdjacentBook()
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
            // 単/見開き固定は本ごとに永続化する(画像本の marks が
            // saveCurrentBookState で即保存されるのと同型。再起動で auto に
            // 戻る不具合 = cooViewer-0dh の修正)
            if let epubBookURL {
                BookHistoryStore.shared.noteReflowColumnMode(
                    path: epubBookURL.path,
                    columnMode: epubSettings.columnMode.rawValue)
            }
        case .toggleSlideshow:
            // スライドショー(§4.9)。タイマーは book に依存しないので
            // そのまま流用し、tick は EPUB 分岐で epubGoForward する
            toggleSlideshow()
        case .toggleLoupe:
            toggleEPUBLoupe()
        case .loupePowerUp:
            adjustEPUBLoupeRate(by: value ?? 0.5)
        case .loupePowerDown:
            adjustEPUBLoupeRate(by: -(value ?? 0.5))
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

    /// ヘッドレス検証では不定なマウス位置を使わず、画面中央でルーペを切り替える
    func debugToggleEPUBLoupeAtCenter() {
        guard let epubView else { return }
        toggleEPUBLoupe(at: CGPoint(x: epubView.bounds.midX,
                                   y: epubView.bounds.midY))
    }

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
        // WKWebView の subview は base に写らないため、ルーペホストを別途焼く。
        // 注意(検証の限界): ルーペの拡大は複製レイヤの scale transform で行うが、
        // cacheDisplay も layer.render(in:) もオフスクリーンでは倍率>1 の
        // サブレイヤ transform を反映できない(Core Animation の既知制約。画像側
        // ルーペと共通)。画面上の合成は正しく拡大される。ここでは白枠と配置を
        // 確認できれば十分なので、向きの狂いが出ない cacheDisplay を使う
        // (layer.render は本ホストだと上下反転する)。倍率 1 のときは内部内容も写る
        if let host = epubLoupeHost, epubLoupe?.isEnabled == true,
           !host.isHidden, host.bounds.width > 0,
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(rep)
            overlays.append((image: image, frame: host.frame))
        }
        // 本文ハイライトも WKWebView の外側にあるため、透明ホストを別途焼く。
        // 子 CALayer は transform を持たないので cacheDisplay へそのまま写る。
        if let host = epubSearchHighlightHost, !host.isHidden,
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
        epubMoveCount &+= 1
        if epubSearchLandingTask != nil {
            // 着地 Task の実行中に届く pageChanged(着地自身、⌘G 連打で取り残された
            // 古い locate、利用者操作)ではハイライトを消さない。表示の可否は着地 Task が
            // 世代と移動回数で判定する(cooViewer-rs2 / rso)。整定判定の印だけ下ろす
            pendingSearchLanding = nil
        } else {
            // ページ送り・目次・しおり等で本文が動けば、旧座標の表示を捨てる。
            clearEPUBSearchHighlight()
        }
        epubContentLoaded = true
        updateEPUBIndicators()
        refreshEPUBLoupeSnapshot()
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
        // スライドショー中の巻末到達は §4.3.4 で停止する(画像本の slideshowTick
        // hitEnd と同型: ループ設定 0 のときだけ下の goToBookStart で巻頭へ戻り
        // 継続する)。単体 EPUB のみここで扱う。cooViewer-9ne: 合本内は下の
        // openCollectionEntry → openBook が stopSlideshow するため、合本全体の
        // 巻端だけでなく各エントリ境界で止まる(横断継続は cooViewer-mji)
        if forward, slideshowTimer != nil, epubCollectionContext == nil,
           settings.loopCheck != 0 {
            stopSlideshow()
            return
        }
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
        refreshEPUBSearchPageNumbers()
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
        refreshEPUBLoupeSnapshot()
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

/// EPUB ルーペ専用。表示だけを重ね、WebKit のクリックやページ送りを奪わない
final class EPUBLoupeHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
