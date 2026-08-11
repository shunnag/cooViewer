import CoreGraphics
import Foundation

/// 表示ピクセルサイズへの高品質リサンプル(設計書 §5 描画品質)。
/// CALayer の trilinear 拡縮(モアレ・甘さが出る)の代わりに、
/// 縮小は CG の高品質補間(Lanczos 相当)、拡大は MetalFX Spatial(任意)で
/// 事前リサンプルした等倍画像を作る。結果は小さな LRU に保持する。
actor ImageResampler {
    static let shared = ImageResampler()

    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private let countLimit = 8
    private lazy var metalFX: MetalFXUpscaler? = MetalFXUpscaler()

    /// image を pixelSize(デバイスピクセル)へリサンプルする。
    /// 同サイズなら image をそのまま返す。upscaleWithMetalFX は拡大時のみ有効で、
    /// 使えない場合は CG へフォールバックする。
    func resample(_ image: CGImage, to pixelSize: CGSize,
                  cacheKey: String, upscaleWithMetalFX: Bool) -> CGImage? {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0 else { return nil }
        if width == image.width, height == image.height { return image }

        let key = "\(cacheKey)|\(image.width)x\(image.height)|\(width)x\(height)|\(upscaleWithMetalFX)"
        if let hit = cache[key] {
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
                order.append(key)
            }
            return hit
        }

        let isUpscale = width > image.width || height > image.height
        var result: CGImage?
        if isUpscale, upscaleWithMetalFX {
            result = metalFXUpscale(image, width: width, height: height)
        }
        if result == nil {
            result = Self.cgResample(image, width: width, height: height)
        }
        if let result {
            cache[key] = result
            order.append(key)
            while order.count > countLimit {
                cache.removeValue(forKey: order.removeFirst())
            }
        }
        return result
    }

    /// MetalFX による拡大(2 倍超の段階適用は MetalFXUpscaler 内でテクスチャの
    /// まま行われる)。失敗時は nil を返し、呼び出し元が CG へフォールバック。
    private func metalFXUpscale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        metalFX?.upscale(image, to: CGSize(width: width, height: height))
    }

    /// CG の高品質補間(Lanczos 相当)によるリサンプル
    static func cgResample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        // グレースケール/CMYK は RGBA コンテキストを作れないため sRGB へ変換する
        let sourceSpace = image.colorSpace
        let space = (sourceSpace?.model == .rgb ? sourceSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
