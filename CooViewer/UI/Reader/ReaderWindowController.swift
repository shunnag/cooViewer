import AppKit
import SwiftUI
import Washi

/// メインウインドウ。本のオープンフロー・表示更新・メニューアクションを担う。
/// 旧 Controller の表示/ナビゲーション部分に相当する(仕様書 §4.1-4.3)。
@MainActor
final class ReaderWindowController: NSWindowController {
    private(set) var book: Book?
    /// 現在の本がパスワード付き書庫か(ロック解除前の isEncrypted で判定)。
    /// 超解像ディスクキャッシュを暗号化して残すかの判断に使う(復号済みページを
    /// 平文で残さない。CWE-312)。ロック解除後は isEncrypted が false を返す実装
    /// (PDFSource: isLocked 依存)があるため解除前の値を保持する。ルーペ配線
    /// (別ファイルの extension)から参照するため getter は internal
    private(set) var currentBookIsEncrypted = false
    private let readerView = ReaderView()
    private let pageBar = PageBarView()
    let pageLabel = NSTextField(labelWithString: "")  // +EPUB からも更新する
    /// 開けなかった本の理由等をウインドウ中央に表示するラベル
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    /// オープン進捗 HUD(大書庫入りフォルダの統合など、開くのに時間が
    /// かかるときだけ中央に表示。設計書 §2.4 補)
    private let openingProgressBox = NSView()
    private let openingProgressSpinner = NSProgressIndicator()
    private let openingProgressLabel = NSTextField(labelWithString: "")
    /// ドラッグジェスチャの方向 HUD(+Input から駆動。設計書 §2.4 の新規機能)
    let gestureHUD = GestureHUDView()
    /// 進捗表示を所有しているオープン処理の世代(nil = 進行中なし)
    private var openingFlowGeneration: Int?
    private var openingProgressName = ""
    private var openingProgressCounts: (done: Int, total: Int)?

    let settings = SettingsStore.shared
    var bindings = BindingConfiguration.load()

    /// 入力ディスパッチ(+Input.swift)からのビューアクセス
    var readerViewForInput: ReaderView { readerView }

    // MARK: リフロー EPUB モード(実装は +EPUB.swift。設計書 §2.4 EPUB 対応)
    /// リフロー EPUB の表示ビュー(初回オープン時に生成し readerView と入替表示)
    var epubView: EPUBReaderView?
    var epubPublication: EPUBPublication?
    var epubBookURL: URL?
    /// WKWebView がキーイベントを食うため、EPUB モード中はローカルモニタで拾う
    var epubKeyMonitor: Any?
    /// EPUB モード中、readerView が隠れて拾えなくなるハードウェアの
    /// スワイプ/回転ジェスチャをローカルモニタで拾い直す(監査 #10)
    var epubGestureMonitor: Any?
    /// 回転ジェスチャの累積角(.began でリセット・.ended で発火。ReaderView と同型)
    var epubRotationSum: CGFloat = 0
    /// EPUB の「N/M (章題)」ページ番号表示(census 完了時のみ非 nil)
    var epubPageLabelText: String?
    /// コレクション(合本)経由で開いた EPUB の文脈(nil = 単体で開いた EPUB)
    var epubCollectionContext: EPUBCollectionContext?
    /// EPUB 提示の世代。presentReflowableEPUB へ至る全入口(単体オープン・合本
    /// 自動入場・合本横断)で採番し、提示直前で照合する。合本内の EPUB↔EPUB 移動は
    /// openBookFlow(openGeneration)を通らないため、提示専用にもう 1 本持つ
    /// (last-request-wins を保証。ThumbnailOverlayModel.presentationEpoch と同型)
    var epubPresentEpoch = 0
    /// 同一 URL の並行 EPUB 解析を 1 本に束ねる(往復連打での無制限並走を防ぐ)
    let epubParseCoalescer = EPUBParseCoalescer()
    /// 合本復帰時の到達方向(代理ページへの着地時に消費。自動入場の向き)
    var epubCollectionArrivalForward: Bool?
    /// 開けなかった代理ページ(FXL/DRM の確定降格)。自動入場せず静的な表紙として
    /// 表示する(全滅フォルダ + ループ設定での無限循環防止)。恒久記録
    var epubFailedPlaceholders: Set<URL> = []
    /// 一過性の解析失敗(nil = 一時 I/O 失敗・壊れファイル)の代理ページ。恒久
    /// ブラックリストと違い「今回の着地だけ」代理表紙にする消費式マーカー:
    /// refreshDisplay が読み取り時に remove して消費し、次の意図的な再着地では
    /// 再解析する。**不変条件: 一括クリアしてはならない** — 挿入→openBook→
    /// 再着地→消費 の順序に依存しており、開始時クリアは挿入とレースして
    /// enterCollectionReflowEPUB→openBook の無限ループを再発させる(消費のみが
    /// 唯一のクリア経路)
    var epubTransientFailedPlaceholders: Set<URL> = []
    /// 合本への復帰オープンが進行中(EPUB 側の巻端イベントを抑止する。
    /// 巻端でのキーリピートが二重の復帰・単体モード誤爆になるのを防ぐ)
    var epubCollectionReturnPending = false
    /// 合本の巻末ループ(LoopCheck 0)による前進再入場では保存位置を復元せず
    /// 先頭から開く(画像本の goToFirst と同じ意味論)
    var epubCollectionArrivalAtFirst = false
    /// コレクション一覧の展開(census 収集 → 差し替え)の進行タスク
    var collectionOverlayTask: Task<Void, Never>?
    /// 表示中の展開済みコレクション一覧(refreshDisplay の follow が
    /// 未展開へ巻き戻さないための対応表)
    var activeCollectionOverlay: ActiveCollectionOverlay?
    /// 合本の「全体ページ」対応表(ページバー・ページ番号・%ジャンプを
    /// 書庫内 zip と同じ全体基準にする。census が揃ってから有効)
    var collectionPageMap: CollectionPageMap?
    var collectionPageMapTask: Task<Void, Never>?
    /// 構築中のキー(folder#metrics。同じ対象の二重構築防止)
    var collectionPageMapPendingKey: String?
    /// published 済みの未完マップの再構築試行回数(pendingKey 別)。DRM/壊れ巻で
    /// 恒久的に欠ける場合に毎ナビゲーション再解析しない上限(一過性は上限内で埋まる)
    var collectionPageMapAttempts: [String: Int] = [:]
    static let collectionPageMapMaxAttempts = 3
    /// 位置保存のデバウンス(ページ送りのたびに書き込まない)
    var epubSaveDebounce: Task<Void, Never>?
    /// EPUB のページカール演出のホストビュー(連打時の掃除用)
    var epubCurlHosts: [NSView] = []
    /// 章メニュー用に平坦化した目次(representedObject は添字)
    var epubFlattenedToc: [(title: String, indent: Int, item: EPUBNavItem)] = []

    private var cursorHideTimer: Timer?
    /// アプリと同寿命のため解除しない(Swift 6 の nonisolated deinit 制約)
    private var settingsObserver: (any NSObjectProtocol)?
    var slideshowTimer: Timer?
    /// 2 本指スワイプ(ページ間スワイプ)の追跡状態(+Input.swift)
    var swipeTrackingActive = false
    var swipeTrackingDeltaX: CGFloat = 0
    var originalSizePanel: NSPanel?
    /// ファイル情報パネル(File > ファイル情報を表示)
    var fileInfoPanel: NSPanel?
    /// 検証用: 最後に表示したファイル情報(--show-file-info のスナップショット。
    /// ヘッドレス実行ではパネルのレイヤーが描画されないため ImageRenderer で描く)
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
    var cachedSiblings: (parent: String, paths: [String], timestamp: Double)?

    /// ページバーホバーのサムネイルバブル(仕様書 §3.4)
    private let pageBarBubble = NSView()
    private let bubbleImageView = NSImageView()
    private let bubbleLabel = NSTextField(labelWithString: "")
    private var bubbleHoverIndex = -1
    /// ホバーサムネイルの進行中/待機中ジョブ(スクラブで EPUB のオフスクリーン
    /// レンダー FIFO にジョブを積み残さないよう、常に in-flight 1 本+最新 1 本
    /// にコアレスする。配達ガードだけでは「結果」しか捨てられない)
    private var bubbleThumbnailInFlight = false
    private var bubbleThumbnailPending: (key: Int, request: () async -> CGImage?)?

    /// 壊れページ用の実行時生成プレースホルダ(多言語対応。旧 broken.png の置換)
    private lazy var brokenPlaceholder: CGImage? = PlaceholderImage.make(
        text: String(localized: "This page could not be loaded."))

    /// 開けなかった本の理由(空の本の汎用メッセージと区別するため保持)
    private var lockedBookReason: String?

    /// 直近に表示したスプレッドのページ index 列(サムネイルの強調に使う)
    private(set) var lastSpreadIndices: [Int] = []
    /// アニメページの読み込み時実効キャップ(entry.id → px)。ウインドウ拡大
    /// での再デコード判定に使う(本切替時にリセット)
    var loadedAnimationFrameCaps: [Int: Int] = [:]

    /// 開くフローの世代(連打時に古いフローが新しい本を上書きしないための番号)
    var openGeneration = 0  // +EPUB(コレクション自動入場)も競合ガードに読む
    /// 消費したスワイプの慣性イベントを飲み込むあいだ true(+Input.swift)
    var swipeConsumeMomentum = false

    /// 表示更新の世代。連打時に古い await 結果が新しい表示を上書きしないための番号
    private var displayGeneration = 0

    /// 次の refreshDisplay に伝えるページ送りの向き(ページ送り系アクションが
    /// 設定し、消費されたら nil に戻る)。nil のままの再表示(ジャンプ・
    /// 設定変更等)ではめくり効果を付けない
    var pendingTurnForward: Bool?

    /// スワイプ追従カールの状態(+Input.swift の状態機械)
    enum InteractiveCurlPhase {
        case starting(forward: Bool)  // モデル移動と準備が非同期進行中
        case active(forward: Bool)    // オーバーレイを指に追従中
        case finished                 // オーバーレイなしで切替済み(以後何もしない)
        case unavailable              // この操作では従来動作(離した時に判定)
    }
    var interactiveCurlPhase: InteractiveCurlPhase?
    var interactiveCurlProgress: CGFloat = 0
    /// 準備完了前にジェスチャが終わった場合の確定/取消の予約
    var interactiveCurlEndDecision: Bool?
    /// マウスドラッグ起点のカール追従(interactiveCurlPhase はスワイプと共有。
    /// 設計書 §2.4 の新規機能)
    var mouseCurlTracking = false
    var mouseCurlDelta: CGFloat = 0
    /// カール追従がドラッグを消費した(直後のクリック/ジェスチャ発火を抑止)
    var mouseCurlConsumedGesture = false
    /// スマートズーム直後の非同期再デコードでスクロール位置が先頭へ戻される
    /// 場合に再適用するアンカー(同一スプレッドのときだけ消費)
    var pendingScrollAnchor: (ratio: CGPoint, index: Int)?
    /// 連続ピンチズーム確定時の cap 上昇再デコードで、setPages が zoomScale=1 に
    /// 落とすため、倍率とアンカーを再適用する(同一スプレッドのときだけ消費)
    var pendingZoom: (scale: CGFloat, ratio: CGPoint, index: Int)?
    /// クイックルーペ(深押し中のみ表示)を保持中か。解放で畳む。
    /// ⌘L 等の常時表示トグルで出したルーペは対象外
    var forceClickLoupeHeld = false

    /// ページ番号/ページバーの位置・寸法制約(設定変更で組み直す。仕様書 §3.4)
    private var indicatorConstraints: [NSLayoutConstraint] = []
    /// リサンプル進行中インジケーター(ページバーの横。設計書 §5 描画品質)。
    /// 白いページ上でも見えるよう、半透過の角丸黒背景(box)に載せる
    private let resampleSpinner = NSProgressIndicator()
    private let resampleSpinnerBox = NSView()
    private var resampleSpinnerShowTask: Task<Void, Never>?
    /// 表示中スプレッドの処理が進行中か(濃い表示)
    private var displayResampleActive = false
    /// 先読みの処理が進行中か(薄い表示。ソフト停止で新旧タスクが
    /// 重なることがあるためカウントで持つ)
    private var prefetchResampleCount = 0
    /// 先読みリサンプルの計画枚数と処理済み枚数(アクティビティ窓の残数用)
    private var prefetchPlannedPages = 0
    private var prefetchDonePages = 0
    /// アクティビティ窓向け: 先読みリサンプルの進行中件数
    var prefetchResampleActiveCount: Int { prefetchResampleCount }
    /// アクティビティ窓向け: 先読みリサンプルの計画枚数(M)と残り枚数(N)。
    /// 先読み中でなければ (0, 0)
    var prefetchPlannedPageCount: Int { prefetchPlannedPages }
    var prefetchRemainingPageCount: Int { max(0, prefetchPlannedPages - prefetchDonePages) }
    /// アクティビティ窓向け: 先読みが処理中のエントリ ID(直列 1 件)
    var preresamplingEntryIDValue: Int? { preresamplingEntryID }
    /// アクティビティ窓向け: 表示中スプレッドのリサンプルが進行中か
    var displayResampleActiveValue: Bool { displayResampleActive }
    /// アクティビティ窓向け: 開いている本の書庫ソース(スプール統計用。
    /// フォルダ/PDF/ネスト統合では nil)
    var currentArchiveSource: ArchiveSource? { book?.source as? ArchiveSource }
    /// 進行中の先読みリサンプル(表示要求を最優先にするため、表示更新時に
    /// キャンセルして ML 実行キューを明け渡す)
    private var preresampleTask: Task<Void, Never>?
    /// 先読みがいま処理中のエントリ ID(処理中のページへジャンプした場合は
    /// キャンセルせず完走させて表示に使うための判定材料)
    private var preresamplingEntryID: Int?
    /// 先読みの実行番号(ソフト停止用: 旧タスクは処理中の 1 件を完走した
    /// 後、この番号のずれで自然停止する)
    private var preresampleRun = 0
    /// 表示中スプレッドのエントリ ID 集合(上記判定に使う)
    private var displayedEntryIDs: Set<Int> = []
    private var indicatorLayoutSignature = ""
    /// 自動隠し(仕様書 §3.4: マウス移動で復活+2 秒で非表示)
    private var indicatorHideTimer: Timer?
    private var indicatorsTemporarilyVisible = true
    /// applySettings の一括化フラグ(defaults 連続書込対策)
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
        // macOS 26 のタイル状態(フィル等)は復元前に autosave 文字列から外す。
        // フレーム自体は保存値のまま使うので終了時の見た目どおりに復元されるが、
        // tilingState 付きのまま復元すると WindowManager がタイルを再確立して
        // 保存し直し、以後ウインドウを動かしても古いフィルが毎回蘇る
        // (自己永続化)ため、タイルとしては復活させない
        Self.untileSavedWindowFrame()
        window.setFrameAutosaveName("ReaderWindow")
        window.isReleasedWhenClosed = false  // 閉じても解放せず再表示できるように
        self.init(window: window)

        setUpContentViews(in: window)
        // 初回起動(保存フレームがまだ無い)のときだけ中央へ。以降は
        // setFrameAutosaveName が前回の位置・サイズを復元する。AppKit は復元時に
        // constrainFrameRect でウインドウを必ず画面内へ収める(解像度変更・ディスプレイ
        // 取り外し後も画面外に出ない。隔離クローンで実測確認済み)ので、独自の画面解像度
        // ゲートは冗長。かつて不一致時に呼んでいた window.center() は autosave の保存位置を
        // 上書きしてしまい、クラッシュ/強制終了で解像度記録が残らないと毎回中央へ
        // リセットされていた(b19 の「位置が保存されない・リセットされる」報告の原因)。
        if UserDefaults.standard.string(forKey: "NSWindow Frame ReaderWindow") == nil {
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
                guard let self, !self.applySettingsScheduled else { return }
                self.applySettingsScheduled = true
                DispatchQueue.main.async {
                    self.applySettingsScheduled = false
                    self.applySettings()
                }
            }
        }
    }

    /// 版面余白プリセット(EPUBPageMargins: 0=狭い/1=標準/2=広い)→ Washi の
    /// insets。下辺はノンブルの居場所として最低限を確保する
    static func epubInsets(forMargins preset: Int) -> EPUBReaderInsets {
        switch preset {
        case 0: EPUBReaderInsets(top: 28, left: 24, bottom: 30, right: 24)
        case 2: EPUBReaderInsets(top: 76, left: 96, bottom: 64, right: 96)
        default: EPUBReaderInsets(top: 56, left: 56, bottom: 52, right: 56)
        }
    }

    /// 設定を即時反映する(設計書 §2.4: 旧 Cancel ロールバック方式からの仕様変更)
    func applySettings() {
        bindings = BindingConfiguration.load()  // 編集タブの変更を即時反映
        // EPUB 表示モード中のみ設定を反映する(退出後の隠れたビューへ流すと、
        // 見えない本の再ページ割り+全文 census が走る。再入場時は
        // presentReflowableEPUB が syncEPUBViewSettings で追い付かせる)
        if isEPUBMode {
            syncEPUBViewSettings()
        }
        let filterChanged = readerView.interpolation != settings.interpolation
            || readerView.noiseReductionLevel != settings.noiseReductionLevel
        readerView.interpolation = settings.interpolation
        readerView.noiseReductionLevel = settings.noiseReductionLevel
        // フィルタ(描画品質)切替: 先読みキューも新条件で組み直す。
        // 処理中の 1 件は完走させ(結果はキャッシュに残る)、残りは停止。
        // 新キューは表示中スプレッドの補間完了を待ってから積まれる
        if filterChanged {
            preresampleAdjacentSpread(sparingInFlight: true)
        }
        readerView.backgroundColor = settings.viewBackgroundColor
        // サムネイルのセルサイズ(設定スライダ → 開いている一覧へ即時反映。
        // 一覧側のピンチ確定が書いた同値は equality ガードで無視される)
        thumbnailOverlayModel.syncCellSizeFromDefaults()
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
        if readerView.fitMode != settings.fitMode {
            readerView.fitMode = settings.fitMode
            refreshDisplayIfCapRaised()
        }
        if let book, book.pageCount > 0 {
            // 見開きしきい値・表紙単ページの変更は現表示を再判定する(仕様書 §6.3)
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
    private func layoutPageIndicators() {
        guard let contentView = window?.contentView else { return }
        let numPosition = settings.pageNumPosition
        let barPosition = settings.pageBarPosition
        let barSize = settings.pageBarSize
        // showPageBar は「バーとの間隔制約を張るか」を変えるため署名に含める
        let signature = "\(numPosition)-\(barPosition)-\(barSize)-\(settings.showPageBar)"
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
        // 進行スピナーはページバーの内側(ウインドウ中央寄り)にバーと同じ高さで
        constraints += [
            resampleSpinnerBox.widthAnchor.constraint(equalToConstant: barSize.height),
            resampleSpinnerBox.heightAnchor.constraint(equalToConstant: barSize.height),
            resampleSpinnerBox.centerYAnchor.constraint(equalTo: pageBar.centerYAnchor),
            barPosition % 2 == 0
                ? resampleSpinnerBox.leadingAnchor.constraint(
                    equalTo: pageBar.trailingAnchor, constant: 6)
                : resampleSpinnerBox.trailingAnchor.constraint(
                    equalTo: pageBar.leadingAnchor, constant: -6),
        ]
        let stacked = numPosition == barPosition
        // 長いファイル名対策(仕様書 §3.4 のファイル名併記が横へ伸びる):
        // (a) ラベルはウインドウの反対端を超えない(必須制約。圧縮耐性を
        //     下げてあるので超過分は尾部省略に落ちる)。
        // (b) バーと同じ上下帯の別コーナーに置かれたときは、バー内側の
        //     スピナー箱(常設・バーに隣接)との間隔も強制して食い込みを防ぐ。
        //     バー非表示設定では張らない(不要な切り詰めを避ける)
        constraints.append(numPosition % 2 == 0
            ? pageLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -8)
            : pageLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: 8))
        let sameBand = !stacked && (numPosition < 2) == (barPosition < 2)
        if sameBand && settings.showPageBar {
            constraints.append(numPosition % 2 == 0
                ? resampleSpinnerBox.leadingAnchor.constraint(
                    greaterThanOrEqualTo: pageLabel.trailingAnchor, constant: 8)
                : pageLabel.leadingAnchor.constraint(
                    greaterThanOrEqualTo: resampleSpinnerBox.trailingAnchor,
                    constant: 8))
        }
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
    /// (ページのない本では常に隠す。EPUB モードからも呼ぶため internal)。
    /// EPUB モードのページ番号ラベルは census の全体 N/M(章題)を画像本と同じ
    /// 位置設定で出す(下記 epubHasNumber)。各ページ下部中央の素のノンブルは
    /// Washi が担うが、下配置(2/3)では帯が重なるため currentEPUBReaderSettings が
    /// ノンブル側を抑止する(epubShowsFolio。設計書 §2.4)
    func updateIndicatorVisibility() {
        let hasPages = (book?.pageCount ?? 0) > 0
        // EPUB は census(全文ページ数の実測)完了後に N/M を表示できる
        let epubHasNumber = isEPUBMode && epubPageLabelText != nil
        pageLabel.isHidden = !(hasPages || epubHasNumber) || !settings.showNumber
            || (settings.pageNumAutoHide && !indicatorsTemporarilyVisible)
        pageBar.isHidden = !(hasPages || isEPUBMode) || !settings.showPageBar
            || (settings.pageBarAutoHide && !indicatorsTemporarilyVisible)
    }

    /// EPUB モードのページバー更新(+EPUB.swift から。進捗は本全体の進行率)
    func updateEPUBPageBar(progress: Double, readsFromLeft: Bool) {
        pageBar.progress = min(max(progress, 0), 1)
        pageBar.readsFromLeft = readsFromLeft
        updateIndicatorVisibility()
    }

    /// 検証用: ページバーのホバーバブルを指定位置で表示する
    /// (--then-show-bubble。マウスホバーは CLI から再現できないため)
    func debugShowPageBarBubble(fraction: Double) {
        pageBar.onHover?((x: pageBar.bounds.width * CGFloat(fraction),
                          fraction: fraction))
    }

    /// 検証用: 表示中のページインジケータの画像と位置(EPUB スナップショット
    /// への合成用。WKWebView 合成には contentView のオーバーレイが写らないため)
    func debugIndicatorOverlays() -> [(image: NSImage, frame: NSRect)] {
        [pageBar, pageLabel, pageBarBubble].compactMap { view in
            guard !view.isHidden, view.bounds.width > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            return (image, view.frame)
        }
    }

    /// 画像の読み込み〜補間(ML 高画質化含む)完成までの控えめな進行表示
    /// (表示中スプレッドの処理)。ReaderView の通知が実状態を反映する
    func setResampleIndicator(_ active: Bool) {
        displayResampleActive = active
        updateResampleIndicator()
    }

    /// 先読みの処理開始・終了(薄い表示の駆動源。先読みタスクから呼ぶ)
    func setPrefetchIndicator(_ active: Bool) {
        prefetchResampleCount = max(0, prefetchResampleCount + (active ? 1 : -1))
        // 先読みが終わったら残数表示もクリアする(次の先読みで再設定)
        if prefetchResampleCount == 0 {
            prefetchPlannedPages = 0
            prefetchDonePages = 0
        }
        updateResampleIndicator()
    }

    /// 先読みループから計画枚数・処理済みを更新する(残数表示用)
    func notePrefetchPlan(planned: Int) { prefetchPlannedPages = planned }
    func notePrefetchProgress(done: Int) { prefetchDonePages = done }

    /// 進行表示の実体: 表示中ページの処理が濃い(0.85)、先読みのみは
    /// 薄い(0.4)。キャッシュ命中等で瞬時に終わるケースでチラつかないよう
    /// 表示は 250ms 遅らせ、完了時は即座に消す
    private func updateResampleIndicator() {
        let visible = displayResampleActive || prefetchResampleCount > 0
        if visible {
            let alpha: CGFloat = displayResampleActive ? 0.85 : 0.4
            if !resampleSpinnerBox.isHidden {
                resampleSpinnerBox.alphaValue = alpha  // 濃さだけ即時更新
                return
            }
            // 表示予約中なら維持(二重通知で遅延タイマーを巻き戻さない。
            // 濃さは表示時点の状態から改めて決まる)
            guard resampleSpinnerShowTask == nil else { return }
            resampleSpinnerShowTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.resampleSpinnerShowTask = nil
                guard self.displayResampleActive || self.prefetchResampleCount > 0
                else { return }
                self.resampleSpinnerBox.alphaValue =
                    self.displayResampleActive ? 0.85 : 0.4
                self.resampleSpinnerBox.isHidden = false
                self.resampleSpinner.startAnimation(nil)
            }
        } else {
            resampleSpinnerShowTask?.cancel()
            resampleSpinnerShowTask = nil
            resampleSpinner.stopAnimation(nil)
            resampleSpinnerBox.isHidden = true
        }
    }

    /// 自動隠し: マウス移動で表示を復活させ、2 秒後に隠す(仕様書 §3.4)
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
    /// 高度設定 OFF のときの先読み深さは、まず置き場所の速度プロファイルの
    /// 既定値(遅い媒体ほど深く)を初期値にし、ページ実サイズが判明した
    /// refreshDisplay で updatePrefetchDepth がメモリ予算連動へ引き上げる。
    /// ON なら明示値を尊重する
    private func applyAdvancedSettings(to book: Book) {
        if settings.advancedSettingsEnabled {
            book.prefetchAhead = settings.prefetchAheadCount
            book.prefetchBehind = settings.prefetchBehindCount
        } else {
            book.prefetchAhead = book.mediaProfile.defaultPrefetchAhead
            book.prefetchBehind = book.mediaProfile.defaultPrefetchBehind
        }
        // キャップは raise 時のクリアを通して反映(設定の上限引き上げにも追従)
        refreshDisplayIfCapRaised()
    }

    /// デコード先読みの深さをメモリ条件に合わせて更新する(設計書 §5)。
    /// 実測のデコード済みページサイズと表示リサンプルの実効ページ数から、
    /// 事前リサンプルが常にデコード済みへ命中する深さを確保する
    /// (固定 12-20 ページのままでは大容量機でリサンプル先読みに追い越され、
    /// I/O と ML 計算が直列化していた)。高度設定 ON は明示値を尊重
    private func updatePrefetchDepth(book: Book, images: [CGImage]) {
        if settings.advancedSettingsEnabled {
            book.prefetchAhead = settings.prefetchAheadCount
            book.prefetchBehind = settings.prefetchBehindCount
            return
        }
        guard let first = images.first else { return }
        let decodedBytes = first.bytesPerRow * first.height
        // 表示リサンプルの実効ページ数(補間なし/低では事前リサンプル自体が
        // 無いので 0 = 媒体別下限と PageCache 予算だけで決まる)
        var resamplePages = 0
        if let targets = readerView.predictedResampleSizes(
            for: images.map { CGSize(width: $0.width, height: $0.height) }),
           let firstTarget = targets.first {
            resamplePages = PreresamplePolicy.pageBudget(
                bytesPerPage: Int(firstTarget.width) * Int(firstTarget.height) * 4,
                physicalMemory: ProcessInfo.processInfo.physicalMemory)
        }
        book.prefetchAhead = PreresamplePolicy.decodeAhead(
            resamplePages: resamplePages,
            decodedPageBytes: decodedBytes,
            pageCacheByteLimit: settings.pageCacheByteLimit,
            mediaFloor: book.mediaProfile.defaultPrefetchAhead)
        book.prefetchBehind = PreresamplePolicy.decodeBehind(
            ahead: book.prefetchAhead)
    }

    /// いまのウインドウ実寸・原寸表示設定から適切なデコード上限を求める
    private func currentDisplayPixelCap() -> Int {
        let scale = window?.backingScaleFactor ?? 2
        let size = window?.contentView?.bounds.size ?? .zero
        // 連続ズーム確定時は拡大ぶんだけ長辺を段階的(1x/2x/4x)に引き上げて
        // くっきり再描画する(毎フレームは isLiveZooming ガードで抑止済み)
        let bucket = ZoomMath.capBucket(zoom: readerView.zoomScale)
        let edge = Int((max(size.width, size.height) * scale * bucket).rounded(.up))
        // ウインドウに収まらない描画をするモードは従来のユーザー上限のまま。
        // ズーム中(bucket>1)も収まらないので同様にユーザー上限でクランプする
        let modeUsesUserCap = switch readerView.fitMode {
        case .noScale, .fitWidth, .fitWidthDivide: true
        default: false
        }
        let usesUserCap = bucket > 1 || modeUsesUserCap
        return DisplayCapPolicy.cap(
            windowLongEdgePixels: edge,
            userCap: settings.displayPixelCap,
            usesUserCap: usesUserCap)
    }

    /// キャップの再評価。上がった(ウインドウ拡大・原寸表示切替)なら
    /// 低解像度キャッシュを捨てて現スプレッドを再デコードする
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
        // 長いファイル名はラベル側を尾部省略で切り詰める(番号が先頭の書式
        // 「N/M (名前)」なので N/M は必ず残る)。layoutPageIndicators の
        // 必須の間隔制約に負けて省略が起きるよう圧縮耐性を下げる
        pageLabel.lineBreakMode = .byTruncatingTail
        pageLabel.setContentCompressionResistancePriority(.defaultLow,
                                                          for: .horizontal)
        pageLabel.isHidden = true
        contentView.addSubview(pageLabel)

        pageBar.translatesAutoresizingMaskIntoConstraints = false
        pageBar.isHidden = true
        contentView.addSubview(pageBar)

        // リサンプル(ML 高画質化含む)進行中の控えめなスピナー。
        // ページバーの横に同じ高さで置く(layoutPageIndicators が制約を組む)。
        // 白いページ上でも見えるよう半透過の角丸黒背景に載せ、濃さは
        // 表示中ページ処理=濃い/先読みのみ=薄い の 2 段階
        resampleSpinnerBox.wantsLayer = true
        resampleSpinnerBox.layer?.backgroundColor =
            CGColor(gray: 0, alpha: 0.35)
        resampleSpinnerBox.layer?.cornerRadius = 4
        // 黒背景の上ではスピナーを明色で描かせる
        resampleSpinnerBox.appearance = NSAppearance(named: .darkAqua)
        resampleSpinnerBox.translatesAutoresizingMaskIntoConstraints = false
        resampleSpinnerBox.isHidden = true
        contentView.addSubview(resampleSpinnerBox)
        resampleSpinner.style = .spinning
        resampleSpinner.isIndeterminate = true
        resampleSpinner.isDisplayedWhenStopped = false
        resampleSpinner.translatesAutoresizingMaskIntoConstraints = false
        resampleSpinnerBox.addSubview(resampleSpinner)
        NSLayoutConstraint.activate([
            resampleSpinner.centerXAnchor.constraint(
                equalTo: resampleSpinnerBox.centerXAnchor),
            resampleSpinner.centerYAnchor.constraint(
                equalTo: resampleSpinnerBox.centerYAnchor),
            resampleSpinner.widthAnchor.constraint(
                equalTo: resampleSpinnerBox.widthAnchor, constant: -4),
            resampleSpinner.heightAnchor.constraint(
                equalTo: resampleSpinnerBox.heightAnchor, constant: -4),
        ])

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
        contentView.addSubview(gestureHUD)

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

            gestureHUD.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            gestureHUD.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
        readerView.onResampleActivityChanged = { [weak self] active in
            self?.setResampleIndicator(active)
        }
        pageBar.onJump = { [weak self] fraction in
            guard let self else { return }
            if self.isEPUBMode {
                self.epubJump(toBookFraction: fraction)  // 合本文脈は全体基準
                return
            }
            // 合本にマップがあれば全体基準(EPUB の途中への直接ジャンプ込み)
            if let map = self.activeCollectionPageMap() {
                self.jumpToCollectionFraction(fraction, map: map)
                return
            }
            guard let book = self.book else { return }
            if book.goToPercent(fraction) == .moved {
                Task { await self.refreshDisplay() }
            }
        }
    }

    // MARK: - 本を開く

    /// URL から本を開く。単一画像は親フォルダに読み替える(仕様書 §4.1.2 手順 2)。
    /// allowCollectionDrill: 画像ゼロのコレクションフォルダで中の本へ自動で
    /// 潜るか(設計書 §2.4)。Finder/ダイアログ等の明示オープンのみ true。
    /// 次/前の本ナビゲーションは false — フォルダ自身に着地して階層を保つ
    /// (潜ると以後の兄弟走査が別の深さで行われ、元の階層に戻れなくなる)
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
        openGeneration += 1
        let generation = openGeneration
        // EPUB 提示専用のエポックも進める。画像本オープンでも採番するのは、
        // dismissEPUBMode より前に in-flight の openCollectionEPUB のパースが
        // 完走して古い EPUB が画像本 commit の前に提示されるのを防ぐため
        epubPresentEpoch += 1
        let presentEpoch = epubPresentEpoch

        var bookURL = url
        var initialPageURL: URL?

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            // ドリルダウンから引き継いだ HUD が残らないように畳む
            endAnyOpeningProgress()
            return
        }
        if !isDirectory.boolValue, !SupportedTypes.isBookFile(url),
           SupportedTypes.isImageFile(url.lastPathComponent) {
            bookURL = url.deletingLastPathComponent()
            initialPageURL = url
        }

        // EPUB の形式振り分け(設計書 追補: Washi 統合)。全オープン入口が
        // openBook(at:) に合流するため、分岐はこの 1 点に集約する:
        // リフロー → 同ウインドウの EPUB 表示モード(+EPUB.swift)へ、
        // 固定レイアウト → EPUBSource で通常の画像パイプラインへ
        if !isDirectory.boolValue, SupportedTypes.isEPUB(bookURL),
           await routeEPUBIfNeeded(bookURL, generation: generation,
                                   atPage: atPage, atLastPage: atLastPage,
                                   epoch: presentEpoch) {
            return
        }

        // ドロップ/関連付けで開いた画像が**現在の本のページ**なら、本を
        // 開き直さずそのページへジャンプする(大量の書庫を含むフォルダの
        // 統合を再構築しない)。サブフォルダ読み込みの下層画像も実ファイル
        // URL の照合で拾う。一覧に無い(=開いた後に追加された)場合は
        // 従来どおり開き直され、結果として一覧も更新される
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
        beginOpeningProgress(generation: generation, name: bookURL.lastPathComponent)

        do {
            let source: any BookSource
            if epubCollectionReturnPending, let context = epubCollectionContext,
               CanonicalPath.normalize(context.folderURL.path)
                   == CanonicalPath.normalize(bookURL.path) {
                // EPUB(合本内の巻)から同じ合本へ戻る復帰は、入場時に文脈へ
                // 保持した合本ソースをそのまま使い回す。作り直すと NestedUnlocker
                // の状態(解錠済みの子・パスワード入力のキャンセル記憶)が失われ、
                // 「キャンセル後は同じ本で再度尋ねない」(設計書 §2.4)に反して
                // 復帰のたびにダイアログが出てしまう。巨大フォルダの統合再構築の
                // 待ちも避けられる。provider は最新のものへ付け替える
                // (setProvider はキャンセル状態を変えない)。復帰フローが途中で
                // 断念した場合 returnPending は残るが、次に開くのも同一セッションの
                // 同じ合本なので再利用でよい(意図した決定)。スプールの再開始は
                // beginSpooling の spoolTask ガードが冪等に吸収する
                await context.source.attachNestedPasswordProvider(
                    nestedPasswordProvider())
                source = context.source
            } else if let prepared = preparedNextBook, prepared.path == bookURL.path {
                preparedNextBook = nil
                if await prepared.source.hasSkippedLockedContent() {
                    // バックグラウンド準備(パスワード UI なし)がロック済みの
                    // ネスト書庫を外して組んでいた場合は使い回さず、通常経路で
                    // 開き直してダイアログを出す(ページの黙落ち防止)
                    source = try await BookSourceFactory.make(
                        for: bookURL, readSubFolders: settings.readSubFolder,
                        nestedPasswordProvider: nestedPasswordProvider())
                } else {
                    // 事前スプール済みの本を再利用(切替を待ちなしに。設計書 §5)。
                    // まだ組んでいない場合に備えてパスワード UI を後付けする
                    await prepared.source.attachNestedPasswordProvider(
                        nestedPasswordProvider())
                    source = prepared.source
                }
            } else {
                // prepared が今回開く本と一致せず、しかも別フォルダの本を開いた
                // ときは、旧フォルダの隣接書庫を握り続けない(スプール済み一時
                // データを抱えたまま居座るリーク。監査 #11)。同フォルダ内なら
                // 巻末で maybePrepareNextBook が置換するので保持のままでよい
                if let prepared = preparedNextBook,
                   URL(fileURLWithPath: prepared.path).deletingLastPathComponent().path
                       != bookURL.deletingLastPathComponent().path {
                    preparedNextBook = nil
                }
                source = try await BookSourceFactory.make(
                    for: bookURL, readSubFolders: settings.readSubFolder,
                    nestedPasswordProvider: nestedPasswordProvider())
            }
            // 復号済みページの暗号化ディスクキャッシュ判定に使うため、ロック解除前に
            // 暗号化状態を控える(PDFSource は解除後 isEncrypted が false を返すため)
            let bookIsEncrypted = await source.isEncrypted()
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
            dismissEPUBMode()  // EPUB モード中なら位置を保存して画像表示へ戻す

            // 置き場所の速度判定は本の展開と並行に走らせる(設計書 キャッシュ節)。
            // [#1] 初回描画をこの判定でブロックしないため Task にして待たない(async let は
            // 宣言スコープ外から await できないので Task を使う)。確定プロファイルは描画後に
            // バックグラウンドで .value を待って適用する。内蔵 SSD は IOKit、ネットワークは
            // statfs で即答なので実質同時。外付けの不明メディア初回のみ最大 ~250ms のベンチ
            // マークが走るが、その分だけ先に 1 ページ目を描ける(結果はボリュームでキャッシュ)。
            let probeURL = bookURL
            let mediaProfileTask = Task { await self.effectiveMediaProfile(for: probeURL) }
            let book = try await Book.open(source: source, sortMode: settings.sortMode,
                                           cacheByteLimit: settings.pageCacheByteLimit)
            guard generation == openGeneration else { return }
            // 画像ゼロのフォルダ(コレクションフォルダ)は中の最初の本を開く
            // (旧実装は開くのを拒否 §4.1.2 手順 3。設計書 §2.4 の仕様変更)。
            // ただしパスワード入力のキャンセル等でネスト書庫を外した結果の
            // 空ならそのまま(自動で開き直すと同じダイアログが即再表示される)
            // 統合ソース(フォルダ内書庫/PDF の合本)が 0 ページなのは組み立て
            // 失敗(壊れ書庫の黙殺 §4.17 等)であり、ドリルダウンすると中の
            // 書庫を「単体の本」として開いてしまい階層がずれる。ドリルは
            // 純粋なコレクション(直下も配下も画像・書庫なし=FolderSource)のみ
            if book.pageCount == 0, allowCollectionDrill, autoOpenDepth < 4,
               !(source is NestedFolderSource),
               await !source.hasSkippedLockedContent() {
                // 候補選定は再帰走査を含むためメインスレッドから外す
                // (NAS/HDD でのビーチボール防止。走査があるので非同期)
                let scanURL = bookURL
                let inner = await Task.detached(priority: .userInitiated) {
                    Self.innerBook(in: scanURL)
                }.value
                guard generation == openGeneration else { return }
                if let inner {
                    // HUD は畳まない: 再帰側の beginOpeningProgress が
                    // 新しい世代で引き継ぐ(走査〜内側の本のオープンまで連続表示)
                    await openBookFlow(url: inner, atPage: nil, atLastPage: atLastPage,
                                       allowCollectionDrill: true,
                                       autoOpenDepth: autoOpenDepth + 1)
                    return
                }
            }
            endOpeningProgress(generation: generation)
            book.readMode = settings.readMode
            // ComicInfo の読み方向ヒント(オプトイン時のみ)。全体既定の上に載せ、
            // 本ごとに保存された読み方向(ユーザーの明示設定)が後で最優先で上書き
            // する = saved > ComicInfo > 既定(cooViewer-4fi.4)
            if settings.respectComicInfoReadingDirection,
               let rtl = await book.comicInfo()?.manga.readsRightToLeft {
                book.readMode = book.readMode.withDirection(readsRightToLeft: rtl)
            }
            // ComicInfo 由来の状態(章メニュー・見開き補助)を構築(4fi.6 / bt1)
            await book.loadComicInfoState(
                useLayoutHints: settings.useComicInfoLayoutHints)
            book.singleSetting = settings.singleSetting
            book.coverSingleFirst = settings.spreadCoverSingle
            // [#1] まず保守的な unknown で表示に進む(既定と同値=従来動作)。
            // 確定プロファイルは描画後にバックグラウンドで適用する(下記)。
            book.mediaProfile = .unknown
            await source.applyMediaProfile(.unknown)
            applyAdvancedSettings(to: book)
            // comicInfo/loadComicInfoState/applyMediaProfile の await を跨いだ間に
            // 新しいオープンが始まっていたら、ここで自己状態を commit しない
            // (連打で「先に押した遅い本」が最後に押した本を上書きするのを防ぐ)
            guard generation == openGeneration else { return }
            self.book = book
            loadedAnimationFrameCaps.removeAll()  // id は本ごとの名前空間
            // 本ごとのリサンプルキャッシュ名前空間(本切替時の取り違え防止)
            readerView.resampleKeyPrefix = book.cacheKey
            // パスワード付き書庫は超解像ディスクキャッシュを暗号化して残す
            // (復号済みページを平文で SuperRes/ に残さない。CWE-312)。まず
            // トップレベルの暗号化状態を反映する(ネスト内は組み立て後に上乗せ)
            currentBookIsEncrypted = bookIsEncrypted
            readerView.superResDiskCacheEncrypted = bookIsEncrypted

            // [#1] スプール開始は確定プロファイルで判断したいので描画後の
            // バックグラウンドへ移動した(unknown で SSD の zip を無駄にスプールしない)。
            // containsProtectedContent は内部で buildIfNeeded するのでここで build 済み。

            // フォルダ内やネスト書庫内の暗号化書庫/PDF を解除して束ねた本も
            // 暗号化キャッシュ対象にする(組み立て後に確定。表示より前に反映する)
            var hasProtectedContent = bookIsEncrypted
            if !hasProtectedContent {
                hasProtectedContent = await source.containsProtectedContent()
            }
            guard generation == openGeneration else { return }
            currentBookIsEncrypted = hasProtectedContent
            readerView.superResDiskCacheEncrypted = hasProtectedContent

            let skipPageRestore = initialPageURL != nil || atPage != nil || atLastPage
            await restoreBookState(for: book, skipPageRestore: skipPageRestore)
            guard generation == openGeneration else { return }

            // 単一画像から開いた場合: まず実ファイル URL、次に名前で探す
            // (サブフォルダ読み込みで同名ファイルがあっても正しいページへ)
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
                // 後退到達(前の本を末尾から)の意図を代理ページ入場へ伝える。
                // 末尾が合本内リフロー EPUB のとき、これが無いと refreshDisplay の
                // forward 既定が true になり EPUB が先頭で開いてしまう(監査 #1)
                epubCollectionArrivalForward = false
                await book.goToLast()
            }
            guard generation == openGeneration else { return }  // goToLast の await をカバー
            let bookTitle = await book.displayTitle()  // ComicInfo 優先(cooViewer-4fi.3)
            guard generation == openGeneration else { return }  // displayTitle の await をカバー
            window?.title = bookTitle
            lockedBookReason = nil
            statusLabel.isHidden = true
            updateIndicatorVisibility()
            await refreshDisplay()
            guard generation == openGeneration else { return }  // refreshDisplay 後の UI 変異を守る

            // [#1] メディア速度プローブが解決したらバックグラウンドで確定プロファイルを
            // 適用する(描画はブロックしない)。確定後にスプール開始(正しいプロファイルで
            // 判断=SSD の zip を無駄にスプールしない)と、新しい並列幅/深さでの先読み再
            // スケジュールを行う。開き直しに追い越されていたら(世代・本の同一性で判定)何も
            // しない。unknown のまま(適応チューニング OFF)なら再適用は不要でスプールのみ。
            let spoolLimit = settings.archiveSpoolSizeLimit
            Task { @MainActor [weak self] in
                let realProfile = await mediaProfileTask.value
                guard let self, self.openGeneration == generation,
                      self.book === book else { return }
                if realProfile != book.mediaProfile {
                    book.mediaProfile = realProfile
                    await source.applyMediaProfile(realProfile)
                    self.applyAdvancedSettings(to: book)
                    book.reschedulePrefetch()
                }
                await source.beginBackgroundPreparation(spoolSizeLimit: spoolLimit)
            }
            // サムネイル表示中に本が切り替わったら一覧も新しい本で組み直す。
            // 非表示中はスナップショットを空にして旧本のソース保持を解く
            // (書庫のスプール/ネスト展開の一時ファイル回収のため)
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

    /// EPUB の事前判定。リフローなら同じウインドウの EPUB 表示モードへ切り替えて
    /// true、固定レイアウトなら false(通常フローが EPUBSource で開く)。
    /// DRM 保護は対処可能性をユーザーへ伝える(黙殺 §4.17 の例外:
    /// ファイル自体は正常で、原因がストア側の保護だと分かるため)
    private func routeEPUBIfNeeded(_ url: URL, generation: Int,
                                   atPage: Int? = nil,
                                   atLastPage: Bool = false,
                                   epoch: Int) async -> Bool {
        let publication = await epubParseCoalescer.publication(at: url)
        // 解析の await 中に新しいオープンが始まっていたら、この古いフローは
        // 何も起こさず終える(連打時の巻き戻り防止。openBookFlow と同じ規則)
        guard generation == openGeneration else {
            endAnyOpeningProgress()
            return true
        }
        guard let publication else {
            return false  // 壊れた EPUB は通常フローの黙殺(ビープ)に任せる
        }
        if publication.isDRMProtected {
            endAnyOpeningProgress()  // ドリルダウンから引き継いだ HUD を畳む
            let alert = NSAlert()
            alert.messageText = String(localized: "This book is protected by DRM.")
            alert.informativeText = publication.drmSchemeName ?? ""
            alert.runModal()
            return true
        }
        guard !publication.isFixedLayout else { return false }
        endAnyOpeningProgress()
        presentReflowableEPUB(publication, url: url,
                              atPage: atPage, atLastPage: atLastPage, epoch: epoch)
        return true
    }

    /// EPUB モードへ入る前に画像本を落とす(+EPUB.swift から使用。
    /// openBookFlow の「旧本の後始末」と同じ手順 + 表示のリセット)
    func unloadImageBookForEPUB() {
        stopSlideshow()
        book?.cancelPrefetch()
        saveCurrentBookState()
        book = nil
        hideThumbnailOverlay()
        thumbnailOverlayModel.clear()
        lockedBookReason = nil
        statusLabel.isHidden = true
        updateIndicatorVisibility()
    }

    /// 開けなかった本(パスワードのキャンセル/試行超過)を「現在の本」として
    /// 空の状態で表示する。これによりページ送りや「次の本」でこの本を
    /// 飛ばして先へ進める。履歴・設定には記録しない。
    private func presentLockedPlaceholder(source: any BookSource, reason: String) {
        stopSlideshow()
        saveCurrentBookState()
        dismissEPUBMode()
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
    func refreshDisplayIfCapRaised() {
        Task { [weak self] in
            guard let self, let book = self.book else { return }
            if await book.updateDisplayPixelCap(self.currentDisplayPixelCap()) {
                await self.refreshDisplay()  // 再表示がアニメも再デコードする
            } else {
                // バケット内のリサイズでもアニメの表示枠は伸び得る
                self.restartAnimationsIfFrameGrew()
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        refreshDisplayIfCapRaised()
    }

    func windowDidResize(_ notification: Notification) {
        // ズーム等の非ライブリサイズ(ライブ中は終了時にまとめて処理)
        guard window?.inLiveResize == false else { return }
        refreshDisplayIfCapRaised()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        refreshDisplayIfCapRaised()  // 別解像度のディスプレイへ移動した場合
    }

    func windowWillClose(_ notification: Notification) {
        stopSlideshow()
        collectionOverlayTask?.cancel()  // 全冊 census をウインドウ亡き後に残さない
        collectionPageMapTask?.cancel()
        // キャンセルしたタスクは自分では pendingKey を消せない(isCancelled
        // guard で先に抜ける)。残すと同キーの再構築が恒久的に塞がる
        collectionPageMapPendingKey = nil
        collectionPageMapAttempts.removeAll()
        epubView?.stopMediaOverlay()  // ウインドウを閉じたら音声も止める
        epubView?.cancelPageCensus()
        saveCurrentBookState()
        saveEPUBState()
    }

    func saveStateBeforeTermination() {
        saveCurrentBookState()
        saveEPUBState()
    }

    // MARK: - ウインドウのタイル状態除去(macOS 26)

    /// autosave 文字列にタイル状態(macOS 26 の tilingState JSON)が付いて
    /// いたら、フレーム欄は保存値のまま JSON だけを落とす。フレームを保つので
    /// フィル等で終了したときは同じ見た目で復元されるが、タイルとしては復活
    /// させない(復活させると WindowManager がタイル状態を保存し直し、その後
    /// ウインドウを動かしても古いフィルが毎回蘇る自己永続化が起きるため)
    static func untileSavedWindowFrame() {
        let key = "NSWindow Frame ReaderWindow"
        let defaults = UserDefaults.standard
        guard let saved = defaults.string(forKey: key),
              let sanitized = untiledFrameString(from: saved) else { return }
        defaults.set(sanitized, forKey: key)
    }

    /// 純粋変換部(テスト用に分離)。差し替え不要・解析不能なら nil。
    /// 文字列は "x y w h sx sy sw sh {JSON}" 形式(JSON は付いていれば)
    nonisolated static func untiledFrameString(from saved: String) -> String? {
        guard let braceIndex = saved.firstIndex(of: "{") else { return nil }
        let fields = saved[..<braceIndex].split(separator: " ").map(String.init)
        guard fields.count == 8,
              let data = saved[braceIndex...].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              json["tilingState"] != nil else { return nil }
        // 末尾の空白も AppKit の書式に合わせる
        return fields.joined(separator: " ") + " "
    }

    private enum UnlockResult {
        case unlocked
        case cancelled
        case attemptsExceeded
    }

    /// ネスト書庫/PDF 用のパスワード入力コールバック(仕様書 §4.1.3 のネスト版)。
    /// 本を開くフロー(entries() 構築)中に呼ばれ、MainActor でダイアログを出す。
    func nestedPasswordProvider() -> NestedPasswordProvider {
        // @Sendable クロージャに非 Sendable の self を捕まえないため、
        // 有効判定は生成時に固定し、チェック状態の記憶はクロージャ内で
        // defaults を直接読み書きする(SettingsStore と同じキー)
        let vaultEnabled = settings.passwordVaultEnabled
        return { name, attempt in
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
                alert.informativeText = attempt == 1
                    ? String(localized: "Enter the password to include it.")
                    : String(localized: "Wrong password. \(4 - attempt) attempts left.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.addButton(withTitle: String(localized: "Skip"))
                let field = NSSecureTextField(
                    frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                let saveCheckbox = Self.makeSaveCheckbox()
                alert.accessoryView = vaultEnabled
                    ? Self.passwordAccessory(field: field, checkbox: saveCheckbox)
                    : field
                alert.window.initialFirstResponder = field
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                let save = vaultEnabled && saveCheckbox.state == .on
                if vaultEnabled {
                    UserDefaults.standard.set(save, forKey: "PasswordVaultSaveByDefault")
                }
                return NestedPasswordAnswer(password: field.stringValue,
                                            saveRequested: save)
            }
        }
    }

    /// パスワードダイアログの「保存」チェックボックス(既定は前回の選択。
    /// 初期値はオフ=保存はユーザーの明示チェックから。設計書 §2.4)
    private static func makeSaveCheckbox() -> NSButton {
        let checkbox = NSButton(
            checkboxWithTitle: String(
                localized: "Save this password (unlock automatically next time)"),
            target: nil, action: nil)
        checkbox.state = UserDefaults.standard
            .bool(forKey: "PasswordVaultSaveByDefault") ? .on : .off
        return checkbox
    }

    /// 検証用: 保存チェックボックス付きアクセサリビューを組んで返す
    /// (--show-password-dialog)。ダイアログ本文と同じ配色の枠に載せる
    func debugPasswordAccessory() -> NSView {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Enter the password to open it.")
        let accessory = Self.passwordAccessory(
            field: field, checkbox: Self.makeSaveCheckbox())
        let container = NSView(frame: accessory.frame.insetBy(dx: -20, dy: -20))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        accessory.setFrameOrigin(NSPoint(x: 20, y: 20))
        container.addSubview(accessory)
        return container
    }

    private static func passwordAccessory(field: NSSecureTextField,
                                          checkbox: NSButton) -> NSView {
        let stack = NSStackView(views: [field, checkbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // 入力欄の幅はチェックボックスのラベル幅に合わせる(下限 240)。
        // frame をラベルより狭く固定するとラベル右側が切れるため、
        // アクセサリ全体を実サイズ(fittingSize)に合わせる
        let width = ceil(max(240, checkbox.intrinsicContentSize.width))
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        let fitting = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
        return stack
    }

    /// パスワード書庫のロック解除(仕様書 §4.1.3)。
    /// 旧実装の「正解かキャンセルまで無限に再表示」をやめ、3 回で打ち切る。
    /// 保存済みパスワード(PasswordVault)があれば先に無言で試し、成功なら
    /// ダイアログを出さない(自動解錠。設計書 §2.4)
    private func unlock(_ source: any BookSource) async -> UnlockResult {
        // UI 検証用の隠しフック/XCTest 実行(モーダルを出さずキャンセル扱いにする)
        if ProcessInfo.processInfo.environment["COOVIEWER_UI_TEST_CANCEL_PASSWORD"] != nil
            || AutomatedRun.isXCTest,
           await source.isEncrypted() {
            return .cancelled
        }
        let vaultKey = PasswordVault.Key.file(path: source.url.path)
        if settings.passwordVaultEnabled, await source.isEncrypted(),
           let saved = await PasswordVault.shared.password(for: vaultKey) {
            if await source.checkAndSetPassword(saved) {
                // 保存済み=同意済み。同じパスワードのネスト子にも保存を展延
                await source.notePasswordSaveConsent(saved)
                return .unlocked
            }
            // パスワードが変更された書庫: 無言で従来のダイアログへ
            // (試行回数は消費しない。成功時に上書き保存される)
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
            let saveCheckbox = Self.makeSaveCheckbox()
            alert.accessoryView = settings.passwordVaultEnabled
                ? Self.passwordAccessory(field: field, checkbox: saveCheckbox)
                : field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
            let save = settings.passwordVaultEnabled && saveCheckbox.state == .on
            if settings.passwordVaultEnabled {
                // チェック状態は誤入力でも記憶する(ネスト側ダイアログと同じ)
                settings.passwordVaultSaveByDefault = save
            }
            if await source.checkAndSetPassword(field.stringValue) {
                if save {
                    await PasswordVault.shared.save(field.stringValue, for: vaultKey)
                    await source.notePasswordSaveConsent(field.stringValue)
                }
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
        // 表示中ページの処理を最優先にする: 実行中の先読み(ML 含む)を
        // 即キャンセルして ML 実行キューを明け渡す(SR はタイル毎に
        // キャンセルを見るため ~50ms で止まる)。先読みは表示確定後に
        // preresampleAdjacentSpread が組み直す。
        // ただしページを処理中の場合は、それが「これから表示するページ」かも
        // しれない(処理中のページへのジャンプ)ため、表示対象が判明する
        // まで判断を保留する(下の displayedEntryIDs 確定後に判定)
        if preresamplingEntryID == nil {
            preresampleTask?.cancel()
        }
        // 読み込み〜補間完成までの進行表示(表示予約。デコードとリサンプルが
        // 速ければ 250ms の猶予内に ReaderView 側の通知が消すので出ない)
        if book.pageCount > 0 {
            setResampleIndicator(true)
        }
        // ウインドウ実寸に応じたデコード上限の自己修復(拡大時は再デコード)
        _ = await book.updateDisplayPixelCap(currentDisplayPixelCap())
        displayGeneration += 1
        let generation = displayGeneration
        let spread = await book.currentSpread()
        // 連打等でより新しい表示更新が始まっていたら、この結果は捨てる
        guard generation == displayGeneration, book === self.book else { return }

        // 一回消費フラグ(めくり向き・合本到達方向・先頭強制)は、連打・競合を
        // 弾く supersession ガードを通過した「勝ち残る表示」でだけ消費する。
        // ガードより前で消費すると、await 中に後発の表示が displayGeneration を
        // 進めた場合に本 pass は上の guard で return して意味を失い、勝ち残る
        // pass には nil が渡る(合本の後退到達が末尾でなく先頭で開く等の取り
        // こぼし)。代理ページ以外へ着地しても必ずここで消費・クリアするため、
        // 残留が後の自動入場を汚染することはない
        let turnForward = pendingTurnForward
        pendingTurnForward = nil
        let collectionArrival = epubCollectionArrivalForward
        epubCollectionArrivalForward = nil
        let collectionArrivalAtFirst = epubCollectionArrivalAtFirst
        epubCollectionArrivalAtFirst = false

        // コレクション(合本)内のリフロー EPUB 代理ページ: 表示せず EPUB
        // モードへ切り替える(前進到達は先頭/復元、後退到達は末尾から。
        // 代理ページは常に単独スプレッドなので素通りしない)。
        // 恒久に開けない本(FXL/DRM)は自動入場せず静的な表紙として表示する
        // (epubFailedPlaceholders)。一過性失敗は「今回だけ」表紙にして次回再入場を
        // 試みる消費式(epubTransientFailedPlaceholders。下の remove を参照)
        if let (entryIndex, epubURL) = spread.indices.lazy.compactMap({ index in
            book.entries.indices.contains(index)
                ? book.entries[index].reflowEPUBURL.map { (index, $0) } : nil
        }).first, !epubFailedPlaceholders.contains(epubURL) {
            // 一過性失敗直後の再着地は「今回だけ」代理表紙として通常描画へ流す
            // (消費式)。remove がヒット = 一過性直後 → return せず下の通常描画で
            // 表紙を出す。恒久ブラックリスト(FXL/DRM)と違い消費後の再着地では
            // また入場を試みる。消費は必ず「入場判断の直前」で(位置がずれると
            // ループ再発)
            if epubTransientFailedPlaceholders.remove(epubURL) == nil {
                setResampleIndicator(false)  // この表示は Web ビューが担う(消し忘れ防止)
                enterCollectionReflowEPUB(url: epubURL, entryIndex: entryIndex,
                                          forward: collectionArrival ?? turnForward ?? true,
                                          atFirst: collectionArrivalAtFirst)
                return
            }
        }

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
        displayedEntryIDs = Set(ids)
        // デコード先読みの深さを実ページサイズ・メモリ条件へ追従させる
        updatePrefetchDepth(book: book, images: images)
        // 保留していた先読みキャンセルの確定: 処理中のページが表示対象なら
        // 完走させて結果をそのまま表示に使う(途中まで進んだ推論を捨てて
        // 最初からやり直すより速い。タスクは世代チェックで自然停止する)
        if let current = preresamplingEntryID, !displayedEntryIDs.contains(current) {
            preresampleTask?.cancel()
        }
        // めくり効果: ページ送りで来た表示のみ。「視差効果を減らす」尊重
        let turn: ReaderView.PageTurn? = {
            guard let turnForward else { return nil }
            let animation = settings.pageTurnAnimation
            guard animation != .none,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            else { return nil }
            return ReaderView.PageTurn(animation: animation, forward: turnForward)
        }()
        // リサンプル済みキャッシュの事前引き当て(照会のみ。事前リサンプルが
        // 温めた完成画像があれば、最初のレイアウト=めくり効果のスナップショット
        // からフィルタ済みの絵を使える)
        var preResampled: [(size: CGSize, image: CGImage)?] = []
        if let targets = readerView.predictedResampleSizes(
            for: images.map { CGSize(width: $0.width, height: $0.height) }) {
            let useMetalFX = settings.interpolation == .high
            let level = settings.noiseReductionLevel
            for (position, image) in images.enumerated() {
                let hit = await ImageResampler.shared.cached(
                    image, to: targets[position],
                    cacheKey: "\(book.cacheKey)#\(ids[position])",
                    upscaleWithMetalFX: useMetalFX, noiseReduction: level)
                preResampled.append(hit.map { (targets[position], $0) })
            }
        }
        readerView.setPages(images, ids: ids,
                            readsFromLeft: book.readMode.readsFromLeft,
                            preResampled: preResampled,
                            turn: turn)
        // スマートズーム直後の再デコード(キャップ上昇)では setPages が
        // スクロールを先頭へ戻すため、同一スプレッドに限りアンカーを再適用する
        if let pending = pendingScrollAnchor {
            pendingScrollAnchor = nil
            if book.currentIndex == pending.index {
                readerView.scroll(toAnchorRatio: pending.ratio)
            }
        }
        // 連続ピンチズーム確定の再デコード: 倍率とアンカーを復元する
        // (setPages が zoomScale=1 に落とすため。同一スプレッドのみ)
        if let pending = pendingZoom {
            pendingZoom = nil
            if book.currentIndex == pending.index {
                readerView.restoreZoom(scale: pending.scale, anchorRatio: pending.ratio)
            }
        }
        readerView.window?.makeFirstResponder(readerView)
        updatePageIndicators(spread: spread)
        if readerView.isLoupeEnabled {
            requestLoupeHighResolution()
        }
        maybePrepareNextBook()
        startAnimationsIfNeeded(spread: spread)
        // サムネイル表示中は本の変化に追従する(%ジャンプ・しおり移動のほか、
        // ソート変更等でエントリ列が変わった場合は一覧を組み直す)
        lastSpreadIndices = spread.indices
        if isThumbnailOverlayVisible {
            if let active = activeCollectionOverlay {
                if active.baseEntries == book.entries {
                    // 展開一覧: エントリ列が合本と異なるため follow に渡さない
                    // (渡すと未展開へ巻き戻り、残った plan ベースの onJump が
                    // 誤ジャンプする)。セルへ写像して強調・画面追従だけ更新
                    thumbnailOverlayModel.focus(
                        currentIndex: active.plan.overlayIndex(
                            forBookPage: book.currentIndex),
                        displayedIndices: spread.indices.map {
                            active.plan.overlayIndex(forBookPage: $0)
                        })
                } else {
                    // 並び替え等でエントリ列が変わった: onJump ごと組み直し、
                    // 展開も再スケジュールする
                    presentThumbnailOverlay(for: book)
                }
            } else {
                thumbnailOverlayModel.follow(book: book,
                                             displayedIndices: spread.indices)
            }
        }
        preresampleAdjacentSpread()
    }

    /// 進行方向の隣のスプレッド列を表示ピクセルサイズへ事前リサンプルして
    /// ImageResampler の LRU に載せる(設計書 §5 描画品質)。めくった直後の
    /// 最初の描画から等倍のシャープな画像になる(従来は一瞬 CALayer の
    /// trilinear 表示 → リサンプル完成後に差し替えだった)。
    /// 先へ進む量はメモリ予算(PreresamplePolicy: 1 ページの表示サイズ ×
    /// 枚数が物理メモリの 1/8・最大 4GB に収まる数。ページ数上限 64 は
    /// 小さすぎるページでの保険)まで。近いスプレッドから順に行い、現スプレッドのリサンプル
    /// (scheduleHighQualityResample)と GPU を奪い合わないよう少し遅らせて
    /// 始め、表示が先へ進んでいたら残りを捨てる
    private func preresampleAdjacentSpread(sparingInFlight: Bool = false) {
        guard let book, book.pageCount > 0 else { return }
        let forward = book.lastMoveForward
        let generation = displayGeneration
        // 実行番号を進めて旧タスクを(ソフト)停止させる。
        // sparingInFlight(フィルタ切替)と「表示対象を処理中」の場合は
        // 切らずに完走させ(結果はキャッシュへ)、現在のページの後に
        // 実行番号チェックで自然停止させる。それ以外は即キャンセル
        preresampleRun += 1
        let run = preresampleRun
        let sparesInFlight = sparingInFlight
            || preresamplingEntryID.map { displayedEntryIDs.contains($0) } == true
        if !sparesInFlight {
            preresampleTask?.cancel()
        }
        preresampleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let self, let book = self.book,
                  generation == self.displayGeneration else { return }
            // 表示中スプレッドの補間(ML 含む)完了を待ってから積む:
            // ML 実行は actor の FIFO のため、ここで先に並ぶと見開き
            // 2 枚目の表示処理が先読み 1 ページ分待たされてしまう
            while self.readerViewForInput.isResamplingDisplayedPages,
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, generation == self.displayGeneration,
                  run == self.preresampleRun, book === self.book else { return }
            let spreads = await book.predictedAdjacentSpreads(
                forward: forward, maxPages: PreresamplePolicy.maxPages)
            guard !spreads.isEmpty else { return }
            // 先読み処理中の薄い進行表示(タスク終了時に必ず対で消す)
            self.setPrefetchIndicator(true)
            defer { self.setPrefetchIndicator(false) }
            let useMetalFX = self.settings.interpolation == .high
            // ページ数の予算は最初のスプレッドの表示サイズが判明した時点で確定する
            var pageLimit = PreresamplePolicy.maxPages
            var limitComputed = false
            var resampledPages = 0
            // 計画枚数(残数表示用)。予算確定前は maxPages 内での見込み
            let plannedPages = min(spreads.reduce(0) { $0 + $1.count },
                                   PreresamplePolicy.maxPages)
            self.notePrefetchPlan(planned: plannedPages)
            for indices in spreads {
                var images: [CGImage] = []
                for index in indices {
                    // 先読み済みならキャッシュ命中、未了なら進行中のデコードに
                    // 合流。HDR(>8bit)ページは通常表示側もリサンプルしないので
                    // 対象外(以降はさらに遠いページなので打ち切ってよい)
                    guard let image = await book.image(at: index),
                          image.bitsPerComponent <= 8 else { return }
                    images.append(image)
                }
                // デコード待ちの間に表示が進んでいたら残りを破棄する
                // (次の refreshDisplay が改めて予約する)
                guard generation == self.displayGeneration,
                      book === self.book else { return }
                let sizes = images.map { CGSize(width: $0.width, height: $0.height) }
                guard let targets = self.readerViewForInput.predictedResampleSizes(
                    for: sizes) else { return }
                if !limitComputed, let first = targets.first {
                    let bytesPerPage = Int(first.width) * Int(first.height) * 4
                    pageLimit = PreresamplePolicy.pageBudget(
                        bytesPerPage: bytesPerPage,
                        physicalMemory: ProcessInfo.processInfo.physicalMemory)
                    limitComputed = true
                    // 予算確定で計画枚数を精緻化(残数表示に反映)
                    self.notePrefetchPlan(
                        planned: min(spreads.reduce(0) { $0 + $1.count }, pageLimit))
                }
                for (position, image) in images.enumerated() {
                    // 表示要求を優先(キャンセル)。ソフト停止で残した
                    // 旧タスク(表示対象の完走・フィルタ切替)は世代または
                    // 実行番号のずれでここで止まる
                    guard !Task.isCancelled,
                          generation == self.displayGeneration,
                          run == self.preresampleRun else { return }
                    let index = indices[position]
                    guard book.entries.indices.contains(index) else { continue }
                    // キーは ReaderView の実表示時と同一(ML 高画質化の段階も
                    // 含めて同一条件で先行計算し、そこでキャッシュ命中する)。
                    // 処理中エントリを公開して「そのページへのジャンプ時は
                    // キャンセルせず完走」判定に使わせる
                    self.preresamplingEntryID = book.entries[index].id
                    _ = await ImageResampler.shared.resample(
                        image, to: targets[position],
                        cacheKey: "\(book.cacheKey)#\(book.entries[index].id)",
                        upscaleWithMetalFX: useMetalFX,
                        noiseReduction: self.settings.noiseReductionLevel,
                        superResEncrypted: self.currentBookIsEncrypted)
                    self.preresamplingEntryID = nil
                    resampledPages += 1
                    self.notePrefetchProgress(done: resampledPages)  // 残数表示に反映
                }
                guard resampledPages < pageLimit else { return }
            }
        }
    }

    /// アニメーション画像(GIF/WebP 等)の再生(設定でオフ可。設計書 §5)
    private func startAnimationsIfNeeded(spread: Book.Spread) {
        guard settings.playAnimatedImages, let book else { return }
        let animatable: Set<String> = ["gif", "png", "apng", "webp", "heics", "avif", "avifs"]
        for (position, index) in spread.indices.enumerated() {
            guard book.entries.indices.contains(index) else { continue }
            let entry = book.entries[index]
            // 一度「静止画」と判定したページは再判定しない(PNG が大半の本で
            // 表示のたびに生データを読み直す無駄の防止)
            guard !book.probedStaticAnimationIDs.contains(entry.id) else { continue }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            guard animatable.contains(ext) else { continue }
            // デコード(最大 120 フレーム)はメインアクターの外で行う。
            // 解像度はページレイヤの実ピクセルに合わせる(全フレーム常駐のため、
            // 一律 2048px より大幅に省メモリ)
            let source = book.source
            let frameCap: Int? = readerViewForInput.pageFramePixelSize(at: position)
                .map { Int(max($0.width, $0.height).rounded(.up)) }
                .flatMap { $0 > 0 ? $0 : nil }
            // 実効キャップ(AnimatedImage 側の上限 2048 を反映)を記録し、
            // ウインドウ拡大時の再デコード要否判定(下記)に使う
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
            if needed > loaded + loaded / 4 {
                startAnimationsIfNeeded(
                    spread: .init(indices: lastSpreadIndices, images: []))
                return
            }
        }
    }

    /// ページバーホバー: ページ番号+サムネイルの吹き出し(仕様書 §3.4)
    private func handlePageBarHover(_ info: (x: CGFloat, fraction: Double)?) {
        guard let info, let contentView = window?.contentView else {
            pageBarBubble.isHidden = true
            bubbleHoverIndex = -1
            bubbleThumbnailPending = nil
            return
        }
        if isEPUBMode {
            handleEPUBPageBarHover(info, contentView: contentView)
            return
        }
        guard let book, book.pageCount > 0 else {
            pageBarBubble.isHidden = true
            bubbleHoverIndex = -1
            bubbleThumbnailPending = nil
            return
        }
        // 合本の全体マップがあるときは吹き出しも全体基準に揃える
        // (バーの進捗・クリック着地と同じ式。ずれるとプレビューと違う場所へ飛ぶ)
        let map = activeCollectionPageMap()
        let globalPage: Int
        let totalLabel: Int
        var thumbnailRequest: (() async -> CGImage?)?
        let imageThumbnail: (Int) -> (() async -> CGImage?)? = { index in
            guard book.entries.indices.contains(index) else { return nil }
            let entry = book.entries[index]
            let source = book.source
            let bookKey = book.cacheKey
            return {
                // ホバー中のプレビューは対話的要求 → 生成ゲートの優先レーンへ
                await ThumbnailCache.shared.thumbnail(
                    for: entry, in: source, bookKey: bookKey, urgent: true)
            }
        }
        if let map {
            globalPage = Int((min(max(info.fraction, 0), 1)
                * Double(max(1, map.total - 1))).rounded())
            totalLabel = map.total
            switch map.target(forGlobalPage: globalPage) {
            case .bookPage(let bookIndex):
                thumbnailRequest = imageThumbnail(bookIndex)
            case .epubPage(let url, _, let spineIndex, let pageInItem, _):
                // EPUB 区間は該当画面の実プレビュー(代理表紙ではなく)。
                // マップの census と同一メトリクスで整合させる
                // (EPUB モード側の「別 URL」分岐と同じ経路)
                let metrics = EPUBScreenMetrics(
                    viewportSize: contentView.bounds.size,
                    settings: plannedEPUBSettings())
                let isDark = isDarkWindowAppearance
                thumbnailRequest = {
                    await EPUBAtlasStore.shared.thumbnail(
                        for: url, spineIndex: spineIndex,
                        pageInItem: pageInItem, metrics: metrics,
                        isDark: isDark, width: 296)
                }
            }
        } else {
            globalPage = min(book.pageCount - 1,
                             max(0, Int(info.fraction * Double(book.pageCount))))
            totalLabel = book.pageCount
            thumbnailRequest = imageThumbnail(globalPage)
        }
        // EPUB モードのキー空間(page / 1_000_000+page / -2)と衝突させない
        let hoverKey = 2_000_000 + globalPage
        let showsThumbnail = settings.pageBarShowThumbnail
            && thumbnailRequest != nil
        layoutPageBarBubble(hoverX: info.x, label: "\(globalPage + 1)/\(totalLabel)",
                            showsThumbnail: showsThumbnail,
                            contentView: contentView)
        guard hoverKey != bubbleHoverIndex else { return }
        bubbleHoverIndex = hoverKey
        bubbleImageView.image = nil
        guard showsThumbnail, let thumbnailRequest else { return }
        requestBubbleThumbnail(hoverKey: hoverKey) { [weak self] in
            let image = await thumbnailRequest()
            // 本の切替を跨いだ配達を防ぐ(キーは本をまたいで重複し得る)
            return self?.book === book ? image : nil
        }
    }

    /// バブルの寸法・位置・番号の共通レイアウト(画像本/EPUB 共用)。
    /// サムネイル無しのときは番号だけの小さなバブルにする(§6.1 PageBarShowThumbnail)
    private func layoutPageBarBubble(hoverX: CGFloat, label: String,
                                     showsThumbnail: Bool, contentView: NSView) {
        bubbleImageView.isHidden = !showsThumbnail
        pageBarBubble.setFrameSize(showsThumbnail
            ? NSSize(width: 148, height: 190) : NSSize(width: 96, height: 30))
        bubbleLabel.frame = NSRect(x: 0, y: 6, width: pageBarBubble.frame.width,
                                   height: 18)
        let barFrame = pageBar.frame
        var x = barFrame.minX + hoverX - pageBarBubble.frame.width / 2
        x = min(max(8, x), contentView.bounds.width - pageBarBubble.frame.width - 8)
        // バーが画面下半分なら上側へ出す(下配置設定への対応)
        let bubbleY = barFrame.midY < contentView.bounds.midY
            ? barFrame.maxY + 6
            : barFrame.minY - pageBarBubble.frame.height - 6
        pageBarBubble.setFrameOrigin(NSPoint(x: x, y: bubbleY))
        bubbleLabel.stringValue = label
        pageBarBubble.isHidden = false
    }

    /// ホバーサムネイルの要求(画像本/EPUB 共用)。最新の要求だけを残し、
    /// 完了時に待機分があれば 1 本だけ流す。EPUB の画面レンダラは FIFO 直列で
    /// キャンセル不能のため、要求側で本数を絞らないとスクラブで放棄ジョブが
    /// 積もり、最後のプレビューが全排出後まで届かない(レビュー指摘)
    private func requestBubbleThumbnail(hoverKey: Int,
                                        request: @escaping () async -> CGImage?) {
        bubbleThumbnailPending = (hoverKey, request)
        pumpBubbleThumbnail()
    }

    private func pumpBubbleThumbnail() {
        guard !bubbleThumbnailInFlight,
              let pending = bubbleThumbnailPending else { return }
        bubbleThumbnailPending = nil
        bubbleThumbnailInFlight = true
        Task { [weak self] in
            let image = await pending.request()
            guard let self else { return }
            self.bubbleThumbnailInFlight = false
            if self.bubbleHoverIndex == pending.key, let image {
                self.bubbleImageView.image = NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height))
            }
            self.pumpBubbleThumbnail()
        }
    }

    /// EPUB モードのページバーホバー。合本マップがあれば全体基準
    /// (バー進捗・クリック着地と同じ式)、単体はリーダー census の
    /// 本単位、census 未完了は進行率のみの小バブル。プレビューは
    /// 実ページ=ThumbnailCache / 同一 EPUB=画面レンダラ / 別 EPUB=アトラス
    private func handleEPUBPageBarHover(_ info: (x: CGFloat, fraction: Double),
                                        contentView: NSView) {
        guard let epubView else {
            pageBarBubble.isHidden = true
            bubbleHoverIndex = -1
            bubbleThumbnailPending = nil
            return
        }
        let fraction = min(max(info.fraction, 0), 1)
        let label: String
        let hoverKey: Int
        var thumbnailRequest: (() async -> CGImage?)?
        if let map = activeCollectionPageMap(),
           epubView.currentGlobalPageRange != nil,
           let context = epubCollectionContext {
            // 合本全体基準
            let page = Int((fraction * Double(max(1, map.total - 1))).rounded())
            label = "\(page + 1)/\(map.total)"
            hoverKey = page
            switch map.target(forGlobalPage: page) {
            case .bookPage(let index):
                if context.entries.indices.contains(index) {
                    let entry = context.entries[index]
                    let source = context.source
                    // 未展開一覧と同じキー(キャッシュ共有)
                    let bookKey =
                        "col:\(context.folderURL.path)#raw\(context.entries.count)"
                    thumbnailRequest = {
                        // ホバープレビューは対話的要求 → 優先レーンへ
                        await ThumbnailCache.shared.thumbnail(
                            for: entry, in: source, bookKey: bookKey, urgent: true)
                    }
                }
            case .epubPage(let url, _, let spineIndex, let pageInItem, _):
                if url == epubBookURL {
                    thumbnailRequest = { [weak epubView] in
                        await epubView?.screenThumbnail(
                            spineIndex: spineIndex, pageInItem: pageInItem,
                            width: 296)
                    }
                } else {
                    let metrics = EPUBScreenMetrics(
                        viewportSize: contentView.bounds.size,
                        settings: plannedEPUBSettings())
                    let isDark = isDarkWindowAppearance
                    thumbnailRequest = {
                        await EPUBAtlasStore.shared.thumbnail(
                            for: url, spineIndex: spineIndex,
                            pageInItem: pageInItem, metrics: metrics,
                            isDark: isDark, width: 296)
                    }
                }
            }
        } else if let counts = epubView.pageCensus,
                  let total = epubView.censusTotalPages, total > 0 {
            // 本単位(単体 EPUB、または合本マップ未構築)
            let page = Int((fraction * Double(max(1, total - 1))).rounded())
            label = "\(page + 1)/\(total)"
            hoverKey = 1_000_000 + page  // 合本キーと区別
            var spineIndex = max(0, counts.count - 1)
            var pageInItem = max(0, max(1, counts.last ?? 1) - 1)
            var cursor = page
            for (item, count) in counts.enumerated() {
                let pages = max(1, count)
                if cursor < pages {
                    spineIndex = item
                    pageInItem = cursor
                    break
                }
                cursor -= pages
            }
            let targetSpine = spineIndex
            let targetPage = pageInItem
            thumbnailRequest = { [weak epubView] in
                await epubView?.screenThumbnail(
                    spineIndex: targetSpine, pageInItem: targetPage, width: 296)
            }
        } else {
            // census 未完了: 進行率だけ(バー表示と同じ近似基準)
            label = "\(Int((fraction * 100).rounded()))%"
            hoverKey = -2
        }
        let showsThumbnail = settings.pageBarShowThumbnail
            && thumbnailRequest != nil
        layoutPageBarBubble(hoverX: info.x, label: label,
                            showsThumbnail: showsThumbnail,
                            contentView: contentView)
        guard hoverKey != bubbleHoverIndex else { return }
        bubbleHoverIndex = hoverKey
        bubbleImageView.image = nil
        guard showsThumbnail, let thumbnailRequest else { return }
        requestBubbleThumbnail(hoverKey: hoverKey, request: thumbnailRequest)
    }

    // MARK: - オープン進捗 HUD

    /// オープン処理の開始を記録し、0.35 秒経っても終わらなければ HUD を出す
    /// (即終わる本でのちらつき防止)。大書庫入りフォルダの統合は全書庫の
    /// 一覧取得を伴い数十秒かかり得るため、無反応に見えるのを防ぐ
    func beginOpeningProgress(generation: Int, name: String) {
        openingFlowGeneration = generation
        openingProgressName = name
        openingProgressCounts = nil
        // ドリルダウンからの引き継ぎで既に表示中なら名前だけ差し替える
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
    func noteOpeningProgress(generation: Int, done: Int, total: Int) {
        guard openingFlowGeneration == generation else { return }
        openingProgressCounts = (done, total)
        if !openingProgressBox.isHidden {
            updateOpeningProgressText()
        }
    }

    /// オープン処理の終了(成功・失敗・ドリル前とも)。HUD を畳む
    func endOpeningProgress(generation: Int) {
        guard openingFlowGeneration == generation else { return }
        endAnyOpeningProgress()
    }

    /// 世代を問わず HUD を畳む(ドリル先の消失など、引き継ぎ先のない失敗用)
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
    func debugShowOpeningProgress() {
        openingFlowGeneration = -1
        openingProgressName = "サンプルシリーズ"
        openingProgressCounts = (done: 12, total: 34)
        revealOpeningProgress()
    }

    /// ページのない本(空/開けなかった)の理由と操作案内を中央に表示する
    private func showBookStatusMessage(_ reason: String) {
        statusLabel.stringValue = reason + "\n"
            + String(localized: "Turn the page or use Next Book to continue.")
        statusLabel.isHidden = false
        pageLabel.isHidden = true
        pageBar.isHidden = true
    }

    private func updatePageIndicators(spread: Book.Spread) {
        updatePageIndicators(indices: spread.indices)
    }

    func updatePageIndicators(indices: [Int]) {
        guard let book, book.pageCount > 0 else {
            pageLabel.stringValue = ""
            pageBar.progress = 0
            return
        }
        // 合本に展開マップがあれば「全体ページ」基準(EPUB を census
        // ページ数で数える。書庫内 zip と同じ §3.4 の意味論)。
        // 無ければ従来どおり合本ページ基準(census が揃うまでの繋ぎ)
        ensureCollectionPageMap()
        let map = activeCollectionPageMap()
        let pageNumber: (Int) -> Int = { index in
            map.map { $0.globalStart(forEntry: index) + 1 } ?? (index + 1)
        }
        let totalPages = map?.total ?? book.pageCount
        let shown = indices.map { String(pageNumber($0)) }
        let numbers = shown.count == 2 ? "\(shown[0])-\(shown[1])" : (shown.first ?? "-")
        // 旧実装のページ番号表示は「#N-M/総数 (ファイル名 / ファイル名)」と
        // 表示中のファイル名を併記していた(仕様書 §3.4)。読み順に並べる
        let relativePaths = settings.showRelativePaths
        let names = indices.compactMap { index in
            book.entries.indices.contains(index)
                ? book.entries[index].displayTitle(relativePath: relativePaths) : nil
        }.joined(separator: " / ")
        pageLabel.stringValue = names.isEmpty
            ? " \(numbers)/\(totalPages) "
            : " \(numbers)/\(totalPages) (\(names)) "
        let lastShown = pageNumber(indices.last ?? 0)
        pageBar.progress = Double(lastShown) / Double(totalPages)
        pageBar.readsFromLeft = book.readMode.readsFromLeft
    }

    // MARK: - ナビゲーション

    private func showNext() {
        guard let book else { return }
        switch book.moveNext() {
        case .moved:
            pendingTurnForward = true
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
                pendingTurnForward = false
                await refreshDisplay()
            case .hitStart:
                handleStartOfBook()
            case .hitEnd:
                break
            }
        }
    }

    /// 巻末超え(仕様書 §4.3.4)
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
                // 巻頭ループで同じ合本の末尾へ戻る。末尾が代理 EPUB のとき
                // 後退到達として末尾から開く(監査 #1。設定なしだと先頭で開く)
                epubCollectionArrivalForward = false
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
                pendingTurnForward = false
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

    /// 拡大中のページ送りは「引いてからめくる」: 先にズームを 1.0 へ戻し、
    /// フィットになってから実際の送り(=設定のめくり演出)を行う(設計書 §2.4)。
    /// 等倍・視差効果オフのときは即実行(animateZoomOut が判定)
    private func turningPage(_ body: @escaping () -> Void) {
        // めくり効果が「なし」のときは、ズームアウト演出も付けず即座に送る
        // (「効果なし」を一貫させる。setPages が zoomScale を 1 に戻す)。
        // 視差効果オフ・等倍時の即実行は animateZoomOut 側が判定する
        guard settings.pageTurnAnimation != .none else {
            body()
            return
        }
        readerView.animateZoomOut(completion: body)
    }

    @objc func nextPage(_ sender: Any?) {
        if isEPUBMode { epubGoForward(); return }
        turningPage { [weak self] in self?.showNext() }
    }
    @objc func previousPage(_ sender: Any?) {
        if isEPUBMode { epubGoBackward(); return }
        turningPage { [weak self] in self?.showPrevious() }
    }

    @objc func halfNextPage(_ sender: Any?) {
        if isEPUBMode { epubGoForward(); return }
        turningPage { [weak self] in
            guard let self, let book = self.book else { return }
            if book.moveHalfNext() == .moved {
                self.pendingTurnForward = true
                Task { await self.refreshDisplay() }
            }
        }
    }

    @objc func halfPreviousPage(_ sender: Any?) {
        if isEPUBMode { epubGoBackward(); return }
        turningPage { [weak self] in
            guard let self, let book = self.book else { return }
            if book.moveHalfPrevious() == .moved {
                self.pendingTurnForward = false
                Task { await self.refreshDisplay() }
            }
        }
    }

    @objc func goToFirstPage(_ sender: Any?) {
        if isEPUBMode { epubGoToFirst(); return }
        book?.goToFirst()
        Task { await refreshDisplay() }
    }

    @objc func goToLastPage(_ sender: Any?) {
        if isEPUBMode { epubGoToLast(); return }
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

    /// 補間(描画品質)の切替。ML 段階は設定ペインと同じ規則で
    /// 初回に同意を取ってから設定する(§7.5 メニューと設定の同値性)
    @objc func changeInterpolation(_ sender: NSMenuItem) {
        guard let quality = RenderQuality(rawValue: sender.tag) else { return }
        let defaults = UserDefaults.standard
        switch quality {
        case .mlDenoise:
            if !defaults.bool(forKey: "NoiseReductionMLAccepted") {
                guard confirmMLDownload(
                    title: String(localized: "Use the “Very High (ML denoise)” level?"),
                    message: String(localized:
                        "A small model (about 1.2 MB) will be downloaded on first use. This method is much heavier: displaying a page can take a few seconds.")
                ) else { return }
                defaults.set(true, forKey: "NoiseReductionMLAccepted")
            }
            settings.renderQuality = quality
            Task { await MLNoiseReducer.shared.ensureModel() }
        case .mlSuperRes:
            if !defaults.bool(forKey: "NoiseReductionSRAccepted") {
                guard confirmMLDownload(
                    title: String(localized: "Use the “Maximum (×4 ML upscale)” level?"),
                    message: String(localized:
                        "A model (about 9 MB) will be downloaded on first use. Each page is upscaled 4× by a neural network — this is the heaviest level: a page can take several seconds, and results are cached on disk.")
                ) else { return }
                defaults.set(true, forKey: "NoiseReductionSRAccepted")
            }
            settings.renderQuality = quality
            Task { await MLSuperResolver.shared.ensureModel() }
        case .none, .standard, .high:
            settings.renderQuality = quality
        }
    }

    /// ML モデルのダウンロード同意ダイアログ(メニュー経由の切替用)
    private func confirmMLDownload(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Download and Use"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 表紙を単ページで表示(見開きモード時のみ効果。設定と同じ defaults を共有)
    @objc func toggleCoverSingleMenu(_ sender: Any?) {
        settings.spreadCoverSingle.toggle()
    }

    @objc func toggleInterpolationMenu(_ sender: Any?) {
        settings.toggleInterpolationNone()
    }

    /// ページめくり効果の切替(設定「表示」ペインと同じ defaults を共有)
    @objc func changePageTurnAnimation(_ sender: NSMenuItem) {
        guard let animation = PageTurnAnimation(rawValue: sender.tag) else { return }
        settings.pageTurnAnimation = animation
    }

    /// ルーペの切替(キー割当 l と同じ toggleLoupe。⌘L)
    @objc func toggleLoupeMenu(_ sender: Any?) {
        toggleLoupe()
    }

    /// ドラッグ中のジェスチャ方向 HUD の表示切替(設定「操作」と同じ defaults を共有)
    @objc func toggleGestureHUDMenu(_ sender: Any?) {
        settings.gestureHUDEnabled.toggle()
    }

    /// 音声メディアオーバーレイ(SMIL)の再生⇔一時停止(既定オフ。EPUB で
    /// オーバーレイを持つ項目のときだけ有効。切替式なので既定は再生していない)
    @objc func toggleMediaOverlayMenu(_ sender: Any?) {
        guard isEPUBMode else { return }
        epubView?.toggleMediaOverlayPlayback()
    }

    @objc func rotateLeft(_ sender: Any?) {
        readerView.rotation += 1  // 仕様書 §4.15: rotateLeft はインクリメント
    }

    @objc func rotateRight(_ sender: Any?) {
        readerView.rotation -= 1
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        // ---- 画像表示専用の設定項目: EPUB モードでは無効(灰色)にする。
        // かつては validate 対象外で「有効表示のまま無効果」だった
        // (cooViewer-c6s.20。回転は非表示の readerView に効いて画像モード
        // 復帰時に残る副作用まであった)
        case #selector(changeFitMode(_:)):
            menuItem.state = readerView.fitMode.rawValue == menuItem.tag ? .on : .off
            return !isEPUBMode
        case #selector(changeReadMode(_:)):
            menuItem.state = book?.readMode.rawValue == menuItem.tag ? .on : .off
            return book != nil
        case #selector(changeInterpolation(_:)):
            menuItem.state = settings.renderQuality.rawValue == menuItem.tag ? .on : .off
            return !isEPUBMode
        case #selector(toggleInterpolationMenu(_:)),
             #selector(rotateLeft(_:)), #selector(rotateRight(_:)):
            return !isEPUBMode
        case #selector(toggleCoverSingleMenu(_:)):
            menuItem.state = settings.spreadCoverSingle ? .on : .off
            return !isEPUBMode
        case #selector(toggleMediaOverlayMenu(_:)):
            // 再生中はチェック。オーバーレイを持つ EPUB 項目のときだけ有効
            menuItem.state = (epubView?.isPlayingMediaOverlay ?? false) ? .on : .off
            return isEPUBMode && (epubView?.hasMediaOverlayForCurrentItem ?? false)
        case #selector(changePageTurnAnimation(_:)):
            menuItem.state = settings.pageTurnAnimation.rawValue == menuItem.tag
                ? .on : .off
            return true  // めくり効果は EPUB でも有効(カール含む)
        case #selector(toggleLoupeMenu(_:)):
            menuItem.state = readerView.isLoupeEnabled ? .on : .off
            return (book?.pageCount ?? 0) > 0
        case #selector(toggleGestureHUDMenu(_:)):
            menuItem.state = settings.gestureHUDEnabled ? .on : .off
            return !isEPUBMode  // EPUB にドラッグジェスチャ経路がない
        case #selector(nextPage(_:)), #selector(previousPage(_:)),
             #selector(halfNextPage(_:)), #selector(halfPreviousPage(_:)),
             #selector(goToFirstPage(_:)), #selector(goToLastPage(_:)):
            // ページ送り系は EPUB モードでも有効
            return (book?.pageCount ?? 0) > 0 || isEPUBMode
        // ---- 本(Book)前提の機能: 空の本・EPUB モードでは無効。
        // かつて default(常に有効)だった項目も guard book で無反応だったため
        // 明示的に灰色へ(しおり・スライドショー・ファイル情報等。c6s.20)
        case #selector(showThumbnailsMenu(_:)):
            // サムネイル一覧は EPUB(画面単位の一覧)でも有効
            return (book?.pageCount ?? 0) > 0 || isEPUBMode
        case #selector(cycleReadMode(_:)),
             #selector(editBookmarksMenu(_:)),
             #selector(addRemoveBookmarkMenu(_:)),
             #selector(nextBookmarkMenu(_:)), #selector(previousBookmarkMenu(_:)),
             #selector(toggleSlideshowMenu(_:)),
             #selector(showFileInfoMenu(_:)),
             #selector(showOtherPageInFinderMenu(_:)):
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

    func readerView(_ view: ReaderView, gesture virtualButton: Int, modifiers: Int,
                    leftHalf: Bool) {
        handleGesture(virtualButton: virtualButton, modifiers: modifiers, leftHalf: leftHalf)
    }

    func readerView(_ view: ReaderView, dragGesture directionModifier: Int,
                    baseModifiers: Int, button: Int, leftHalf: Bool) {
        handleDragGesture(directionModifier: directionModifier, baseModifiers: baseModifiers,
                          button: button, leftHalf: leftHalf)
    }

    func readerView(_ view: ReaderView, dragTracking dx: CGFloat, dy: CGFloat,
                    button: Int, modifiers: Int, elapsed: TimeInterval) {
        handleDragTracking(dx: dx, dy: dy, button: button, modifiers: modifiers,
                           elapsed: elapsed)
    }

    func readerViewDragTrackingEnded(_ view: ReaderView) {
        handleDragTrackingEnded()
    }

    func readerViewSmartMagnify(_ view: ReaderView, at point: CGPoint) {
        handleSmartZoom(at: point)
    }

    func readerViewZoomWillBegin(_ view: ReaderView) {
        // 進行中のカール追従・保留めくりを畳む(ズームとは別系統)
        pendingTurnForward = nil
    }

    func readerViewZoomDidEnd(_ view: ReaderView, scale: CGFloat) {
        // 確定倍率に見合う解像度へ段階引き上げ(cap 上昇時のみ再デコード)。
        // 再デコードは setPages を通り zoomScale=1 に落とすため、復元予約を置く
        if scale > 1, let book {
            pendingZoom = (scale, view.currentZoomAnchorRatio, book.currentIndex)
        }
        refreshDisplayIfCapRaised()
    }

    func readerViewForceClick(_ view: ReaderView, at point: CGPoint) -> Bool {
        handleForceClick()
    }

    func readerViewForceClickEnded(_ view: ReaderView) {
        handleForceClickEnded()
    }

    func readerViewShouldDragScroll(_ view: ReaderView, button: Int, modifiers: Int) -> Bool {
        shouldDragScroll(button: button, modifiers: modifiers)
    }

    func readerView(_ view: ReaderView, scrollWheel event: NSEvent) {
        handleScrollWheel(event)
    }
}
