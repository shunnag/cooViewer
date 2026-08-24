import AppKit
import WebKit

/// EPUB リーダービュー(WKWebView ベース)。
/// リフローは ReaderScripts のページネーション、固定レイアウトは ICB への
/// アスペクトフィット(pageZoom + フレーム調整)で描画する。
/// 余白はネイティブ側(webView のインセット配置 + layer 背景)で実現し、
/// CSS multicol の座標計算を単純に保つ。
@MainActor
public final class EPUBReaderView: NSView {
    public private(set) var publication: EPUBPublication?
    public weak var delegate: (any EPUBReaderViewDelegate)?

    public var settings = EPUBReaderSettings() {
        didSet {
            guard oldValue != settings else { return }
            applyTheme()
            if oldValue.forwardsKeyEventsNatively
                != settings.forwardsKeyEventsNatively {
                updateNativeKeyMonitor()
            }
            if oldValue.allowsScriptedContent != settings.allowsScriptedContent {
                // JS 許可はビュー構成ごと作り直す(WKWebViewConfiguration は不変)
                reloadCurrentPublication()
            } else if oldValue.fontScale != settings.fontScale
                        || oldValue.pageGap != settings.pageGap
                        || oldValue.insets != settings.insets
                        || oldValue.columnMode != settings.columnMode
                        || oldValue.defaultFontFamily != settings.defaultFontFamily {
                // ページ割りに影響する変更のみ再ページ割り(余白は webView
                // フレームにも効かせる)
                needsLayout = true
                schedulePagination(preserveProgression: true)
            } else {
                // 配色・めくり演出・柱の表示などはページ割りを保ったまま反映
                applyThemeCSSOnly()
                updateFurniture()
            }
        }
    }

    private var webView: WKWebView?
    private var schemeHandler: EPUBSchemeHandler?
    private var messageProxy: MessageProxy?

    /// ノンブル(各ページの下部中央に素のページ番号。Apple Books 風)。
    /// 見開き時は左右 1 つずつ、単ページ時は先頭だけ使う
    private let pageNumberLabels = [NSTextField(labelWithString: ""),
                                    NSTextField(labelWithString: "")]
    /// 現在ページが「画像 1 枚だけのページ」(表紙等)か。ノンブルを隠す
    private var isImagePage = false
    /// 1 画面あたりのページ数(1=単ページ / 2=見開き。setup 結果から)。
    /// ホストが見開きトグル(columnMode)の基準にできるよう読み取り公開
    public private(set) var pagesPerScreen = 1

    /// 現在位置
    public private(set) var currentSpineIndex = 0
    public private(set) var pageInItem = 0
    public private(set) var pageCountInItem = 1
    private var isFixedLayoutItem = false

    /// 読み込み完了時に適用する表示位置
    private enum PendingTarget {
        case start
        case end
        case progression(Double)
        case fragment(String)
    }
    private var pendingTarget: PendingTarget = .start
    private var isSettingUp = false
    /// spine 項目の読み込み中(旧文書から届く境界イベントを捨てて
    /// 章の飛び越しを防ぐ)
    private var isLoadingSpineItem = false
    /// spine 読み込みの世代。loadSpineItem のたびに進める。
    /// runSetup は「開始時と各 await 後」に世代一致を確認し、高速なページ
    /// 送りで古いセットアップが新しい文書の状態(pendingTarget・
    /// isLoadingSpineItem・復元位置)を消費・破壊しないようにする
    private var spineLoadGeneration = 0
    /// 現在有効なナビゲーション(didFinish/didFail の遅延配達を、後続の
    /// loadSpineItem 後に古い文書ぶんとして無視するための同一性チェック)
    private var currentNavigation: WKNavigation?
    /// ネイティブキー横取りのローカルモニタ(forwardsKeyEventsNatively)
    private var keyEventMonitor: Any?
    /// めくりアニメーションのオーバーレイ(spine 切替時に掃除)
    private var turnOverlays: [NSView] = []
    /// 直前のめくり時刻(高速連打時はアニメーションを省略して即めくり)
    private var lastTurnDate = Date.distantPast
    /// セットアップ実行中に届いた再ページ割り要求(捨てずに後追い実行する)
    private var pendingRepaginate = false
    private var repaginateWork: Task<Void, Never>?
    private var lastLaidOutSize: CGSize = .zero
    /// 復元先(復元完了まで currentLocator の答えとして使う。復元前の保存で
    /// 位置が (0,0) に潰れるのを防ぐ)
    private var pendingRestoreLocator: EPUBLocator?
    /// FXL の viewport キャッシュ(layoutFixedItem がリサイズ毎に XHTML を
    /// 再パースしないため)
    private var fxlViewportCache: [Int: CGSize] = [:]

    static let washiWorld = WKContentWorld.world(name: "washi")  // census と共用

    /// 外部ネットワークを遮断するコンテンツルール(コンパイルは初回のみ)
    private static let contentRuleList: Task<WKContentRuleList?, Never> = Task { @MainActor in
        let json = """
        [
          {"trigger": {"url-filter": "https?://.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "wss?://.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^washi-epub://.*"},
           "action": {"type": "ignore-previous-rules"}}
        ]
        """
        return try? await WKContentRuleListStore.default()?
            .compileContentRuleList(forIdentifier: "washi-network-lockdown",
                                    encodedContentRuleList: json)
    }

    // MARK: - ライフサイクル

    /// キーボードフォーカスを受ける(ホストのキーバインド転送や
    /// モード切替時の makeFirstResponder の受け皿)
    public override var acceptsFirstResponder: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        for label in pageNumberLabels {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.isHidden = true
            addSubview(label)
        }
        // ファイルドロップはホスト(delegate)に委ねる(「別の本を開く」等)
        registerForDraggedTypes([.fileURL])
        // ピンチ=フォント倍率(リフローの自然な拡大。認識器なら WKWebView 上の
        // ジェスチャも確実に届く)
        addGestureRecognizer(NSMagnificationGestureRecognizer(
            target: self, action: #selector(handleMagnification(_:))))
        applyTheme()
    }

    // MARK: - ピンチ(フォント倍率)

    /// フォント倍率の許容範囲
    public static let fontScaleRange: ClosedRange<Double> = 0.5...3.0

    /// ピンチ開始時の倍率(確定は指を離したとき)
    private var pinchBaseFontScale: Double?

    /// ピンチ中は WKWebView.magnification で視覚追従だけ行い(再ページ割り
    /// なしで滑らか)、終了時に fontScale へ確定して進行率を保ったまま
    /// 再ページ割りする(テキストは再流し込みされるのでシャープなまま)
    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        guard settings.pinchAdjustsFontScale,
              !isFixedLayoutItem, let webView, publication != nil else { return }
        let base = pinchBaseFontScale ?? settings.fontScale
        // 確定可能な範囲に対応する視覚倍率へクランプ
        let target = min(Self.fontScaleRange.upperBound,
                         max(Self.fontScaleRange.lowerBound,
                             base * (1 + gesture.magnification)))
        let previewFactor = target / base
        switch gesture.state {
        case .began:
            pinchBaseFontScale = settings.fontScale
        case .changed:
            webView.setMagnification(previewFactor,
                                     centeredAt: gesture.location(in: webView))
        case .ended, .cancelled, .failed:
            webView.magnification = 1
            pinchBaseFontScale = nil
            guard abs(target - settings.fontScale) > 0.01 else { return }
            var updated = settings
            updated.fontScale = target
            settings = updated  // didSet → 進行率を保った再ページ割り
            delegate?.readerView(self, didChangeFontScale: target)
        default:
            break
        }
    }

    /// フォント倍率の段階調整(キー割当・メニュー用)
    public func adjustFontScale(by delta: Double) {
        let target = min(Self.fontScaleRange.upperBound,
                         max(Self.fontScaleRange.lowerBound,
                             settings.fontScale + delta))
        guard abs(target - settings.fontScale) > 0.001 else { return }
        var updated = settings
        updated.fontScale = target
        settings = updated
        delegate?.readerView(self, didChangeFontScale: target)
    }

    // MARK: - ドラッグ&ドロップ(ホストへの委譲)

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = NSURL(from: sender.draggingPasteboard) as URL? else {
            return false
        }
        return delegate?.readerView(self, didReceiveDroppedFileURL: url) ?? false
    }

    // MARK: - テーマ(ライト/ダーク)

    /// 実効ダークか(theme=system はビューの実効外観に追従)
    private var isDarkEffective: Bool {
        switch settings.theme {
        case .light: return false
        case .dark: return true
        case .system:
            return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
        applyThemeCSSOnly()
    }

    /// ネイティブ側(余白の背景・柱・ノンブルの色)へテーマを反映する
    private func applyTheme() {
        let colors = settings.effectiveColors(isDark: isDarkEffective)
        layer?.backgroundColor = Self.parseCSSColor(colors.background)
            ?? NSColor.textBackgroundColor.cgColor
        // ノンブルは紙の本らしく控えめなグレー
        let furnitureColor = isDarkEffective
            ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        for label in pageNumberLabels {
            label.textColor = furnitureColor
        }
    }

    /// ページ側(Web コンテンツ)へ配色 CSS だけを差し替える(再ページ割りなし)
    private func applyThemeCSSOnly() {
        guard webView != nil else { return }
        let css = settings.composedUserCSS(isDark: isDarkEffective)
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        evaluate("__washi.setUserCSS(`\(escaped)`);")
    }

    /// "#rrggbb" / "#rgb" のみ解釈(それ以外はシステム色にフォールバック)
    private static func parseCSSColor(_ css: String) -> CGColor? {
        var hex = css.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    // MARK: - 本の読み込み

    /// 本を開く。locator 指定で前回位置から再開する
    public func load(publication: EPUBPublication, at locator: EPUBLocator? = nil) {
        self.publication = publication
        fxlViewportCache.removeAll()
        // 旧本あての再ページ割り予約を破棄(新 webView に古い設定同期由来の
        // repaginate が発火しないように)
        repaginateWork?.cancel()
        pendingRepaginate = false
        // census は本に紐づく(scheme handler ごと作り直す)
        censusTask?.cancel()
        censusTask = nil
        censusEngine?.invalidate()  // 旧本のオフスクリーンを確実に畳む
        censusEngine = nil
        censusCache.removeAll()
        censusFailureCounts.removeAll()
        censusKey = nil
        thumbnailRenderer?.invalidate()  // サムネイルレンダラも本に紐づく
        thumbnailRenderer = nil
        if pageCensus != nil {
            pageCensus = nil
            delegate?.readerViewDidUpdatePageCensus(self)
        }
        // 保存位置は idref で突き合わせる(改版で spine が並べ替わった本でも
        // 別の章を無言で開かない。該当 idref が消えた本は先頭から)
        let resolved = locator.flatMap { publication.resolve($0) }
        let index = resolved.map {
            max(0, min($0.spineIndex, publication.readingOrder.count - 1))
        } ?? 0
        let target: PendingTarget = resolved.map { .progression($0.progression) } ?? .start
        pendingRestoreLocator = resolved
        rebuildWebView(for: publication)
        loadSpineItem(at: index, target: target)
    }

    private func reloadCurrentPublication() {
        guard let publication else { return }
        let locator = currentLocator
        rebuildWebView(for: publication)
        loadSpineItem(at: locator.spineIndex, target: .progression(locator.progression))
    }

    private func rebuildWebView(for publication: EPUBPublication) {
        webView?.removeFromSuperview()
        messageProxy?.owner = nil

        let handler = EPUBSchemeHandler(publication: publication,
                                        allowsScripts: settings.allowsScriptedContent)
        self.schemeHandler = handler

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            settings.allowsScriptedContent
        configuration.setURLSchemeHandler(handler, forURLScheme: EPUBSchemeHandler.scheme)

        let proxy = MessageProxy(owner: self)
        self.messageProxy = proxy
        let controller = configuration.userContentController
        controller.add(proxy, contentWorld: Self.washiWorld, name: "washi")
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.pageScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: Self.washiWorld))
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.baseCSSInjector, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: Self.washiWorld))

        let webView = WashiWebView(frame: contentFrame(),
                                   configuration: configuration)
        webView.suppressesContextMenu = { [weak self] in
            self?.settings.suppressesContextMenu ?? false
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = []
        webView.alphaValue = 0  // 初回セットアップ完了までチラつきを隠す
        // WKWebView 自身のドロップ処理を外し、コンテナ(自ビュー)の
        // ファイルドロップ委譲を生かす(本は読み取り専用なので失うものはない)
        webView.unregisterDraggedTypes()
        addSubview(webView)
        // ノンブルは Web ビューより前面に
        for label in pageNumberLabels {
            addSubview(label, positioned: .above, relativeTo: webView)
        }
        self.webView = webView

        Task { [weak webView] in
            if let ruleList = await Self.contentRuleList.value {
                webView?.configuration.userContentController.add(ruleList)
            }
        }
    }

    /// リフロー時の webView 配置(設定の余白でインセット)。
    /// FXL は全面(余白なし)に配置してページ自体を版面として見せる
    private func contentFrame() -> NSRect {
        if isFixedLayoutItem {
            return NSRect(origin: .zero, size: bounds.size)
        }
        let insets = settings.insets
        return NSRect(
            x: insets.left,
            y: insets.bottom,
            width: max(1, bounds.width - insets.left - insets.right),
            height: max(1, bounds.height - insets.top - insets.bottom))
    }

    /// ノンブルを各ページの下部中央に置く(Apple Books の版面に倣う。
    /// 見開き時は左右のページそれぞれの下、単ページ時は中央)。
    /// AppKit 座標系: 下原点
    private func layoutFurniture() {
        let insets = settings.insets
        let contentWidth = max(1, bounds.width - insets.left - insets.right)
        // ページスロットの中心 x(見開きはノドを挟んだ半幅 2 面)
        let centers: [CGFloat]
        if pagesPerScreen == 2 {
            let gutter = spreadGutter(forContentWidth: contentWidth)
            let pageWidth = (contentWidth - gutter) / 2
            centers = [insets.left + pageWidth / 2,
                       insets.left + contentWidth - pageWidth / 2]
        } else {
            centers = [insets.left + contentWidth / 2]
        }
        for (index, label) in pageNumberLabels.enumerated() {
            guard index < centers.count, !label.isHidden else { continue }
            label.sizeToFit()
            let size = label.frame.size
            label.frame = NSRect(
                x: centers[index] - size.width / 2,
                y: (insets.bottom - size.height) / 2,
                width: size.width, height: size.height)
        }
    }

    /// 各ページのノンブル(素の章内ページ番号。Apple Books 風)を更新する。
    /// FXL・画像ページ(表紙)では隠す。右綴じは右スロットが先のページ
    private func updateFurniture() {
        let visible = settings.showsPageFurniture && publication != nil
            && !isFixedLayoutItem && !isImagePage
        guard visible else {
            for label in pageNumberLabels { label.isHidden = true }
            return
        }
        // スロット順 = [左, 右]。表示ページ順は綴じ方向で決まる
        var slotNumbers: [Int?] = [nil, nil]
        let first = pageInItem + 1
        let second = pageInItem + 2 <= pageCountInItem ? pageInItem + 2 : nil
        if pagesPerScreen == 2 {
            if isRTL {
                slotNumbers = [second, first]
            } else {
                slotNumbers = [first, second]
            }
        } else {
            slotNumbers = [first, nil]
        }
        for (index, label) in pageNumberLabels.enumerated() {
            if let number = slotNumbers[index] {
                label.stringValue = String(number)
                label.isHidden = false
            } else {
                label.isHidden = true
            }
        }
        layoutFurniture()
    }

    // 見開き判定・ノド幅は EPUBScreenMetrics が単一の正(リーダー外の
    // 一覧展開と式を共有し、ページ割りの一致を保証する)

    private func spreadGutter(forContentWidth width: CGFloat) -> CGFloat {
        EPUBScreenMetrics.spreadGutter(forContentWidth: width)
    }

    private func shouldUseSpread(forContentWidth width: CGFloat) -> Bool {
        EPUBScreenMetrics.usesSpread(contentWidth: width,
                                     columnMode: settings.columnMode)
    }

    /// 現在の表示条件の画面計画(census・サムネイルのオプションもここから)
    private var currentScreenMetrics: EPUBScreenMetrics {
        EPUBScreenMetrics(viewportSize: bounds.size, settings: settings)
    }

    private func loadSpineItem(at index: Int, target: PendingTarget,
                               preservingTurnCover: Bool = false) {
        guard let publication, let schemeHandler, let webView,
              publication.readingOrder.indices.contains(index) else { return }
        currentSpineIndex = index
        pendingTarget = target
        pageInItem = 0
        pageCountInItem = 1
        isImagePage = false
        isLoadingSpineItem = true
        spineLoadGeneration += 1
        repaginateWork?.cancel()  // 旧文書あての再ページ割りを新文書へ流さない
        // 進行中のめくり演出は新しい章の表示を隠すので畳む。
        // spine 遷移演出の持ち越しカバー(旧ページ)だけは読み込み中も残す
        if !preservingTurnCover { clearPendingSpineTurn() }
        for overlay in turnOverlays where overlay !== pendingSpineTurn?.cover {
            overlay.removeFromSuperview()
        }
        turnOverlays.removeAll { $0 !== pendingSpineTurn?.cover }
        let entry = publication.readingOrder[index]
        isFixedLayoutItem =
            publication.package.effectiveLayout(for: entry.itemRef) == .prePaginated
        updateFurniture()
        guard let url = schemeHandler.url(forContainerPath: entry.containerPath) else {
            return
        }
        webView.alphaValue = 0
        currentNavigation = webView.load(URLRequest(url: url))
    }

    // MARK: - ナビゲーション API

    /// 右綴じ(page-progression-direction: rtl)か
    public var isRTL: Bool {
        publication?.readingDirection == .rtl
    }

    public var currentLocator: EPUBLocator {
        // 復元がまだ適用されていない間は復元先を答える(開いてすぐ閉じたときに
        // 保存済み位置を (0,0) で潰さない)
        if let pendingRestoreLocator { return pendingRestoreLocator }
        let progression = pageCountInItem <= 1
            ? 0 : Double(pageInItem) / Double(pageCountInItem - 1)
        // idref 併記(publication.resolve で改版追跡できる形)で返す
        return publication?.locator(forSpineIndex: currentSpineIndex,
                                    progression: progression)
            ?? EPUBLocator(spineIndex: currentSpineIndex,
                           progression: progression)
    }

    /// 読書順で次へ(項目内の次ページ → 次の spine 項目)。
    /// リフローの項目内判定は JS 側(turnInDoc)に任せる: native のページ
    /// カウンタは非同期更新のため、キーリピート連打で章を飛ばす競合がある
    public func goForward() { turnInDocAnimated(forward: true) }

    /// 読書順で前へ
    public func goBackward() { turnInDocAnimated(forward: false) }

    /// 項目内めくり + 演出。
    /// 順序が命: **旧ページのカバーを先に被せてから**めくり、新ページの
    /// スナップショットを取ってから演出に入る(めくり直後の新ページが
    /// 一瞬見えてから演出が始まる「チラつき」を構造的に排除する)。
    /// ホスト(delegate)がページカール等の独自演出で置き換えられる。
    /// 「視差効果を減らす」時・高速連打時・端到達時は演出なし
    private func turnInDocAnimated(forward: Bool) {
        guard let webView else { return }
        let wantsAnimation = settings.pageTurnStyle != .none
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && Date().timeIntervalSince(lastTurnDate) > 0.3
        lastTurnDate = Date()
        if isFixedLayoutItem {
            // FXL 項目は常に隣接 spine への移動。演出ありなら旧ページの
            // カバーを持ち越して spine 遷移演出(下の boundary 経路と同じ)
            if wantsAnimation {
                Task { [weak self] in
                    await self?.beginFXLSpineTurn(forward: forward,
                                                  webView: webView)
                }
            } else {
                advanceSpine(forward: forward)
            }
            return
        }
        guard wantsAnimation else {
            evaluate("__washi.turnInDoc(\(forward));")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.performAnimatedTurn(forward: forward, webView: webView)
        }
    }

    /// FXL 項目からの隣接 spine 移動をカバー持ち越しで演出する
    private func beginFXLSpineTurn(forward: Bool, webView: WKWebView) async {
        let fast = WKSnapshotConfiguration()
        fast.afterScreenUpdates = false
        guard let oldPage = try? await webView.takeSnapshot(configuration: fast)
        else {
            advanceSpine(forward: forward)
            return
        }
        let cover = NSImageView(image: oldPage)
        cover.imageScaling = .scaleAxesIndependently
        cover.frame = webView.frame
        addSubview(cover, positioned: .above, relativeTo: webView)
        turnOverlays.append(cover)
        pendingSpineTurn = PendingSpineTurn(
            oldPage: oldPage, cover: cover, forward: forward)
        scheduleSpineTurnTimeout(for: cover)
        advanceSpine(forward: forward)
    }

    /// spine 遷移(章間・表紙→本文)もめくり演出で見せるための持ち越し状態。
    /// 境界めくり(turnInDoc が boundary)から次項目の表示完了までカバーで
    /// 旧ページを見せ続け、完了時に項目内めくりと同じ演出で切り替える
    private struct PendingSpineTurn {
        let oldPage: NSImage
        let cover: NSImageView
        let forward: Bool
    }
    private var pendingSpineTurn: PendingSpineTurn?

    private func clearPendingSpineTurn() {
        guard let pending = pendingSpineTurn else { return }
        pendingSpineTurn = nil
        pending.cover.removeFromSuperview()
        turnOverlays.removeAll { $0 === pending.cover }
    }

    /// 読み込みが来ないままカバーが残る事態(端で何も起きない・失敗)の安全弁
    private func scheduleSpineTurnTimeout(for cover: NSImageView) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.pendingSpineTurn?.cover === cover else { return }
            self.clearPendingSpineTurn()
        }
    }

    private func performAnimatedTurn(forward: Bool, webView: WKWebView) async {
        // 1. 旧ページを撮り、カバーとして被せる(以後ユーザーには旧ページが
        //    見え続け、下でめくりが起きても分からない)
        let fast = WKSnapshotConfiguration()
        fast.afterScreenUpdates = false
        guard let oldPage = try? await webView.takeSnapshot(configuration: fast)
        else {
            evaluate("__washi.turnInDoc(\(forward));")
            return
        }
        let cover = NSImageView(image: oldPage)
        cover.imageScaling = .scaleAxesIndependently
        cover.frame = webView.frame
        addSubview(cover, positioned: .above, relativeTo: webView)
        turnOverlays.append(cover)

        // 2. カバーの下でめくる。境界なら次項目の表示完了までカバーを持ち越す
        //    (boundary 通知 → advanceSpine → runSetup 完了時に演出)。
        //    JS 呼び出しの**前に**登録する: boundary メッセージが戻り値より
        //    先に届いても loadSpineItem がカバーを保持できるように
        pendingSpineTurn = PendingSpineTurn(
            oldPage: oldPage, cover: cover, forward: forward)
        let result = try? await webView.callAsyncJavaScript(
            "return __washi.turnInDoc(\(forward));",
            arguments: [:], in: nil, contentWorld: Self.washiWorld)
        switch result as? String {
        case "turned":
            pendingSpineTurn = nil
        case "boundary":
            // カバーの後始末は advanceSpine / didReachBookEdge /
            // runSetup(表示完了)側が引き取る
            scheduleSpineTurnTimeout(for: cover)
            return
        default:
            // 'ignored'(setup 前)・nil(評価失敗): 何も起きないので畳む
            pendingSpineTurn = nil
            cover.removeFromSuperview()
            turnOverlays.removeAll { $0 === cover }
            return
        }

        // 3. 新ページを描画完了込みで撮り、演出でカバーを取り除く
        let after = WKSnapshotConfiguration()
        after.afterScreenUpdates = true
        let newPage = try? await webView.takeSnapshot(configuration: after)
        runTurnEffect(oldPage: oldPage, newPage: newPage,
                      cover: cover, forward: forward)
    }

    /// めくり演出の本体(項目内・spine 遷移で共通)。
    /// ホスト独自演出(ページカール等)があれば委譲し、なければ内蔵の
    /// スライド/フェードでカバー(旧ページ)を取り除く
    private func runTurnEffect(oldPage: NSImage, newPage: NSImage?,
                               cover: NSImageView, forward: Bool) {
        func removeCover() {
            cover.removeFromSuperview()
            turnOverlays.removeAll { $0 === cover }
        }
        let frame = webView?.frame ?? bounds
        if let newPage,
           delegate?.readerView(self, animatePageTurnFrom: oldPage, to: newPage,
                                forward: forward, in: frame) == true {
            removeCover()  // ホストのオーバーレイが被さっている
            return
        }
        switch settings.pageTurnStyle {
        case .slide:
            // 物理方向: 進む=旧ページが綴じの反対側へ抜ける
            // (右綴じで進む=右へ、左綴じで進む=左へ)
            let direction: CGFloat = (forward ? 1 : -1) * (isRTL ? 1 : -1)
            let target = cover.frame.offsetBy(dx: direction * frame.width, dy: 0)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cover.animator().frame = target
            }, completionHandler: { removeCover() })
        case .fade:
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                cover.animator().alphaValue = 0
            }, completionHandler: { removeCover() })
        case .none:
            removeCover()
        }
    }

    /// 物理方向のページ送り(右綴じなら「左」=進む)
    public func turnPageLeft() { isRTL ? goForward() : goBackward() }
    public func turnPageRight() { isRTL ? goBackward() : goForward() }

    public func go(to locator: EPUBLocator) {
        guard let publication,
              publication.readingOrder.indices.contains(locator.spineIndex) else { return }
        if locator.spineIndex == currentSpineIndex {
            applyTarget(.progression(locator.progression))
        } else {
            loadSpineItem(at: locator.spineIndex,
                          target: .progression(locator.progression))
        }
    }

    /// 目次項目へ移動
    public func go(to navItem: EPUBNavItem) {
        guard let publication,
              let index = publication.spineIndex(forNavItem: navItem) else { return }
        let fragment = navItem.href.flatMap(Self.fragment(of:))
        let target: PendingTarget = fragment.map { .fragment($0) } ?? .start
        if index == currentSpineIndex {
            applyTarget(target)
        } else {
            loadSpineItem(at: index, target: target)
        }
    }

    public func goToBookStart() { loadSpineItem(at: 0, target: .start) }

    public func goToBookEnd() {
        guard let publication else { return }
        loadSpineItem(at: publication.readingOrder.count - 1, target: .end)
    }

    private func advanceSpine(forward: Bool) {
        guard let publication else { return }
        let next = currentSpineIndex + (forward ? 1 : -1)
        guard publication.readingOrder.indices.contains(next) else {
            // 巻頭/巻末超え: ホストの反応(ループ・隣の本・何もしない)は
            // めくり演出ではないので、持ち越しカバーを先に畳む
            clearPendingSpineTurn()
            delegate?.readerView(self, didReachBookEdge: forward)
            return
        }
        loadSpineItem(at: next, target: forward ? .start : .end,
                      preservingTurnCover: true)
    }

    private func applyTarget(_ target: PendingTarget) {
        switch target {
        case .start:
            evaluate("__washi.showPage(0);")
        case .end:
            evaluate("__washi.showLastPage();")
        case .progression(let progression):
            evaluate("__washi.showProgression(\(progression));")
        case .fragment(let fragment):
            let escaped = fragment
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            evaluate("__washi.showFragment('\(escaped)');")
        }
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, in: nil, in: Self.washiWorld)
    }

    // MARK: - レイアウト

    public override func layout() {
        super.layout()
        layoutFurniture()
        guard let webView else { return }
        if isFixedLayoutItem {
            layoutFixedItem()
            // FXL 項目の表示中でもリサイズで census のメトリクスは変わる
            // (再ページ割りは不要だが、N/M とジャンプ写像は寸法依存)。
            // scheduleCensusIfNeeded はキーで重複排除するので毎回呼んで安全
            scheduleCensusIfNeeded()
        } else {
            webView.frame = contentFrame()
            if lastLaidOutSize != bounds.size {
                schedulePagination(preserveProgression: true)
            }
        }
        lastLaidOutSize = bounds.size
    }

    /// FXL: ICB へのアスペクトフィット。中央寄せは webView フレームで行う。
    /// viewport はキャッシュする(リサイズ毎の XHTML 再パースを避ける)
    private func layoutFixedItem() {
        guard let webView, let publication else { return }
        let viewport: CGSize
        if let cached = fxlViewportCache[currentSpineIndex] {
            viewport = cached
        } else {
            viewport = (try? publication
                .fixedLayoutInfo(forSpineIndex: currentSpineIndex))?.viewportSize
                ?? CGSize(width: 1200, height: 1600)
            fxlViewportCache[currentSpineIndex] = viewport
        }
        let available = contentFrame()
        guard viewport.width > 0, viewport.height > 0,
              available.width > 0, available.height > 0 else { return }
        let scale = min(available.width / viewport.width,
                        available.height / viewport.height)
        let size = NSSize(width: viewport.width * scale,
                          height: viewport.height * scale)
        webView.frame = NSRect(
            x: available.minX + (available.width - size.width) / 2,
            y: available.minY + (available.height - size.height) / 2,
            width: size.width, height: size.height)
        webView.pageZoom = scale
    }

    /// リサイズ・設定変更後の再ページ割り(連続リサイズをデバウンス)。
    /// セットアップ実行中に届いた要求は捨てずに完了後へ繰り越す(捨てると
    /// lastLaidOutSize が先に更新され、以後そのサイズでは再ページ割りされない)
    private func schedulePagination(preserveProgression: Bool) {
        guard webView != nil, publication != nil else { return }
        // spine 読み込み中(didFinish 前)は再ページ割りを走らせない。
        // ここで走らせると、文書のロード完了前に repaginate が isLoadingSpineItem
        // や alpha を早期リセットして、旧文書の境界イベント受理や表示のちらつきを
        // 招く(世代トークンは同一世代なので防げない)。didFinish 後の
        // runSetup 完了時に defer が pendingRepaginate を拾って正しい順序で走る
        if isSettingUp || isLoadingSpineItem {
            pendingRepaginate = true
            return
        }
        repaginateWork?.cancel()
        let generation = spineLoadGeneration
        repaginateWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.runSetup(preserveProgression: preserveProgression,
                                 generation: generation)
        }
    }

    private func setupOptionsJSON() -> String {
        let frame = contentFrame()
        var options: [String: Any] = [
            "width": Double(frame.width.rounded(.down)),
            "height": Double(frame.height.rounded(.down)),
            "gap": settings.pageGap,
            "spread": shouldUseSpread(forContentWidth: frame.width),
            "gutter": Double(spreadGutter(forContentWidth: frame.width)),
            "fixedLayout": isFixedLayoutItem,
            "keysEnabled": settings.handlesKeyboardNavigation,
            "userCSS": settings.composedUserCSS(isDark: isDarkEffective),
        ]
        if isFixedLayoutItem { options["width"] = 0; options["height"] = 0 }
        let data = (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// didFinish 後(または再ページ割り時)のセットアップ実行。
    /// generation が現在の spine 読み込み世代と食い違ったら何もしない
    /// (guard は JS await の後にも必要 — await 中に別の spine へ
    /// 移っていたら、その文書の状態を消費・破壊してはならない)
    private func runSetup(preserveProgression: Bool, generation: Int) async {
        guard let webView, generation == spineLoadGeneration else { return }
        isSettingUp = true
        defer {
            isSettingUp = false
            // 実行中に届いた再ページ割り(リサイズ・設定変更)を後追いする
            if pendingRepaginate {
                pendingRepaginate = false
                schedulePagination(preserveProgression: true)
            }
        }
        let call = preserveProgression
            ? "return __washi.repaginate(\(setupOptionsJSON()));"
            : "return __washi.setup(\(setupOptionsJSON()));"
        do {
            let result = try await webView.callAsyncJavaScript(
                call, arguments: [:], in: nil, contentWorld: Self.washiWorld)
            guard generation == spineLoadGeneration,
                  webView === self.webView else { return }
            if let dict = result as? [String: Any] {
                if let count = dict["pageCount"] as? Int {
                    pageCountInItem = max(1, count)
                }
                isImagePage = dict["imagePage"] as? Bool ?? false
                pagesPerScreen = max(1, dict["pagesPerScreen"] as? Int ?? 1)
            }
            if !preserveProgression {
                applyTarget(pendingTarget)
                pendingTarget = .start
                pendingRestoreLocator = nil  // 復元適用完了
            }
            isLoadingSpineItem = false
            updateFurniture()
            scheduleCensusIfNeeded()  // メトリクス変化(フォント・寸法)に追従
            webView.alphaValue = 1  // 持ち越しカバーがあればその下で戻る
            if let pending = pendingSpineTurn {
                // spine 遷移演出の仕上げ: 新ページの描画完了を待って撮り、
                // 項目内めくりと同じ演出でカバー(旧ページ)を取り除く
                pendingSpineTurn = nil
                let config = WKSnapshotConfiguration()
                config.afterScreenUpdates = true
                let newPage = try? await webView.takeSnapshot(
                    configuration: config)
                guard generation == spineLoadGeneration else { return }
                runTurnEffect(oldPage: pending.oldPage, newPage: newPage,
                              cover: pending.cover, forward: pending.forward)
            }
        } catch {
            // 古い文書の JS 失敗で新しい文書の読み込み状態を壊さない
            guard generation == spineLoadGeneration else { return }
            isLoadingSpineItem = false
            clearPendingSpineTurn()
            webView.alphaValue = 1
            delegate?.readerView(self, didFailWith: error)
        }
    }

    // MARK: - 全文ページ数の実測(census)

    /// 現在のメトリクスでの各 spine 項目のページ数(実測完了まで nil)。
    /// フォントサイズ・ウインドウ寸法・見開き切替のたびに再実測される
    public private(set) var pageCensus: [Int]?

    /// 全文ページ数(census 完了まで nil)
    public var censusTotalPages: Int? { pageCensus?.reduce(0, +) }

    /// 実測済み census のメトリクスキー(ホストが自前のキャッシュへ
    /// 流用するときの一致検証用。実測が完了しているときだけ返す —
    /// censusKey 自体は実測開始時に先行更新されるため単独では信用できない)
    public var pageCensusMetricsKey: String? {
        pageCensus != nil ? censusKey : nil
    }

    private var censusEngine: EPUBPaginationCensus?
    private var censusTask: Task<Void, Never>?
    /// 計測時のメトリクスキー(census 用オプション JSON。sortedKeys で決定的)
    private var censusKey: String?
    /// メトリクスキー → 実測結果(フォントを行き来したときの再計測を省く)
    private var censusCache: [String: [Int]] = [:]

    /// spine 項目の先頭ページの全文オフセット(0 始まり)
    public func censusPageOffset(forSpineIndex index: Int) -> Int? {
        guard let pageCensus, index >= 0, index <= pageCensus.count else { return nil }
        return pageCensus.prefix(index).reduce(0, +)
    }

    /// 表示中ページの全文ページ番号範囲(1 始まり。見開きは 2 ページ分)。
    /// 実測と表示中の実ページ数がずれ得る境界はクランプする
    public var currentGlobalPageRange: ClosedRange<Int>? {
        guard let counts = pageCensus,
              counts.indices.contains(currentSpineIndex),
              let offset = censusPageOffset(forSpineIndex: currentSpineIndex)
        else { return nil }
        let itemPages = counts[currentSpineIndex]
        let first = offset + min(pageInItem, max(0, itemPages - 1)) + 1
        let last = offset + min(pageInItem + pagesPerScreen, itemPages)
        return first...max(first, last)
    }

    /// 全文ページ番号(0 始まり)→ 位置。census 完了まで nil
    public func censusLocator(forGlobalPage page: Int) -> EPUBLocator? {
        guard let counts = pageCensus, !counts.isEmpty else { return nil }
        var remaining = max(0, page)
        for (index, count) in counts.enumerated() {
            if remaining < count {
                let progression = count <= 1
                    ? 0 : Double(remaining) / Double(count - 1)
                return publication?.locator(forSpineIndex: index,
                                            progression: progression)
                    ?? EPUBLocator(spineIndex: index, progression: progression)
            }
            remaining -= count
        }
        return publication?.locator(forSpineIndex: counts.count - 1, progression: 1)
            ?? EPUBLocator(spineIndex: counts.count - 1, progression: 1)
    }

    // MARK: - 画面サムネイル(ホストの一覧 UI 用)

    /// 現メトリクスで 1 画面に並ぶページ数(1=単ページ/2=見開き)。
    /// サムネイル一覧の画面割りに使う(画像 1 枚の項目は実行時に 1 になるが、
    /// ここは「リフロー本文ならこうなる」計画値)
    public var plannedPagesPerScreen: Int {
        currentScreenMetrics.pagesPerScreen
    }

    private var thumbnailRenderer: EPUBScreenThumbnailRenderer?

    /// 指定画面のサムネイル(本番・census と同一のページ割り。画面外で描画し、
    /// 配色は現在のテーマに合わせる)。width は出力幅 pt。失敗時 nil
    public func screenThumbnail(spineIndex: Int, pageInItem: Int,
                                width: CGFloat) async -> CGImage? {
        guard let publication else { return nil }
        let renderer = thumbnailRenderer
            ?? EPUBScreenThumbnailRenderer(publication: publication)
        thumbnailRenderer = renderer
        let metrics = currentScreenMetrics
        return await renderer.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            optionsJSON: metrics.themedOptionsJSON(isDark: isDarkEffective),
            contentSize: metrics.contentSize, snapshotWidth: width)
    }

    /// リフロー時のコンテンツ寸法(現在項目が FXL でも「リフロー項目なら
    /// こうなる」寸法。census のメトリクスは現在項目に依存させない)
    private func reflowContentSize() -> NSSize {
        currentScreenMetrics.contentSize
    }

    /// census 用のセットアップオプション(= リフロー項目の setup と同値。
    /// メトリクスの同一性キーとしても使う)
    private func censusOptionsJSON() -> String {
        currentScreenMetrics.censusOptionsJSON
    }

    /// メトリクスごとの実測失敗回数(タイムアウト・WebContent 死等)。
    /// 上限を超えたキーは再スケジュールしない(壊れた spine を持つ本で
    /// runSetup のたびに 15 秒タイムアウトを繰り返さないため)
    private var censusFailureCounts: [String: Int] = [:]

    /// バックグラウンドの census を止める(ホストが EPUB 表示を離れるとき用。
    /// 次の runSetup / layout で自然に再スケジュールされる)
    public func cancelPageCensus() {
        censusTask?.cancel()
        censusTask = nil
    }

    /// ウインドウから外れたら(クローズ・ビューの取り外し)オフスクリーン
    /// 計測を止め、不可視ウインドウと WebContent プロセスを畳む。
    /// 明示的な cancelPageCensus を知らないホストでもリークしないための保険。
    /// 再表示されれば次の runSetup / layout が census を自然に再開する
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateNativeKeyMonitor()
        guard window == nil else { return }
        cancelPageCensus()
        censusEngine?.invalidate()
        censusEngine = nil
        thumbnailRenderer?.invalidate()
        thumbnailRenderer = nil
    }

    // MARK: - ネイティブキー横取り(forwardsKeyEventsNatively)

    /// ウインドウ在席と設定に応じてローカルキーモニタを付け外しする。
    /// WKWebView がファーストレスポンダを握るとビューの keyDown は呼ばれず
    /// JS 経路のキーも取りこぼすため、ホストが確実に NSEvent を受け取れるよう
    /// ウインドウレベルの local monitor で横取りする(cooViewer が自前で
    /// やっていた対処をパッケージ側の任意機能として提供)
    private func updateNativeKeyMonitor() {
        let shouldMonitor = window != nil && settings.forwardsKeyEventsNatively
        if shouldMonitor, keyEventMonitor == nil {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self, let window = self.window,
                      event.window === window, self.delegate != nil,
                      // 自分(またはその子 WebView)がこのウインドウで
                      // 表示中のときだけ横取りする
                      !self.isHidden, self.superview != nil else { return event }
                return self.delegate?.readerView(self, didReceiveNativeKey: event)
                    == true ? nil : event
            }
        } else if !shouldMonitor, let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    /// メトリクスが変わっていれば census を(デバウンス付きで)再実測する。
    /// runSetup 完了時と FXL 表示中のリサイズで呼ぶ — リサイズ・フォント倍率・
    /// 見開き切替に追従する
    private func scheduleCensusIfNeeded() {
        guard let publication, !publication.readingOrder.isEmpty else { return }
        // ウインドウから外れている間はオフスクリーン計測を始めない
        // (viewDidMoveToWindow で畳んだ直後に runSetup 由来の呼び出しが
        // 実測を復活させ、不可視ウインドウ/プロセスが生き返るのを防ぐ。
        // 再表示されれば layout/runSetup が改めて呼ぶ)
        guard window != nil else { return }
        let key = censusOptionsJSON()
        // 実測に使う寸法はキーと同じ瞬間に採る(デバウンス起床時に採ると、
        // 窓の終盤のリサイズで「旧キーに新寸法の実測」が入りキャッシュが汚れる)
        let size = reflowContentSize()
        if censusKey == key {
            if pageCensus != nil { return }
            // 同一メトリクスで実測中なら継続させる(spine 遷移のたびに
            // runSetup から呼ばれるため、ここで中断すると大きい本で
            // いつまでも完走しない)。失敗完了したタスクは censusTask = nil に
            // 戻してあるので、この分岐が再実測を塞ぐことはない
            if let censusTask, !censusTask.isCancelled { return }
        }
        if let cached = censusCache[key] {
            censusKey = key
            pageCensus = cached
            // 旧キーの計測が走っていれば止める(完走させても無駄なうえ、
            // 同じキーへ戻ったときの並走の種になる)
            censusTask?.cancel()
            delegate?.readerViewDidUpdatePageCensus(self)
            return
        }
        if censusFailureCounts[key, default: 0] >= 2 { return }
        // 古いメトリクスの番号を出し続けないよう、まず無効化を通知
        if pageCensus != nil {
            pageCensus = nil
            delegate?.readerViewDidUpdatePageCensus(self)
        }
        censusKey = key
        censusTask?.cancel()
        let previous = censusTask
        censusTask = Task { [weak self] in
            // リサイズ嵐・連続の設定変更を合流させる
            try? await Task.sleep(for: .milliseconds(300))
            // 旧計測の完全な離脱を待つ(FIFO 直列化)。同じ WKWebView 上で
            // 新旧の measure が並走すると、ナビゲーションイベントの取り違えで
            // 失敗や「1 項目ずれた実測値」のキャッシュ汚染が起きる
            // (EPUBPageRasterizer と同じ直列化方針)
            _ = await previous?.value
            // measure の await をまたいで self を強参照しない: ホストが
            // ビューを手放したら、全 spine 実測(壊れた本は 1 項目 15 秒
            // タイムアウト×N)を道連れにビューが生き残らないように
            guard !Task.isCancelled,
                  let publication = self?.publication, self?.censusKey == key
            else { return }
            let engine = self?.censusEngine ?? EPUBPaginationCensus()
            self?.censusEngine = engine
            let counts = await engine.measure(
                publication: publication, optionsJSON: key, contentSize: size)
            guard let self, !Task.isCancelled, self.censusKey == key else { return }
            guard let counts else {
                // 失敗完了は「実測中」ではない — タスクを解放して次の
                // runSetup での再実測を許す(回数はキーごとに上限あり)
                self.censusFailureCounts[key, default: 0] += 1
                self.censusTask = nil
                return
            }
            self.censusCache[key] = counts
            self.pageCensus = counts
            self.delegate?.readerViewDidUpdatePageCensus(self)
        }
    }

    // MARK: - スナップショット

    /// ビュー全体(余白 + Web コンテンツ)を合成した画像を返す。
    /// WKWebView はレイヤ描画(cacheDisplay 等)に写らないため、
    /// takeSnapshot の結果を背景と合成する(ヘッドレス検証・サムネイル用)
    public func snapshot() async throws -> NSImage {
        guard let webView else { throw EPUBError.malformed("本が開かれていない") }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let webImage = try await webView.takeSnapshot(configuration: configuration)
        let background = NSColor(cgColor: layer?.backgroundColor
            ?? NSColor.textBackgroundColor.cgColor) ?? .white
        let size = bounds.size
        let webFrame = webView.frame
        let furniture = pageNumberLabels
            .filter { !$0.isHidden }
            .map { (text: $0.attributedStringValue, frame: $0.frame,
                    color: $0.textColor ?? .secondaryLabelColor,
                    font: $0.font ?? .systemFont(ofSize: 11)) }
        return NSImage(size: size, flipped: false) { rect in
            background.setFill()
            rect.fill()
            webImage.draw(in: webFrame)
            for item in furniture {
                // 柱・ノンブルも合成する(検証スナップショットで版面を確認するため)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: item.font, .foregroundColor: item.color,
                ]
                NSAttributedString(string: item.text.string,
                                   attributes: attributes).draw(in: item.frame)
            }
            return true
        }
    }

    // MARK: - JS からのメッセージ

    fileprivate func handleScriptMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else { return }
        switch type {
        case "pageChanged":
            pageInItem = dict["page"] as? Int ?? 0
            pageCountInItem = max(1, dict["pageCount"] as? Int ?? 1)
            pagesPerScreen = max(1, dict["pagesPerScreen"] as? Int ?? pagesPerScreen)
            pendingRestoreLocator = nil  // 実位置が確定した
            updateFurniture()
            delegate?.readerView(self, didMoveTo: currentLocator,
                                 pageInItem: pageInItem,
                                 pageCountInItem: pageCountInItem)
        case "boundary":
            // spine 切替の読み込み中に旧文書から届く境界イベントは捨てる
            // (トラックパッド慣性やキーリピートでの章飛び越し防止)
            guard !isLoadingSpineItem else { break }
            let forward = dict["forward"] as? Bool ?? true
            advanceSpine(forward: forward)
        case "wheelTurn":
            // ホイール/トラックパッドの 1 ジェスチャ 1 ページ(JS でラッチ済み)。
            // native 経由にするのはスライド演出を共通で付けるため。
            // spine 読み込み中の残存慣性は boundary と同じく捨てる(FXL 項目が
            // 表示される前に advanceSpine で飛ばされるカスケードを防ぐ)。
            // 水平ジェスチャは物理方向(deltaX>0=右側のページ)として受け、
            // 綴じ方向への変換はタップと同じく turnPageLeft/Right が担う
            // (JS は表紙等の画像ページで本の writing-mode を知れない)。
            // 垂直ジェスチャは内部縦積みと一致するので下=読書順で次
            guard !isLoadingSpineItem else { break }
            let forward = dict["forward"] as? Bool ?? true
            if dict["horizontal"] as? Bool ?? false {
                forward ? turnPageRight() : turnPageLeft()
            } else {
                forward ? goForward() : goBackward()
            }
        case "link":
            if let href = dict["href"] as? String {
                handleLink(href)
            }
        case "tap":
            // DOM のボタン番号(0=左,1=中,2=右,3/4=サイド)→ NSEvent 流
            // (0=左,1=右,2=中,3/4=サイド)へ写像。右は JS 側で除外済み
            let domButton = dict["button"] as? Int ?? 0
            let button = domButton == 1 ? 2 : (domButton == 2 ? 1 : domButton)
            let event = EPUBClickEvent(
                x: dict["x"] as? Double ?? 0.5,
                y: dict["y"] as? Double ?? 0.5,
                button: button,
                shift: dict["shift"] as? Bool ?? false,
                option: dict["alt"] as? Bool ?? false,
                control: dict["ctrl"] as? Bool ?? false,
                command: dict["meta"] as? Bool ?? false)
            dispatchClick(event)
        case "key":
            let event = EPUBKeyEvent(
                key: dict["key"] as? String ?? "",
                code: dict["code"] as? String ?? "",
                shift: dict["shift"] as? Bool ?? false,
                option: dict["alt"] as? Bool ?? false,
                control: dict["ctrl"] as? Bool ?? false,
                command: dict["meta"] as? Bool ?? false)
            delegate?.readerView(self, didReceiveKey: event)
        default:
            break
        }
    }

    /// クリックの共通ディスパッチ(JS の tap 通知と余白のネイティブクリック)
    private func dispatchClick(_ event: EPUBClickEvent) {
        if delegate?.readerView(self, didClick: event) != true,
           event.isPlainPrimary {
            // 既定動作: 左右端のタップでページ送り(物理方向。
            // 右綴じなら左=進む — 紙の本のめくり方向と一致)
            if event.x < 0.4 {
                turnPageLeft()
            } else if event.x > 0.6 {
                turnPageRight()
            }
        }
    }

    // MARK: - 余白(WKWebView 外)のネイティブ入力

    // 版面余白(insets)は WKWebView の外側にあり JS の click/wheel 捕捉が
    // 届かない。画像本は view 全域でバインドが効くため、柱・ノンブル領域の
    // クリックとホイールも同じ入力系へ合流させる(WKWebView 内のイベントは
    // WKWebView 自身が消費するのでここへは来ない)

    private var marginPressTime: TimeInterval = 0
    private var marginPressLocation = NSPoint.zero

    public override func mouseDown(with event: NSEvent) {
        notePress(event)
        super.mouseDown(with: event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        notePress(event)
        super.otherMouseDown(with: event)
    }

    private func notePress(_ event: NSEvent) {
        marginPressTime = event.timestamp
        marginPressLocation = convert(event.locationInWindow, from: nil)
    }

    public override func mouseUp(with event: NSEvent) {
        if !dispatchMarginClick(event, button: 0) { super.mouseUp(with: event) }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if !dispatchMarginClick(event, button: event.buttonNumber) {
            super.otherMouseUp(with: event)
        }
    }

    private func dispatchMarginClick(_ event: NSEvent, button: Int) -> Bool {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              !(webView.map { $0.frame.contains(location) } ?? false)
        else { return false }
        // JS の click 抑制と同じ閾値(§5.9): 30pt 超のドラッグ・1 秒超の
        // 長押しの解放はクリックにしない(イベントは消費する)
        guard event.timestamp - marginPressTime <= 1.0,
              max(abs(location.x - marginPressLocation.x),
                  abs(location.y - marginPressLocation.y)) <= 30
        else { return true }
        let flags = event.modifierFlags
        // y は JS の tap と同じ「上端 0」の正規化(この view は非 flipped)
        dispatchClick(EPUBClickEvent(
            x: Double(location.x / max(1, bounds.width)),
            y: Double(1 - location.y / max(1, bounds.height)),
            button: button,
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            command: flags.contains(.command)))
        return true
    }

    private var marginWheelAccumulator: CGFloat = 0
    private var marginWheelLastTime: TimeInterval = 0
    private var marginWheelLatched = false
    private var marginWheelHorizontal = false

    public override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              !(webView.map { $0.frame.contains(location) } ?? false)
        else {
            super.scrollWheel(with: event)
            return
        }
        // JS 側と同じ「1 ジェスチャ = 1 ページ」量子化(250ms 静穏で解除・
        // 軸は最初のイベントで確定)。慣性はラッチが飲み込む
        if event.timestamp - marginWheelLastTime > 0.25 {
            marginWheelLatched = false
            marginWheelAccumulator = 0
            marginWheelHorizontal =
                abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        marginWheelLastTime = event.timestamp
        guard !marginWheelLatched else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        marginWheelAccumulator += scale * (marginWheelHorizontal
            ? event.scrollingDeltaX : event.scrollingDeltaY)
        guard abs(marginWheelAccumulator) >= 50 else { return }
        let positive = marginWheelAccumulator > 0
        marginWheelAccumulator = 0
        marginWheelLatched = true
        // AppKit の scrollingDelta は DOM の wheel と符号が逆(正=文書の
        // 先頭方向へのスクロール)なので、JS の wheelTurn と対になる写像
        if marginWheelHorizontal {
            positive ? turnPageLeft() : turnPageRight()
        } else {
            positive ? goBackward() : goForward()
        }
    }

    /// href からフラグメントを取り出す。split は空要素を落とすため
    /// "#note1" のような同一文書内リンクで壊れないよう firstIndex で切る
    static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let fragment = String(href[href.index(after: hash)...])
        return fragment.isEmpty ? nil : fragment
    }

    private func handleLink(_ href: String) {
        guard let publication else { return }
        // 外部リンク(スキーム付き)
        if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            if delegate?.readerView(self, shouldOpenExternalURL: url) ?? true {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let currentPath = publication.readingOrder[currentSpineIndex].containerPath
        guard let path = ContainerPath.resolve(base: currentPath, href: href) else {
            return
        }
        goToContainerPath(path, fragment: Self.fragment(of: href))
    }

    /// コンテナ内パスへの移動(リンクの共通経路)。必ず loadSpineItem を
    /// 経由して currentSpineIndex を保つ — WKWebView に直接遷移させると
    /// 柱・ページバー・読書位置の保存がすべて旧 spine 項目のまま狂う
    fileprivate func goToContainerPath(_ path: String, fragment: String?) {
        guard let publication,
              publication.readingOrder.indices.contains(currentSpineIndex)
        else { return }
        if path == publication.readingOrder[currentSpineIndex].containerPath {
            if let fragment { applyTarget(.fragment(fragment)) }
            return
        }
        guard let index = publication.readingOrder
            .firstIndex(where: { $0.containerPath == path }) else { return }
        loadSpineItem(at: index, target: fragment.map { .fragment($0) } ?? .start)
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension EPUBReaderView: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async
        -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else {
            return (.cancel, preferences)
        }
        if url.scheme?.lowercased() == EPUBSchemeHandler.scheme {
            // JS の click 捕捉をすり抜けた内部リンクの安全網(将来の未知の
            // リンク形態も含む): 直接遷移は spine 状態を狂わせるため止め、
            // loadSpineItem 経由で移動する
            if navigationAction.navigationType == .linkActivated {
                if let path = schemeHandler?.containerPath(for: url) {
                    goToContainerPath(
                        path, fragment: url.fragment(percentEncoded: false))
                }
                return (.cancel, preferences)
            }
            preferences.allowsContentJavaScript = settings.allowsScriptedContent
            return (.allow, preferences)
        }
        // JS のクリック捕捉をすり抜けたリンク(area 等)の安全網
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
           navigationAction.navigationType == .linkActivated {
            if delegate?.readerView(self, shouldOpenExternalURL: url) ?? true {
                NSWorkspace.shared.open(url)
            }
        }
        return (.cancel, preferences)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 別の spine へ移った後に届いた古い didFinish は無視する
        // (これを通すと古いセットアップが新文書の pendingTarget を消費する)
        guard navigation == nil || navigation === currentNavigation else { return }
        if isFixedLayoutItem {
            layoutFixedItem()
        }
        let generation = spineLoadGeneration
        Task { [weak self] in
            await self?.runSetup(preserveProgression: false,
                                 generation: generation)
        }
    }

    /// 連続ページ送りで前のナビゲーションが破棄されたときのキャンセル
    /// (NSURLErrorCancelled / WKError.frameLoadInterrupted)は正常系。
    /// 本物の失敗はコンテンツを見せたまま(alpha 復帰)通知する
    private func handleNavigationFailure(_ error: any Error) {
        let nsError = error as NSError
        let isCancellation =
            (nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled)
            // WebKitErrorFrameLoadInterruptedByPolicyChange(102): 別ナビゲーション
            // による中断(公開 enum に定数がないためドメイン+コードで判定)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        guard !isCancellation else { return }
        isLoadingSpineItem = false
        clearPendingSpineTurn()
        webView?.alphaValue = 1
        delegate?.readerView(self, didFailWith: error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: any Error) {
        // 別 spine へ移った後に届く古い失敗は無視(新文書の状態を壊さない)
        guard navigation == nil || navigation === currentNavigation else { return }
        handleNavigationFailure(error)
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: any Error) {
        guard navigation == nil || navigation === currentNavigation else { return }
        handleNavigationFailure(error)
    }

    /// Web コンテンツプロセスが落ちたら現在位置で開き直す
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadCurrentPublication()
    }

    /// ポップアップは開かせない
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// userContentController が handler を強参照するため、weak 中継で循環を断つ
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: EPUBReaderView?

    init(owner: EPUBReaderView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(message.body)
    }
}

/// 右クリック/コントロールクリックのコンテキストメニューを任意で抑制できる
/// WKWebView。ホストが独自メニューを出せるようにするための最小サブクラス
/// (EPUBReaderSettings.suppressesContextMenu)
private final class WashiWebView: WKWebView {
    /// 呼ばれた時点の設定を参照するクロージャ(true で抑制)
    var suppressesContextMenu: (() -> Bool)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        if suppressesContextMenu?() == true {
            menu.removeAllItems()  // 空メニューは表示されない(標準的な抑制手法)
            return
        }
        super.willOpenMenu(menu, with: event)
    }
}
