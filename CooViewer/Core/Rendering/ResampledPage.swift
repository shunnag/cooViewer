import CoreGraphics

/// 画像処理の同一性。キャッシュ照会の await 中に設定が変わっても、取得条件を保持する。
struct ImageProcessingSettings: Equatable {
    let interpolation: ImageInterpolation
    let noiseReduction: NoiseReductionLevel
}

/// 完成画像には取得時の処理条件を添え、表示側が現在の条件と照合して採用する。
struct ResampledPage {
    let size: CGSize
    let image: CGImage
    let processing: ImageProcessingSettings
}
