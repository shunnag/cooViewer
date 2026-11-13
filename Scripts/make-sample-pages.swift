// 検証用 FXL 漫画のページ画像を生成する(番号入り縦長 PNG)
//
//   swift Scripts/make-sample-pages.swift <出力先> <枚数>
//   swift Scripts/make-sample-pages.swift <出力先> <枚数> --halftone gray|rgb|colour [--size <幅>x<高さ>]
//
// --halftone は網点処理(設計書 §5)の検証用の合成ページを作る: 上 3/4 に細かい網点(周期 4 px、45 度。
// 下へ向かってインクの面積率が 0.2 から 0.8 へ増える)、下 1/4 に白地の番号と線。すべて式で描く合成画像。
//   gray   1 チャンネルのグレー(Generic Gray 2.2)の PNG
//   rgb    同じ輝度を R = G = B で持つ sRGB の PNG(色なしの RGB のスキャン)
//   colour 赤いインクとクリーム色の紙で刷った sRGB の PNG(色のあるページとして素通しになる)
// 大きさの既定は 1362x2046(単ページのスキャンの大きさ)。
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2]) ?? 6

/// 網点のページ。kind は gray / rgb / colour
func makeHalftonePages(kind: String, width: Int, height: Int) {
    let tonedHeight = height * 3 / 4
    for page in 1...count {
        // 輝度(紙 240、インク 20)。雑音は ±2 の決定的な擬似乱数
        var luma = [UInt8](repeating: 240, count: width * height)
        var state = UInt64(page) &* 0x9E37_79B9_7F4A_7C15
        let period = 4.0
        let angle = 45.0 * Double.pi / 180
        let cosT = cos(angle), sinT = sin(angle)
        for y in 0..<height {
            let coverage = y < tonedHeight ? 0.2 + 0.6 * Double(y) / Double(tonedHeight) : 0
            for x in 0..<width {
                state = state &+ 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                let noise = Double(Int(z % 5) - 2)
                var value = 240.0
                if coverage > 0 {
                    let u = Double(x) * cosT + Double(y) * sinT, v = -Double(x) * sinT + Double(y) * cosT
                    let s = (cos(2 * Double.pi * u / period) + cos(2 * Double.pi * v / period)) / 4 + 0.5
                    let ink = min(1, max(0, (s - (1 - coverage)) * period / 1.5 + 0.5))
                    value = 240 - 220 * ink
                }
                luma[y * width + x] = UInt8(max(0, min(255, (value + noise).rounded())))
            }
        }
        // 下の白地: 番号と枠線を輝度のページへ描く(文脈は輝度のバイト列を借りる間だけ使う)
        let grayImage = luma.withUnsafeMutableBytes { raw -> CGImage in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setStrokeColor(gray: 0.06, alpha: 1)
            ctx.setLineWidth(6)
            ctx.stroke(CGRect(x: 40, y: 40, width: width - 80, height: height - tonedHeight - 80))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let text = "\(page)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: CGFloat(height - tonedHeight) / 2),
                .foregroundColor: NSColor.black,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2,
                                  y: (CGFloat(height - tonedHeight) - size.height) / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            ctx.flush()
            return ctx.makeImage()!
        }

        let image: CGImage
        if kind == "gray" {
            image = grayImage
        } else {
            // rgb は R = G = B、colour はインクと紙の 2 色の間を輝度で内分する
            let ink: [Double] = kind == "colour" ? [200, 30, 40] : [20, 20, 20]
            let paper: [Double] = kind == "colour" ? [250, 244, 226] : [240, 240, 240]
            var rgb = [UInt8](repeating: 255, count: width * height * 4)
            for i in 0..<(width * height) {
                let f = min(1, max(0, (Double(luma[i]) - 20) / 220))
                for c in 0..<3 {
                    let value = kind == "colour" ? ink[c] + (paper[c] - ink[c]) * f : Double(luma[i])
                    rgb[4 * i + c] = UInt8(max(0, min(255, value.rounded())))
                }
            }
            image = rgb.withUnsafeMutableBytes { raw -> CGImage in
                CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
            }
        }
        let url = URL(fileURLWithPath: "\(outDir)/p\(String(format: "%03d", page)).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
    print("generated \(count) \(kind) halftone pages (\(width)x\(height)) in \(outDir)")
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--halftone"), index + 1 < arguments.count {
    let kind = arguments[index + 1]
    guard ["gray", "rgb", "colour"].contains(kind) else {
        print("--halftone は gray / rgb / colour")
        exit(2)
    }
    var halftoneWidth = 1362
    var halftoneHeight = 2046
    if let sizeIndex = arguments.firstIndex(of: "--size"), sizeIndex + 1 < arguments.count {
        let parts = arguments[sizeIndex + 1].split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            print("--size は <幅>x<高さ>")
            exit(2)
        }
        halftoneWidth = parts[0]
        halftoneHeight = parts[1]
    }
    makeHalftonePages(kind: kind, width: halftoneWidth, height: halftoneHeight)
    exit(0)
}

let width = 848
let height = 1200

for page in 1...count {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let hue = CGFloat(page - 1) / CGFloat(count)
    let color = NSColor(hue: hue, saturation: 0.25, brightness: 0.95, alpha: 1)
    ctx.setFillColor(color.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setLineWidth(12)
    ctx.stroke(CGRect(x: 20, y: 20, width: width - 40, height: height - 40))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let text = "\(page)" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 400),
        .foregroundColor: NSColor.black,
    ]
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2,
                          y: (CGFloat(height) - size.height) / 2), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()

    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: "\(outDir)/p\(String(format: "%03d", page)).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("generated \(count) pages in \(outDir)")
