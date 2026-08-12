import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// 圧縮ノイズ低減の強さ(古い JPEG のブロックノイズ向け。既定はなし)。
/// 弱・中は CINoiseReduction、強は CoreML の超解像モデル(MLNoiseReducer。
/// 未導入時は中相当の CI へフォールバック)
enum NoiseReductionLevel: Int, CaseIterable {
    case none = 0
    case light = 1
    case medium = 2
    case strong = 3
}

/// 圧縮ノイズ低減の適用範囲。メイン表示は常に含まれ、選択で
/// ルーペ・原寸表示へ広げる(強い低減は等倍で見ると甘く感じることが
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
    /// 強はモデル(MLNoiseReducer)の担当で、ここへ来た場合は
    /// フォールバックとして中と同じ処理を行う
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
        case .medium, .strong:
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
