import CoreGraphics
import CoreImage
import Darwin
import Foundation

/// Int 変換と RGBA 確保を同じ入口で検証し、非有限値・桁溢れ・巨大確保を避ける。
struct BitmapDimensions {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let byteCount: Int

    init?(_ target: CGSize, rounding: FloatingPointRoundingRule = .towardZero) {
        guard let width = Int(exactly: target.width.rounded(rounding)),
              let height = Int(exactly: target.height.rounded(rounding)) else { return nil }
        self.init(width: width, height: height)
    }

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let row = width.multipliedReportingOverflow(by: 4)
        let bytes = row.partialValue.multipliedReportingOverflow(by: height)
        let limit = max(64 << 20, min(1 << 30, Int(clamping: ProcessInfo.processInfo.physicalMemory / 16)))
        guard !row.overflow, !bytes.overflow, bytes.partialValue <= limit else { return nil }
        self.width = width
        self.height = height
        bytesPerRow = row.partialValue
        byteCount = bytes.partialValue
    }
}

/// 成功が確認できた RGBA バッファだけを CGImage へ渡す。開始・完了の両方の失敗を検出する。
enum BitmapRendering {
    static func render(_ image: CIImage, context: CIContext,
                       size: BitmapDimensions, colorSpace: CGColorSpace) -> CGImage? {
        guard FileDescriptorHeadroom.isAvailable(),
              let buffer = calloc(1, size.byteCount) else { return nil }
        var transferred = false
        defer { if !transferred { free(buffer) } }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let destination = CIRenderDestination(bitmapData: buffer, width: size.width,
            height: size.height, bytesPerRow: size.bytesPerRow, format: .RGBA8)
        destination.colorSpace = colorSpace
        destination.alphaMode = .premultiplied
        // toBitmap と同じくメモリ先頭を画像上端にする。
        destination.isFlipped = true
        defer { withExtendedLifetime((image, context, destination)) {} }
        do {
            let task = try context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        } catch { return nil }
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: size.byteCount,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }) else { return nil }
        transferred = true
        return CGImage(width: size.width, height: size.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
