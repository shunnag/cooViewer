import CoreGraphics
import Foundation

/// PageCache.swift と一緒に swiftc -O -parse-as-library でコンパイルする。
/// 同じメインアクターの読者からの命中を測り、隔離の変更前後を比較する。
/// 変更前の actor 版を測るときだけ -D PAGE_CACHE_ACTOR を渡す。
@main
struct PageCacheBenchmark {
    @MainActor
    static func main() async {
        let context = CGContext(data: nil, width: 8, height: 8,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let count = 128
        let iterations = 20_000
        let cache = PageCache(byteLimit: image.bytesPerRow * image.height * count)
        for id in 0..<count {
            #if PAGE_CACHE_ACTOR
            await cache.insert(image, for: id)
            #else
            cache.insert(image, for: id)
            #endif
        }
        for round in 0..<6 {
            var checksum = 0
            let start = ContinuousClock.now
            for step in 0..<iterations {
                #if PAGE_CACHE_ACTOR
                let hit = await cache.image(for: step % count)
                #else
                let hit = cache.image(for: step % count)
                #endif
                if let hit {
                    checksum += hit.width
                }
            }
            let elapsed = ContinuousClock.now - start
            let parts = elapsed.components
            let milliseconds = Double(parts.seconds) * 1_000
                + Double(parts.attoseconds) / 1e15
            print("round=\(round) hits=\(iterations) checksum=\(checksum) ms=\(milliseconds)")
        }
    }
}
