import AppKit

/// ドラッグジェスチャ HUD の状態導出(純関数。設計書 §7.6 によりユニットテスト対象)。
/// マウスジェスチャは「何が起きるか見えない」のが旧来の弱点だったため、
/// ドラッグ中に方向と割当アクション名を予告する(2.0 の新規機能・設計書 §2.4)
enum GestureHUDModel {
    enum State: Equatable, Sendable {
        case hidden
        /// 薄表示(10pt 超〜閾値以下: これから何が起きるかの予告)
        case faint(direction: Int)
        /// 強調(30pt 超: 離せば発火する)
        case armed(direction: Int)
        /// 1 秒超過: 離しても発火しない予告(仕様書 §5.9 の長押しキャンセル)
        case expired
    }

    static func state(dx: CGFloat, dy: CGFloat, elapsed: TimeInterval) -> State {
        if elapsed > 1 { return .expired }
        if let direction = MouseGestureRecognizer.dragDirection(dx: dx, dy: dy) {
            return .armed(direction: direction)
        }
        if let direction = provisionalDirection(dx: dx, dy: dy) {
            return .faint(direction: direction)
        }
        return .hidden
    }

    /// 10pt 超の暫定方向。判定規則は本判定(MouseGestureRecognizer.dragDirection)
    /// と同型: 閾値を超えた軸のうち大きい方、同値なら水平勝ち
    static func provisionalDirection(dx: CGFloat, dy: CGFloat) -> Int? {
        let horizontal = abs(dx) > 10 ? abs(dx) : 0
        let vertical = abs(dy) > 10 ? abs(dy) : 0
        if vertical > horizontal {
            return dy < 0 ? LegacyModifier.dragUp : LegacyModifier.dragDown
        }
        if horizontal > 0 {
            return dx < 0 ? LegacyModifier.dragLeft : LegacyModifier.dragRight
        }
        return nil
    }

    /// 方向 modifier → SF Symbols の矢印名
    static func symbolName(for direction: Int) -> String {
        switch direction {
        case LegacyModifier.dragLeft: "arrow.left"
        case LegacyModifier.dragRight: "arrow.right"
        case LegacyModifier.dragUp: "arrow.up"
        case LegacyModifier.dragDown: "arrow.down"
        default: "questionmark"
        }
    }
}

/// 画面中央に出す方向矢印+割当アクション名のカード。
/// オープン進捗 HUD と同じ配色(黒 0.78・角丸 10)。イベントは奪わない
@MainActor
final class GestureHUDView: NSView {
    private let arrowView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 10
        isHidden = true

        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 26, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(arrowView)
        addSubview(label)
        NSLayoutConstraint.activate([
            arrowView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            arrowView.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: arrowView.bottomAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// HUD はフィードバック専用でクリック等を吸わない
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 状態を反映する。actionName=nil は未割当(灰色表示で学習可能にする)
    func apply(state: GestureHUDModel.State, actionName: String?) {
        switch state {
        case .hidden:
            hide()
        case .faint(let direction):
            show(direction: direction, actionName: actionName, alpha: 0.55, armed: false)
        case .armed(let direction):
            show(direction: direction, actionName: actionName, alpha: 1.0, armed: true)
        case .expired:
            // 長押し超過: 離しても発火しないことを薄さで予告
            alphaValue = 0.25
        }
    }

    private func show(direction: Int, actionName: String?, alpha: CGFloat, armed: Bool) {
        // フェードアウト中の再表示: 進行中のアニメーションと完了処理を無効化
        fadeGeneration += 1
        layer?.removeAllAnimations()
        arrowView.image = NSImage(
            systemSymbolName: GestureHUDModel.symbolName(for: direction),
            accessibilityDescription: nil)
        if let actionName {
            label.stringValue = actionName
            label.textColor = .white
            arrowView.contentTintColor = armed ? .controlAccentColor : .white
        } else {
            label.stringValue = String(localized: "Not assigned")
            label.textColor = .secondaryLabelColor
            arrowView.contentTintColor = .secondaryLabelColor
        }
        alphaValue = alpha
        isHidden = false
    }

    private var fadeGeneration = 0

    /// フェードアウトして隠す(視差効果を減らす設定では即時)
    func hide() {
        guard !isHidden else { return }
        fadeGeneration += 1
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            isHidden = true
            return
        }
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: {
            // NSAnimationContext の完了はメインスレッドで呼ばれる
            MainActor.assumeIsolated {
                guard generation == self.fadeGeneration else { return }
                self.isHidden = true
                self.alphaValue = 1
            }
        }
    }
}
