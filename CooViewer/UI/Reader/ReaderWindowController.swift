import AppKit
import SwiftUI

/// メインウインドウ。本のオープンフロー・表示更新・メニューアクションを担う。
/// 旧 Controller の表示/ナビゲーション部分に相当する(仕様書 §4.1-4.3)。
/// EN: Main window controller: opens books, drives display updates, handles menus.
@MainActor
final class ReaderWindowController: NSWindowController {
    private(set) var book: Book?
    private let readerView = ReaderView()
    private let pageBar = PageBarView()
    private let pageLabel = NSTextField(labelWithString: "")
    /// 開けなかった本の理由等をウインドウ中央に表示するラベル
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    /// オープン進捗 HUD(大書庫入りフォルダの統合など、開くのに時間が
    /// かかるときだけ中央に表示。設計書 §2.4 補)
    /// EN: Opening-progress HUD, shown only when the open takes noticeable time.
    private let openingProgressBox = NSView()
    private let openingProgressSpinner = NSProgressIndicator()
    private let openingProgressLabel = NSTextField(labelWithString: "")
    /// 進捗表示を所有しているオープン処理の世代(nil = 進行中なし)
    /// EN: Generation of the open flow that owns the HUD (nil = none in flight).
    private var openingFlowGeneration: Int?
    private var openingProgressName = ""
    private var openingProgressCounts: (done: Int, total: Int)?

    let settings = SettingsStore.shared
    var bindings = BindingConfiguration.load()

    /// 入力ディスパッチ(+Input.swift)からのビューアクセス
    var readerViewForInput: ReaderView { readerView }

    private var cursorHideTimer: Timer?
    /// アプリと同寿命のため解除しない(Swift 6 の nonisolated deinit 制約)
    /// EN: Never removed; this controller lives for the app's lifetime.
    private var settingsObserver: (any NSObjectProtocol)?
    var slideshowTimer: Timer?
    /// 2 本指スワイプ(ページ間スワイプ)の追跡状態(+Input.swift)
    var swipeTrackingActive = false
    var swipeTrackingDeltaX: CGFloat = 0
    var originalSizePanel: NSPanel?
    /// ファイル情報パネル(File > ファイル情報を表示)
    /// EN: File Info utility panel.
    var fileInfoPanel: NSPanel?
    /// 検証用: 最後に表示したファイル情報(--show-file-info のスナップショット。
    /// ヘッドレス実行ではパネルのレイヤーが描画されないため ImageRenderer で描く)
    /// EN: Last presented File Info details, for headless snapshot rendering.
    var fileInfoDebugDetails: PageFileInfo.Details?

    /// サムネイルオーバーレイ(ウインドウ内表示。仕様書 §4.8)
    let thumbnailOverlayModel = ThumbnailOverlayModel()
    var thumbnailHostingView: NSHostingView<ThumbnailOverlayView>?

    /// しおり編集シート(仕様書 §4.7.2)
    var bookmarkEditorWindow: NSWindow?

    /// 事前準備済みの「次の本」(巻末接近時にバックグラウンドでスプール開始)
    var preparedNextBook: (path: String, source: any BookSource)?
    var preparingNextBookPath: String?
    /// 同フォルダの本一覧のキャッシュ(+Library。巻末付近の毎ページ走査対策)
    /// EN: Sibling-book list cache (see +Library).
    var cachedSiblings: (parent: String, paths: [String], timestamp: Double)?

    /// ページバーホバーのサムネイルバブル(仕様書 §3.4)
    private let pageBarBubble = NSView()
    private let bubbleImageView = NSImageView()
    private let bubbleLabel = NSTextField(labelWithString: "")
    private var bubbleHoverIndex = -1

    /// 壊れページ用の実行時生成プレースホルダ(多言語対応。旧 broken.png の置換)
    private lazy var brokenPlaceholder: CGImage? = PlaceholderImage.make(
        text: String(localized: "This page could not be loaded."))

    /// 開けなかった本の理由(空の本の汎用メッセージと区別するため保持)
    private var lockedBookReason: String?

    /// 直近に表示したスプレッドのページ index 列(サムネイルの強調に使う)
    private(set) var lastSpreadIndices: [Int] = []
    /// アニメページの読み込み時実効キャップ(entry.id → px)。ウインドウ拡大
    /// での再デコード判定に使う(本切替時にリセット)
    /// EN: Effective decode cap per animated page id; drives grow-and-redecode.
    var loadedAnimationFrameCaps: [Int: Int] = [:]

    /// 開くフローの世代(連打時に古いフローが新しい本を上書きしないための番号)
    /// EN: Generation counter for openBookFlow, mirroring displayGeneration.
    private var openGeneration = 0
    /// 消費したスワイプの慣性イベントを飲み込むあいだ true(+Input.swift)
    /// EN: True while momentum events of a consumed swipe should be swallowed.
    var swipeConsumeMomentum = false

    /// 表示更新の世代。連打時に古い await 結果が新しい表示を上書きしないための番号
    private var displayGeneration = 0

    /// ページ番号/ページバーの位置・寸法制約(設定変更で組み直す。仕様書 §3.4)
    private var indicatorConstraints: [NSLayoutConstraint] = []
    private var indicatorLayoutSignature = ""
    /// 自動隠し(仕様書 §3.4: マウス移動で復活+2 秒で非表示)
    private var indicatorHideTimer: Timer?
    private var indicatorsTemporarilyVisible = true
    /// applySettings の一括化フラグ(defaults 連続書込対策)
    /// EN: Coalescing flag for applySettings bursts.
    private var applySettingsScheduled = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "cooViewer"
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 300, height: 200)
        window.setFrameAutosaveName("ReaderWindow")
        window.isReleasedWhenClosed = false  // 閉じても解放せず再表示できるように
        self.init(window: window)

        setUpContentViews(in: window)
        // 前回終了時と画面解像度が一致するときだけ autosave の位置を生かし、
        // 解像度が変わっていた(または初回起動の)場合は従来どおり中央へ。
        // サイズは setFrameAutosaveName がどちらの場合も復元する
        // EN: Keep the autosaved position only when the screen resolution
        // EN: matches the one recorded at last quit; otherwise center as before.
        if !Self.shouldRestoreWindowPosition() {
            window.center()
        }
        window.delegate = self
        readerView.delegate = self
        applySettings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 1 runloop 内の連続書込(スライダー操作・ウインドウ枠保存等)を
                // 1 回の適用にまとめる(バインディング再読込を含む全再適用のため)
                // EN: Coalesce bursts of defaults writes into one apply pass.
                guard let self, !self.applySettingsScheduled else { return }
                self.applySettingsScheduled = true
                DispatchQueue.main.async {
                    self.applySettingsScheduled = false
                    self.applySettings()
                }
            }
        }
    }

    /// 設定を即時反映する(設計書 §2.4: 旧 Cancel ロールバック方式からの仕様変更)
    /// EN: Apply settings immediately (no Cancel rollback), restyle indicators,
    /// EN: and refresh the open book when relevant values changed.
    func applySettings() {
        bindings = BindingConfiguration.load()  // 編集タブの変更を即時反映
        readerView.interpolation = settings.interpolation
        readerView.backgroundColor = settings.viewBackgroundColor
        // ページ番号/ページバーの見た目(仕様書 §3.4, §6.1)
        pageLabel.font = settings.pageNumFont
        pageLabel.textColor = settings.pageNumTextColor
        pageLabel.backgroundColor = settings.pageNumBackgroundColor
        pageLabel.layer?.borderColor = settings.pageNumBorderColor.cgColor
        pageLabel.layer?.borderWidth = 1
        pageBar.backgroundColor = settings.pageBarBackgroundColor
        pageBar.borderColor = settings.pageBarBorderColor
        pageBar.readColor = settings.pageBarReadColor
        layoutPageIndicators()
        updateIndicatorVisibility()
        // 表示モードは設定ウインドウ/メニューのどちらからでも変わる
        // (共に defaults "FitMode" 経由。ここが唯一の反映点)
        // EN: Fit mode changes arrive via the "FitMode" default from either
        // EN: the Settings window or the menu; this is the single apply point.
        if readerView.fitMode != settings.fitMode {
            readerView.fitMode = settings.fitMode
            refreshDisplayIfCapRaised()
        }
        if let book, book.pageCount > 0 {
            // 見開きしきい値・表紙単ページの変更は現表示を再判定する(仕様書 §6.3)
            // EN: Re-evaluate the on-screen spread when pairing inputs change.
            var pairingChanged = false
            if book.singleSetting != settings.singleSetting {
                book.singleSetting = settings.singleSetting
                pairingChanged = true
            }
            if book.coverSingleFirst != settings.spreadCoverSingle {
                book.coverSingleFirst = settings.spreadCoverSingle
                pairingChanged = true
            }
            if pairingChanged {
                // ページの区切り(偶奇)も先頭起点で組み直してから再表示する
                // (途中ページで切り替えても 3-4 → 2-3 のように即座に変わる)
                // EN: Realign the spread parity from page 0, then refresh, so
                // EN: mid-book toggles re-pair the on-screen spread too.
                Task {
                    await book.reanchorToLeadingPartition()
                    await refreshDisplay()
                }
            }
            applyAdvancedSettings(to: book)
        }
        readerView.singleSetting = settings.singleSetting
    }

    /// 位置(4 隅)と寸法の制約を設定から組み直す(仕様書 §6.1
    /// PageNumPosition/PageBarPosition: 0=左上/1=右上/2=左下/3=右下)。
    /// 同じ隅を指すときはページ番号とバーを縦に積む(旧既定の並び)
    /// EN: Rebuild the corner/size constraints for the page number and page bar;
    /// EN: when both share a corner they are stacked vertically.
    private func layoutPageIndicators() {
        guard let contentView = window?.contentView else { return }
        let numPosition = settings.pageNumPosition
        let barPosition = settings.pageBarPosition
        let barSize = settings.pageBarSize
        let signature = "\(numPosition)-\(barPosition)-\(barSize)"
        guard signature != indicatorLayoutSignature else { return }
        indicatorLayoutSignature = signature

        NSLayoutConstraint.deactivate(indicatorConstraints)
        var constraints = [
            pageBar.widthAnchor.constraint(equalToConstant: barSize.width),
            pageBar.heightAnchor.constraint(equalToConstant: barSize.height),
        ]
        func pinHorizontally(_ view: NSView, position: Int) {
            constraints.append(position % 2 == 0
                ? view.leadingAnchor.constraint(
                    equalTo: contentView.leadingAnchor, constant: 8)
                : view.trailingAnchor.constraint(
                    equalTo: contentView.trailingAnchor, constant: -8))
        }
        pinHorizontally(pageLabel, position: numPosition)
        pinHorizontally(pageBar, position: barPosition)
        let stacked = numPosition == barPosition
        if numPosition < 2 {
            constraints.append(pageLabel.topAnchor.constraint(
                equalTo: contentView.topAnchor, constant: 6))
        } else if stacked {
            constraints.append(pageLabel.bottomAnchor.constraint(
                equalTo: pageBar.topAnchor, constant: -4))
        } else {
            constraints.append(pageLabel.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -6))
        }
        if barPosition >= 2 {
            constraints.append(pageBar.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -6))
        } else if stacked {
            constraints.append(pageBar.topAnchor.constraint(
                equalTo: pageLabel.bottomAnchor, constant: 4))
        } else {
            constraints.append(pageBar.topAnchor.constraint(
                equalTo: contentView.topAnchor, constant: 6))
        }
        NSLayoutConstraint.activate(constraints)
        indicatorConstraints = constraints
    }

    /// ShowNumber/ShowPageBar と自動隠し状態から表示可否を決める
    /// (ページのない本では常に隠す)
    /// EN: Resolve indicator visibility from the master toggles, auto-hide state,
    /// EN: and whether the book has pages at all.
    private func updateIndicatorVisibility() {
        let hasPages = (book?.pageCount ?? 0) > 0
        pageLabel.isHidden = !hasPages || !settings.showNumber
            || (settings.pageNumAutoHide && !indicatorsTemporarilyVisible)
        pageBar.isHidden = !hasPages || !settings.showPageBar
            || (settings.pageBarAutoHide && !indicatorsTemporarilyVisible)
    }

    /// 自動隠し: マウス移動で表示を復活させ、2 秒後に隠す(仕様書 §3.4)
    /// EN: Auto-hide: reveal the indicators on mouse move, hide them 2 s later.
    func noteMouseMovedForIndicators() {
        guard settings.pageNumAutoHide || settings.pageBarAutoHide else { return }
        indicatorsTemporarilyVisible = true
        updateIndicatorVisibility()
        indicatorHideTimer?.invalidate()
        indicatorHideTimer = Timer.scheduledTimer(
            withTimeInterval: 2, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.indicatorsTemporarilyVisible = false
                self.updateIndicatorVisibility()
            }
        }
    }

    /// 実効メディアプロファイル: 自動調整の判定結果に、高度設定の明示値
    /// (スプール方針の三択)を上書きしたもの。整合規則は「明示は自動に勝つ」。
    /// 自動調整 OFF でも明示のスプール方針は効く
    /// EN: Effective media profile: probe result (or unknown) with explicit
    /// EN: Advanced-tab overrides applied. Explicit always beats automatic,
    /// EN: and the spool policy works even with adaptive tuning off.
    func effectiveMediaProfile(for url: URL) async -> MediaProfile {
        var profile = settings.adaptiveMediaTuning
            ? await MediaSpeedProbe.profile(for: url)
            : MediaProfile.unknown
        switch settings.archiveSpoolPolicy {
        case .automatic: break
        case .always: profile.spoolOverride = true
        case .never: profile.spoolOverride = false
        }
        return profile
    }

    /// 設定「高度」の値を本へ反映する(キャッシュ上限は開き直しで反映)。
    /// 高度設定 OFF のときの先読み深さは、置き場所の速度プロファイルの
    /// 既定値(遅い媒体ほど深く)を使う。ON なら明示値を尊重する
    /// EN: Push the Advanced-tab tunables into the open book. While the
    /// EN: Advanced switch is off, prefetch depth follows the media profile.
    private func applyAdvancedSettings(to book: Book) {
        if settings.advancedSettingsEnabled {
            book.prefetchAhead = settings.prefetchAheadCount
            book.prefetchBehind = settings.prefetchBehindCount
        } else {
            book.prefetchAhead = book.mediaProfile.defaultPrefetchAhead
            book.prefetchBehind = book.mediaProfile.defaultPrefetchBehind
        }
        // キャップは raise 時のクリアを通して反映(設定の上限引き上げにも追従)
        // EN: Route through the raise-aware update (covers Settings changes).
        refreshDisplayIfCapRaised()
    }

    /// いまのウインドウ実寸・原寸表示設定から適切なデコード上限を求める
    /// EN: Decode cap for the current window pixels and fit mode.
    private func currentDisplayPixelCap() -> Int {
        let scale = window?.backingScaleFactor ?? 2
        let size = window?.contentView?.bounds.size ?? .zero
        let edge = Int((max(size.width, size.height) * scale).rounded(.up))
        // ウインドウに収まらない描画をするモードは従来のユーザー上限のまま
        // EN: Modes rendering beyond the window keep the user cap.
        let usesUserCap = switch readerView.fitMode {
        case .noScale, .fitWidth, .fitWidthDivide: true
        default: false
        }
        return DisplayCapPolicy.cap(
            windowLongEdgePixels: edge,
            userCap: settings.displayPixelCap,
            usesUserCap: usesUserCap)
    }

    /// キャップの再評価。上がった(ウインドウ拡大・原寸表示切替)なら
    /// 低解像度キャッシュを捨てて現スプレッドを再デコードする
    /// EN: Re-evaluate the cap; a raise drops the low-res cache and refreshes.
    func updateDisplayPixelCapIfNeeded() async {
        guard let book else { return }
        _ = await book.updateDisplayPixelCap(currentDisplayPixelCap())
    }

    private func setUpContentViews(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        readerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(readerView)

        // ページバー/ページ番号の位置・寸法は layoutPageIndicators が設定から組む
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = .white
        pageLabel.backgroundColor = .black.withAlphaComponent(0.8)
        pageLabel.drawsBackground = true
        pageLabel.wantsLayer = true
        pageLabel.layer?.cornerRadius = 4
        pageLabel.layer?.masksToBounds = true
        pageLabel.isHidden = true
        contentView.addSubview(pageLabel)

        pageBar.translatesAutoresizingMaskIntoConstraints = false
        pageBar.isHidden = true
        contentView.addSubview(pageBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .white
        statusLabel.isHidden = true
        contentView.addSubview(statusLabel)

        openingProgressBox.translatesAutoresizingMaskIntoConstraints = false
        openingProgressBox.wantsLayer = true
        openingProgressBox.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(0.78).cgColor
        openingProgressBox.layer?.cornerRadius = 10
        openingProgressBox.isHidden = true
        openingProgressSpinner.translatesAutoresizingMaskIntoConstraints = false
        openingProgressSpinner.style = .spinning
        openingProgressSpinner.controlSize = .small
        openingProgressSpinner.isIndeterminate = true
        openingProgressSpinner.appearance = NSAppearance(named: .darkAqua)
        openingProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        openingProgressLabel.font = .monospacedDigitSystemFont(ofSize: 13,
                                                               weight: .regular)
        openingProgressLabel.textColor = .white
        openingProgressLabel.lineBreakMode = .byTruncatingMiddle
        openingProgressBox.addSubview(openingProgressSpinner)
        openingProgressBox.addSubview(openingProgressLabel)
        contentView.addSubview(openingProgressBox)

        NSLayoutConstraint.activate([
            readerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            readerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            readerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            openingProgressBox.centerXAnchor.constraint(
                equalTo: contentView.centerXAnchor),
            openingProgressBox.centerYAnchor.constraint(
                equalTo: contentView.centerYAnchor),
            openingProgressBox.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            openingProgressSpinner.leadingAnchor.constraint(
                equalTo: openingProgressBox.leadingAnchor, constant: 14),
            openingProgressSpinner.centerYAnchor.constraint(
                equalTo: openingProgressBox.centerYAnchor),
            openingProgressLabel.leadingAnchor.constraint(
                equalTo: openingProgressSpinner.trailingAnchor, constant: 8),
            openingProgressLabel.trailingAnchor.constraint(
                equalTo: openingProgressBox.trailingAnchor, constant: -16),
            openingProgressLabel.topAnchor.constraint(
                equalTo: openingProgressBox.topAnchor, constant: 12),
            openingProgressLabel.bottomAnchor.constraint(
                equalTo: openingProgressBox.bottomAnchor, constant: -12),
        ])

        // ホバーバブル(フレームベース配置。ホバー中のみ表示)
        pageBarBubble.wantsLayer = true
        pageBarBubble.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        pageBarBubble.layer?.cornerRadius = 8
        pageBarBubble.frame = NSRect(x: 0, y: 0, width: 148, height: 190)
        pageBarBubble.isHidden = true
        bubbleImageView.imageScaling = .scaleProportionallyUpOrDown
        bubbleImageView.frame = NSRect(x: 8, y: 28, width: 132, height: 154)
        pageBarBubble.addSubview(bubbleImageView)
        bubbleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        bubbleLabel.textColor = .white
        bubbleLabel.alignment = .center
        bubbleLabel.frame = NSRect(x: 0, y: 6, width: 148, height: 18)
        pageBarBubble.addSubview(bubbleLabel)
        contentView.addSubview(pageBarBubble)

        // サムネイルオーバーレイ(最前面。非表示で開始)
        let overlay = NSHostingView(
            rootView: ThumbnailOverlayView(model: thumbnailOverlayModel))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        thumbnailHostingView = overlay

        pageBar.onHover = { [weak self] info in
            self?.handlePageBarHover(info)
        }
        pageBar.onJump = { [weak self] fraction in
            guard let self, let book = self.book else { return }
            if book.goToPercent(fraction) == .moved {
                Task { await self.refreshDisplay() }
            }
        }
    }

    // MARK: - 本を開く

    /// URL から本を開く。単一画像は親フォルダに読み替える(仕様書 §4.1.2 手順 2)。
    /// EN: Open a book; a single image file opens its parent folder at that page.
    /// allowCollectionDrill: 画像ゼロのコレクションフォルダで中の本へ自動で
    /// 潜るか(設計書 §2.4)。Finder/ダイアログ等の明示オープンのみ true。
    /// 次/前の本ナビゲーションは false — フォルダ自身に着地して階層を保つ
    /// (潜ると以後の兄弟走査が別の深さで行われ、元の階層に戻れなくなる)
    /// EN: allowCollectionDrill is true only for explicit opens; next/previous
    /// EN: navigation lands on the folder itself so the sibling scan keeps
    /// EN: operating at the same depth of the hierarchy.
    func openBook(at url: URL, atPage page: Int? = nil, atLastPage: Bool = false,
                  allowCollectionDrill: Bool = true) {
        Task {
            await openBookFlow(url: url, atPage: page, atLastPage: atLastPage,
                               allowCollectionDrill: allowCollectionDrill)
        }
    }

    private func openBookFlow(url: URL, atPage: Int?, atLastPage: Bool,
                              allowCollectionDrill: Bool = true,
                              autoOpenDepth: Int = 0) async {
        // ウインドウが閉じられた後の「最近使った本」「関連付けから開く」でも
        // 必ず再表示する(仕様書 §4.1.2 手順 1: window 前面化)
        showWindow(nil)
        // 連打時は最後に要求された本だけを確定する(古いフローの巻き戻り防止)
        // EN: Open-generation guard: only the newest open request may commit.
        openGeneration += 1
        let generation = openGeneration

        var bookURL = url
        var initialPageURL: URL?

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            // ドリルダウンから引き継いだ HUD が残らないように畳む
            // EN: Fold up a HUD inherited from a drill step; no successor follows.
            endAnyOpeningProgress()
            return
        }
        if !isDirectory.boolValue, !SupportedTypes.isBookFile(url),
           SupportedTypes.isImageFile(url.lastPathComponent) {
            bookURL = url.deletingLastPathComponent()
            initialPageURL = url
        }

        // ドロップ/関連付けで開いた画像が**現在の本のページ**なら、本を
        // 開き直さずそのページへジャンプする(大量の書庫を含むフォルダの
        // 統合を再構築しない)。サブフォルダ読み込みの下層画像も実ファイル
        // URL の照合で拾う。一覧に無い(=開いた後に追加された)場合は
        // 従来どおり開き直され、結果として一覧も更新される
        // EN: If the dropped image is a page of the CURRENT book, just jump —
        // EN: never rebuild a large folder merge. Files not in the listing
        // EN: (added after opening) fall through to the normal reopen path.
        if let initialPageURL, let book {
            let targetPath = initialPageURL.standardizedFileURL.path
            if let index = book.entries.firstIndex(where: {
                $0.fileURL?.standardizedFileURL.path == targetPath
            }) {
                book.goTo(index: index)
                await refreshDisplay()
                return
            }
        }

        // 時間のかかるオープン(大書庫入りフォルダの統合等)の進捗表示を武装
        // EN: Arm the opening-progress HUD for slow opens.
        beginOpeningProgress(generation: generation, name: bookURL.lastPathComponent)

        do {
            let source: any BookSource
            if let prepared = preparedNextBook, prepared.path == bookURL.path {
                preparedNextBook = nil
                if await prepared.source.hasSkippedLockedContent() {
                    // バックグラウンド準備(パスワード UI なし)がロック済みの
                    // ネスト書庫を外して組んでいた場合は使い回さず、通常経路で
                    // 開き直してダイアログを出す(ページの黙落ち防止)
                    // EN: The prepared source silently dropped locked children;
                    // EN: rebuild through the interactive path so prompts appear.
                    source = try await BookSourceFactory.make(
                        for: bookURL, readSubFolders: settings.readSubFolder,
                        nestedPasswordProvider: nestedPasswordProvider())
                } else {
                    // 事前スプール済みの本を再利用(切替を待ちなしに。設計書 §5)。
                    // まだ組んでいない場合に備えてパスワード UI を後付けする
                    // EN: Reuse the prepared source; attach the password UI in
                    // EN: case assembly has not run yet.
                    await prepared.source.attachNestedPasswordProvider(
                        nestedPasswordProvider())
                    source = prepared.source
                }
            } else {
                source = try await BookSourceFactory.make(
                    for: bookURL, readSubFolders: settings.readSubFolder,
                    nestedPasswordProvider: nestedPasswordProvider())
            }
            switch await unlock(source) {
            case .unlocked:
                break
            case .cancelled:
                endOpeningProgress(generation: generation)
                presentLockedPlaceholder(
                    source: source,
                    reason: String(localized: "Password entry was canceled."))
                return
            case .attemptsExceeded:
                endOpeningProgress(generation: generation)
                presentLockedPlaceholder(
                    source: source,
                    reason: String(localized: "Too many failed password attempts."))
                return
            }

            guard generation == openGeneration else { return }

            // 統合ソースの組み立て(全書庫の一覧取得)の進捗を HUD へ流す
            // EN: Route merged-source assembly progress into the HUD.
            await source.setAssemblyProgressHandler { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.noteOpeningProgress(generation: generation,
                                              done: done, total: total)
                }
            }

            // 旧本の後始末(仕様書 §4.1.2 手順 4)
            stopSlideshow()
            self.book?.cancelPrefetch()  // 旧本のバックグラウンド I/O を止める
            saveCurrentBookState()

            // 置き場所の速度判定は本の展開と並行に走らせる(設計書 キャッシュ節)
            // EN: Probe the volume speed concurrently with opening the book.
            let probeURL = bookURL
            async let mediaProfileTask = effectiveMediaProfile(for: probeURL)
            let book = try await Book.open(source: source, sortMode: settings.sortMode,
                                           cacheByteLimit: settings.pageCacheByteLimit)
            let mediaProfile = await mediaProfileTask
            guard generation == openGeneration else { return }
            // 画像ゼロのフォルダ(コレクションフォルダ)は中の最初の本を開く
            // (旧実装は開くのを拒否 §4.1.2 手順 3。設計書 §2.4 の仕様変更)。
            // ただしパスワード入力のキャンセル等でネスト書庫を外した結果の
            // 空ならそのまま(自動で開き直すと同じダイアログが即再表示される)
            // EN: A folder with no images but containing books opens its first
            // EN: inner book — unless it is empty because the user cancelled a
            // EN: nested password prompt (auto-open would re-prompt instantly).
            // 統合ソース(フォルダ内書庫/PDF の合本)が 0 ページなのは組み立て
            // 失敗(壊れ書庫の黙殺 §4.17 等)であり、ドリルダウンすると中の
            // 書庫を「単体の本」として開いてしまい階層がずれる。ドリルは
            // 純粋なコレクション(直下も配下も画像・書庫なし=FolderSource)のみ
            // EN: A 0-page merged source means assembly failed; drilling would
            // EN: open an inner archive standalone at the wrong depth. Only
            // EN: drill into pure collections (plain FolderSource, no books).
            if book.pageCount == 0, allowCollectionDrill, autoOpenDepth < 4,
               !(source is NestedFolderSource),
               await !source.hasSkippedLockedContent() {
                // 候補選定は再帰走査を含むためメインスレッドから外す
                // (NAS/HDD でのビーチボール防止。走査があるので非同期)
                // EN: The candidate scan recurses into subfolders; run it off
                // EN: the main thread so slow volumes cannot beachball the UI.
                let scanURL = bookURL
                let inner = await Task.detached(priority: .userInitiated) {
                    Self.innerBook(in: scanURL)
                }.value
                guard generation == openGeneration else { return }
                if let inner {
                    // HUD は畳まない: 再帰側の beginOpeningProgress が
                    // 新しい世代で引き継ぐ(走査〜内側の本のオープンまで連続表示)
                    // EN: Keep the HUD up; the recursive open re-arms it.
                    await openBookFlow(url: inner, atPage: nil, atLastPage: atLastPage,
                                       allowCollectionDrill: true,
                                       autoOpenDepth: autoOpenDepth + 1)
                    return
                }
            }
            endOpeningProgress(generation: generation)
            book.readMode = settings.readMode
            book.singleSetting = settings.singleSetting
            book.coverSingleFirst = settings.spreadCoverSingle
            book.mediaProfile = mediaProfile
            await source.applyMediaProfile(mediaProfile)
            applyAdvancedSettings(to: book)
            self.book = book
            loadedAnimationFrameCaps.removeAll()  // id は本ごとの名前空間
            // 本ごとのリサンプルキャッシュ名前空間(本切替時の取り違え防止)
            // EN: Namespace the resample cache by book identity.
            readerView.resampleKeyPrefix = book.cacheKey

            // 書庫のローカルスプール等を開始(パスワード解除後。設計書 キャッシュ節)
            await source.beginBackgroundPreparation(
                spoolSizeLimit: settings.archiveSpoolSizeLimit)

            let skipPageRestore = initialPageURL != nil || atPage != nil || atLastPage
            await restoreBookState(for: book, skipPageRestore: skipPageRestore)

            // 単一画像から開いた場合: まず実ファイル URL、次に名前で探す
            // (サブフォルダ読み込みで同名ファイルがあっても正しいページへ)
            // EN: Prefer matching by file URL; name is only the fallback.
            if let initialPageURL {
                let targetPath = initialPageURL.standardizedFileURL.path
                if let index = book.entries.firstIndex(where: {
                    $0.fileURL?.standardizedFileURL.path == targetPath
                }) ?? book.entries.firstIndex(where: {
                    $0.name == initialPageURL.lastPathComponent
                }) {
                    book.goTo(index: index)
                }
            } else if let atPage {
                book.goTo(index: atPage)
            } else if atLastPage {
                await book.goToLast()
            }
            window?.title = book.displayName
            lockedBookReason = nil
            statusLabel.isHidden = true
            updateIndicatorVisibility()
            await refreshDisplay()
            // サムネイル表示中に本が切り替わったら一覧も新しい本で組み直す。
            // 非表示中はスナップショットを空にして旧本のソース保持を解く
            // (書庫のスプール/ネスト展開の一時ファイル回収のため)
            // EN: Rebuild the visible overlay for the new book; when hidden,
            // EN: clear the snapshot so the old source's temp files get reclaimed.
            if isThumbnailOverlayVisible, book.pageCount > 0 {
                presentThumbnailOverlay(for: book)
            } else {
                hideThumbnailOverlay()
                thumbnailOverlayModel.clear()
            }
        } catch {
            // 旧実装のエラー黙殺方針(仕様書 §4.17): ダイアログは出さない
            NSSound.beep()
            endOpeningProgress(generation: generation)
        }
    }

    /// 開けなかった本(パスワードのキャンセル/試行超過)を「現在の本」として
    /// 空の状態で表示する。これによりページ送りや「次の本」でこの本を
    /// 飛ばして先へ進める。履歴・設定には記録しない。
    /// EN: Show a locked/unopenable book as an empty placeholder so navigation
    /// EN: can still skip past it; nothing is recorded to history.
    private func presentLockedPlaceholder(source: any BookSource, reason: String) {
        stopSlideshow()
        saveCurrentBookState()
        let placeholder = Book(source: source, entries: [])
        book = placeholder
        hideThumbnailOverlay()
        thumbnailOverlayModel.clear()
        lockedBookReason = reason
        window?.title = placeholder.displayName
        readerView.setPages([], readsFromLeft: false)
        showBookStatusMessage(reason)
    }

    // MARK: - 終了処理(§7.7 の保存漏れを塞ぐ)

    /// キャップが上がる変化(ウインドウ拡大・原寸表示切替)なら再デコード
    /// EN: Redecode when the change raised the cap (bigger window, noScale).
    func refreshDisplayIfCapRaised() {
        Task { [weak self] in
            guard let self, let book = self.book else { return }
            if await book.updateDisplayPixelCap(self.currentDisplayPixelCap()) {
                await self.refreshDisplay()  // 再表示がアニメも再デコードする
            } else {
                // バケット内のリサイズでもアニメの表示枠は伸び得る
                // EN: Same-bucket resizes can still outgrow animation frames.
                self.restartAnimationsIfFrameGrew()
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        refreshDisplayIfCapRaised()
    }

    func windowDidResize(_ notification: Notification) {
        // ズーム等の非ライブリサイズ(ライブ中は終了時にまとめて処理)
        // EN: Non-live resizes such as zoom; live resizes handled at end.
        guard window?.inLiveResize == false else { return }
        refreshDisplayIfCapRaised()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        refreshDisplayIfCapRaised()  // 別解像度のディスプレイへ移動した場合
    }

    func windowWillClose(_ notification: Notification) {
        stopSlideshow()
        saveCurrentBookState()
        saveWindowScreenSize()
    }

    func saveStateBeforeTermination() {
        saveCurrentBookState()
        saveWindowScreenSize()
    }

    // MARK: - ウインドウ位置の復元(解像度一致時のみ)

    /// ウインドウがある画面の解像度(frame サイズ)を保存する。
    /// 起動時にこの値と一致する画面があれば autosave の位置を復元する
    /// EN: Record the resolution of the window's screen at quit/close; launch
    /// EN: restores the autosaved position only when a screen still matches.
    private func saveWindowScreenSize() {
        guard let size = window?.screen?.frame.size else { return }
        UserDefaults.standard.set(NSStringFromSize(size),
                                  forKey: "ReaderWindowScreenSize")
    }

    /// 保存済みフレームがあり、かつ終了時の画面解像度が現在のいずれかの
    /// 画面と一致するときだけ位置を復元する(不一致・初回は中央配置)
    /// EN: True when an autosaved frame exists and the recorded resolution
    /// EN: matches one of the attached screens.
    static func shouldRestoreWindowPosition() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "NSWindow Frame ReaderWindow") != nil
        else { return false }
        return shouldRestorePosition(
            savedScreenSize: defaults.string(forKey: "ReaderWindowScreenSize"),
            screenSizes: NSScreen.screens.map { $0.frame.size })
    }

    /// 純粋判定部(テスト用に分離): 保存解像度が候補のいずれかと一致するか
    /// EN: Pure comparison split out for unit tests.
    nonisolated static func shouldRestorePosition(
        savedScreenSize: String?, screenSizes: [CGSize]) -> Bool {
        guard let savedScreenSize else { return false }
        let size = NSSizeFromString(savedScreenSize)
        guard size.width > 0, size.height > 0 else { return false }
        return screenSizes.contains(size)
    }

    private enum UnlockResult {
        case unlocked
        case cancelled
        case attemptsExceeded
    }

    /// ネスト書庫/PDF 用のパスワード入力コールバック(仕様書 §4.1.3 のネスト版)。
    /// 本を開くフロー(entries() 構築)中に呼ばれ、MainActor でダイアログを出す。
    /// EN: Password callback for nested books; hops to MainActor and shows a
    /// EN: dialog while the open flow is assembling entries().
    func nestedPasswordProvider() -> NestedPasswordProvider {
        { name, attempt in
            await MainActor.run {
                // UI 検証用の隠しフック/XCTest 実行(モーダルを出さずキャンセル扱い)
                if ProcessInfo.processInfo.environment[
                    "COOVIEWER_UI_TEST_CANCEL_PASSWORD"] != nil || AutomatedRun.isXCTest {
                    return nil
                }
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "“\(name)” in this book is password-protected.")
                // 2 回目以降は誤入力を伝える(外側書庫のダイアログと同じ書式)
                // EN: Retries surface the wrong-password state, like the outer dialog.
                alert.informativeText = attempt == 1
                    ? String(localized: "Enter the password to include it.")
                    : String(localized: "Wrong password. \(4 - attempt) attempts left.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.addButton(withTitle: String(localized: "Skip"))
                let field = NSSecureTextField(
                    frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                alert.accessoryView = field
                alert.window.initialFirstResponder = field
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                return field.stringValue
            }
        }
    }

    /// パスワード書庫のロック解除(仕様書 §4.1.3)。
    /// 旧実装の「正解かキャンセルまで無限に再表示」をやめ、3 回で打ち切る。
    /// EN: Password prompt with a 3-attempt limit (the legacy app retried forever).
    private func unlock(_ source: any BookSource) async -> UnlockResult {
        // UI 検証用の隠しフック/XCTest 実行(モーダルを出さずキャンセル扱いにする)
        if ProcessInfo.processInfo.environment["COOVIEWER_UI_TEST_CANCEL_PASSWORD"] != nil
            || AutomatedRun.isXCTest,
           await source.isEncrypted() {
            return .cancelled
        }
        let maxAttempts = 3
        var attemptsLeft = maxAttempts
        while await source.isEncrypted() {
            guard attemptsLeft > 0 else { return .attemptsExceeded }
            let alert = NSAlert()
            alert.messageText = String(localized: "This archive is password-protected.")
            alert.informativeText = attemptsLeft == maxAttempts
                ? String(localized: "Enter the password to open it.")
                : String(localized: "Wrong password. \(attemptsLeft) attempts left.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
            if await source.checkAndSetPassword(field.stringValue) {
                return .unlocked
            }
            attemptsLeft -= 1
        }
        return .unlocked
    }

    /// 画像ゼロのフォルダ内にある「本」(名前順の最初)。フォルダ以外は nil。
    /// サブフォルダは中のどこかに画像か本があるものだけを候補にする
    /// (.app 等のパッケージや無関係なディレクトリへ潜って、行き止まりの
    /// 深い階層に置き去りになるのを防ぐ)
    /// EN: First book-like item inside an image-less folder. Subfolders count
    /// EN: only when they actually lead to book content; packages (.app etc.)
    /// EN: and dead-end directories are skipped so the drill never strands the
    /// EN: reader deep inside an unrelated tree.
    nonisolated static func innerBook(in url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return nil }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { url.appendingPathComponent($0) }
            .first { candidate in
                let values = try? candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isPackageKey])
                if values?.isPackage == true { return false }
                if values?.isDirectory == true {
                    return folderLeadsToBookContent(at: candidate)
                }
                return SupportedTypes.isBookFile(candidate)
            }
    }

    /// フォルダのどこかに画像か本(書庫/PDF)があるか。最初の 1 件で打ち切る。
    /// 巨大ツリーは 2000 項目で走査をやめ **true**(=候補として許容)を返す:
    /// ここでの誤判定はドリル先の選択を左右するため、「大きすぎて判定不能」は
    /// 実際に開いてみる側へ倒す(false だと本のある巨大フォルダを不当に飛ばす)
    /// EN: Whether the folder eventually contains an image or a book file;
    /// EN: stops at the first hit. Gives up after 2000 items and returns TRUE —
    /// EN: an unscannable-huge folder must stay a candidate (skipping it would
    /// EN: wrongly reject legitimate large series folders); the real open decides.
    nonisolated static func folderLeadsToBookContent(at url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > 2000 { return true }
            let isDirectory = (try? fileURL.resourceValues(
                forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }
            if SupportedTypes.isImageFile(fileURL.lastPathComponent)
                || SupportedTypes.isBookFile(fileURL) {
                return true
            }
        }
        return false
    }

    // MARK: - 表示更新

    func refreshDisplay() async {
        guard let book else { return }
        // ウインドウ実寸に応じたデコード上限の自己修復(拡大時は再デコード)
        // EN: Self-healing decode cap on every display pass.
        _ = await book.updateDisplayPixelCap(currentDisplayPixelCap())
        displayGeneration += 1
        let generation = displayGeneration
        let spread = await book.currentSpread()
        // 連打等でより新しい表示更新が始まっていたら、この結果は捨てる
        // EN: Drop this result if a newer refresh started while we awaited.
        guard generation == displayGeneration, book === self.book else { return }

        if spread.indices.isEmpty {
            // ページのない本: 理由をウインドウ中央に表示する
            // (旧 empty.png 方式 §4.17 を多言語メッセージに置換)
            readerView.setPages([], readsFromLeft: book.readMode.readsFromLeft)
            let reason = lockedBookReason
                ?? String(localized: "This book contains no displayable images.")
            showBookStatusMessage(reason)
            updatePageIndicators(spread: spread)
            // サブフォルダに画像があるならヒントを添える(走査があるので非同期)
            if lockedBookReason == nil, !settings.readSubFolder,
               book.source is FolderSource {
                let url = book.source.url
                Task { [weak self, weak book] in
                    let found = await Task.detached {
                        FolderSource.subfoldersContainImages(at: url)
                    }.value
                    guard found, let self, let book, book === self.book,
                          book.pageCount == 0 else { return }
                    self.showBookStatusMessage(reason + "\n" + String(localized:
                        "Subfolders contain images. Turn on “Read subfolders” in Settings to include them."))
                }
            }
            return
        }
        statusLabel.isHidden = true
        // 壊れページは理由入りプレースホルダで表示(ページ数は保つ。§4.17)
        let images = spread.images.map { $0 ?? brokenPlaceholder }.compactMap(\.self)
        // 非同期の合間に本が入れ替わった場合に備えて範囲を検証する(範囲外は
        // インデックスをそのままキーにする。クラッシュ報告 Index out of range 対策)
        let ids = spread.indices.map { index in
            book.entries.indices.contains(index) ? book.entries[index].id : index
        }
        readerView.setPages(images, ids: ids,
                            readsFromLeft: book.readMode.readsFromLeft)
        readerView.window?.makeFirstResponder(readerView)
        updatePageIndicators(spread: spread)
        if readerView.isLoupeEnabled {
            requestLoupeHighResolution()
        }
        maybePrepareNextBook()
        startAnimationsIfNeeded(spread: spread)
        // サムネイル表示中は本の変化に追従する(%ジャンプ・しおり移動のほか、
        // ソート変更等でエントリ列が変わった場合は一覧を組み直す)
        // EN: Keep the visible overlay in sync: follow page jumps and rebuild
        // EN: the grid when the entry order changed (sort / shuffle).
        lastSpreadIndices = spread.indices
        if isThumbnailOverlayVisible {
            thumbnailOverlayModel.follow(book: book, displayedIndices: spread.indices)
        }
    }

    /// アニメーション画像(GIF/WebP 等)の再生(設定でオフ可。設計書 §5)
    /// EN: Start GIF/WebP-style playback for animated pages in the spread.
    private func startAnimationsIfNeeded(spread: Book.Spread) {
        guard settings.playAnimatedImages, let book else { return }
        let animatable: Set<String> = ["gif", "png", "apng", "webp", "heics", "avif", "avifs"]
        for (position, index) in spread.indices.enumerated() {
            guard book.entries.indices.contains(index) else { continue }
            let entry = book.entries[index]
            // 一度「静止画」と判定したページは再判定しない(PNG が大半の本で
            // 表示のたびに生データを読み直す無駄の防止)
            // EN: Skip pages already probed static; without this every PNG
            // EN: page re-reads its raw bytes on every redisplay.
            guard !book.probedStaticAnimationIDs.contains(entry.id) else { continue }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            guard animatable.contains(ext) else { continue }
            // デコード(最大 120 フレーム)はメインアクターの外で行う。
            // 解像度はページレイヤの実ピクセルに合わせる(全フレーム常駐のため、
            // 一律 2048px より大幅に省メモリ)
            // EN: Frame decoding runs off the main actor, capped at the page
            // EN: layer's actual pixel size (all frames stay resident).
            let source = book.source
            let frameCap: Int? = readerViewForInput.pageFramePixelSize(at: position)
                .map { Int(max($0.width, $0.height).rounded(.up)) }
                .flatMap { $0 > 0 ? $0 : nil }
            // 実効キャップ(AnimatedImage 側の上限 2048 を反映)を記録し、
            // ウインドウ拡大時の再デコード要否判定(下記)に使う
            // EN: Record the effective cap for the grow-and-redecode check.
            loadedAnimationFrameCaps[entry.id] = min(frameCap ?? 2048, 2048)
            Task.detached(priority: .userInitiated) { [weak self, weak book] in
                guard let data = await source.imageData(for: entry) else { return }
                let animation = AnimatedImage.load(from: data, maxPixelSize: frameCap)
                await MainActor.run {
                    guard let self, let book, book === self.book else { return }
                    guard let animation else {
                        book.probedStaticAnimationIDs.insert(entry.id)
                        return
                    }
                    self.readerViewForInput.applyAnimation(
                        frames: animation.frames, delays: animation.delays,
                        forPageAt: position, id: entry.id)
                }
            }
        }
    }

    /// ウインドウ拡大でアニメページの表示枠が読み込み時キャップを超えたら
    /// 再デコードする。表示キャップのバケット(1024 刻み・最低 2048)が
    /// 変わらないリサイズでは refreshDisplay が走らないため、ここで補う
    /// EN: Re-decode animated pages when the frame outgrew the loaded cap —
    /// EN: needed because same-bucket resizes never trigger refreshDisplay.
    func restartAnimationsIfFrameGrew() {
        guard settings.playAnimatedImages, let book else { return }
        for (position, index) in lastSpreadIndices.enumerated() {
            guard book.entries.indices.contains(index) else { continue }
            let id = book.entries[index].id
            guard let loaded = loadedAnimationFrameCaps[id], loaded < 2048,
                  let size = readerViewForInput.pageFramePixelSize(at: position)
            else { continue }
            let needed = min(Int(max(size.width, size.height).rounded(.up)), 2048)
            // 1.25 倍以上の拡大でだけ再デコード(微小リサイズの連発を防ぐ)
            // EN: Only re-decode on >=1.25x growth to avoid churn.
            if needed > loaded + loaded / 4 {
                startAnimationsIfNeeded(
                    spread: .init(indices: lastSpreadIndices, images: []))
                return
            }
        }
    }

    /// ページバーホバー: ページ番号+サムネイルの吹き出し(仕様書 §3.4)
    /// EN: Position the hover bubble and lazily load its page thumbnail.
    private func handlePageBarHover(_ info: (x: CGFloat, fraction: Double)?) {
        guard let info, let book, book.pageCount > 0,
              let contentView = window?.contentView else {
            pageBarBubble.isHidden = true
            bubbleHoverIndex = -1
            return
        }
        let index = min(book.pageCount - 1,
                        max(0, Int(info.fraction * Double(book.pageCount))))
        // サムネイル無しのときは番号だけの小さなバブルにする(§6.1 PageBarShowThumbnail)
        let showsThumbnail = settings.pageBarShowThumbnail
        bubbleImageView.isHidden = !showsThumbnail
        pageBarBubble.setFrameSize(showsThumbnail
            ? NSSize(width: 148, height: 190) : NSSize(width: 96, height: 30))
        bubbleLabel.frame = NSRect(x: 0, y: 6, width: pageBarBubble.frame.width, height: 18)
        let barFrame = pageBar.frame
        var x = barFrame.minX + info.x - pageBarBubble.frame.width / 2
        x = min(max(8, x), contentView.bounds.width - pageBarBubble.frame.width - 8)
        // バーが画面下半分なら上側へ出す(下配置設定への対応)
        let bubbleY = barFrame.midY < contentView.bounds.midY
            ? barFrame.maxY + 6
            : barFrame.minY - pageBarBubble.frame.height - 6
        pageBarBubble.setFrameOrigin(NSPoint(x: x, y: bubbleY))
        bubbleLabel.stringValue = "\(index + 1)/\(book.pageCount)"
        pageBarBubble.isHidden = false
        guard index != bubbleHoverIndex else { return }
        bubbleHoverIndex = index
        bubbleImageView.image = nil
        guard showsThumbnail, book.entries.indices.contains(index) else { return }
        let entry = book.entries[index]
        Task { [weak self] in
            guard let self else { return }
            if let thumbnail = await ThumbnailCache.shared.thumbnail(
                for: entry, in: book.source, bookKey: book.cacheKey),
               self.bubbleHoverIndex == index, book === self.book {
                self.bubbleImageView.image = NSImage(
                    cgImage: thumbnail,
                    size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
        }
    }

    // MARK: - オープン進捗 HUD

    /// オープン処理の開始を記録し、0.35 秒経っても終わらなければ HUD を出す
    /// (即終わる本でのちらつき防止)。大書庫入りフォルダの統合は全書庫の
    /// 一覧取得を伴い数十秒かかり得るため、無反応に見えるのを防ぐ
    /// EN: Arm the opening HUD; it appears only if the open outlives 0.35 s,
    /// EN: so fast opens never flicker. Folder merges (listing every archive)
    /// EN: can take tens of seconds and looked unresponsive without this.
    func beginOpeningProgress(generation: Int, name: String) {
        openingFlowGeneration = generation
        openingProgressName = name
        openingProgressCounts = nil
        // ドリルダウンからの引き継ぎで既に表示中なら名前だけ差し替える
        // EN: If inherited from a drill step the HUD is already up; retitle it.
        if !openingProgressBox.isHidden {
            updateOpeningProgressText()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.openingFlowGeneration == generation,
                  self.openingProgressBox.isHidden else { return }
            self.revealOpeningProgress()
        }
    }

    /// 統合ソースの組み立て進捗(完了書庫数/総数)を反映する
    /// EN: Update the HUD with assembly progress (books done / total).
    func noteOpeningProgress(generation: Int, done: Int, total: Int) {
        guard openingFlowGeneration == generation else { return }
        openingProgressCounts = (done, total)
        if !openingProgressBox.isHidden {
            updateOpeningProgressText()
        }
    }

    /// オープン処理の終了(成功・失敗・ドリル前とも)。HUD を畳む
    /// EN: The open flow ended (success, failure or before drilling); hide the HUD.
    func endOpeningProgress(generation: Int) {
        guard openingFlowGeneration == generation else { return }
        endAnyOpeningProgress()
    }

    /// 世代を問わず HUD を畳む(ドリル先の消失など、引き継ぎ先のない失敗用)
    /// EN: Unconditionally hide the HUD (failures with no successor flow).
    private func endAnyOpeningProgress() {
        openingFlowGeneration = nil
        openingProgressBox.isHidden = true
        openingProgressSpinner.stopAnimation(nil)
    }

    private func revealOpeningProgress() {
        updateOpeningProgressText()
        openingProgressBox.isHidden = false
        openingProgressSpinner.startAnimation(nil)
    }

    private func updateOpeningProgressText() {
        let name = openingProgressName
        if let counts = openingProgressCounts, counts.total > 0 {
            openingProgressLabel.stringValue = String(
                localized: "Opening “\(name)”… \(counts.done)/\(counts.total) books")
        } else {
            openingProgressLabel.stringValue = String(localized: "Opening “\(name)”…")
        }
    }

    /// 検証用: HUD を固定内容で表示する(--show-opening-progress)
    /// EN: Verification hook: show the HUD with fixed contents.
    func debugShowOpeningProgress() {
        openingFlowGeneration = -1
        openingProgressName = "サンプルシリーズ"
        openingProgressCounts = (done: 12, total: 34)
        revealOpeningProgress()
    }

    /// ページのない本(空/開けなかった)の理由と操作案内を中央に表示する
    /// EN: Centered explanation for empty/unopenable books, with a next-step hint.
    private func showBookStatusMessage(_ reason: String) {
        statusLabel.stringValue = reason + "\n"
            + String(localized: "Turn the page or use Next Book to continue.")
        statusLabel.isHidden = false
        pageLabel.isHidden = true
        pageBar.isHidden = true
    }

    private func updatePageIndicators(spread: Book.Spread) {
        guard let book, book.pageCount > 0 else {
            pageLabel.stringValue = ""
            pageBar.progress = 0
            return
        }
        let shown = spread.indices.map { String($0 + 1) }
        let numbers = shown.count == 2 ? "\(shown[0])-\(shown[1])" : (shown.first ?? "-")
        // 旧実装のページ番号表示は「#N-M/総数 (ファイル名 / ファイル名)」と
        // 表示中のファイル名を併記していた(仕様書 §3.4)。読み順に並べる
        // EN: Legacy format: page numbers plus displayed file names in reading order.
        let relativePaths = settings.showRelativePaths
        let names = spread.indices.compactMap { index in
            book.entries.indices.contains(index)
                ? book.entries[index].displayTitle(relativePath: relativePaths) : nil
        }.joined(separator: " / ")
        pageLabel.stringValue = names.isEmpty
            ? " \(numbers)/\(book.pageCount) "
            : " \(numbers)/\(book.pageCount) (\(names)) "
        let lastShown = (spread.indices.last ?? 0) + 1
        pageBar.progress = Double(lastShown) / Double(book.pageCount)
        pageBar.readsFromLeft = book.readMode.readsFromLeft
    }

    // MARK: - ナビゲーション

    private func showNext() {
        guard let book else { return }
        switch book.moveNext() {
        case .moved:
            Task { await refreshDisplay() }
        case .hitEnd:
            handleEndOfBook()
        case .hitStart:
            break
        }
    }

    private func showPrevious() {
        guard let book else { return }
        Task {
            switch await book.movePrevious() {
            case .moved:
                await refreshDisplay()
            case .hitStart:
                handleStartOfBook()
            case .hitEnd:
                break
            }
        }
    }

    /// 巻末超え(仕様書 §4.3.4)
    /// EN: End-of-book behavior per the LoopCheck setting (loop / next book / stop).
    func handleEndOfBook() {
        guard let book else { return }
        // 開けなかった本(空)はループ設定に関わらずスキップして次へ
        if book.pageCount == 0 {
            openAdjacentBook(forward: true)
            return
        }
        switch settings.loopCheck {
        case 0:
            book.goToFirst()
            Task { await refreshDisplay() }
        case 1, 2:
            // 前方は 1/2 とも「次の本の先頭」(仕様書 §4.3.4)
            openAdjacentBook(forward: true)
        default:
            break
        }
    }

    func handleStartOfBook() {
        guard let book else { return }
        if book.pageCount == 0 {
            openAdjacentBook(forward: false)
            return
        }
        switch settings.loopCheck {
        case 0:
            Task {
                await book.goToLast()
                await refreshDisplay()
            }
        case 1:
            // 前の本の先頭へ(GoToLastPage 復元が働き得る。仕様書 §4.3.4)
            openAdjacentBook(forward: false)
        case 2:
            // 前の本を必ず末尾から(復元バイパス。仕様書 §4.3.4)
            openAdjacentBook(forward: false, openLast: true)
        default:
            break
        }
    }

    /// ジャンプ系アクション後の再表示(+Input.swift から使用)
    func refreshAfterJump() {
        Task { await refreshDisplay() }
    }

    /// 前ページへ戻り、PrevPageMode=1 ならページ末尾から表示(仕様書 §6.1)
    func performPreviousFromEnd() {
        guard let book else { return }
        Task {
            switch await book.movePrevious() {
            case .moved:
                await refreshDisplay()
                if settings.prevPageMode == 1 {
                    readerView.scrollToEnd()
                }
            case .hitStart:
                handleStartOfBook()
            case .hitEnd:
                break
            }
        }
    }

    // MARK: - メニューアクション

    @objc func nextPage(_ sender: Any?) { showNext() }
    @objc func previousPage(_ sender: Any?) { showPrevious() }

    @objc func halfNextPage(_ sender: Any?) {
        guard let book else { return }
        if book.moveHalfNext() == .moved {
            Task { await refreshDisplay() }
        }
    }

    @objc func halfPreviousPage(_ sender: Any?) {
        guard let book else { return }
        if book.moveHalfPrevious() == .moved {
            Task { await refreshDisplay() }
        }
    }

    @objc func goToFirstPage(_ sender: Any?) {
        book?.goToFirst()
        Task { await refreshDisplay() }
    }

    @objc func goToLastPage(_ sender: Any?) {
        Task {
            await book?.goToLast()
            await refreshDisplay()
        }
    }

    @objc func changeFitMode(_ sender: NSMenuItem) {
        guard let mode = ReaderView.FitMode(rawValue: sender.tag) else { return }
        setFitMode(mode)
    }

    /// 表示モードの唯一の変更経路(メニュー/キー巡回/設定)。ビューへ即時
    /// 反映しつつ defaults へ保存する(applySettings 側は同値なら何もしない)
    /// EN: Single entry point for fit-mode changes: apply to the view now and
    /// EN: persist; the coalesced applySettings pass then no-ops on equality.
    func setFitMode(_ mode: ReaderView.FitMode) {
        settings.fitMode = mode
        guard readerView.fitMode != mode else { return }
        readerView.fitMode = mode
        refreshDisplayIfCapRaised()
    }

    @objc func changeReadMode(_ sender: NSMenuItem) {
        guard let book, let mode = ReadMode(rawValue: sender.tag) else { return }
        book.readMode = mode
        Task { await refreshDisplay() }
    }

    @objc func cycleReadMode(_ sender: Any?) {
        guard let book else { return }
        book.readMode = book.readMode.cycled
        Task { await refreshDisplay() }
    }

    @objc func changeInterpolation(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "Interpolation")
    }

    /// 表紙を単ページで表示(見開きモード時のみ効果。設定と同じ defaults を共有)
    /// EN: Toggle "cover page stays single"; shares the Settings default.
    @objc func toggleCoverSingleMenu(_ sender: Any?) {
        settings.spreadCoverSingle.toggle()
    }

    @objc func toggleInterpolationMenu(_ sender: Any?) {
        settings.toggleInterpolationNone()
    }

    @objc func rotateLeft(_ sender: Any?) {
        readerView.rotation += 1  // 仕様書 §4.15: rotateLeft はインクリメント
    }

    @objc func rotateRight(_ sender: Any?) {
        readerView.rotation -= 1
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(changeFitMode(_:)):
            menuItem.state = readerView.fitMode.rawValue == menuItem.tag ? .on : .off
            return true
        case #selector(changeReadMode(_:)):
            menuItem.state = book?.readMode.rawValue == menuItem.tag ? .on : .off
            return book != nil
        case #selector(changeInterpolation(_:)):
            menuItem.state = settings.interpolation.rawValue == menuItem.tag ? .on : .off
            return true
        case #selector(toggleCoverSingleMenu(_:)):
            menuItem.state = settings.spreadCoverSingle ? .on : .off
            return true
        case #selector(nextPage(_:)), #selector(previousPage(_:)),
             #selector(halfNextPage(_:)), #selector(halfPreviousPage(_:)),
             #selector(goToFirstPage(_:)), #selector(goToLastPage(_:)),
             #selector(cycleReadMode(_:)), #selector(showThumbnailsMenu(_:)),
             #selector(editBookmarksMenu(_:)):
            return (book?.pageCount ?? 0) > 0
        default:
            return true
        }
    }

    // MARK: - フルスクリーンのカーソル自動非表示(仕様書 §3.3)

    func windowDidEnterFullScreen(_ notification: Notification) {
        scheduleCursorHide()
        refreshDisplayIfCapRaised()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        cursorHideTimer?.invalidate()
        cursorHideTimer = nil
    }

    func noteMouseMoved() {
        guard window?.styleMask.contains(.fullScreen) == true else { return }
        scheduleCursorHide()
    }

    private func scheduleCursorHide() {
        cursorHideTimer?.invalidate()
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            Task { @MainActor in
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    // MARK: -

}

// MARK: - NSWindowDelegate

extension ReaderWindowController: NSWindowDelegate {}

// MARK: - NSMenuItemValidation

extension ReaderWindowController: NSMenuItemValidation {}

// MARK: - ReaderViewDelegate

extension ReaderWindowController: ReaderViewDelegate {
    func readerView(_ view: ReaderView, didReceiveDropped url: URL) {
        openBook(at: url)
    }

    func readerViewMouseMoved(_ view: ReaderView) {
        noteMouseMoved()
        noteMouseMovedForIndicators()
    }

    func readerView(_ view: ReaderView, handleKey event: NSEvent) -> Bool {
        handleKeyEvent(event)
    }

    func readerView(_ view: ReaderView, clickedButton button: Int,
                    modifiers: Int, leftHalf: Bool) {
        handleClick(button: button, modifiers: modifiers, leftHalf: leftHalf)
    }

    func readerView(_ view: ReaderView, gesture virtualButton: Int, modifiers: Int) {
        handleGesture(virtualButton: virtualButton, modifiers: modifiers)
    }

    func readerView(_ view: ReaderView, dragGesture directionModifier: Int, baseModifiers: Int) {
        handleDragGesture(directionModifier: directionModifier, baseModifiers: baseModifiers)
    }

    func readerViewShouldDragScroll(_ view: ReaderView, modifiers: Int) -> Bool {
        shouldDragScroll(modifiers: modifiers)
    }

    func readerView(_ view: ReaderView, scrollWheel event: NSEvent) {
        handleScrollWheel(event)
    }
}
