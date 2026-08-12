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
    func readerView(_ view: ReaderView, gesture virtualButton: Int, modifiers: Int)
    /// ±30px 以上のドラッグジェスチャ(方向 modifier は LegacyModifier.drag*)
    func readerView(_ view: ReaderView, dragGesture directionModifier: Int, baseModifiers: Int)
    /// このドラッグを 1:1 スクロールとして扱うか(バインディング照会)
    func readerViewShouldDragScroll(_ view: ReaderView, modifiers: Int) -> Bool
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
        didSet { scrollOffset = .zero; needsLayout = true }
    }

    /// 回転(仕様書 §4.15): 0=なし, 1=左90°, 2=180°, 3=右90°。永続化しない。
    var rotation: Int = 0 {
        didSet {
            rotation = ((rotation % 4) + 4) % 4
            scrollOffset = .zero
            needsLayout = true
        }
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
        pressure.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.removeCurlOverlay()
            }
        }
        pressure.activate()
    }

    deinit {
        memoryPressureSource?.cancel()
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
        rotation == 0 && !loupe.isEnabled
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
        let scaled = zip(sizes, scales).map {
            CGSize(width: $0.width * $1, height: $0.height * $1)
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
    private func scheduleHighQualityResample(scaledSizes: [CGSize], backingScale: CGFloat) {
        guard interpolation == .systemDefault || interpolation == .high,
              !images.isEmpty else {
            setResampleActivity(false)
            return
        }
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
                    noiseReduction: request.noiseReduction) else { continue }
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

    private var mouseDownPoint: CGPoint?
    private var didDragScroll = false

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didDragScroll = false
    }

    override func mouseDragged(with event: NSEvent) {
        if loupe.isEnabled {
            loupe.move(to: convert(event.locationInWindow, from: nil))
        }
        let modifiers = LegacyModifier.encode(flags: event.modifierFlags)
        guard fitMode != .fitToScreen,
              delegate?.readerViewShouldDragScroll(self, modifiers: modifiers) == true else {
            return
        }
        didDragScroll = true
        NSCursor.closedHand.set()
        scroll(by: CGPoint(x: -event.deltaX, y: -event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if didDragScroll {
            NSCursor.arrow.set()
            return  // ドラッグスクロール後はクリック処理をしない(仕様書 §5.7.5)
        }
        guard let start = mouseDownPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let modifiers = LegacyModifier.encode(flags: event.modifierFlags)

        if max(abs(dx), abs(dy)) >= 30 {
            // ドラッグジェスチャ(±30px。仕様書 §5.9)。isFlipped のため dy>0 は下方向
            let direction: Int
            if abs(dx) >= abs(dy) {
                direction = dx < 0 ? LegacyModifier.dragLeft : LegacyModifier.dragRight
            } else {
                direction = dy < 0 ? LegacyModifier.dragUp : LegacyModifier.dragDown
            }
            delegate?.readerView(self, dragGesture: direction, baseModifiers: modifiers)
        } else {
            delegate?.readerView(self, clickedButton: 0, modifiers: modifiers,
                                 leftHalf: end.x < bounds.midX)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardClick(event, button: 1)
    }

    override func otherMouseDown(with event: NSEvent) {
        forwardClick(event, button: event.buttonNumber)
    }

    private func forwardClick(_ event: NSEvent, button: Int) {
        let point = convert(event.locationInWindow, from: nil)
        delegate?.readerView(self, clickedButton: button,
                             modifiers: LegacyModifier.encode(flags: event.modifierFlags),
                             leftHalf: point.x < bounds.midX)
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
                             modifiers: LegacyModifier.encode(flags: event.modifierFlags))
    }

    private var magnificationSum: CGFloat = 0
    private var rotationSum: CGFloat = 0

    override func magnify(with event: NSEvent) {
        // キャンセルされたジェスチャの残滓が次回に混ざらないよう開始時に捨てる
        if event.phase == .began { magnificationSum = 0 }
        magnificationSum += event.magnification
        guard event.phase == .ended else { return }
        defer { magnificationSum = 0 }
        guard abs(magnificationSum) > 0.05 else { return }
        let virtualButton = magnificationSum > 0
            ? VirtualButton.pinchOut : VirtualButton.pinchIn
        delegate?.readerView(self, gesture: virtualButton,
                             modifiers: LegacyModifier.encode(flags: event.modifierFlags))
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
                             modifiers: LegacyModifier.encode(flags: event.modifierFlags))
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
