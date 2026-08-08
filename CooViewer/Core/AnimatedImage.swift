import CoreGraphics
import Foundation
import ImageIO

/// アニメーション画像(GIF/APNG/WebP/HEICS/AVIF シーケンス)の全フレーム読込。
/// 再生は ReaderView が CAKeyframeAnimation で行う(設計書 §5 描画品質)。
/// EN: Loads all frames of an animated image; playback happens in ReaderView.
struct AnimatedImage {
    let frames: [CGImage]
    let delays: [Double]

    var duration: Double { delays.reduce(0, +) }

    /// 複数フレームを持つ場合のみ返す。メモリ保護のためフレーム数と
    /// 解像度(既定 2048px)に上限を設ける。
    /// EN: Returns nil for single-frame images; frame count and size capped.
    static func load(from data: Data, maxPixelSize: Int? = nil,
                     maxFrames: Int = 120) -> AnimatedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        let pixelCap = min(maxPixelSize ?? 2048, 2048)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelCap,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<min(count, maxFrames) {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(
                source, index, options as CFDictionary) else { continue }
            frames.append(frame)
            delays.append(delay(source: source, index: index))
        }
        guard frames.count > 1 else { return nil }
        return AnimatedImage(frames: frames, delays: delays)
    }

    /// フレーム表示時間。形式別の辞書から unclamped → clamped の順で読む
    /// EN: Per-frame delay, read per container format; 0.1s default,
    /// EN: floored at 0.02s like browsers do.
    private static func delay(source: CGImageSource, index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any] ?? [:]
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary,
             kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary,
             kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary,
             kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary,
             kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictionaryKey, unclampedKey, clampedKey) in containers {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else {
                continue
            }
            let value = (dictionary[unclampedKey] as? Double)
                ?? (dictionary[clampedKey] as? Double) ?? 0
            if value > 0 { return max(0.02, value) }
        }
        return 0.1
    }
}
