// 検証用 FXL 漫画のページ画像を生成する(番号入り縦長 PNG)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2]) ?? 6
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
