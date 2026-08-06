import AppKit

/// ページ描画ビュー。
/// TODO(マイルストーン5): 1/2 ページの CALayer 配置・フィットモード・スクロール・
/// 回転を実装する(設計書 §3.2)。現状は背景のみのプレースホルダ。
@MainActor
final class ReaderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
}
