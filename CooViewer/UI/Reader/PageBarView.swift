import AppKit

/// ページバー(仕様書 §3.4)。進捗表示とクリック/ドラッグでのページジャンプ。
/// 既読部分は読み方向に応じて左端/右端から塗る。
/// 位置・色・寸法のカスタマイズはマイルストーン 6/7 で設定に接続する。
@MainActor
final class PageBarView: NSView {
    /// 0.0-1.0 の進捗(既読率)
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    var readsFromLeft = false {
        didSet { needsDisplay = true }
    }

    /// クリック位置(読み方向基準の 0.0-1.0)でのジャンプ要求
    var onJump: ((Double) -> Void)?

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
        NSColor.black.withAlphaComponent(0.8).setFill()
        background.fill()

        // 既読部分(仕様書 §3.4: readFromLeft に応じ左端/右端から)
        let readWidth = barRect.width * progress
        if readWidth > 0 {
            let readRect = readsFromLeft
                ? NSRect(x: barRect.minX, y: barRect.minY, width: readWidth, height: barRect.height)
                : NSRect(x: barRect.maxX - readWidth, y: barRect.minY,
                         width: readWidth, height: barRect.height)
            let readPath = NSBezierPath(roundedRect: readRect, xRadius: radius, yRadius: radius)
            NSColor.white.withAlphaComponent(0.5).setFill()
            readPath.fill()
        }

        NSColor.white.setStroke()
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
        var fraction = min(max(0, point.x / bounds.width), 1)
        if !readsFromLeft { fraction = 1 - fraction }
        onJump?(fraction)
    }
}
