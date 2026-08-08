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
/// EN: Layer-backed page view: renders 1-2 pages side by side and manages
/// EN: fit modes, rotation, and internal scrolling with edge detection.
@MainActor
final class ReaderView: NSView {
    /// 表示モード(仕様書 §3.2)。旧 fitScreenMode の整数値を維持。
    /// EN: Fit modes; raw values match the legacy integers.
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
    /// EN: Cache namespace (book cacheKey) so ids never collide across books.
    var resampleKeyPrefix = ""
    /// 見開きしきい値(横長判定。fitWidthDivide 用。設定から注入される)
    /// EN: Spread threshold used by the divide fit mode; injected from settings.
    var singleSetting = PageLayout.defaultSingleSetting
    private(set) var readsFromLeft = false

    /// ページ毎の高品質リサンプル結果(対象ピクセルサイズ付き。設計書 §5 描画品質)
    private var resampledPages: [(size: CGSize, image: CGImage)?] = []
    /// ルーペ表示専用の高解像度画像(ページ index → 画像)。通常表示には使わない
    private var loupeHighResImages: [Int: CGImage] = [:]
    private var resampleTask: Task<Void, Never>?
    private var resampleGeneration = 0

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - コンテンツ設定

    /// 読み順のページ画像(1 or 2 枚)を表示する。
    /// ids はリサンプルキャッシュのキーに使う(空なら画像順の連番)。
    /// EN: Show the given pages in reading order; ids key the resample cache.
    func setPages(_ images: [CGImage], ids: [Int] = [], readsFromLeft: Bool) {
        self.images = images
        self.pageIDs = ids.count == images.count ? ids : Array(images.indices)
        self.readsFromLeft = readsFromLeft
        resampledPages = Array(repeating: nil, count: images.count)
        loupeHighResImages.removeAll()
        for pageLayer in pageLayers {
            pageLayer.removeAnimation(forKey: "pageAnimation")
        }
        scrollOffset = .zero
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollToHome()
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
        // EN: The first page in reading order sits on the right for
        // EN: right-to-left books.
        let backingScale = window?.backingScaleFactor ?? 2
        let screenOrder = readsFromLeft ? Array(scaled.indices) : scaled.indices.reversed()
        var x = pad.x - scrollOffset.x
        for (position, imageIndex) in screenOrder.enumerated() {
            _ = position
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
    /// EN: Debounced pre-resample to exact display pixels (high-quality CG for
    /// EN: downscale, MetalFX for upscale); finished pages swap in 1:1.
    private func scheduleHighQualityResample(scaledSizes: [CGSize], backingScale: CGFloat) {
        guard interpolation == .systemDefault || interpolation == .high,
              !images.isEmpty else { return }
        let requests: [(index: Int, image: CGImage, pixelSize: CGSize, key: String)] =
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
                        "\(resampleKeyPrefix)#\(pageIDs[index])")
            }
        guard !requests.isEmpty else { return }

        resampleTask?.cancel()
        resampleGeneration += 1
        let generation = resampleGeneration
        let useMetalFX = interpolation == .high
        resampleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            for request in requests {
                guard let resampled = await ImageResampler.shared.resample(
                    request.image, to: request.pixelSize,
                    cacheKey: request.key, upscaleWithMetalFX: useMetalFX) else { continue }
                guard let self, !Task.isCancelled else { return }
                self.applyResampled(resampled, size: request.pixelSize,
                                    at: request.index, generation: generation)
            }
        }
    }

    private func applyResampled(_ image: CGImage, size: CGSize,
                                at index: Int, generation: Int) {
        guard generation == resampleGeneration,
              resampledPages.indices.contains(index) else { return }
        resampledPages[index] = (size, image)
        needsLayout = true
    }

    /// ページ毎のスケール(仕様書 §4.2.3, §3.2)
    /// EN: Per-page scale factors for the current fit mode.
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
    /// EN: Returns false when already at the edge (used to trigger page turns).
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
    /// EN: Play animated frames via a discrete keyframe animation; the id check
    /// EN: ignores results that arrive after the page changed.
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
    /// EN: Inject a loupe-only high-res image without touching normal display.
    func setLoupeHighResImage(_ image: CGImage, forPageAt index: Int, entryID: Int) {
        // ページめくり直後に届いた古いページの結果は捨てる(id 照合)
        // EN: Drop stale results delivered after a page turn (id check).
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
            // EN: Drags of 30 px or more become directional gestures;
            // EN: shorter ones are treated as clicks.
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
        // EN: Reset on .began so a cancelled gesture's residue never carries over.
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
