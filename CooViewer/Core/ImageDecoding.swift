import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// 画像データ → CGImage のデコード。
enum ImageDecoding {
    /// data をデコードする。maxPixelSize を指定すると長辺がその値以下になるよう
    /// 縮小した画像を返す(EXIF の回転は適用済み)。
    static func decode(_ data: Data, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return try decodeWithAppKit(data, maxPixelSize: maxPixelSize)
        }
        // ゲインマップ付き HDR は EDR 表示用にフル HDR デコードする
        // (長辺 8192px まで。CALayer 側は preferredDynamicRange = .high)
        if maxPixelSize != nil,
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(
               source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            let hdrOptions: [CFString: Any] = [
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let hdr = CGImageSourceCreateImageAtIndex(
                source, 0, hdrOptions as CFDictionary),
               max(hdr.width, hdr.height) <= 8192 {
                return hdr
            }
        }
        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return try decodeWithAppKit(data, maxPixelSize: maxPixelSize)
            }
            return image
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return try decodeWithAppKit(data, maxPixelSize: maxPixelSize)
        }
        return image
    }

    /// ImageIO が扱えない形式(SVG 等のベクトル画像)を NSImage で
    /// ラスタライズするフォールバック。ベクトルは指定解像度(既定 2048)で
    /// 描くため拡大してもシャープになる。
    private static func decodeWithAppKit(_ data: Data, maxPixelSize: Int?) throws -> CGImage {
        guard let image = loadAppKitImage(data),
              image.size.width > 0, image.size.height > 0 else {
            throw BookSourceError.pageLoadFailed("undecodable image data")
        }
        let longSide = max(image.size.width, image.size.height)
        let scale = CGFloat(maxPixelSize ?? 2048) / longSide
        let width = max(1, Int(image.size.width * scale))
        let height = max(1, Int(image.size.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BookSourceError.pageLoadFailed("undecodable image data")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else {
            throw BookSourceError.pageLoadFailed("undecodable image data")
        }
        return result
    }

    /// NSImage(data:) は拡張子ヒントなしでは SVG を判別できないため、
    /// SVG らしきデータは .svg の一時ファイル経由で読み込む。
    private static func loadAppKitImage(_ data: Data) -> NSImage? {
        if let image = NSImage(data: data) { return image }
        let head = String(decoding: data.prefix(512), as: UTF8.self)
            .lowercased()
        guard head.contains("<svg") else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cooViewer-svg-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return nil }
        return NSImage(contentsOf: url)
    }
}
