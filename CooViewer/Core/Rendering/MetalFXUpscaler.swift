import CoreImage
import Metal
import MetalFX
import MetalKit

/// MetalFX Spatial Scaler による拡大(設計書 §5 描画品質)。
/// 1〜2 倍の拡大を GPU の空間アップスケーラで行う。対応外の環境や失敗時は
/// 呼び出し側(ImageResampler)が CG の高品質補間へフォールバックする。
final class MetalFXUpscaler {
    /// 対応外 GPU だけを恒久的な CG 代替とする。資源不足による初期化失敗は含めない。
    static var deviceIsUnsupported: Bool {
        guard FileDescriptorHeadroom.isAvailable(), let device = MTLCreateSystemDefaultDevice() else { return false }
        return !MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let loader: MTKTextureLoader
    private let ciContext: CIContext
    let maximumTextureDimension: Int
    private var scaler: (any MTLFXSpatialScaler)?
    private var scalerKey = ""

    init?() {
        guard FileDescriptorHeadroom.isAvailable(),
              let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        // Apple の Metal Feature Set Tables: Apple10 は 32768、それ以前と Mac2 は 16384。
        // バイト予算に収まる細長い画像でも、長辺超過の texture は assert で停止し得る。
        self.maximumTextureDimension = device.supportsFamily(.apple10) ? 32768 : 16384
        self.queue = queue
        self.loader = MTKTextureLoader(device: device)
        self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// image を target(ピクセル)へ拡大する。拡大でない場合や失敗時は nil。
    /// MetalFX Spatial の推奨倍率(≤2 倍)を超える場合は、CGImage への往復を
    /// せず **テクスチャのまま** ≤2 倍ずつ段階適用する(往復すると
    /// MTKTextureLoader のバイト順解釈で色化けするため。回帰テストあり)。
    func upscale(_ image: CGImage, to target: CGSize) -> CGImage? {
        guard let size = BitmapDimensions(target) else { return nil }
        let outWidth = size.width
        let outHeight = size.height
        guard outWidth >= image.width, outHeight >= image.height,
              outWidth > image.width || outHeight > image.height,
              supportsDimensions(image, width: outWidth, height: outHeight) else { return nil }
        guard FileDescriptorHeadroom.isAvailable() else { return nil }

        // MTKTextureLoader は premultipliedFirst(BGRA 系)の CGImage
        // (ImageIO のサムネイルデコード経路など)でバイト順を誤読するため、
        // 既知の RGBA8 形式へ正規化してから渡す(回帰テストあり)。
        // 既に RGBA8/premultipliedLast/既定バイト順ならフル再描画を省く
        let alreadyRGBA8 = image.bitsPerComponent == 8
            && image.bitsPerPixel == 32
            && image.alphaInfo == .premultipliedLast
            && image.bitmapInfo.intersection(.byteOrderMask) == []
            && image.colorSpace?.model == .rgb
        let normalized: CGImage
        if alreadyRGBA8 {
            normalized = image
        } else if let redrawn = ImageResampler.cgResample(
            image, width: image.width, height: image.height) {
            normalized = redrawn
        } else {
            return nil
        }
        guard var current = try? loader.newTexture(cgImage: normalized, options: [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .SRGB: false,
        ]) else { return nil }

        // まず目標サイズへの単発適用を試し、スケーラを作れなければ段階適用する
        while current.width < outWidth || current.height < outHeight {
            let direct = makeScaler(inputWidth: current.width, inputHeight: current.height,
                                    outputWidth: outWidth, outputHeight: outHeight,
                                    format: current.pixelFormat) != nil
            let stepWidth = direct ? outWidth : min(outWidth, current.width * 2)
            let stepHeight = direct ? outHeight : min(outHeight, current.height * 2)
            guard let next = encodePass(input: current,
                                        outputWidth: stepWidth, outputHeight: stepHeight)
            else { return nil }
            current = next
        }
        let output = current

        // CMYK / Gray を RGB へ正規化した後は、その色空間を使う。
        // 元の非 RGB 空間を RGBA texture / bitmap へ指定すると描画が失敗する。
        let colorSpace = normalized.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard var ciImage = CIImage(mtlTexture: output, options: [.colorSpace: colorSpace])
        else { return nil }
        // MTLTexture 由来の CIImage は上下反転している
        ciImage = ciImage.transformed(
            by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -ciImage.extent.height))
        // createCGImage はテクスチャのピクセルフォーマット解釈で色化けし得るため、
        // 明示的に RGBA8 としてレンダリングして CGImage を組み立てる
        // 出力バッファは malloc 領域へ直接レンダリングし、CGImage に所有権ごと
        // 渡す(従来は [UInt8] → Data → CFData で全画素を 2 回コピーしていた)
        return BitmapRendering.render(ciImage, context: ciContext, size: size, colorSpace: colorSpace)
    }

    // MARK: - 内部

    func supportsDimensions(_ image: CGImage, width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumTextureDimension && height <= maximumTextureDimension
            && image.width <= maximumTextureDimension && image.height <= maximumTextureDimension
    }

    /// スケーラ生成は高価なため、同一サイズ構成の間は使い回す
    private func makeScaler(inputWidth: Int, inputHeight: Int,
                            outputWidth: Int, outputHeight: Int,
                            format: MTLPixelFormat) -> (any MTLFXSpatialScaler)? {
        let key = "\(inputWidth)x\(inputHeight)->\(outputWidth)x\(outputHeight)-\(format.rawValue)"
        if let scaler, scalerKey == key { return scaler }
        guard FileDescriptorHeadroom.isAvailable() else { return nil }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = format
        descriptor.outputTextureFormat = format
        descriptor.colorProcessingMode = .perceptual
        scaler = descriptor.makeSpatialScaler(device: device)
        scalerKey = key
        return scaler
    }

    /// 1 パス分の拡大をエンコードして出力テクスチャを返す
    private func encodePass(input: any MTLTexture,
                            outputWidth: Int, outputHeight: Int) -> (any MTLTexture)? {
        guard let scaler = makeScaler(
            inputWidth: input.width, inputHeight: input.height,
            outputWidth: outputWidth, outputHeight: outputHeight,
            format: input.pixelFormat) else { return nil }

        let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat, width: outputWidth, height: outputHeight,
            mipmapped: false)
        outDescriptor.usage = [.renderTarget, .shaderRead]
        outDescriptor.storageMode = .private
        guard let output = device.makeTexture(descriptor: outDescriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        scaler.colorTexture = input
        scaler.inputContentWidth = input.width
        scaler.inputContentHeight = input.height
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return output
    }
}
