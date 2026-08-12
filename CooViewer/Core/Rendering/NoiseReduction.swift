import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// 描画品質(補間+ML 高画質化を 1 本に統合した UI 上の段階。設定と
/// 表示メニューの「補間」)。永続化はこの値そのものではなく、旧互換の
/// `Interpolation`(0-3。1.x と共有するため未知値を書かない)と新設の
/// `NoiseReductionLevel`(0/3/4)の**組合せ**で行う(SettingsStore.renderQuality)
enum RenderQuality: Int, CaseIterable {
    /// 補間なし(ニアレスト。ドット絵向け)
    case none = 0
    /// 標準(高品質縮小。モアレ低減)
    case standard = 1
    /// 高(標準+MetalFX 拡大)
    case high = 2
    /// 超高(高+waifu2x の ML ノイズ除去。全ページ対象)
    case mlDenoise = 3
    /// 最高(高+Real-ESRGAN の ×4 ML 超解像。全ページ対象)
    case mlSuperRes = 4

    /// 対応する基礎補間(レイヤーフィルタ+リサンプル経路)の保存値
    var interpolationRawValue: Int {
        switch self {
        case .none: 1        // ReaderView.Interpolation.none
        case .standard: 0    // .systemDefault
        case .high, .mlDenoise, .mlSuperRes: 3  // .high
        }
    }

    /// 対応する ML 処理段階の保存値
    var noiseReductionRawValue: Int {
        switch self {
        case .none, .standard, .high: 0
        case .mlDenoise: NoiseReductionLevel.strong.rawValue
        case .mlSuperRes: NoiseReductionLevel.maximum.rawValue
        }
    }
}

/// ML 高画質化(旧・圧縮ノイズ低減)の処理段階。UI からは RenderQuality
/// 経由で 0/3/4 のみ設定されるが、2.0b16 以前の設定値(弱 1・中 2 の
/// CINoiseReduction)も従来どおり動作させるため enum としては残す。
/// 強は CoreML のノイズ除去モデル(MLNoiseReducer)、最高は CoreML の
/// ×4 超解像モデル(MLSuperResolver)。ML 系はモデル未導入・失敗時に
/// 1 段ずつフォールバックする(最高→強→中相当の CI)
enum NoiseReductionLevel: Int, CaseIterable {
    case none = 0
    case light = 1
    case medium = 2
    case strong = 3
    case maximum = 4

    /// 等倍表示(ルーペ・原寸)での実効レベル。「最高」は縮小表示前の
    /// ×4 拡大で効果を出す仕組みのため、等倍系では「強」として扱う
    var cappedForOriginalSize: NoiseReductionLevel {
        self == .maximum ? .strong : self
    }
}

/// ML 高画質化の適用範囲。メイン表示は常に含まれ、選択で
/// ルーペ・原寸表示へ広げる(強い処理は等倍で見ると甘く感じることが
/// あるため、原寸系は好みで外せるようにする)
enum NoiseReductionScope: Int, CaseIterable {
    case displayOnly = 0
    case displayAndLoupe = 1
    case everywhere = 2

    var includesLoupe: Bool { self != .displayOnly }
    var includesOriginalSize: Bool { self == .everywhere }
}

/// CINoiseReduction(Metal)による圧縮ノイズ低減。
/// JPEG の 8×8 ブロック境界を含む圧縮ノイズをエッジを保ちつつ均す。
/// Metal が使えない環境では nil を返し、呼び出し側は原画のまま表示する
final class NoiseReducer {
    private let context: CIContext

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// image にノイズ低減を掛けた複製を返す(同サイズ)。失敗時は nil。
    /// 強・最高はモデル(MLNoiseReducer / MLSuperResolver)の担当で、
    /// ここへ来た場合はフォールバックとして中と同じ処理を行う
    func reduce(_ image: CGImage, level: NoiseReductionLevel) -> CGImage? {
        guard level != .none else { return image }
        let filter = CIFilter.noiseReduction()
        filter.inputImage = CIImage(cgImage: image)
        switch level {
        case .none:
            return image
        case .light:
            filter.noiseLevel = 0.035
            filter.sharpness = 0.50
        case .medium, .strong, .maximum:
            filter.noiseLevel = 0.06
            filter.sharpness = 0.35
        }
        guard let output = filter.outputImage else { return nil }

        // 色空間は表示経路の他フィルタと同じ規則(RGB 以外は sRGB へ)
        let sourceSpace = image.colorSpace
        let space = (sourceSpace?.model == .rgb ? sourceSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // 出力は malloc 領域へ直接レンダリングし、CGImage に所有権ごと渡す
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                      alignment: 16)
        context.render(
            output, toBitmap: buffer, rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: space)
        guard let provider = CGDataProvider(
            dataInfo: nil, data: buffer, size: byteCount,
            releaseData: { _, data, _ in data.deallocate() }) else {
            buffer.deallocate()
            return nil
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }
}
