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
        guard FileDescriptorHeadroom.isAvailable(),
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// image を target(ピクセル)へ縮小する。縮小でない場合や失敗時は nil。
    func downscale(_ image: CGImage, to target: CGSize, displayTarget: DisplayColorTarget? = nil,
                   outputColorSpace: CGColorSpace? = nil) -> CGImage? {
        guard let size = BitmapDimensions(target) else { return nil }
        let outWidth = size.width
        let outHeight = size.height
        guard outWidth <= image.width, outHeight <= image.height,
              outWidth < image.width || outHeight < image.height else { return nil }
        guard FileDescriptorHeadroom.isAvailable() else { return nil }

        // 設計書 §5: 表示先への変換は GPU の最終出力で行い、合成時の変換を避ける。
        let sourceSpace = image.colorSpace
        let space = outputColorSpace ?? displayTarget?.space(for: image)
            ?? (sourceSpace?.model == .rgb ? sourceSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: image)
        let verticalScale = CGFloat(outHeight) / CGFloat(image.height)
        filter.scale = Float(verticalScale)
        filter.aspectRatio = Float(
            (CGFloat(outWidth) / CGFloat(image.width)) / verticalScale)
        guard let output = filter.outputImage else { return nil }

        return BitmapRendering.render(output, context: context, size: size, colorSpace: space)
    }
}
