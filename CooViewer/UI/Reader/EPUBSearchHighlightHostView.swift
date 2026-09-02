import AppKit
import QuartzCore

/// Washi が返す本文矩形を EPUBReaderView 上へ重ねる透明ホスト。
/// 矩形は Washi 側(locateTextRange)で既に EPUBReaderView 座標へ変換済みなので、
/// ホストは親と同じ座標系(flip を上書きしない)で受け取る。flipped にすると
/// 矩形が縦に反転して描かれる(E2E で実測)。WebKit の入力は一切奪わない。
@MainActor
final class EPUBSearchHighlightHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 変換を挟まず、EPUBReaderView 座標の矩形ごとに薄いレイヤを置く。
    func show(rects: [CGRect]) {
        guard let rootLayer = layer else { return }
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for rect in rects where !rect.isEmpty && !rect.isNull && !rect.isInfinite {
            let highlight = CALayer()
            highlight.frame = rect
            highlight.backgroundColor = NSColor.systemYellow
                .withAlphaComponent(0.32).cgColor
            highlight.cornerRadius = min(3, rect.height / 4)
            rootLayer.addSublayer(highlight)
        }
    }
}
