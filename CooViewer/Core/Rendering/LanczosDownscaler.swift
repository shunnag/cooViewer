import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// CoreImage(Metal)の Lanczos スケーリングによる縮小(設計書 §5 描画品質)。
/// 従来の CGContext 高品質補間(CPU・単一スレッド)を GPU に置き換え、
/// 大判ページの縮小リサンプルを速くする。Metal が使えない環境や失敗時は
/// 呼び出し側(ImageResampler)が従来の CG 経路へフォールバックする。
///
/// CIImage(cgImage:) は CG と同じ向きで取り込まれるため、MetalFXUpscaler の
/// テクスチャ経路のような上下反転補正は不要(向きの回帰テストあり)。
final class LanczosDownscaler {
    private let context: CIContext

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// image を target(ピクセル)へ縮小する。縮小でない場合や失敗時は nil。
    func downscale(_ image: CGImage, to target: CGSize) -> CGImage? {
        let outWidth = Int(target.width)
        let outHeight = Int(target.height)
        guard outWidth > 0, outHeight > 0,
              outWidth <= image.width, outHeight <= image.height,
              outWidth < image.width || outHeight < image.height else { return nil }

        // 色空間は cgResample と同じ規則(RGB 以外は sRGB に変換)
        let sourceSpace = image.colorSpace
        let space = (sourceSpace?.model == .rgb ? sourceSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: image)
        let verticalScale = CGFloat(outHeight) / CGFloat(image.height)
        filter.scale = Float(verticalScale)
        filter.aspectRatio = Float(
            (CGFloat(outWidth) / CGFloat(image.width)) / verticalScale)
        guard let output = filter.outputImage else { return nil }

        // 出力は malloc 領域へ直接レンダリングし、CGImage に所有権ごと渡す
        // (中間コピーなし。MetalFXUpscaler と同じ受け渡し方式)
        let bytesPerRow = outWidth * 4
        let byteCount = bytesPerRow * outHeight
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        context.render(
            output, toBitmap: buffer, rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(outWidth),
                           height: CGFloat(outHeight)),
            format: .RGBA8, colorSpace: space)
        guard let provider = CGDataProvider(
            dataInfo: nil, data: buffer, size: byteCount,
            releaseData: { _, data, _ in data.deallocate() }) else {
            buffer.deallocate()
            return nil
        }
        return CGImage(
            width: outWidth, height: outHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }
}
