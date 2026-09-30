/// 水平スワイプの設定は、解決済みのページ送りだけに適用する。
/// 反対側の仮想ボタンへ付け替えると非対称のユーザー割当まで変わるため、再解決しない。
enum GestureActionPolicy {
    static func action(_ action: ReaderAction, virtualButton: Int,
                       swipeToTurnPage: Bool, flipSwipeDirection: Bool) -> ReaderAction? {
        guard virtualButton == VirtualButton.swipeLeft || virtualButton == VirtualButton.swipeRight,
              action == .nextPage || action == .previousPage else { return action }
        guard swipeToTurnPage else { return nil }
        guard flipSwipeDirection else { return action }
        return action == .nextPage ? .previousPage : .nextPage
    }
}
