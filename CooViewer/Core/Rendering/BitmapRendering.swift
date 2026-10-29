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

    /// 設計書 §5: 画素数を変えず行だけを揃え、Core Animation の表示時コピーを避ける。
    static func alignedBytesPerRow(width: Int, bytesPerPixel: Int) -> Int? {
        guard width > 0, bytesPerPixel > 0 else { return nil }
        let row = width.multipliedReportingOverflow(by: bytesPerPixel)
        let padded = row.partialValue.addingReportingOverflow(15)
        guard !row.overflow, !padded.overflow else { return nil }
        return padded.partialValue & ~15
    }

    init?(_ target: CGSize, rounding: FloatingPointRoundingRule = .towardZero) {
        guard let width = Int(exactly: target.width.rounded(rounding)),
              let height = Int(exactly: target.height.rounded(rounding)) else { return nil }
        self.init(width: width, height: height)
    }

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        guard let row = Self.alignedBytesPerRow(width: width, bytesPerPixel: 4) else { return nil }
        let bytes = row.multipliedReportingOverflow(by: height)
        let limit = max(64 << 20, min(1 << 30, Int(clamping: ProcessInfo.processInfo.physicalMemory / 16)))
        guard !bytes.overflow, bytes.partialValue <= limit else { return nil }
        self.width = width
        self.height = height
        bytesPerRow = row
        byteCount = bytes.partialValue
    }
}

/// 成功した一成分または RGBA バッファだけを、出力プロファイルつき CGImage へ渡す(設計書 §5)。
enum BitmapRendering {
    static func render(_ image: CIImage, context: CIContext,
                       size: BitmapDimensions, colorSpace: CGColorSpace) -> CGImage? {
        let gray = colorSpace.model == .monochrome
        guard let rowBytes = BitmapDimensions.alignedBytesPerRow(
            width: size.width, bytesPerPixel: gray ? 1 : 4) else { return nil }
        let byteCount = rowBytes * size.height
        guard FileDescriptorHeadroom.isAvailable(),
              let buffer = calloc(1, byteCount) else { return nil }
        var transferred = false
        defer { if !transferred { free(buffer) } }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let destination = CIRenderDestination(bitmapData: buffer, width: size.width,
            height: size.height, bytesPerRow: rowBytes, format: gray ? .L8 : .RGBA8)
        destination.colorSpace = colorSpace
        destination.alphaMode = gray ? .none : .premultiplied
        // toBitmap と同じくメモリ先頭を画像上端にする。
        destination.isFlipped = true
        defer { withExtendedLifetime((image, context, destination)) {} }
        do {
            let task = try context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        } catch { return nil }
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: byteCount,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }) else { return nil }
        transferred = true
        // 設計書 §5: L8 も描画先と同じ灰色プロファイルを明示して合成時の変換を避ける。
        return CGImage(width: size.width, height: size.height,
            bitsPerComponent: 8, bitsPerPixel: gray ? 8 : 32, bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: (gray ? CGImageAlphaInfo.none : .premultipliedLast).rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
