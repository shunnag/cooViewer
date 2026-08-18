import Foundation

/// マウス 1 回の押下〜解放を仕様書 §5.9 の規則で分類する状態機械。
/// 旧 CustomImageView の mouseDown/mouseDragged/mouseUp 相当を値型に抽出し、
/// イベント合成なしで境界値をテストできるようにしたもの(設計書 §7.6)。
/// 旧実装が rightMouse*/otherMouse* を左の処理へ転送していたのと同様、
/// 全ボタン(左/右/中/拡張)で同一の規則を共有する。
struct MouseGestureRecognizer: Sendable, Equatable {
    /// 解放時の分類結果
    enum Outcome: Sendable, Equatable {
        /// 発火なし(1 秒超の長押しキャンセル、またはドラッグスクロール後。仕様書 §5.9)
        case none
        /// クリック(移動が閾値以下)
        case click(button: Int, modifiers: Int)
        /// 30pt 超のドラッグジェスチャ(directionModifier は LegacyModifier.drag*)
        case dragGesture(directionModifier: Int, baseModifiers: Int, button: Int)
    }

    // 追跡中の状態は HUD 等の進行表示にも使うため読み取りを公開する
    private(set) var button = 0
    private(set) var startPoint = CGPoint.zero
    private(set) var startTime: TimeInterval = 0
    private var didDragScroll = false
    private(set) var isTracking = false
    /// このドラッグが 1:1 スクロールとして確定しているか。
    /// 旧実装は mouseDown 時に dragScrollDic と照合して確定し、ドラッグ中の
    /// 修飾キー変更は影響しない(CustomImageView.m:141-168)
    private(set) var isDragScrolling = false

    /// 押下。dragScroll には押下時点のバインディング照会結果を渡す
    mutating func begin(button: Int, point: CGPoint, time: TimeInterval, dragScroll: Bool) {
        self.button = button
        startPoint = point
        startTime = time
        isDragScrolling = dragScroll
        didDragScroll = false
        isTracking = true
    }

    /// ドラッグスクロール中にドラッグイベントが来たら呼ぶ。実際に画面が
    /// 動けたかに関わらず、その解放ではクリックもジェスチャも発火しない
    /// (仕様書 §5.7.5 の排他。動かさず離した場合だけクリック扱い=旧の癖)
    mutating func noteDragScrolled() {
        didDragScroll = true
    }

    /// Force click(深押し)が発火した押下の追跡を打ち切る。以後この押下では
    /// ドラッグ追跡イベントもクリック/ジェスチャも発火しない
    /// (ルーペトグルとの二重発火・ルーペドラッグ中の HUD/カール発動を防ぐ)
    mutating func noteForceClick() {
        isTracking = false
        isDragScrolling = false
    }

    /// 解放。分類結果を返し状態をリセットする。
    /// 方向判定は解放位置と押下位置の純変位で行う(旧実装は最後の mouseDragged
    /// 位置を使うが解放位置と実質同一のため簡略化。累積和ではない点は同じ)
    mutating func finish(point: CGPoint, time: TimeInterval, modifiers: Int) -> Outcome {
        guard isTracking else { return .none }
        isTracking = false
        isDragScrolling = false
        if didDragScroll { return .none }
        // 1 秒超の長押しはクリックもジェスチャもキャンセル(仕様書 §5.9)
        if time - startTime > 1 { return .none }
        if let direction = Self.dragDirection(dx: point.x - startPoint.x,
                                              dy: point.y - startPoint.y) {
            return .dragGesture(directionModifier: direction, baseModifiers: modifiers,
                                button: button)
        }
        return .click(button: button, modifiers: modifiers)
    }

    /// 変位から 4 方向を判定する(該当なしは nil=クリック)。
    /// 閾値は厳密に 30pt 超 — ちょうど 30 はクリック(旧 CustomImageView.m:199 の
    /// > 比較。仕様書 §5.9 の「±30px」の正はコード側)。両軸が閾値を超えたときは
    /// 変位の大きい方、同値なら水平を採る(旧 ud>lr の厳密比較)。
    /// dy は flipped 座標(下が正)前提。
    static func dragDirection(dx: CGFloat, dy: CGFloat) -> Int? {
        let horizontal = abs(dx) > 30 ? abs(dx) : 0
        let vertical = abs(dy) > 30 ? abs(dy) : 0
        if vertical > horizontal {
            return dy < 0 ? LegacyModifier.dragUp : LegacyModifier.dragDown
        }
        if horizontal > 0 {
            return dx < 0 ? LegacyModifier.dragLeft : LegacyModifier.dragRight
        }
        return nil
    }
}
