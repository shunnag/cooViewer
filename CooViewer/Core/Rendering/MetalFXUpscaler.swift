import CoreImage
import Metal
import MetalFX
import MetalKit

/// MetalFX Spatial Scaler による拡大(設計書 §5 描画品質)。
/// 1〜2 倍の拡大を GPU の空間アップスケーラで行う。対応外の環境や失敗時は
/// 呼び出し側(ImageResampler)が CG の高品質補間へフォールバックする。
/// EN: GPU upscaling via MetalFX Spatial; caller falls back to CG on failure.
final class MetalFXUpscaler {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let loader: MTKTextureLoader
    private let ciContext: CIContext
    private var scaler: (any MTLFXSpatialScaler)?
    private var scalerKey = ""

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.loader = MTKTextureLoader(device: device)
        self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// image を target(ピクセル)へ拡大する。拡大でない場合や失敗時は nil。
    /// MetalFX Spatial の推奨倍率(≤2 倍)を超える場合は、CGImage への往復を
    /// せず **テクスチャのまま** ≤2 倍ずつ段階適用する(往復すると
    /// MTKTextureLoader のバイト順解釈で色化けするため。回帰テストあり)。
    /// EN: Upscales to target pixels; >2x is applied in <=2x stages while
    /// EN: staying in texture space to avoid CGImage round-trip color bugs.
    func upscale(_ image: CGImage, to target: CGSize) -> CGImage? {
        let outWidth = Int(target.width)
        let outHeight = Int(target.height)
        guard outWidth >= image.width, outHeight >= image.height,
              outWidth > image.width || outHeight > image.height else { return nil }

        // MTKTextureLoader は premultipliedFirst(BGRA 系)の CGImage
        // (ImageIO のサムネイルデコード経路など)でバイト順を誤読するため、
        // 既知の RGBA8 形式へ正規化してから渡す(回帰テストあり)。
        // 既に RGBA8/premultipliedLast/既定バイト順ならフル再描画を省く
        // EN: Normalize BGRA-style images (regression-tested); skip the
        // EN: full redraw when the image is already plain RGBA8.
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

        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard var ciImage = CIImage(mtlTexture: output, options: [.colorSpace: colorSpace])
        else { return nil }
        // MTLTexture 由来の CIImage は上下反転している
        // EN: CIImages made from MTLTextures are vertically flipped.
        ciImage = ciImage.transformed(
            by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -ciImage.extent.height))
        // createCGImage はテクスチャのピクセルフォーマット解釈で色化けし得るため、
        // 明示的に RGBA8 としてレンダリングして CGImage を組み立てる
        // EN: Render explicitly as RGBA8 instead of createCGImage, which can
        // EN: misinterpret the texture's pixel format.
        // 出力バッファは malloc 領域へ直接レンダリングし、CGImage に所有権ごと
        // 渡す(従来は [UInt8] → Data → CFData で全画素を 2 回コピーしていた)
        // EN: Render straight into a malloc'd buffer handed to CGImage,
        // EN: avoiding two full-frame copies.
        let bytesPerRow = outWidth * 4
        let byteCount = bytesPerRow * outHeight
        let bufferPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: 16)
        ciContext.render(
            ciImage, toBitmap: bufferPointer, rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(outWidth), height: CGFloat(outHeight)),
            format: .RGBA8, colorSpace: colorSpace)
        guard let provider = CGDataProvider(
            dataInfo: nil, data: bufferPointer, size: byteCount,
            releaseData: { _, data, _ in data.deallocate() }) else {
            bufferPointer.deallocate()
            return nil
        }
        return CGImage(
            width: outWidth, height: outHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - 内部

    /// スケーラ生成は高価なため、同一サイズ構成の間は使い回す
    /// EN: Scalers are expensive to build; reuse while the geometry matches.
    private func makeScaler(inputWidth: Int, inputHeight: Int,
                            outputWidth: Int, outputHeight: Int,
                            format: MTLPixelFormat) -> (any MTLFXSpatialScaler)? {
        let key = "\(inputWidth)x\(inputHeight)->\(outputWidth)x\(outputHeight)-\(format.rawValue)"
        if let scaler, scalerKey == key { return scaler }
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
    /// EN: Encodes one MetalFX pass and waits for the GPU to finish.
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
        return output
    }
}
