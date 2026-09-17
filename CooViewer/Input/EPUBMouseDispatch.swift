/// EPUB モードの otherMouse 解放結果をアクションへ解決する(設計書 §2.4)。
/// 画像本の handleClick / handleDragGesture と同じ規則: クリックは resolveMouse、
/// ドラッグは resolveDrag → 未割当かつ dragFallsBackToClick ならクリック割当へ。
enum EPUBMouseDispatch {
    static func resolve(_ outcome: MouseGestureRecognizer.Outcome,
                        bindings: BindingConfiguration,
                        readsFromLeft: Bool) -> (action: ReaderAction, value: Double?)? {
        let binding: MouseBinding?
        switch outcome {
        case .none:
            return nil
        case .click(let button, let modifiers):
            binding = bindings.resolveMouse(
                button: button, modifiers: modifiers,
                fitMode: 0, readsFromLeft: readsFromLeft)
        case .dragGesture(let direction, let baseModifiers, let button):
            if let dragBinding = bindings.resolveDrag(
                button: button, baseModifiers: baseModifiers, directionModifier: direction,
                fitMode: 0, readsFromLeft: readsFromLeft) {
                binding = dragBinding
            } else if BindingConfiguration.dragFallsBackToClick(button: button) {
                binding = bindings.resolveMouse(
                    button: button, modifiers: baseModifiers,
                    fitMode: 0, readsFromLeft: readsFromLeft)
            } else {
                binding = nil
            }
        }
        guard let binding, let action = binding.action else { return nil }
        return (action, binding.value)
    }
}
