import AppKit
import CryptoKit

/// 表示先のプロファイルと、合成時の変換不要を確認した灰色プロファイル(設計書 §5)。
struct DisplayColorTarget: Sendable, Equatable {
    let rgb: CGColorSpace
    let gray: CGColorSpace?
    let identity: String

    /// 設計書 §5: 実画面で合成時の追加変換がないと確認済みの灰色を既定で使う。
    init(rgb: CGColorSpace,
         verifiedGray: CGColorSpace? = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)) {
        self.rgb = rgb
        gray = verifiedGray
        identity = Self.identity(rgb) + "|gray:" + (verifiedGray.map(Self.identity) ?? "disabled")
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    static func identity(_ space: CGColorSpace) -> String {
        if let data = space.copyICCData() as Data? {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return "\(space.name as String? ?? "unnamed"):\(space.model.rawValue):\(space.numberOfComponents)"
    }

    @MainActor
    static func current(window: NSWindow?) -> Self {
        Self(rgb: window?.colorSpace?.cgColorSpace
             ?? NSScreen.main?.colorSpace?.cgColorSpace
             ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// 灰色でも透明度があれば一成分へ落とさず、半精度画像は元のまま扱う(設計書 §5)。
    func space(for image: CGImage) -> CGColorSpace {
        if Self.preservesHDR(image) { return image.colorSpace ?? rgb }
        if Self.isOpaqueGray(image), let gray { return gray }
        return rgb
    }

    /// 設計書 §5: PQ・HLG は 8bit の符号値でも HDR なので、SDR 化・再量子化を避ける。
    static func preservesHDR(_ image: CGImage) -> Bool {
        image.bitsPerComponent > 8 || (image.colorSpace.map { $0.isHDR() || CGColorSpaceUsesITUR_2100TF($0) } ?? false)
    }

    /// 設計書 §5: パレット画像・透明度つき画像・詰め物つき画像は単一成分とみなさない。
    static func isOpaqueGray(_ image: CGImage) -> Bool {
        image.colorSpace?.model == .monochrome && image.alphaInfo == .none
            && image.bitsPerComponent <= 8 && image.bitsPerPixel == image.bitsPerComponent
    }

    func matches(_ image: CGImage, colorSpace: CGColorSpace? = nil) -> Bool {
        if Self.preservesHDR(image) { return true }
        let space = colorSpace ?? space(for: image)
        return image.colorSpace == space && (space.model != .monochrome
            || (Self.isOpaqueGray(image) && image.bitsPerComponent == 8))
    }

    /// 初回表示と縮小後の双方で同じ色管理を使い、主スレッドの合成変換を避ける(設計書 §5)。
    func converted(_ image: CGImage, colorSpace: CGColorSpace? = nil) -> CGImage? {
        if matches(image, colorSpace: colorSpace) { return image }
        return Self.draw(image, width: image.width, height: image.height,
                         space: colorSpace ?? space(for: image))
    }

    /// 回転・縮小・色変換を一回の描画にまとめる。寸法検証は既存の確保上限に従う(設計書 §5)。
    static func draw(_ image: CGImage, width: Int, height: Int,
                     space: CGColorSpace, orientation: UInt32 = 1) -> CGImage? {
        guard BitmapDimensions(width: width, height: height) != nil else { return nil }
        let gray = space.model == .monochrome
        let info = gray ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swapped = (5...8).contains(orientation)
        context.scaleBy(x: CGFloat(width) / (swapped ? h : w),
                        y: CGFloat(height) / (swapped ? w : h))
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: transform = .identity
        }
        context.concatenate(transform)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
