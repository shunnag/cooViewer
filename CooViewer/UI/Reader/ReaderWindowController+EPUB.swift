import AppKit
import SwiftUI
import Washi

/// リフロー EPUB の表示モード(設計書 §2.4 EPUB 対応)。
/// 独立ウインドウではなく**同じリーダーウインドウの表示切替**として実装する:
/// readerView(画像)と epubView(Washi)を入替表示し、開閉・ページ送り・
/// 次/前の本・メニュー・履歴の操作感を画像本(PDF 等)と揃える。
/// キーバインドは resolveKey/resolveMouse を共有し、実行だけを EPUB 用の
/// 縮小ディスパッチャで行う(仕様書 §5.3/§5.4 の switchAction も有効)
extension ReaderWindowController: EPUBReaderViewDelegate {
    var isEPUBMode: Bool { epubSession?.isActive == true }

    /// ホストが作る非同期処理は、同じ publication の再提示でも旧結果を捨てる。
    func ownsEPUBSession(_ session: EPUBReadingSession) -> Bool {
        epubSession === session && session.isActive
    }

    /// Washi は旧 document/spine の通知を内部で失効させる。ホストはそれに加え、
    /// 現在のビュー・publication と提示設定中でないことを確認する。
    func acceptsEPUBCallback(from view: EPUBReaderView) -> Bool {
        guard let session = epubSession, ownsEPUBSession(session),
              !session.isConfiguringView, epubView === view else { return false }
        return EPUBPersistencePolicy.shouldPersist(
            callbackPublication: view.publication,
            currentPublication: session.publication)
    }

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
                               epoch: Int,
                               fromSlideshow: Bool = false) {
        // 入口: この提示が最後に要求されたものでなければ旧本の teardown を始めない
        // (合本内 EPUB↔EPUB の横断連打で last-request-wins を保証。openGeneration は
        // 合本内移動で動かないため専用の epubPresentEpoch で照合する)
        guard epubPresentEpoch == epoch else { return }

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
        // cooViewer-oxr.23: 復元確認の modal が run loop を回している間は、旧
        // publication と旧 URL を一切差し替えない。旧ビューの callback が新しい
        // 本へ保存される混線を防ぎ、最新要求だけが以下の状態を変更する（設計書 §2.4）。
        guard epubPresentEpoch == epoch else { return }

        unloadImageBookForEPUB(fromSlideshow: fromSlideshow)
        endEPUBSession()  // EPUB → EPUB でも旧本の保存と後片付けを同じ順で行う
        collectionNavigation.returnPending = false
        // 永続層は Washi 非依存のタプルを返すため、復元位置と同じく境界で
        // EPUBLocator を直接構築する(matchingLocator 経路は導入しない)
        let bookmarks = history.savedReflowBookmarks(forPath: url.path)
            .map { bookmark in
                (bookmark.name, EPUBLocator(
                    spineIndex: bookmark.spineIndex,
                    progression: bookmark.progression,
                    idref: bookmark.idref))
            }
        let session = EPUBReadingSession(
            publication: publication, url: url, collectionContext: collectionContext,
            bookmarks: bookmarks)
        epubSession = session
        epubMouseRecognizer = MouseGestureRecognizer()
        epubScrollGesture = EPUBScrollGestureRecognizer()
        epubRotationSum = 0

        let view = ensureEPUBView()
        readerViewForInput.isHidden = true
        view.isHidden = false
        let titleMetadata = publication.metadata.titles.first { $0.type == "main" }
            ?? publication.metadata.titles.first
        let rawEPUBTitle = titleMetadata?.value ?? url.lastPathComponent
        // cooViewer-oxr.52: 設計書 §2.4 の title 境界で isolate し、合本名や
        // AppKit の残りの title へ RTL/LTR 状態を漏らさない。
        let epubTitle = EPUBTitleFormatter.windowTitle(
            rawEPUBTitle, direction: titleMetadata?.direction)
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

        // 設定同期と columnMode 復元は modal(restoredEPUBLocator)より後・
        // load 直前に行う。modal 中に旧本(切替元)のビューへ設定を書くと再ページ
        // 割りが走り、その pageChanged が既に切替先 URL になった epubBookURL で
        // 保存して位置が混線するため(Codex レビュー指摘)。まず退出中に変わった
        // 設定(余白・フォント・ノンブル等)へ追い付かせ、続けて単/見開き固定
        // (s キー = columnMode)を本ごとの保存から復元する。census の metricsKey は
        // columnMode(由来の spread)を含むため load / importCensus より前に反映
        // する(順序が崩れると census 不一致で再実測)。保存が無ければ
        // plannedEPUBSettings のセッション引き継ぎ値を残す(cooViewer-0dh)
        session.isConfiguringView = true
        syncEPUBViewSettings()
        if let saved = history.savedReflowColumnMode(forPath: url.path),
           let mode = EPUBColumnMode(rawValue: saved) {
            var restored = view.settings
            restored.columnMode = mode
            view.settings = restored
        }
        // cooViewer-oxr.45: 設定同期後の新しい publication の版面キーを導き、
        // 外部画面との往復では直近 3 件から同じ版面を選ぶ。view の完了済みキーは
        // load 前だと旧 publication の値なので参照しない（設計書 §2.4）。
        let preferredCensusMetricsKey = EPUBScreenMetrics(
            viewportSize: window?.contentView?.bounds.size ?? view.bounds.size,
            settings: view.settings,
            renditionSpread: publication.metadata.rendition.spread).cacheKey
        // cooViewer-t4e: 再構築される webView の旧スナップショットを保持した
        // ルーペを、次の publication の load より先に必ず無効化する。
        disableEPUBLoupe()
        view.load(publication: publication, at: locator)
        // 保存済みの census を注入する。版・spine 数・メトリクスが一致すれば
        // Washi 側が採用し、同一寸法での再オープンで再実測を省く(整合検証は
        // importCensus 側。不一致なら無視され通常どおり再実測する)
        let matchingCensus = history.savedReflowCensus(
            forPath: url.path, metricsKey: preferredCensusMetricsKey)
        if let saved = matchingCensus
            ?? history.savedReflowCensus(forPath: url.path) {
            view.importCensus(EPUBCensusRecord(
                metricsKey: saved.metricsKey, counts: saved.counts,
                releaseIdentifier: saved.releaseIdentifier))
        }
        session.isConfiguringView = false
        // コレクション経由では「本」はコレクション自体(開いた時点で記録済み)。
        // 子 EPUB で最近使った本を埋めない
        if collectionContext == nil {
            history.noteOpened(path: url.path)
        }
        installEPUBKeyMonitorIfNeeded()
        installEPUBGestureMonitorIfNeeded()
        installEPUBScrollMonitorIfNeeded()
        installEPUBMouseMonitorIfNeeded()
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
                              ?? (publication.effectiveReadingDirection != .rtl))
        // 同期 importCensus の通知を抑止した場合も確定済みのページ数へ追い付かせる。
        if view.censusTotalPages != nil { updateEPUBIndicators() }
    }

    /// 前回位置の復元。保存側のゲート(§7.3)に加えて、画像本と同じ
    /// GoToLastPageMode(0=確認/1=自動/2=無効。§7.3)を通す。
    /// リフローに固定ページ番号は無いため、確認ダイアログは全体進行率で示す
    private func restoredEPUBLocator(for url: URL,
                                     publication: EPUBPublication) -> EPUBLocator? {
        guard settings.goToLastPageMode < 2,
              let saved = history.savedReflowPosition(forPath: url.path)
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

    /// cooViewer-oxr.46 C41 / 仕様 RS 3.3 §3.9: 本文中のリンクでブラウザや
    /// メールソフトを黙って起動しない。本の中身は信頼できない前提なので、
    /// 開く前に行き先を見せて確認する(既定はキャンセル側)。
    func readerView(_ view: EPUBReaderView, shouldOpenExternalURL url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open this link outside cooViewer?")
        // 極端に長い URL でダイアログが伸びないよう頭を見せる
        let shown = url.absoluteString
        alert.informativeText = shown.count > 200
            ? String(shown.prefix(200)) + "…" : shown
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
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
        // cooViewer-oxr.32/33/35/38: 設計書 §2.4 の host 値を pure mapper
        // へまとめ、本文表示と画面計画が同一の単位変換を使う。
        EPUBSettingsMapper.readerSettings(from: EPUBSettingsValues(
            pageTurnStyle: epubPageTurnStyle,
            fontScale: settings.epubFontScale,
            pinchAdjustsFontScale: settings.epubPinchFontScale,
            // 下配置では host の N/M ラベルと Washi のノンブルが重なるため抑止。
            showsPageFurniture: Self.epubShowsFolio(
                showNumber: settings.showNumber,
                pageNumPosition: settings.pageNumPosition),
            insets: Self.epubInsets(forMargins: settings.epubPageMargins),
            defaultFontFamily: settings.epubDefaultFont,
            theme: EPUBReaderTheme(rawValue: settings.epubTheme) ?? .system,
            forcesReadableColors: settings.epubForceReadableColors,
            horizontalWheelTurnsPages: settings.swipeToTurnPage,
            reversesHorizontalWheelTurn: epubHorizontalWheelReversed,
            hidesFootnoteAsides: settings.epubHidesFootnoteAsides,
            lineHeightScale: settings.epubLineHeightScale,
            letterSpacing: settings.epubLetterSpacing,
            paragraphSpacing: settings.epubParagraphSpacing,
            forceFont: settings.epubForceFont,
            hidesRuby: settings.epubHidesRuby,
            showsPrintPageInFurniture: settings.epubShowsPrintPage))
    }

    /// Washi の水平ホイールめくりを画像本のスワイプめくりと同じ論理方向へ
    /// そろえるための反転フラグ。画像側 f=「次」⟺(実効綴じ方向 != 反転設定)、
    /// Washi 側 g=「次」⟺ 本が RTL。両者が食い違うとき反転する(監査 #2。
    /// 混在方向コレクションでは Washi は本の宣言方向でめくるため、コレクション
    /// の readMode との差もここで吸収される)
    private var epubHorizontalWheelReversed: Bool {
        let bookRTL = epubPublication?.effectiveReadingDirection == .rtl
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
        // 退出中の押下を画像本や次の EPUB へ持ち越さない(設計書 §2.4)。
        if let epubMouseMonitor {
            NSEvent.removeMonitor(epubMouseMonitor)
            self.epubMouseMonitor = nil
        }
        epubMouseRecognizer = MouseGestureRecognizer()
        guard isEPUBMode else { return }
        endEPUBSession()
        epubView?.stopMediaOverlay()  // 退出したら音声ナレーションも止める
        epubView?.cancelPageCensus()  // 退出後のオフスクリーン計測を止める
        collectionNavigation.returnPending = false
        hideThumbnailOverlay()  // EPUB の一覧を画像本に持ち越さない
        // cooViewer-oxr.79: 設計書 §2.4 の画像/EPUB 入替では、非表示だけでは
        // ウインドウのリサイズが Washi へ届き、再ページ割りと census が続く。
        // インスタンスと設定は保持したまま window から外し、Washi の teardown を促す。
        epubView?.removeFromSuperview()
        readerViewForInput.isHidden = false
        // EPUB 中にクリックすると WKWebView が first responder を握る。
        // 外した後もそのままだとキーイベントが元の WebView へ流れ、
        // ReaderView.keyDown が呼ばれずキー操作が全滅する(特に
        // 「表示できる画像がありません」の空の本はキーだけが頼りなので致命的)。
        // モードを戻すときに必ずフォーカスも戻す
        window?.makeFirstResponder(readerViewForInput)
    }

    /// 旧ビューを参照できる間に保存し、本に属する処理を終了してから所有を放す。
    /// 閉窓ではこの処理を呼ばず、再表示に必要な読書セッションを保持する。
    private func endEPUBSession() {
        guard let session = epubSession else { return }
        saveEPUBState()
        session.end()
        disableEPUBLoupe()
        epubSession = nil
    }

    /// キー/マウスの綴じ方向解決に使う実効 readsFromLeft。
    /// 単体の EPUB は本の宣言(!isRTL)、コレクション文脈では
    /// コレクションの readMode(表示は宣言のまま、操作系だけ合わせる)
    var epubInputReadsFromLeft: Bool {
        epubCollectionContext?.readsFromLeft
            ?? (epubPublication?.effectiveReadingDirection != .rtl)
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
        let view: EPUBReaderView
        if let epubView {
            view = epubView
        } else {
            view = EPUBReaderView()
            view.settings = currentEPUBReaderSettings()
            view.delegate = self
            view.translatesAutoresizingMaskIntoConstraints = false
            // 自動隠しインジケータのためのマウス移動監視(owner に直接イベントが
            // 届く。WKWebView 上でも tracking area は独立して機能する)
            view.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self))
            self.epubView = view
        }
        if view.superview == nil, let contentView = window?.contentView {
            // cooViewer-oxr.79: 再入場時は同じビューを load より前に戻す。
            // readerView の直上に置くことで、ページ表示・検索・カール・ルーペの
            // ホストを従来どおり EPUB 本文より上に保つ(設計書 §2.4)。
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
        return view
    }

    // MARK: - 状態保存

    /// 現在の EPUB の読書位置を保存する(切替時・クローズ時・終了時)
    func saveEPUBState() {
        guard let session = epubSession else { return }
        guard let epubView, acceptsEPUBCallback(from: epubView) else { return }
        let locator = epubView.currentLocator
        let census = epubView.exportCensus().map {
            ReflowCensusSnapshot(metricsKey: $0.metricsKey, counts: $0.counts,
                                releaseIdentifier: $0.releaseIdentifier)
        }
        let result = history.saveReflowBook(
            path: session.url.path, snapshot: .init(
                position: .init(spineIndex: locator.spineIndex,
                                progression: locator.progression, idref: locator.idref),
                columnMode: epubView.settings.columnMode.rawValue,
                bookmarks: session.bookmarks.map {
                    .init(name: $0.name, position: .init(
                        spineIndex: $0.locator.spineIndex,
                        progression: $0.locator.progression, idref: $0.locator.idref))
                },
                census: census,
                forceRememberBeyondRecents: epubCollectionContext != nil))
        session.saveSchedule.recordAttempt(at: Date(), succeeded: result == .saved)
    }

    /// 表示中 EPUB のしおりを Washi 非依存のタプルへ変換して保存する
    func saveEPUBBookmarks() {
        guard let session = epubSession else { return }
        history.noteReflowBookmarks(
            path: session.url.path,
            bookmarks: session.bookmarks.map { bookmark in
                (bookmark.name, bookmark.locator.spineIndex,
                 bookmark.locator.progression, bookmark.locator.idref)
            })
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
        // 保存された割当値に NaN が混じっても Int 変換で停止しない。
        guard fraction.isFinite else { return }
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
        guard count > 0 else { return }
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
    /// cooViewer-oxr.38: 数値でなければ印刷版ページ名へ解決する。全体 census
    /// が未完でも page-list があれば操作できる（設計書 §2.4）。
    private func promptEPUBGoToPage() {
        guard let epubView else { return }
        let total = epubCurrentTotalPages ?? 0
        let printLabels = epubView.printPageLabels
        guard total > 0 || !printLabels.isEmpty else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Go to Page")
        alert.addButton(withTitle: String(localized: "Go"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        if total > 0, let firstPrintLabel = printLabels.first {
            field.placeholderString = "1-\(total) / \(firstPrintLabel)"
        } else if total > 0 {
            field.placeholderString = "1-\(total)"
        } else {
            field.placeholderString = printLabels.first
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch EPUBPageJumpResolver.resolve(
            input: field.stringValue,
            printLabels: printLabels,
            totalPages: total) {
        case .global(let page):
            epubGoToPage(page)
        case .printPage(let label):
            _ = epubView.go(toPrintPage: label)
        case .invalid:
            break
        }
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
        guard let session = epubSession else { return }
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
                session.pageLabelText = title.map { " \(numbers)/\(map.total) (\($0)) " }
                    ?? " \(numbers)/\(map.total) "
                pageLabel.stringValue = session.pageLabelText ?? ""
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
            session.pageLabelText = title.map { " \(numbers)/\(total) (\($0)) " }
                ?? " \(numbers)/\(total) "
        } else {
            let locator = epubView.currentLocator
            let inItem = Double(epubView.pageInItem + 1)
                / Double(max(1, epubView.pageCountInItem))
            let progress = (Double(locator.spineIndex) + inItem)
                / Double(max(1, epubPublication.readingOrder.count))
            updateEPUBPageBar(progress: progress, readsFromLeft: readsFromLeft)
            session.pageLabelText = nil
        }
        pageLabel.stringValue = session.pageLabelText ?? ""
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

    /// 隠れた ReaderView に届かない中・サイドボタンを捕捉し、画像本と同じ
    /// 状態機械でクリック・ドラッグ・長押しキャンセルを判定する(仕様書 §5.9)。
    /// 左右ボタンは対象外とし、本文の選択・コンテキストメニューを保つ。
    func installEPUBMouseMonitorIfNeeded() {
        guard epubMouseMonitor == nil else { return }
        epubMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { [weak self] event in
            // nil(消費)をそのまま返す。`?? event` にすると消費が打ち消され
            // WKWebView 側の JS 経路と二重発火する
            guard let self else { return event }
            return self.handleEPUBMouseEvent(event)
        }
    }

    func handleEPUBMouseEvent(_ event: NSEvent) -> NSEvent? {
        // マウスは event.window で対象窓を特定できるため、キー入力と異なり
        // キーウインドウ判定は不要。前面化に依存しない同期検証にも対応する。
        guard self.isEPUBMode, event.window === self.window,
              event.buttonNumber >= 2,
              let epubView = self.epubView else { return event }
        let point = epubView.convert(event.locationInWindow, from: nil)
        // EPUB ビューは非フリップ座標なので、状態機械が前提とする
        // ReaderView と同じ下向き正の変位へ揃える(仕様書 §5.9)。
        let gesturePoint = CGPoint(x: point.x,
                                   y: epubView.isFlipped ? point.y : -point.y)
        switch event.type {
        case .otherMouseDown:
            // 同時押しで追跡中のボタンや始点を上書きしない。
            guard !self.epubMouseRecognizer.isTracking else { return nil }
            guard epubView.bounds.contains(point) else { return event }
            self.epubMouseRecognizer.begin(
                button: event.buttonNumber, point: gesturePoint,
                time: event.timestamp, dragScroll: false)
            return nil
        case .otherMouseDragged:
            return self.epubMouseRecognizer.isTracking ? nil : event
        case .otherMouseUp:
            guard self.epubMouseRecognizer.isTracking,
                  self.epubMouseRecognizer.button == event.buttonNumber
            else { return event }
            let outcome = self.epubMouseRecognizer.finish(
                point: gesturePoint, time: event.timestamp,
                modifiers: LegacyModifier.encode(flags: event.modifierFlags))
            if let resolved = EPUBMouseDispatch.resolve(
                outcome, bindings: self.bindings,
                readsFromLeft: self.epubInputReadsFromLeft) {
                _ = self.performEPUB(
                    resolved.action, value: resolved.value,
                    leftHalf: self.epubLeftHalf(
                        locationInWindow: event.locationInWindow))
            }
            return nil
        default:
            return event
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
        guard let binding = bindings.resolveMouse(
            button: virtualButton, modifiers: modifiers,
            fitMode: 0, readsFromLeft: epubInputReadsFromLeft),
            let action = binding.action else { return false }
        guard let effective = GestureActionPolicy.action(
            action, virtualButton: virtualButton,
            swipeToTurnPage: settings.swipeToTurnPage,
            flipSwipeDirection: settings.flipSwipeDirection) else { return true }
        return performEPUB(effective, value: binding.value, leftHalf: leftHalf)
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
        case .epubGoBack:
            // cooViewer-oxr.31: 設計書 §2.4 のリンク履歴だけを戻す。
            // 履歴が無い場合も割当済み操作として消費し、ビープは鳴らさない。
            if epubView?.canGoBack == true {
                epubView?.goBack()
            }
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
            // ページ番号ダイアログ(§5.8)。census 完了後は全体ページ番号、
            // page-list があれば印刷版ラベルでも移動できる(cooViewer-oxr.38)。
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
            // cooViewer-oxr.20: 設計書 §2.4。画像だけの表紙では実測
            // pagesPerScreen が常に 1 なので、Washi の画面計画を反転する。
            guard let epubView else { return false }
            epubView.toggleColumnMode()
            // 単/見開き固定は本ごとに永続化する(画像本の marks が
            // saveCurrentBookState で即保存されるのと同型。再起動で auto に
            // 戻る不具合 = cooViewer-0dh の修正)
            if let epubBookURL {
                history.noteReflowColumnMode(
                    path: epubBookURL.path,
                    columnMode: epubView.settings.columnMode.rawValue)
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
        case .contextualMenu:
            // cooViewer-oxr.35: 右クリックに既存の「コンテキストメニュー」
            // アクションが割り当てられている場合も画像本と同じ host menu を出す
            // （設計書 §2.4）。willShowContextMenu はその後 Washi 側を抑止する。
            showContextMenu()
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
        guard let session = epubSession else { return }
        guard let index = sender.representedObject as? Int,
              session.flattenedToc.indices.contains(index) else { return }
        epubView?.go(to: session.flattenedToc[index].item)
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
        guard let session = epubSession else { return nil }
        guard isEPUBMode, let epubView,
              let base = try? await epubView.snapshot(),
              ownsEPUBSession(session) else { return nil }
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
        if let host = session.search.highlightHost, !host.isHidden,
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
        guard let session = epubSession else { return }
        // cooViewer-oxr.23: 旧 WKWebView の遅延通知を新 URL の状態へ混ぜない
        // （設計書 §2.4）。
        guard acceptsEPUBCallback(from: view) else { return }
        // 参照後に利用者が別ページへ動いた場合、旧アンカーの非同期結果や
        // 表示中の注を新しいページへ残さない(cooViewer-oxr.32、設計書 §2.4)。
        dismissEPUBFootnote()
        session.search.moveCount &+= 1
        if session.search.landingTask != nil {
            // 着地 Task の実行中に届く pageChanged(着地自身、⌘G 連打で取り残された
            // 古い locate、利用者操作)ではハイライトを消さない。表示の可否は着地 Task が
            // 世代と移動回数で判定する(cooViewer-rs2 / rso)。整定判定の印だけ下ろす
            session.search.pendingLanding = nil
        } else {
            // ページ送り・目次・しおり等で本文が動けば、旧座標の表示を捨てる。
            clearEPUBSearchHighlight()
        }
        session.contentLoaded = true
        updateEPUBIndicators()
        refreshEPUBLoupeSnapshot()
        // 通常は 2 秒デバウンスしつつ、通知が連続する朗読でも 30 秒を上限に
        // 保存を確定する（cooViewer-oxr.23、設計書 §2.4）。
        session.saveDebounce?.cancel()
        if session.saveSchedule.shouldSaveNow(at: Date()) {
            saveEPUBState()
            return
        }
        session.saveDebounce = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let session,
                  self.ownsEPUBSession(session) else { return }
            session.saveDebounce = nil
            self.saveEPUBState()
        }
    }

    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {
        guard acceptsEPUBCallback(from: view) else { return }
        // 復帰オープン中の重複イベント(巻端でのキーリピート等)は無視する
        // (二重復帰や、文脈なし分岐への誤爆=単体モード意味論での兄弟
        // オープン・保存位置の巻末上書きを防ぐ)
        guard !collectionNavigation.returnPending else { return }
        // コレクション(合本)内の EPUB は、巻端で合本の隣接エントリへ
        // シームレスに復帰する(合本自体の巻端は openCollectionEntry が
        // 仕様書 §4.9 / §4.3.4 のループ規則で処理する。1/2 は次の本へ継続し、
        // 3 のスライドショーだけ停止する(cooViewer-7hj/mji)
        if let context = epubCollectionContext {
            openCollectionEntry(context: context,
                                at: context.entryIndex + (forward ? 1 : -1),
                                forward: forward,
                                fromSlideshow: slideshowTimer != nil)
            return
        }
        // 巻末/巻頭超えは画像本と同じループ設定に従う(仕様書 §4.3.4)
        if forward {
            switch settings.loopCheck {
            case 0: view.goToBookStart()
            case 1, 2:
                openAdjacentBook(forward: true, fromSlideshow: slideshowTimer != nil)
            case 3:
                if slideshowTimer != nil { stopSlideshow() }
            default:
                if slideshowTimer != nil { stopSlideshow() }
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

    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {
        guard acceptsEPUBCallback(from: view) else { return }
        // cooViewer-oxr.31: 設計書 §2.4。⌘[ の enabled 状態を直ちに再検証する。
        NSApp.mainMenu?.update()
    }

    func readerView(_ view: EPUBReaderView, didClick event: EPUBClickEvent) -> Bool {
        guard let session = epubSession, acceptsEPUBCallback(from: view) else { return false }
        // マウス割当を画像本と同じ解決順で引く(仕様書 §5.3)。
        // 左・中・サイドボタン+修飾キー(Shift/Option/Control)に対応。
        // 右クリックは cooViewer-oxr.35 の willShowContextMenu で解決する
        // （設計書 §2.4）。
        // 未割当なら false → Washi の既定(修飾なし左の左右端タップめくり)
        session.lastClickLocation = event.locationInView
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

    func readerView(
        _ view: EPUBReaderView,
        selectionDidChange selection: EPUBTextSelection?
    ) {
        guard let session = epubSession else { return }
        guard acceptsEPUBCallback(from: view),
              let term = EPUBSelectionSearchTerm.term(from: selection?.text) else {
            return
        }
        // cooViewer-oxr.34: 空選択では直前値を消さず、標準 ⌘E の対象を維持する。
        session.latestSelectionText = term
        NSApp.mainMenu?.update()
    }

    func readerView(
        _ view: EPUBReaderView,
        willShowContextMenu menu: NSMenu,
        at event: EPUBClickEvent?
    ) -> NSMenu? {
        guard let session = epubSession else { return menu }
        guard acceptsEPUBCallback(from: view), let event else { return menu }
        session.lastClickLocation = event.locationInView
        var modifiers = 0
        if event.shift { modifiers += LegacyModifier.shift }
        if event.option { modifiers += LegacyModifier.option }
        if event.control { modifiers += LegacyModifier.control }
        // cooViewer-oxr.35: context-menu callback では右ボタンの割当だけを
        // イベント修飾付きで解決する（設計書 §2.4）。
        let binding = bindings.resolveMouse(
            button: 1, modifiers: modifiers,
            fitMode: 0, readsFromLeft: epubInputReadsFromLeft)
        let action = binding?.action
        guard EPUBContextMenuDecision.shouldSuppressMenu(
            hasResolvedAction: action != nil),
              let binding, let action else {
            return menu
        }
        _ = performEPUB(
            action,
            value: binding.value,
            leftHalf: event.locationInView.x < view.bounds.midX)
        return nil
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
        // cooViewer-oxr.23: 本切替前の census callback は表示にも保存にも使わない
        // （設計書 §2.4）。
        guard acceptsEPUBCallback(from: view) else { return }
        // 全文ページ数の実測が完了/無効化された(フォントサイズ・寸法の
        // 変更に追従)。ページ番号とバーをページ単位へ切替え/差し戻す
        updateEPUBIndicators()
        refreshEPUBSearchPageNumbers()
        // 合本一覧の census はアトラス側で独立に集めるため、現在巻の通知で
        // 全巻計画を再始動しない。単体一覧だけを実測値へ差し替える(cooViewer-oxr.64)。
        if epubCollectionContext == nil {
            refreshVisibleEPUBThumbnailOverlay()
        }
        // 実測が完了したら永続化する。次回同一メトリクスで開くとき注入して
        // オフスクリーン再実測を省き、N/M・ページバーを即出す
        if let url = epubBookURL, let record = view.exportCensus() {
            history.noteReflowCensus(
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
        guard acceptsEPUBCallback(from: view) else { return }
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
        guard let session = epubSession, acceptsEPUBCallback(from: view) else { return false }
        guard settings.pageTurnAnimation == .curl,
              let oldContent = oldPage.cgImage(forProposedRect: nil, context: nil,
                                               hints: nil),
              let newContent = newPage.cgImage(forProposedRect: nil, context: nil,
                                               hints: nil) else { return false }
        // 進行中のカールは畳む(連打時に残骸が重ならないように)
        for host in session.curlHosts { host.removeFromSuperview() }
        session.curlHosts.removeAll()

        // PageCurlOverlay は flipped 座標系(ReaderView)前提のため、
        // flipped なホストビューをページ領域に重ねてその layer で駆動する
        let host = EPUBCurlHostView(frame: pageRect)
        host.wantsLayer = true
        view.addSubview(host)
        session.curlHosts.append(host)

        let configuration = PageCurlOverlay.Configuration(
            bounds: CGRect(origin: .zero, size: pageRect.size),
            leafOnLeft: PageTurnAnimation.entersFromLeft(
                forward: forward, readsFromLeft: !view.isRTL),
            oldContent: oldContent,
            newContent: newContent)
        guard let overlay = PageCurlOverlay.makeAnimated(configuration) else {
            host.removeFromSuperview()
            session.curlHosts.removeAll { $0 === host }
            return false
        }
        host.layer?.addSublayer(overlay)
        Task { [weak session, weak host] in
            try? await Task.sleep(for: .seconds(configuration.duration + 0.05))
            guard let host else { return }
            host.removeFromSuperview()
            session?.curlHosts.removeAll { $0 === host }
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
