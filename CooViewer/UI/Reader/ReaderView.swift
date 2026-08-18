import AppKit

@MainActor
protocol ReaderViewDelegate: AnyObject {
    func readerView(_ view: ReaderView, didReceiveDropped url: URL)
    func readerViewMouseMoved(_ view: ReaderView)
    /// キーイベント。処理したら true(false でシステム既定=ビープ)
    func readerView(_ view: ReaderView, handleKey event: NSEvent) -> Bool
    /// クリック/仮想ボタン。leftHalf=画面左半分での操作か
    func readerView(_ view: ReaderView, clickedButton button: Int,
                    modifiers: Int, leftHalf: Bool)
    /// マルチタッチ仮想ボタン。leftHalf は positional 系アクション用(仕様書 §5.9)
    func readerView(_ view: ReaderView, gesture virtualButton: Int, modifiers: Int,
                    leftHalf: Bool)
    /// 30pt 超のドラッグジェスチャ(方向 modifier は LegacyModifier.drag*)
    func readerView(_ view: ReaderView, dragGesture directionModifier: Int,
                    baseModifiers: Int, button: Int, leftHalf: Bool)
    /// ドラッグジェスチャの追跡中(HUD 用。ドラッグスクロール時は呼ばれない)
    func readerView(_ view: ReaderView, dragTracking dx: CGFloat, dy: CGFloat,
                    button: Int, modifiers: Int, elapsed: TimeInterval)
    /// 追跡終了(発火の有無に関わらず解放時に呼ぶ)
    func readerViewDragTrackingEnded(_ view: ReaderView)
    /// 2 本指ダブルタップ(スマートズーム)。point はビュー座標
    func readerViewSmartMagnify(_ view: ReaderView, at point: CGPoint)
    /// 連続ピンチズーム開始(カール等の抑止用)
    func readerViewZoomWillBegin(_ view: ReaderView)
    /// 連続ピンチズーム確定(scale>1 なら高解像度再描画を要求)
    func readerViewZoomDidEnd(_ view: ReaderView, scale: CGFloat)
    /// トラックパッドの深押し。処理したら true(その解放のクリックを抑止)
    func readerViewForceClick(_ view: ReaderView, at point: CGPoint) -> Bool
    /// 深押しした押下の解放(クイックルーペを畳む合図)
    func readerViewForceClickEnded(_ view: ReaderView)
    /// このドラッグを 1:1 スクロールとして扱うか(押下時のバインディング照会)
    func readerViewShouldDragScroll(_ view: ReaderView, button: Int, modifiers: Int) -> Bool
    func readerView(_ view: ReaderView, scrollWheel event: NSEvent)
}

/// ページ描画ビュー(設計書 §3.2)。
/// 旧 CustomImageView の BufferingMode=New 相当: 1/2 ページを CALayer で並置描画する。
/// スクロールは NSScrollView を使わず内部オフセットで管理する
/// (端到達判定 §4.16 をページ送りに使うため)。
@MainActor
final class ReaderView: NSView {
    /// 表示モード(仕様書 §3.2)。旧 fitScreenMode の整数値を維持。
    enum FitMode: Int, CaseIterable {
        case fitToScreen = 0      // 全体フィット・スクロールなし
        case fitWidth = 1         // 幅フィット・縦スクロール
        case noScale = 2          // ポイント原寸
        case fitWidthDivide = 3   // 横長 1 枚を 2 ページ幅とみなす幅フィット
    }

    /// 補間(仕様書 §6.1 Interpolation)。旧整数値を維持。
    enum Interpolation: Int {
        case systemDefault = 0
        case none = 1
        case low = 2
        case high = 3

        var filter: CALayerContentsFilter {
            switch self {
            case .none: .nearest
            case .low: .linear
            case .systemDefault, .high: .trilinear
            }
        }
    }

    weak var delegate: (any ReaderViewDelegate)?

    private let containerLayer = CALayer()
    private let pageLayers = [CALayer(), CALayer()]
    private let loupe = LoupeController()

    private(set) var images: [CGImage] = []
    private(set) var pageIDs: [Int] = []
    /// リサンプルキャッシュの名前空間(本の cacheKey。本切替時の取り違え防止)
    var resampleKeyPrefix = ""
    /// 超解像(最高)のディスクキャッシュを暗号化して残すか。パスワード付き書庫では
    /// true を注入し、復号済みページをキーチェーン鍵で暗号化して SuperRes/ に
    /// 残す(平文で残さない。CWE-312)。既定 false(通常本は従来どおり平文)
    var superResDiskCacheEncrypted = false
    /// 見開きしきい値(横長判定。fitWidthDivide 用。設定から注入される)
    var singleSetting = PageLayout.defaultSingleSetting
    private(set) var readsFromLeft = false

    /// ページ毎の高品質リサンプル結果(対象ピクセルサイズ付き。設計書 §5 描画品質)
    private var resampledPages: [(size: CGSize, image: CGImage)?] = []
    /// 表示中スプレッドのリサンプル(ML 高画質化含む)が進行中かの通知。
    /// コントローラがページバー横のインジケーター表示に使う
    var onResampleActivityChanged: ((Bool) -> Void)?
    /// 表示中スプレッドのリサンプルが進行中か(先読みが ML キューを
    /// 先取りしないための待機判定にも使う)
    private(set) var isResamplingDisplayedPages = false
    /// ルーペ表示専用の高解像度画像(ページ index → 画像)。通常表示には使わない
    private var loupeHighResImages: [Int: CGImage] = [:]
    private var resampleTask: Task<Void, Never>?
    private var resampleGeneration = 0
    /// 進行中リサンプルの要求署名集合(ページ毎のキー・サイズ・条件)。
    /// レイアウトは頻繁に走るため、新しい要求が進行中の要求の部分集合なら
    /// 打ち切らず続行させる(ML は 1 ページ数秒かかるのでやり直しは体感
    /// 遅延に直結する。ページが 1 枚完成するとレイアウトが走って要求が
    /// 縮むため、完全一致ではなく部分集合で判定する)
    private var resampleRequestKeys: Set<String> = []
    /// フィルタ(補間・ML 段階)切替の印。次回のリサンプル予約では
    /// 進行中の 1 件を完走させ(結果はキャッシュに残る)、残りを世代
    /// チェックで止めてから新しい要求を積む(即キャンセルしない)
    private var softRestartRequested = false

    var fitMode: FitMode = .fitToScreen {
        didSet { scrollOffset = .zero; resetZoom(); needsLayout = true }
    }

    /// 回転(仕様書 §4.15): 0=なし, 1=左90°, 2=180°, 3=右90°。永続化しない。
    var rotation: Int = 0 {
        didSet {
            rotation = ((rotation % 4) + 4) % 4
            scrollOffset = .zero
            resetZoom()
            needsLayout = true
        }
    }

    /// 連続ピンチズームの倍率(1.0=現在の表示モードの見え方=下限)。
    /// fitMode は昇格させず純粋な乗数として relayout の scaled にだけ掛かる
    /// (predictedResampleSizes は 1.0 基準を保ち先読み予算を汚さない)。
    /// ページめくり・モード変更・回転で 1.0 に戻る
    private(set) var zoomScale: CGFloat = 1 {
        didSet {
            guard zoomScale != oldValue else { return }
            needsLayout = true  // スクロール位置は保持(拡縮のみ)
        }
    }
    /// ライブズーム中(リサンプル洪水を抑止。inLiveResize と同じ発想)
    private var isLiveZooming = false

    /// ズームを下限へ戻し、進行中の慣性タイマも必ず止める。zoomScale=1 を
    /// 外部から起こす全経路(setPages/fitMode/rotation)はこれを通す —
    /// settle 中に新ページ/新モードが来ても旧 target へズームし直さないため
    private func resetZoom() {
        zoomSettleTimer?.invalidate()
        zoomSettleTimer = nil
        zoomSettleCompletion = nil
        isLiveZooming = false
        zoomScale = 1
    }

    var interpolation: Interpolation = .systemDefault {
        didSet {
            for layer in pageLayers {
                layer.magnificationFilter = interpolation.filter
            }
            if interpolation != oldValue {
                resampledPages = Array(repeating: nil, count: images.count)
                softRestartRequested = true
                needsLayout = true
            }
        }
    }

    /// ML 高画質化の処理段階(設定から注入。全ページ対象)。
    /// 変更時はリサンプルを作り直す(補間変更と同じ扱い)
    var noiseReductionLevel: NoiseReductionLevel = .none {
        didSet {
            if noiseReductionLevel != oldValue {
                softRestartRequested = true
                resampledPages = Array(repeating: nil, count: images.count)
                needsLayout = true
            }
        }
    }

    var backgroundColor: NSColor = .black {
        didSet { layer?.backgroundColor = backgroundColor.cgColor }
    }

    private var contentSize: CGSize = .zero
    private var scrollOffset: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// メモリ圧迫時にカールオーバーレイ(スナップショット 2 枚を保持)を
    /// 即時解放するための監視
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.masksToBounds = true
        containerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(containerLayer)
        for pageLayer in pageLayers {
            pageLayer.contentsGravity = .resize
            pageLayer.magnificationFilter = interpolation.filter
            pageLayer.minificationFilter = .trilinear
            pageLayer.isHidden = true
            // HDR(ゲインマップ)画像を EDR ディスプレイで輝度拡張表示する
            pageLayer.preferredDynamicRange = .high
            containerLayer.addSublayer(pageLayer)
        }
        registerForDraggedTypes([.fileURL])

        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressureSource = pressure
        // @Sendable でクロージャの隔離推論を止める。setEventHandler の引数は @Sendable では
        // ないため、@MainActor の init 内で書いたこのクロージャは @MainActor 隔離と推論される。
        // DispatchSource はそれを .global(qos: .utility) で呼ぶので、macOS 26.6 の Swift 並行性
        // ランタイムがクロージャ入口で隔離アサート(dispatch_assert_queue)に失敗し SIGTRAP する
        // (本を開く前のランダムクラッシュとして報告)。@Sendable なら非隔離になり内側の
        // Task へ安全に到達する。
        pressure.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in
                self?.removeCurlOverlay()
            }
        }
        pressure.activate()
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // ウインドウから外れた(閉じた)ら慣性タイマを止める。run loop に
        // 強参照で保持されるため放置すると [weak self] の空撃ちが永久に続く
        // (deinit は nonisolated で Timer に触れないためここで畳む)
        if window == nil {
            zoomSettleTimer?.invalidate()
            zoomSettleTimer = nil
            zoomSettleCompletion = nil
            isLiveZooming = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - コンテンツ設定

    /// ページ送りのめくり効果の指定(効果の種類+進行方向)
    struct PageTurn {
        let animation: PageTurnAnimation
        let forward: Bool
    }

    /// 読み順のページ画像(1 or 2 枚)を表示する。
    /// ids はリサンプルキャッシュのキーに使う(空なら画像順の連番)。
    /// preResampled はリサンプル済みキャッシュの事前引き当て(サイズ+画像。
    /// 未命中は nil): 渡すと最初のレイアウトから完成画像を使うため、
    /// めくり効果のスナップショットにもフィルタ済みの絵が入る。
    /// turn を渡すとページめくり効果を付ける(ページ送り系のみ。nil で即時)
    func setPages(_ images: [CGImage], ids: [Int] = [], readsFromLeft: Bool,
                  preResampled: [(size: CGSize, image: CGImage)?] = [],
                  turn: PageTurn? = nil) {
        // スワイプ追従カールの予約(refreshDisplay 前にコントローラが設定)。
        // 自動再生の turn より優先する
        let interactive = pendingInteractiveCurl
        pendingInteractiveCurl = nil
        // 進行中のカールは即終了(連打時は最後のめくりだけが動く)
        removeCurlOverlay()
        // カールは差し替え前の見た目(旧内容)のスナップショットが要る
        var oldContentForCurl: CGImage?
        if interactive == nil, let turn, turn.animation == .curl, canRunCurl {
            oldContentForCurl = snapshotContent()
        }
        // フェード/スライドは内容差し替えを挟んで補間する CATransition なので
        // 差し替えの前に仕込む
        if interactive == nil, let turn {
            addTurnTransitionIfNeeded(turn, newReadsFromLeft: readsFromLeft)
        }
        self.images = images
        self.pageIDs = ids.count == images.count ? ids : Array(images.indices)
        self.readsFromLeft = readsFromLeft
        // 事前引き当て分を最初から採用する(サイズが実レイアウトと一致した
        // ページだけが使われ、不一致・未命中は通常の非同期リサンプルが埋める)
        resampledPages = preResampled.count == images.count
            ? preResampled : Array(repeating: nil, count: images.count)
        loupeHighResImages.removeAll()
        for pageLayer in pageLayers {
            pageLayer.removeAnimation(forKey: "pageAnimation")
        }
        scrollOffset = .zero
        resetZoom()  // ズームはページを跨いで持ち越さない(送りで下限へ)
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollToHome()
        // ズームフェードは新内容のレイアウト確定後に container へ掛ける。
        // カールは旧内容と新内容のスナップショットからオーバーレイを組む
        if let interactive {
            if canRunCurl {
                startInteractiveCurlOverlay(oldContent: interactive.oldContent,
                                            forward: interactive.forward)
            }
        } else if let turn {
            if turn.animation == .curl {
                if let old = oldContentForCurl, let new = snapshotContent() {
                    runCurlAnimation(oldContent: old, newContent: new,
                                     forward: turn.forward)
                }
            } else {
                addTurnContainerAnimationIfNeeded(turn)
            }
        }
    }

    // MARK: - ページめくり効果(設計書 §2.4。既定オフ)

    /// フェード/スライド: レイヤーツリーの差し替え前後を CATransition で補間する
    private func addTurnTransitionIfNeeded(_ turn: PageTurn, newReadsFromLeft: Bool) {
        guard let layer else { return }
        let transition = CATransition()
        transition.duration = 0.20
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        switch turn.animation {
        case .fade:
            transition.type = .fade
        case .slide:
            transition.type = .push
            transition.subtype = PageTurnAnimation.entersFromLeft(
                forward: turn.forward, readsFromLeft: newReadsFromLeft)
                ? .fromLeft : .fromRight
        case .none, .zoomFade, .curl:
            return
        }
        layer.add(transition, forKey: "pageTurn")
    }

    /// ズームフェード: 新しい内容の container に入場アニメーションを掛ける。
    /// relayout は position と 2D 変換(モデル値)しか触らないため、
    /// from/to 明示のアニメーションはリサイズ等と競合しない
    private func addTurnContainerAnimationIfNeeded(_ turn: PageTurn) {
        guard turn.animation == .zoomFade else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.2
        fade.toValue = 1
        let zoom = CABasicAnimation(keyPath: "transform.scale")
        zoom.fromValue = 0.98
        zoom.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [fade, zoom]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        containerLayer.add(group, forKey: "pageTurnZoom")
    }

    // MARK: - ページカール(設計書 §2.4)

    /// 進行中のカールオーバーレイ(nil なら非表示)。
    /// 本のノド=画面中央として、めくれる半面をストリップ列で 3D 湾曲させる
    private var curlOverlay: CALayer?

    /// カールを実行できる状態か。回転表示中は軸の幾何が合わず、ルーペ表示中は
    /// スナップショットにルーペが写り込むため省略する
    private var canRunCurl: Bool {
        rotation == 0 && !loupe.isEnabled && zoomScale == 1
            && bounds.width > 1 && bounds.height > 1
    }

    /// 現在の描画内容(背景+ページ)をピクセルスケールでスナップショットする
    /// (internal: PageCurlRenderTests が実経路の向き検証に使う)。
    /// flipped ビューの layer を直接 render すると上下逆の像になるため
    /// 補正する(設定ウインドウの NSHostingView スナップショットと同じ癖。
    /// 向きは PageCurlRenderTests の実描画比較で担保)
    func snapshotContent() -> CGImage? {
        guard let layer else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return context.makeImage()
    }

    func removeCurlOverlay() {
        curlScrubTimer?.invalidate()
        curlScrubTimer = nil
        curlOverlay?.removeFromSuperlayer()
        curlOverlay = nil
    }

    // MARK: - スワイプ追従カール(指の移動量で進行度を駆動する)

    /// setPages 前にコントローラが設定する予約(旧内容+進行方向)。
    /// 設定されていると、自動再生の代わりに speed=0 のオーバーレイを組み、
    /// updateInteractiveCurl(progress:) の timeOffset 駆動で指に追従させる
    var pendingInteractiveCurl: (oldContent: CGImage, forward: Bool)?
    private var interactiveCurlDuration: CFTimeInterval = 0.45
    private var curlScrubTimer: Timer?

    /// スワイプ追従カールが有効か(オーバーレイが停止状態で存在する)
    var hasInteractiveCurl: Bool {
        curlOverlay != nil && curlOverlay?.speed == 0
    }

    private func startInteractiveCurlOverlay(oldContent: CGImage, forward: Bool) {
        guard let layer, let newContent = snapshotContent() else { return }
        let configuration = PageCurlOverlay.Configuration(
            bounds: bounds,
            leafOnLeft: PageTurnAnimation.entersFromLeft(
                forward: forward, readsFromLeft: readsFromLeft),
            oldContent: oldContent,
            newContent: newContent)
        guard let overlay = PageCurlOverlay.makeAnimated(configuration) else { return }
        // speed=0 で止めて timeOffset をスクラブする(標準的な手法)
        overlay.speed = 0
        overlay.timeOffset = 0
        layer.addSublayer(overlay)
        curlOverlay = overlay
        interactiveCurlDuration = configuration.duration
    }

    /// 進行度(0-1)を反映する。1.0 は完了直前で止める(確定は finish で)
    func updateInteractiveCurl(progress: CGFloat) {
        guard let curlOverlay, curlOverlay.speed == 0 else { return }
        curlOverlay.timeOffset =
            Double(min(max(progress, 0), 0.999)) * interactiveCurlDuration
    }

    /// 指を離した後、残りを再生してめくりを確定する(モデルは進んでいる前提)
    func finishInteractiveCurl() {
        guard let overlay = curlOverlay, overlay.speed == 0 else { return }
        let offset = overlay.timeOffset
        overlay.speed = 1
        overlay.timeOffset = 0
        overlay.beginTime = CACurrentMediaTime() - offset
        let remaining = max(0.02, interactiveCurlDuration - offset)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.03) {
            [weak self, weak overlay] in
            guard let self, let overlay, self.curlOverlay === overlay else { return }
            self.removeCurlOverlay()
        }
    }

    /// 指を離した後、巻き戻して取りやめる。巻き戻し完了時に completion
    /// (呼び出し側がモデルを元のページへ戻し、その再表示でオーバーレイが畳まれる)
    func cancelInteractiveCurl(completion: @escaping @MainActor () -> Void) {
        guard let overlay = curlOverlay, overlay.speed == 0,
              overlay.timeOffset > 0.01 else {
            completion()
            return
        }
        curlScrubTimer?.invalidate()
        let start = overlay.timeOffset
        let rewindDuration = 0.05 + 0.15 * start / interactiveCurlDuration
        let startTime = CACurrentMediaTime()
        curlScrubTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 120, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // オーバーレイが差し替え等で消えていたら巻き戻しをやめる
                guard let overlay = self.curlOverlay, overlay.speed == 0 else {
                    self.curlScrubTimer?.invalidate()
                    self.curlScrubTimer = nil
                    return
                }
                let progress = (CACurrentMediaTime() - startTime) / rewindDuration
                if progress >= 1 {
                    self.curlScrubTimer?.invalidate()
                    self.curlScrubTimer = nil
                    overlay.timeOffset = 0
                    completion()
                } else {
                    overlay.timeOffset = start * (1 - progress)
                }
            }
        }
    }

    /// 本式のページめくり: 画面をノド(中央)で左右に分割し、空く側の半面が
    /// リーフとしてカールしながら反対側へ倒れる(構築は PageCurlOverlay)。
    /// 空いていく側は下にある live コンテンツ(新内容)がそのまま現れる
    private func runCurlAnimation(oldContent: CGImage, newContent: CGImage,
                                  forward: Bool) {
        guard let layer else { return }
        let configuration = PageCurlOverlay.Configuration(
            bounds: bounds,
            leafOnLeft: PageTurnAnimation.entersFromLeft(
                forward: forward, readsFromLeft: readsFromLeft),
            oldContent: oldContent,
            newContent: newContent)
        guard let overlay = PageCurlOverlay.makeAnimated(configuration) else { return }
        layer.addSublayer(overlay)
        curlOverlay = overlay

        // 完了でオーバーレイごと畳む(下は既に新内容なので切れ目なし)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            guard let self, let overlay, self.curlOverlay === overlay else { return }
            self.removeCurlOverlay()
        }
        let lifetime = CABasicAnimation(keyPath: "opacity")
        lifetime.fromValue = 1
        lifetime.toValue = 1
        lifetime.duration = configuration.duration
        overlay.add(lifetime, forKey: "curlLifetime")
        CATransaction.commit()
    }

    // MARK: - レイアウト

    /// 回転を考慮した実効表示領域(回転空間でのサイズ)
    private var availableSize: CGSize {
        rotation % 2 == 1
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
    }

    override func layout() {
        super.layout()
        // リサイズでオーバーレイの幾何が古くなったらカールは打ち切る
        if let curlOverlay, curlOverlay.frame.size != bounds.size {
            removeCurlOverlay()
        }
        relayout()
        // レイアウト変化(ページ切替・スクロール・リサイズ)をルーペにも反映
        if loupe.isEnabled {
            loupe.update(content: loupeContent())
        }
    }

    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let available = availableSize
        containerLayer.bounds = CGRect(origin: .zero, size: available)
        containerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        containerLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 2))

        guard !images.isEmpty, available.width > 0, available.height > 0 else {
            contentSize = .zero
            for layer in pageLayers { layer.isHidden = true }
            // 表示するものがない=リサンプルも起きない。進行表示の予約を解除する
            setResampleActivity(false)
            return
        }

        let sizes = images.map { CGSize(width: $0.width, height: $0.height) }
        let scales = pageScales(for: sizes, available: available)
        // zoomScale は表示モードのスケールに掛かる純乗数。pageScales 側には
        // 混ぜない(predictedResampleSizes/先読み予算が 1.0 基準を保つため)
        let scaled = zip(sizes, scales).map {
            CGSize(width: $0.width * $1 * zoomScale, height: $0.height * $1 * zoomScale)
        }
        contentSize = CGSize(
            width: scaled.reduce(0) { $0 + $1.width },
            height: scaled.map(\.height).max() ?? 0
        )
        clampScrollOffset()

        // コンテンツが表示領域より小さい軸はセンタリング
        let pad = CGPoint(
            x: max(0, (available.width - contentSize.width) / 2),
            y: max(0, (available.height - contentSize.height) / 2)
        )

        // 画面上の並び: 読み順先頭ページは、左綴じなら左、右綴じなら右(仕様書 §4.2.5)
        let backingScale = window?.backingScaleFactor ?? 2
        let screenOrder = readsFromLeft ? Array(scaled.indices) : scaled.indices.reversed()
        var x = pad.x - scrollOffset.x
        for imageIndex in screenOrder {
            let size = scaled[imageIndex]
            let layer = pageLayers[imageIndex]
            layer.isHidden = false
            // 高品質リサンプル済みで表示サイズが一致するならそれを使う(1:1 表示)
            let pixelSize = CGSize(width: (size.width * backingScale).rounded(),
                                   height: (size.height * backingScale).rounded())
            if let resampled = resampledPages.indices.contains(imageIndex)
                ? resampledPages[imageIndex] : nil,
               resampled.size == pixelSize {
                layer.contents = resampled.image
            } else {
                layer.contents = images[imageIndex]
            }
            // 垂直はコンテンツ高(2 枚の最大)に対しセンタリング(仕様書 §4.2.3)
            let y = pad.y - scrollOffset.y + (contentSize.height - size.height) / 2
            layer.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width
        }
        for index in images.count..<pageLayers.count {
            pageLayers[index].isHidden = true
        }
        scheduleHighQualityResample(scaledSizes: scaled, backingScale: backingScale)
    }

    // MARK: - 高品質リサンプル(設計書 §5 描画品質)

    /// 補間設定が「既定/高」のとき、表示ピクセルサイズへの事前リサンプルを
    /// 予約する(縮小=CG Lanczos 相当、「高」は拡大に MetalFX)。
    /// ライブリサイズ中の洪水を避けるため短いデバウンスを挟み、
    /// 完成したページから順に等倍画像へ差し替える。
    /// [#4] キャップデコード画像が表示目標に対しこの倍率以内の「僅かな縮小」なら、
    /// Lanczos/MetalFX の高品質リサンプル(GPU 二重処理)を省いて CALayer のトリリニア
    /// 縮小に委ねる。5% 差は見た目に判別できず、長時間読書での GPU/電力・発熱を抑える。
    private static let resampleSkipTolerance = 1.05

    private func scheduleHighQualityResample(scaledSizes: [CGSize], backingScale: CGFloat) {
        guard interpolation == .systemDefault || interpolation == .high,
              !images.isEmpty else {
            setResampleActivity(false)
            return
        }
        // ライブズーム中は毎フレーム pixelSize が変わるため、リサンプル(ML は
        // 1 ページ数秒)の洪水を避けて trilinear 拡大表示に委ねる。確定時
        // (isLiveZooming=false の最後の relayout)に 1 回だけ予約される
        guard !isLiveZooming else { setResampleActivity(false); return }
        let requests: [(index: Int, image: CGImage, pixelSize: CGSize, key: String,
                        noiseReduction: NoiseReductionLevel)] =
            images.indices.compactMap { index in
                // レイアウトと setPages の間で配列長が食い違っても落ちないように検証
                guard scaledSizes.indices.contains(index),
                      resampledPages.indices.contains(index),
                      pageIDs.indices.contains(index),
                      images[index].bitsPerComponent <= 8 else { return nil }
                let pixelSize = CGSize(
                    width: (scaledSizes[index].width * backingScale).rounded(),
                    height: (scaledSizes[index].height * backingScale).rounded())
                if let done = resampledPages[index], done.size == pixelSize { return nil }
                // [#4] キャップ画像が目標に十分近い(僅かな縮小・拡大ではない・ノイズ低減
                // なし)なら高品質リサンプルを省き、CALayer のトリリニア縮小に委ねる。
                // 「そのキャップ画像で目標サイズを満たした」と記録して再要求を防ぐ
                // (ページ切替で resampledPages はリセットされるので stale にならない)。
                let cap = images[index]
                if noiseReductionLevel == .none,
                   cap.width >= Int(pixelSize.width), cap.height >= Int(pixelSize.height),
                   Double(cap.width) <= pixelSize.width * Self.resampleSkipTolerance,
                   Double(cap.height) <= pixelSize.height * Self.resampleSkipTolerance {
                    resampledPages[index] = (pixelSize, cap)
                    return nil
                }
                return (index, images[index], pixelSize,
                        "\(resampleKeyPrefix)#\(pageIDs[index])", noiseReductionLevel)
            }
        // 新しい要求が進行中の要求の部分集合なら打ち切らず続行させる
        // (レイアウトは頻繁に走るため、無条件にやり直すと ML リサンプルが
        // 何度も最初からになる)
        let requestKeys = Set(requests.map {
            "\($0.key)|\(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))"
                + "|nr\($0.noiseReduction.rawValue)|mfx\(interpolation == .high)"
        })
        if softRestartRequested {
            // フィルタ切替: 進行中の 1 件は完走させて(結果はキャッシュへ
            // 残り、レベルを戻したとき等に活きる)、残りの要求は世代
            // チェックで止める。新しい要求は完走中の 1 件の後ろに並ぶ
            softRestartRequested = false
            resampleGeneration += 1
            resampleTask = nil  // 旧タスクは現要求の完了後に自然停止する
        } else {
            if !requests.isEmpty, resampleTask != nil,
               requestKeys.isSubset(of: resampleRequestKeys) {
                return
            }
            // 旧スプレッドの進行中リサンプルは、今回の対象が空でも必ず打ち切る
            // (>8bit ページ等で対象ゼロのとき、旧タスクの遅延書込が新しい
            // スプレッドのスロットを汚す穴の修正)
            resampleTask?.cancel()
            resampleGeneration += 1
        }
        resampleRequestKeys = requests.isEmpty ? [] : requestKeys
        setResampleActivity(!requests.isEmpty)
        guard !requests.isEmpty else { return }

        let generation = resampleGeneration
        let useMetalFX = interpolation == .high
        // デバウンスはライブリサイズ中の洪水対策。ページ送りでは待たずに
        // 即リサンプルして、最初の描画から等倍のシャープな画像に近づける
        let debounce: Bool = inLiveResize
        resampleTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            for request in requests {
                // フィルタ切替のソフト停止: 進行中の 1 件の完了後、
                // 世代が進んでいたら残りを始めずに譲る
                guard let self, !Task.isCancelled,
                      generation == self.resampleGeneration else { return }
                guard let resampled = await ImageResampler.shared.resample(
                    request.image, to: request.pixelSize,
                    cacheKey: request.key, upscaleWithMetalFX: useMetalFX,
                    noiseReduction: request.noiseReduction,
                    superResEncrypted: superResDiskCacheEncrypted) else { continue }
                guard !Task.isCancelled else { return }
                self.applyResampled(resampled, size: request.pixelSize,
                                    at: request.index, generation: generation,
                                    key: request.key)
            }
            // このスプレッドの計算が最後まで走り切ったら進行表示を消し、
            // 完了済みタスクへの参照と署名を片付ける(残すと同じ要求の
            // 再リサンプルが「進行中」と誤判定されて抑止されてしまう)
            if let self, !Task.isCancelled, generation == self.resampleGeneration {
                self.setResampleActivity(false)
                self.resampleTask = nil
                self.resampleRequestKeys = []
            }
        }
    }

    /// リサンプル進行状態をコントローラへ通知する。
    /// 同値でも毎回通知する: コントローラは refreshDisplay 開始時に
    /// 「表示予約」を出しており、リサンプル不要のスプレッド(全ページ
    /// 事前引き当て済み・HDR ページ等)では false の再通知が予約解除の
    /// 唯一の手段になる(抑制するとスピナーが出っぱなしになる)
    private func setResampleActivity(_ active: Bool) {
        isResamplingDisplayedPages = active
        onResampleActivityChanged?(active)
    }

    private func applyResampled(_ image: CGImage, size: CGSize,
                                at index: Int, generation: Int, key: String) {
        // 世代に加えてページの同一性(キャッシュキー)も照合する(遅延書込対策)
        guard generation == resampleGeneration,
              resampledPages.indices.contains(index),
              pageIDs.indices.contains(index),
              key == "\(resampleKeyPrefix)#\(pageIDs[index])" else { return }
        resampledPages[index] = (size, image)
        needsLayout = true
    }

    /// まだ表示していないページの表示ピクセルサイズを予測する(次スプレッドの
    /// 事前リサンプル用)。現在のフィットモード・回転・ウインドウ実寸で、
    /// このサイズのページを表示したときのリサンプル目標と同じ値を返す。
    /// 事前リサンプルが不要な補間モード(なし/低)や未レイアウトでは nil
    func predictedResampleSizes(for sizes: [CGSize]) -> [CGSize]? {
        guard interpolation == .systemDefault || interpolation == .high,
              !sizes.isEmpty else { return nil }
        let available = availableSize
        guard available.width > 0, available.height > 0 else { return nil }
        let backingScale = window?.backingScaleFactor ?? 2
        let scales = pageScales(for: sizes, available: available)
        return zip(sizes, scales).map {
            CGSize(width: ($0.width * $1 * backingScale).rounded(),
                   height: ($0.height * $1 * backingScale).rounded())
        }
    }

    /// ページ毎のスケール(仕様書 §4.2.3, §3.2)
    private func pageScales(for sizes: [CGSize], available: CGSize) -> [CGFloat] {
        let pageCount = CGFloat(sizes.count)
        switch fitMode {
        case .fitToScreen:
            return sizes.map { size in
                min(available.width / pageCount / size.width, available.height / size.height)
            }
        case .fitWidth:
            return sizes.map { size in available.width / pageCount / size.width }
        case .noScale:
            return sizes.map { _ in 1.0 }
        case .fitWidthDivide:
            // 横長 1 枚は「横半分=1 ページ幅」とみなす → 表示幅は領域の 2 倍(仕様書 §3.2)
            if sizes.count == 1, let size = sizes.first,
               size.width / size.height > CGFloat(singleSetting) / 1000.0 {
                return [available.width * 2 / size.width]
            }
            return sizes.map { size in available.width / pageCount / size.width }
        }
    }

    // MARK: - スクロール

    /// テスト用: 現在のスクロール位置(読み取りのみ)
    var debugScrollOffset: CGPoint { scrollOffset }

    private var maxScrollOffset: CGPoint {
        CGPoint(
            x: max(0, contentSize.width - availableSize.width),
            y: max(0, contentSize.height - availableSize.height)
        )
    }

    private func clampScrollOffset() {
        scrollOffset.x = min(max(0, scrollOffset.x), maxScrollOffset.x)
        scrollOffset.y = min(max(0, scrollOffset.y), maxScrollOffset.y)
    }

    /// ズーム中か(コントローラがページ送りを抑止しパンへ振り替える判定に使う)
    var isZoomed: Bool { zoomScale > 1 }
    /// 現在のズーム倍率(アクティビティ窓向け)
    var currentZoomScale: CGFloat { zoomScale }

    // MARK: - アクティビティ窓向けの実態アクセサ
    /// 表示中スプレッドのリサンプル進行中要求数
    var resampleInFlightCount: Int { resampleRequestKeys.count }
    /// 表示中ページのうち高品質リサンプルが完成している枚数
    var resampledCompletedCount: Int { resampledPages.compactMap { $0 }.count }

    /// 検証用: 中心アンカーで倍率を直接与え、確定経路(cap 再デコード)も通す
    func debugSetZoom(_ scale: CGFloat) {
        zoomAnchorRatio = CGPoint(x: 0.5, y: 0.5)
        zoomAnchorCursor = CGPoint(x: bounds.midX, y: bounds.midY)
        zoomScale = max(1, scale)
        reanchorZoom()
        // 実ピンチと同じ確定通知(高解像度再デコード→pendingZoom 復元)を起こす
        delegate?.readerViewZoomDidEnd(self, scale: zoomScale)
    }

    /// 確定ズームの cap 上昇再デコード後に、倍率とアンカーを復元する
    /// (setPages が zoomScale=1 に落とすため。コントローラの pendingZoom 経由)
    func restoreZoom(scale: CGFloat, anchorRatio: CGPoint) {
        guard scale > 1 else { return }
        zoomAnchorRatio = anchorRatio
        // 復元時はカーソルが無いのでアンカー点を中央に据える
        zoomAnchorCursor = CGPoint(x: bounds.midX, y: bounds.midY)
        zoomScale = scale
        reanchorZoom()
    }

    /// 確定ズームのアンカー比率(コントローラが再デコード後の復元に使う)
    var currentZoomAnchorRatio: CGPoint { zoomAnchorRatio }

    /// delta 分スクロールする。1px も動けなかったら false(端到達。仕様書 §4.16)。
    @discardableResult
    func scroll(by delta: CGPoint) -> Bool {
        let before = scrollOffset
        scrollOffset.x += delta.x
        scrollOffset.y += delta.y
        clampScrollOffset()
        guard scrollOffset != before else { return false }
        needsLayout = true
        return true
    }

    /// ページ先頭へ(上端。水平は綴じ方向の読み始め側。仕様書 §5.5 action 28)
    func scrollToHome() {
        scrollOffset = CGPoint(x: readsFromLeft ? 0 : maxScrollOffset.x, y: 0)
        needsLayout = true
    }

    /// ページ末尾へ(下端。水平は読み終わり側)
    func scrollToEnd() {
        scrollOffset = CGPoint(x: readsFromLeft ? maxScrollOffset.x : 0, y: maxScrollOffset.y)
        needsLayout = true
    }

    /// 1 画面分の縦送り。動けなければ false(仕様書 §5.5 action 24-27)。
    @discardableResult
    func pageUp() -> Bool {
        scroll(by: CGPoint(x: 0, y: -availableSize.height * 0.9))
    }

    @discardableResult
    func pageDown() -> Bool {
        scroll(by: CGPoint(x: 0, y: availableSize.height * 0.9))
    }

    // MARK: - ルーペ(仕様書 §4.10。実装は LoupeController)

    var isLoupeEnabled: Bool { loupe.isEnabled }

    func enableLoupe(size: Double, rate: Double) {
        guard let layer, let window else { return }
        loupe.size = size
        loupe.rate = rate
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        loupe.enable(in: layer, at: point, content: loupeContent())
    }

    func disableLoupe() {
        loupe.disable()
    }

    func setLoupeRate(_ rate: Double) {
        loupe.rate = rate
    }

    /// アニメーション画像の再生(設計書 §5)。CAKeyframeAnimation の discrete
    /// 補間でフレームを切り替える。ページが替わっていたら無視する。
    func applyAnimation(frames: [CGImage], delays: [Double],
                        forPageAt index: Int, id: Int) {
        guard pageIDs.indices.contains(index), pageIDs[index] == id,
              frames.count > 1, pageLayers.indices.contains(index) else { return }
        let total = delays.reduce(0, +)
        guard total > 0 else { return }
        var keyTimes: [NSNumber] = [0]
        var elapsed = 0.0
        for delay in delays.dropLast() {
            elapsed += delay
            keyTimes.append(NSNumber(value: elapsed / total))
        }
        keyTimes.append(1)
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        pageLayers[index].add(animation, forKey: "pageAnimation")
    }

    /// ルーペ超解像の目標サイズ計算用: ページ layer の実表示ピクセルサイズ
    func pageFramePixelSize(at index: Int) -> CGSize? {
        guard pageLayers.indices.contains(index), images.indices.contains(index)
        else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let size = pageLayers[index].frame.size
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// ルーペにだけ高解像度画像を差し込む(通常表示・先読みには影響しない)。
    /// 表示中の画像より低解像度なら採用しない(SVG のフォールバック既定
    /// 2048px が表示用 4096px を下回るケースの逆転防止)。
    func setLoupeHighResImage(_ image: CGImage, forPageAt index: Int, entryID: Int) {
        // ページめくり直後に届いた古いページの結果は捨てる(id 照合)
        guard pageIDs.indices.contains(index), pageIDs[index] == entryID else { return }
        if images.indices.contains(index),
           image.width * image.height < images[index].width * images[index].height {
            return
        }
        loupeHighResImages[index] = image
        if loupe.isEnabled {
            loupe.update(content: loupeContent())
        }
    }

    private func loupeContent() -> LoupeController.Content {
        LoupeController.Content(
            containerBounds: containerLayer.bounds,
            containerPosition: containerLayer.position,
            containerTransform: containerLayer.affineTransform(),
            pages: images.indices.map { index in
                LoupeController.Page(frame: pageLayers[index].frame,
                                     image: loupeHighResImages[index] ?? images[index])
            },
            backgroundColor: layer?.backgroundColor)
    }

    // MARK: - キー入力(バインディングシステムへ転送。仕様書 §5)

    override func keyDown(with event: NSEvent) {
        if delegate?.readerView(self, handleKey: event) != true {
            super.keyDown(with: event)
        }
    }

    // MARK: - マウス(クリック/ドラッグスクロール/ドラッグジェスチャ。仕様書 §5.9)

    /// 全ボタン共通の状態機械。旧実装は rightMouse*/otherMouse* を左の処理へ
    /// 転送して同一規則で扱う(右/中ボタンのドラッグジェスチャや DragScroll
    /// 割当も成立し、クリックは解放時に発火する。仕様書 §5.9)
    private var mouseRecognizer = MouseGestureRecognizer()

    /// positional 系アクション用の左右半面判定。旧実装はクリック=contentView /
    /// ジェスチャ=imageView と基準が不統一だったが view bounds に統一
    /// (設計書 §2.4 の仕様変更)
    func isLeftHalf(locationInWindow point: NSPoint) -> Bool {
        convert(point, from: nil).x < bounds.midX
    }

    override func mouseDown(with event: NSEvent) { beginMouse(event, button: 0) }
    override func rightMouseDown(with event: NSEvent) { beginMouse(event, button: 1) }
    override func otherMouseDown(with event: NSEvent) {
        beginMouse(event, button: event.buttonNumber)
    }

    override func mouseDragged(with event: NSEvent) { dragMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { dragMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { dragMouse(event) }

    override func mouseUp(with event: NSEvent) { finishMouse(event, button: 0) }
    override func rightMouseUp(with event: NSEvent) { finishMouse(event, button: 1) }
    override func otherMouseUp(with event: NSEvent) {
        finishMouse(event, button: event.buttonNumber)
    }

    private func beginMouse(_ event: NSEvent, button: Int) {
        // 追跡中の同時押し(chord)は無視する — 状態機械は 1 押下分なので、
        // 上書きするとドラッグスクロールのカーソルが戻らない等の混線を起こす
        guard !mouseRecognizer.isTracking else { return }
        // DragScroll は押下時に確定する(ドラッグ中の修飾キー変更は影響しない。
        // 旧 CustomImageView.m:141-168)。Fit to Screen では成立しない(仕様書 §5.7.5)
        let modifiers = LegacyModifier.encode(flags: event.modifierFlags)
        let dragScroll = fitMode != .fitToScreen
            && delegate?.readerViewShouldDragScroll(self, button: button,
                                                    modifiers: modifiers) == true
        mouseRecognizer.begin(button: button,
                              point: convert(event.locationInWindow, from: nil),
                              time: event.timestamp, dragScroll: dragScroll)
        if dragScroll { NSCursor.closedHand.set() }  // 押下時から表示(旧互換)
    }

    private func dragMouse(_ event: NSEvent) {
        if loupe.isEnabled {
            loupe.move(to: convert(event.locationInWindow, from: nil))
        }
        if mouseRecognizer.isDragScrolling {
            mouseRecognizer.noteDragScrolled()
            scroll(by: CGPoint(x: -event.deltaX, y: -event.deltaY))
            return
        }
        guard mouseRecognizer.isTracking else { return }
        let point = convert(event.locationInWindow, from: nil)
        delegate?.readerView(self, dragTracking: point.x - mouseRecognizer.startPoint.x,
                             dy: point.y - mouseRecognizer.startPoint.y,
                             button: mouseRecognizer.button,
                             modifiers: LegacyModifier.encode(flags: event.modifierFlags),
                             elapsed: event.timestamp - mouseRecognizer.startTime)
    }

    private func finishMouse(_ event: NSEvent, button: Int) {
        // 深押し中の押下の解放: クイックルーペを畳む(深押しは左ボタンのみ)
        if button == 0, forceClickActive {
            forceClickActive = false
            delegate?.readerViewForceClickEnded(self)
            return
        }
        // 追跡中のボタンの解放だけを終端にする(chord の他ボタン解放は無視)
        guard mouseRecognizer.isTracking, mouseRecognizer.button == button else { return }
        delegate?.readerViewDragTrackingEnded(self)
        let point = convert(event.locationInWindow, from: nil)
        let wasDragScrolling = mouseRecognizer.isDragScrolling
        let outcome = mouseRecognizer.finish(
            point: point, time: event.timestamp,
            modifiers: LegacyModifier.encode(flags: event.modifierFlags))
        if wasDragScrolling { NSCursor.arrow.set() }
        switch outcome {
        case .none:
            break
        case .click(let button, let modifiers):
            delegate?.readerView(self, clickedButton: button, modifiers: modifiers,
                                 leftHalf: point.x < bounds.midX)
        case .dragGesture(let direction, let base, let button):
            delegate?.readerView(self, dragGesture: direction, baseModifiers: base,
                                 button: button, leftHalf: point.x < bounds.midX)
        }
    }

    // MARK: - ホイール/マルチタッチジェスチャ(仕様書 §4.16, §5.1)

    override func scrollWheel(with event: NSEvent) {
        delegate?.readerView(self, scrollWheel: event)
    }

    override func swipe(with event: NSEvent) {
        let virtualButton: Int
        if abs(event.deltaX) >= abs(event.deltaY) {
            virtualButton = event.deltaX > 0
                ? VirtualButton.swipeLeft : VirtualButton.swipeRight
        } else {
            virtualButton = event.deltaY > 0
                ? VirtualButton.swipeUp : VirtualButton.swipeDown
        }
        delegate?.readerView(self, gesture: virtualButton,
                             modifiers: LegacyModifier.encode(flags: event.modifierFlags),
                             leftHalf: isLeftHalf(locationInWindow: event.locationInWindow))
    }

    private var rotationSum: CGFloat = 0
    /// ライブズームのカーソルアンカー(.began で固定)
    private var zoomAnchorRatio = CGPoint(x: 0.5, y: 0.5)
    private var zoomAnchorCursor = CGPoint.zero
    private var zoomSettleTimer: Timer?

    /// ピンチで連続ズームする(現在の表示モードを下限 1.0 とした純乗数)。
    /// 段階的な表示モード切替(旧 pinchIn/pinchOut → enlarge/reduceViewMode)は
    /// キー・他ボタン割当に残し、ピンチジェスチャは常に連続ズーム
    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            zoomSettleTimer?.invalidate()
            isLiveZooming = true
            let cursor = convert(event.locationInWindow, from: nil)
            zoomAnchorCursor = cursor
            zoomAnchorRatio = contentAnchorRatio(for: cursor)
            removeCurlOverlay()
            delegate?.readerViewZoomWillBegin(self)
        case .changed:
            guard isLiveZooming else { return }
            zoomScale = ZoomMath.updatedScale(current: zoomScale,
                                              magnification: event.magnification)
            reanchorZoom()
        case .ended, .cancelled:
            guard isLiveZooming else { return }
            settleZoom(to: ZoomMath.settleTarget(scale: zoomScale))
        default:
            break
        }
    }

    /// カーソル下の点を不動に保つ(.changed ごと)
    private func reanchorZoom() {
        needsLayout = true
        layoutSubtreeIfNeeded()  // contentSize を確定させてからアンカーを合わせる
        scrollOffset = ZoomMath.anchoredScrollOffset(
            anchorRatio: zoomAnchorRatio, cursor: zoomAnchorCursor,
            contentSize: contentSize, available: availableSize)
        clampScrollOffset()
        needsLayout = true
    }

    /// ズームアウト完了後に実行する処理(「引いてからめくる」用)
    private var zoomSettleCompletion: (() -> Void)?

    /// 拡大中のページ送り前に、ズームを 1.0 へ滑らかに戻してから completion を
    /// 呼ぶ(2 段階演出。設計書 §2.4)。既に等倍・視差効果オフなら即実行
    func animateZoomOut(completion: @escaping () -> Void) {
        guard zoomScale > 1,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            resetZoom()
            completion()
            return
        }
        isLiveZooming = true  // ズームアウト中のリサンプル洪水を抑止
        zoomSettleCompletion = completion
        settleZoom(to: 1)
    }

    /// 指を離した後の慣性/吸着(120Hz でスクラブ。cancelInteractiveCurl と同型)
    private func settleZoom(to target: CGFloat) {
        zoomSettleTimer?.invalidate()
        zoomSettleTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 120, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let next = ZoomMath.settleStep(current: self.zoomScale, target: target)
                self.zoomScale = next
                self.reanchorZoom()
                if next == target {
                    self.zoomSettleTimer?.invalidate()
                    self.zoomSettleTimer = nil
                    self.isLiveZooming = false
                    self.needsLayout = true  // 確定倍率で高品質リサンプルを予約
                    if let completion = self.zoomSettleCompletion {
                        // ズームアウト→めくり: cap 再デコードはせず次の遷移へ
                        self.zoomSettleCompletion = nil
                        completion()
                    } else {
                        self.delegate?.readerViewZoomDidEnd(self, scale: next)
                    }
                }
            }
        }
    }

    override func rotate(with event: NSEvent) {
        if event.phase == .began { rotationSum = 0 }
        rotationSum += CGFloat(event.rotation)
        guard event.phase == .ended else { return }
        defer { rotationSum = 0 }
        guard abs(rotationSum) > 5 else { return }
        let virtualButton = rotationSum > 0
            ? VirtualButton.rotateLeft : VirtualButton.rotateRight
        delegate?.readerView(self, gesture: virtualButton,
                             modifiers: LegacyModifier.encode(flags: event.modifierFlags),
                             leftHalf: isLeftHalf(locationInWindow: event.locationInWindow))
    }

    // MARK: - スマートズーム/Force click(旧実装には無い新規操作。設計書 §2.4)

    override func smartMagnify(with event: NSEvent) {
        delegate?.readerViewSmartMagnify(
            self, at: convert(event.locationInWindow, from: nil))
    }

    private var pressureStage = 0
    /// 深押しが発火した押下を保持中(解放で readerViewForceClickEnded を送る)
    private var forceClickActive = false

    override func pressureChange(with event: NSEvent) {
        // 深押し(stage 2)への遷移で 1 回だけ発火。対応デバイス以外では
        // イベント自体が来ない
        defer { pressureStage = event.stage }
        guard event.stage == 2, pressureStage < 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard delegate?.readerViewForceClick(self, at: point) == true else { return }
        forceClickActive = true
        // 発火した押下の追跡を打ち切る(クリック/ジェスチャ/HUD の二重発火防止)。
        // ドラッグスクロール中だった場合はカーソルもここで戻す
        if mouseRecognizer.isDragScrolling { NSCursor.arrow.set() }
        mouseRecognizer.noteForceClick()
        delegate?.readerViewDragTrackingEnded(self)
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment, performanceTime: .now)
    }

    /// スマートズーム用: ビュー座標の点が内容のどの比率位置かを返す
    /// (回転表示中は中央扱い)
    func contentAnchorRatio(for point: CGPoint) -> CGPoint {
        guard rotation == 0, contentSize.width > 0, contentSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let available = availableSize
        let pad = CGPoint(x: max(0, (available.width - contentSize.width) / 2),
                          y: max(0, (available.height - contentSize.height) / 2))
        let x = (point.x - pad.x + scrollOffset.x) / contentSize.width
        let y = (point.y - pad.y + scrollOffset.y) / contentSize.height
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }

    /// スマートズーム用: 内容の比率位置が表示中央付近に来るようスクロールする
    /// (fitMode 変更直後に呼ぶ。端はクランプ)
    func scroll(toAnchorRatio ratio: CGPoint) {
        needsLayout = true
        layoutSubtreeIfNeeded()  // fitMode 変更直後の contentSize を確定させる
        let available = availableSize
        scrollOffset = CGPoint(
            x: ratio.x * contentSize.width - available.width / 2,
            y: ratio.y * contentSize.height - available.height / 2)
        clampScrollOffset()
        needsLayout = true
    }

    // MARK: - マウス移動(フルスクリーン時のカーソル自動非表示用。仕様書 §3.3)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        if loupe.isEnabled {
            loupe.move(to: convert(event.locationInWindow, from: nil))
        }
        delegate?.readerViewMouseMoved(self)
    }

    // MARK: - ドラッグ&ドロップ

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .generic
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = NSURL(from: sender.draggingPasteboard) as URL? else { return false }
        delegate?.readerView(self, didReceiveDropped: url)
        return true
    }
}
