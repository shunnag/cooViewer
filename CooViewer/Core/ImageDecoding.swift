import CoreGraphics
import Foundation
import ImageIO

/// 画像データ → CGImage のデコード。
enum ImageDecoding {
    /// data をデコードする。maxPixelSize を指定すると長辺がその値以下になるよう
    /// 縮小した画像を返す(EXIF の回転は適用済み)。
    static func decode(_ data: Data, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw BookSourceError.pageLoadFailed("undecodable image data")
        }
        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw BookSourceError.pageLoadFailed("undecodable image data")
            }
            return image
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw BookSourceError.pageLoadFailed("undecodable image data")
        }
        return image
    }
}
