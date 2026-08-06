import AppKit

@MainActor
protocol ReaderViewDelegate: AnyObject {
    func readerViewDidRequestNext(_ view: ReaderView)
    func readerViewDidRequestPrevious(_ view: ReaderView)
    func readerView(_ view: ReaderView, didReceiveDropped url: URL)
    func readerViewMouseMoved(_ view: ReaderView)
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

    private(set) var images: [CGImage] = []
    private(set) var readsFromLeft = false

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
    func setPages(_ images: [CGImage], readsFromLeft: Bool) {
        self.images = images
        self.readsFromLeft = readsFromLeft
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
        let screenOrder = readsFromLeft ? Array(scaled.indices) : scaled.indices.reversed()
        var x = pad.x - scrollOffset.x
        for (position, imageIndex) in screenOrder.enumerated() {
            _ = position
            let size = scaled[imageIndex]
            let layer = pageLayers[imageIndex]
            layer.isHidden = false
            layer.contents = images[imageIndex]
            // 垂直はコンテンツ高(2 枚の最大)に対しセンタリング(仕様書 §4.2.3)
            let y = pad.y - scrollOffset.y + (contentSize.height - size.height) / 2
            layer.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width
        }
        for index in images.count..<pageLayers.count {
            pageLayers[index].isHidden = true
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
               size.width / size.height > CGFloat(PageLayout.defaultSingleSetting) / 1000.0 {
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

    // MARK: - 暫定キー入力(マイルストーン6 でバインディングシステムに置換)

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case NSEvent.SpecialKey.leftArrow?:
            readsFromLeft
                ? delegate?.readerViewDidRequestPrevious(self)
                : delegate?.readerViewDidRequestNext(self)
        case NSEvent.SpecialKey.rightArrow?:
            readsFromLeft
                ? delegate?.readerViewDidRequestNext(self)
                : delegate?.readerViewDidRequestPrevious(self)
        default:
            if event.charactersIgnoringModifiers == " " {
                delegate?.readerViewDidRequestNext(self)
            } else {
                super.keyDown(with: event)
            }
        }
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
