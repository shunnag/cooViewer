// ベンチマーク用コーパス生成: 漫画風 JPEG/PNG ページとサムネイル級 JPEG を決定論的に作る
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 決定論的な乱数(再現性のため arc4random は使わない)
struct LCG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

func writeImage(_ image: CGImage, to url: URL, type: UTType, quality: Double) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        fatalError("dest \(url)")
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize \(url)") }
}

// 写真調ノイズページ(JPEG 用): グラデーション背景+ノイズ+コマ枠
func makeJPEGPage(width: Int, height: Int, seed: UInt64) -> CGImage {
    var rng = LCG(seed: seed)
    let bytesPerRow = width * 3
    var buf = [UInt8](repeating: 0, count: bytesPerRow * height)
    // ノイズを一括生成してからグラデーションを加算(振幅を抑えて現実的なファイルサイズに)
    for i in 0..<buf.count { buf[i] = UInt8(truncatingIfNeeded: rng.next() >> 32) }
    for y in 0..<height {
        let base = 96 + (96 * y) / height
        let row = y * bytesPerRow
        for x in 0..<bytesPerRow {
            let noise = Int(buf[row + x] % 49) - 24
            buf[row + x] = UInt8(clamping: base + noise)
        }
    }
    // コマ枠(暗い矩形の輪郭)を数個(小さい画像では省く)
    for _ in 0..<6 where width > 500 && height > 600 {
        let rx = Int(rng.next() % UInt64(width - 400))
        let ry = Int(rng.next() % UInt64(height - 500))
        let rw = 300 + Int(rng.next() % 400), rh = 300 + Int(rng.next() % 500)
        for x in rx..<min(rx + rw, width) {
            for y in [ry, min(ry + rh, height - 1)] {
                let o = y * bytesPerRow + x * 3
                buf[o] = 20; buf[o+1] = 20; buf[o+2] = 20
            }
        }
        for y in ry..<min(ry + rh, height) {
            for x in [rx, min(rx + rw, width - 1)] {
                let o = y * bytesPerRow + x * 3
                buf[o] = 20; buf[o+1] = 20; buf[o+2] = 20
            }
        }
    }
    let data = CFDataCreate(nil, buf, buf.count)!
    let provider = CGDataProvider(data: data)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                   bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

// 漫画スキャン調ページ(PNG 用): 白背景+網点+枠線+微小ノイズ(グレースケール)
func makePNGPage(width: Int, height: Int, seed: UInt64) -> CGImage {
    var rng = LCG(seed: seed)
    var buf = [UInt8](repeating: 245, count: width * height)
    // 網点(セルごとに濃度が変わるドット)
    let cell = 6
    for cy in stride(from: 0, to: height, by: cell) {
        for cx in stride(from: 0, to: width, by: cell) {
            let density = Int((rng.next() >> 16) % 5)  // 0-4
            if density == 0 { continue }
            for dy in 0..<density {
                for dx in 0..<density {
                    let x = cx + dx + 1, y = cy + dy + 1
                    if x < width && y < height { buf[y * width + x] = 60 }
                }
            }
        }
    }
    // 枠線
    for _ in 0..<8 {
        let rx = Int(rng.next() % UInt64(width - 300))
        let ry = Int(rng.next() % UInt64(height - 400))
        let rw = 250 + Int(rng.next() % 500), rh = 250 + Int(rng.next() % 600)
        for t in 0..<3 {
            for x in rx..<min(rx + rw, width) {
                for y in [ry + t, min(ry + rh, height - 1) - t] { buf[y * width + x] = 0 }
            }
            for y in ry..<min(ry + rh, height) {
                for x in [rx + t, min(rx + rw, width - 1) - t] { buf[y * width + x] = 0 }
            }
        }
    }
    let data = CFDataCreate(nil, buf, buf.count)!
    let provider = CGDataProvider(data: data)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                   bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: makecorpus <outdir>") }
let out = URL(fileURLWithPath: args[1])
let fm = FileManager.default

let jpegDir = out.appendingPathComponent("pages-jpeg")
let pngDir = out.appendingPathComponent("pages-png")
let tinyDir = out.appendingPathComponent("tiny-jpeg")
for d in [jpegDir, pngDir, tinyDir] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }

// 200 ページの JPEG 本(1600x2400)
DispatchQueue.concurrentPerform(iterations: 200) { i in
    let url = jpegDir.appendingPathComponent(String(format: "page%03d.jpg", i))
    if fm.fileExists(atPath: url.path) { return }
    let img = makeJPEGPage(width: 1600, height: 2400, seed: UInt64(1000 + i))
    writeImage(img, to: url, type: .jpeg, quality: 0.82)
}
// 100 ページの PNG 本(1600x2400)
DispatchQueue.concurrentPerform(iterations: 100) { i in
    let url = pngDir.appendingPathComponent(String(format: "page%03d.png", i))
    if fm.fileExists(atPath: url.path) { return }
    let img = makePNGPage(width: 1600, height: 2400, seed: UInt64(5000 + i))
    writeImage(img, to: url, type: .png, quality: 1.0)
}
// 2000 個のサムネイル級 JPEG(160x240)
DispatchQueue.concurrentPerform(iterations: 2000) { i in
    let url = tinyDir.appendingPathComponent(String(format: "tiny%04d.jpg", i))
    if fm.fileExists(atPath: url.path) { return }
    let img = makeJPEGPage(width: 160, height: 240, seed: UInt64(9000 + i))
    writeImage(img, to: url, type: .jpeg, quality: 0.7)
}
print("corpus done")
