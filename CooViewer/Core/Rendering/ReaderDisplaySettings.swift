/// 表示モード(仕様書 §3.2)。保存された旧 fitScreenMode の整数値を維持する。
/// 表示・設定・入力が共有する値であり、ビューの寿命には依存しない。
enum ReaderFitMode: Int, Sendable, CaseIterable {
    case fitToScreen = 0      // 全体フィット・スクロールなし
    case fitWidth = 1         // 幅フィット・縦スクロール
    case noScale = 2          // ポイント原寸
    case fitWidthDivide = 3   // 横長 1 枚を 2 ページ幅とみなす幅フィット
}

/// 補間(仕様書 §6.1 Interpolation)。旧整数値を維持する。
/// CALayer のフィルタへの変換は描画側で行う。
enum ImageInterpolation: Int, Sendable {
    case systemDefault = 0
    case none = 1
    case low = 2
    case high = 3
}
