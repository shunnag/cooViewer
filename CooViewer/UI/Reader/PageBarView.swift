import AppKit

/// ページバー(仕様書 §3.4)。進捗表示とクリック/ドラッグでのページジャンプ。
/// 既読部分は読み方向に応じて左端/右端から塗る。位置・寸法は
/// ReaderWindowController が制約で、色は下記プロパティで設定から反映する。
/// EN: Progress bar with click/drag page jumping and hover reporting;
/// EN: the read portion fills from the side matching the reading direction.
@MainActor
final class PageBarView: NSView {
    /// 0.0-1.0 の進捗(既読率)
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    // 色(仕様書 §6.1 PageBarBGColor/PageBarBorderColor/PageBarReadedColor)
    var backgroundColor: NSColor = .black.withAlphaComponent(0.8) {
        didSet { needsDisplay = true }
    }

    var borderColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    var readColor: NSColor = .white.withAlphaComponent(0.5) {
        didSet { needsDisplay = true }
    }

    var readsFromLeft = false {
        didSet { needsDisplay = true }
    }

    /// クリック位置(読み方向基準の 0.0-1.0)でのジャンプ要求
    var onJump: ((Double) -> Void)?

    /// ホバー位置((バー内 x, 読み方向基準の割合))。nil で退出(仕様書 §3.4 バブル)
    var onHover: (((x: CGFloat, fraction: Double)?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let barRect = bounds
        let radius = barRect.height / 2

        let background = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)
        backgroundColor.setFill()
        background.fill()

        // 既読部分(仕様書 §3.4: readFromLeft に応じ左端/右端から)
        let readWidth = barRect.width * progress
        if readWidth > 0 {
            let readRect = readsFromLeft
                ? NSRect(x: barRect.minX, y: barRect.minY, width: readWidth, height: barRect.height)
                : NSRect(x: barRect.maxX - readWidth, y: barRect.minY,
                         width: readWidth, height: barRect.height)
            let readPath = NSBezierPath(roundedRect: readRect, xRadius: radius, yRadius: radius)
            readColor.setFill()
            readPath.fill()
        }

        borderColor.setStroke()
        let border = NSBezierPath(
            roundedRect: barRect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        jump(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        jump(to: event)
    }

    private func jump(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return }
        onJump?(fraction(atX: point.x))
    }

    /// x 位置 → 読み方向補正済みの割合
    /// EN: Convert an x position into a reading-direction-relative fraction.
    private func fraction(atX x: CGFloat) -> Double {
        var fraction = min(max(0, x / bounds.width), 1)
        if !readsFromLeft { fraction = 1 - fraction }
        return fraction
    }

    // MARK: - ホバー(サムネイルバブル用)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return }
        onHover?((x: point.x, fraction: fraction(atX: point.x)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }
}
