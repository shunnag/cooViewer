import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// 画像データ → CGImage のデコード。
enum ImageDecoding {
    /// ヘッダ情報だけからピクセル寸法を読む(EXIF 回転適用後)。デコードなし。
    /// 見開き判定(縦横比)のための軽量経路。読めない形式は nil
    static func imageSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            // ImageIO が知らない形式はレトロ形式(MAG/MAKI)のヘッダを試す
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else { return nil }
            return RetroImageDecoding.imageSize(data)
        }
        return imageSize(from: source)
    }

    static func imageSize(from data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return RetroImageDecoding.imageSize(data)
        }
        return imageSize(from: source)
    }

    private static func imageSize(from source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0 else { return nil }
        // EXIF 5-8 は 90 度系の回転(デコード時の transform 適用後に合わせる)
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    /// data をデコードする。maxPixelSize を指定すると長辺がその値以下になるよう
    /// 縮小した画像を返す(EXIF の回転は適用済み)。
    static func decode(_ data: Data, maxPixelSize: Int? = nil,
                       displayTarget: DisplayColorTarget? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return try decodeWithAppKit(data, maxPixelSize: maxPixelSize)
        }
        // ゲインマップ付き HDR は EDR 表示用にフル HDR デコードする
        // (長辺 8192px まで。CALayer 側は preferredDynamicRange = .high)
        // サムネイル等の小さな要求(< 2048px)はフル HDR デコードしない
        // (キャップ無視のフル解像度がキャッシュへ入るのを防ぐ)
        if let cap = maxPixelSize, cap >= 2048,
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(
               source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            // まず表示キャップを適用した HDR デコードを試す(8K の半精度
            // フル解像度がキャッシュを食い潰すのを防ぐ)。結果が HDR
            // (>8bit)でなければ従来のフル解像度 HDR デコードへ
            let cappedOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: cap,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            ]
            if let capped = CGImageSourceCreateThumbnailAtIndex(
                source, 0, cappedOptions as CFDictionary),
               capped.bitsPerComponent > 8 {
                return capped
            }
            let hdrOptions: [CFString: Any] = [
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? Int.max
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? Int.max
            if max(width, height) <= 8192, let hdr = CGImageSourceCreateImageAtIndex(
                source, 0, hdrOptions as CFDictionary),
               max(hdr.width, hdr.height) <= 8192 {
                return hdr
            }
        }
        // 設計書 §5: キャップ近傍では全体デコード、大幅縮小 JPEG は縮小復号を使う。
        if let cap = maxPixelSize {
            guard cap > 0 else { throw BookSourceError.pageLoadFailed("invalid pixel cap") }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let depth = (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
            let path = cappedPath(width: width, height: height, cap: cap,
                                  isJPEG: CGImageSourceGetType(source) == "public.jpeg" as CFString,
                                  bitsPerComponent: depth)
            if path != .thumbnail {
                var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
                if case .subsampled(let factor) = path {
                    options[kCGImageSourceSubsampleFactor] = factor
                }
                if let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                    let swapped = (5...8).contains(orientation)
                    let w = swapped ? image.height : image.width
                    let h = swapped ? image.width : image.height
                    if let size = cappedDimensions(width: w, height: h, cap: cap) {
                        if size.width == w, size.height == h, orientation == 1 {
                            if let displayTarget { return displayTarget.converted(image) ?? image }
                            return image
                        }
                        // 設計書 §5: 表示先なしの灰色＋透明度も RGBA で保ち、サムネイルを黒くしない。
                        let sourceSpace = image.colorSpace
                        let fallbackSpace = (sourceSpace?.model == .rgb || DisplayColorTarget.isOpaqueGray(image))
                            ? sourceSpace : nil
                        let space = displayTarget?.space(for: image) ?? fallbackSpace
                            ?? CGColorSpace(name: CGColorSpace.sRGB)!
                        if let result = DisplayColorTarget.draw(image,
                            width: size.width, height: size.height, space: space,
                            orientation: orientation) { return result }
                    }
                }
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
            return displayTarget?.converted(image) ?? image
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return try decodeWithAppKit(data, maxPixelSize: maxPixelSize)
        }
        return displayTarget?.converted(image) ?? image
    }

    /// 設計書 §5: 長辺は整数の cap に固定し、短辺だけを四捨五入して 1px 以上に保つ。
    static func cappedDimensions(width: Int, height: Int, cap: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, cap > 0 else { return nil }
        let long = max(width, height)
        guard long > cap else { return (width, height) }
        let scaled = (Double(min(width, height)) / Double(long) * Double(cap)).rounded()
        guard let short = Int(exactly: scaled) else { return nil }
        return width >= height ? (cap, max(1, min(cap, short))) : (max(1, min(cap, short)), cap)
    }

    /// 出力は必ずキャップ内。全体復号の一時確保にも既存の安全上限を適用する(設計書 §5)。
    enum CappedPath: Equatable {
        case full
        case subsampled(Int)
        case thumbnail
    }

    static func cappedPath(width: Int, height: Int, cap: Int, isJPEG: Bool,
                           bitsPerComponent: Int = 8) -> CappedPath {
        // 設計書 §5: 高ビット深度の一時確保と HDR の選択は従来の経路を維持する。
        guard width > 0, height > 0, cap > 0,
              bitsPerComponent <= 8 else { return .thumbnail }
        let ratio = Double(max(width, height)) / Double(cap)
        if ratio <= 1.1, BitmapDimensions(width: width, height: height) != nil { return .full }
        if isJPEG, ratio >= 2 {
            let factor = ratio >= 8 ? 8 : (ratio >= 4 ? 4 : 2)
            if BitmapDimensions(width: max(1, width / factor), height: max(1, height / factor)) != nil {
                return .subsampled(factor)
            }
        }
        return .thumbnail
    }

    /// ImageIO が扱えない形式(SVG 等のベクトル画像)を NSImage で
    /// ラスタライズするフォールバック。ベクトルは指定解像度(既定 2048)で
    /// 描くため拡大してもシャープになる。
    private static func decodeWithAppKit(_ data: Data, maxPixelSize: Int?) throws -> CGImage {
        // レトロ日本形式(MAG/MAKI)は先頭マジックで判定して専用デコード
        if RetroImageDecoding.isRetroImage(data),
           let retro = RetroImageDecoding.decode(data) {
            return downscaled(retro, maxPixelSize: maxPixelSize)
        }
        guard let image = loadAppKitImage(data),
              image.size.width > 0, image.size.height > 0 else {
            throw BookSourceError.pageLoadFailed("undecodable image data")
        }
        let longSide = max(image.size.width, image.size.height)
        var scale = CGFloat(maxPixelSize ?? 2048) / longSide
        // ラスタ画像は拡大しない(ImageIO 経路と同じ挙動)。ベクトルのみ拡大可
        if image.representations.contains(where: { $0 is NSBitmapImageRep }) {
            scale = min(scale, 1)
        }
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

    /// maxPixelSize を超える画像を縮小する(レトロ形式のサムネイル用)
    private static func downscaled(_ image: CGImage, maxPixelSize: Int?) -> CGImage {
        guard let maxPixelSize, max(image.width, image.height) > maxPixelSize
        else { return image }
        let scale = CGFloat(maxPixelSize) / CGFloat(max(image.width, image.height))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// NSImage(data:) は拡張子ヒントなしでは SVG を判別できないため、
    /// SVG らしきデータは .svg の一時ファイル経由で読み込む。
    ///
    /// 既知の残余(cooViewer-0kn。CWE-312 の受容): decode は保護状態を知らないため、
    /// 暗号化書庫内の SVG ページを復号したデータもここで平文の一時ファイルへ一瞬
    /// 書き出す(defer で即削除。プロセスがこの間に死ねば残る)。他の経路(SuperRes
    /// キャッシュ=暗号化 or 非保存、サムネイル=ディスク層バイパス)と非対称だが、
    /// 「暗号化書庫内の SVG ページ」自体がほぼ存在しない稀ケースで、正しい修正は
    /// decode 系 API 全体へ protected を通す配線(nonisolated ホットパスにアクタ跳躍を
    /// 足す)を要し、トリガの稀さに対して不相応。受容し据え置く(macOS 公開 API に
    /// 一時ファイルなしの SVG ラスタライズ手段が無いのも理由)。
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
