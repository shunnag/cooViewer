import CoreGraphics

/// 画像処理の同一性。キャッシュ照会の await 中に設定が変わっても、取得条件を保持する。
/// printAppearanceTag は元画像を作ったときの網点処理の印(切っているときは空。設計書 §5)。
/// 画素からは見分けられないので、完成画像を現在の条件で採用するかの照合に含める
struct ImageProcessingSettings: Equatable {
    let interpolation: ImageInterpolation
    let noiseReduction: NoiseReductionLevel
    var printAppearanceTag = ""
}

/// 完成画像には取得時の処理条件を添え、表示側が現在の条件と照合して採用する。
struct ResampledPage {
    let size: CGSize
    let image: CGImage
    let processing: ImageProcessingSettings
    var colorTarget: DisplayColorTarget? = nil
}
