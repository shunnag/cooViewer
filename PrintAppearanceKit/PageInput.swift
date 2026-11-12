import Accelerate
import CoreGraphics
import Foundation
import ImageIO

// ページの受け付け(設計書 §5): どのファイルを処理するか、エンジンへ渡す輝度、処理済みのページの縮小。
// 1 画素ずつの処理はすべてここに置く(アプリの Debug 構成は最適化なしで、そこで回すと遅いため)。
//
// 判定の順(先に決まったものを返す。デコードの前に決まる理由ほど先に調べる):
//   ImageIO で開けない・フレームが 1 つでない → format
//   辺が 128 px 未満 → small
//   EXIF の向きが 1 以外 → orientation(エンジンは保存されたラスタをそのまま扱い、向きを変えた見え方で
//     確かめていないため)
//   深さが 8 bit 以外、色モデルがグレーと RGB 以外 → format
//   画素数が maxPixels を超える → tooLarge
//   幅 / 高さが 0.5〜1.6 の外 → aspect(画素から距離への換算はページの高さを 173 mm とみなす。単ページと
//     1 枚の見開きでは成り立つが、縦長の帯や横長のパノラマでは成り立たず、強くまとめすぎるため)
//   HDR のゲインマップ → format
//   デコードしてから: 8 bit でない・HDR の色空間・グレーと RGB と索引色以外 → format、不透明でない画素 → transparency、
//     色のあるページ → colour。
//
// 輝度と色の判定は検証済みの実装と同じ規則・同じ呼び出しで行う:
//   デコードは CGImageSourceCreateImageAtIndex(ShouldCacheImmediately だけ。表示先の色変換も縮小もしない)。
//   ヘッダを読んだソースとは別の、何も問い合わせていないソースでデコードする。同じソースで先に
//   CGImageSourceCopyPropertiesAtIndex やゲインマップの問い合わせをすると、JPEG によってはデコード結果が
//   ±1 変わる(実測)。検証済みの実装とアプリの上限なしの経路(ImageDecoding の最後の分岐)は問い合わせずに
//   デコードする。上限ありの経路は先にヘッダを読むので、素通しの raw はそちらとは一致しないことがある。
//   輝度: 8 bit・不透明・1 チャンネルで色空間の名前が Generic Gray Gamma 2.2 の画像は標本のバイトをそのまま使う。
//     それ以外は 0 で埋めた 8 bit sRGB RGBA(premultipliedLast)の文脈へ描き直し、
//     Y = (299 R + 587 G + 114 B + 500) / 1000 を整数で求める。
//   色: ヘッダの色モデルがグレー、または不透明な 1 チャンネルのデコードは色なし。それ以外は同じ描き直しの上で
//     max - min >= 32 の画素の割合が 0.5% を超えれば色あり。描き直しは 1 回で、輝度・色・透明度に使う。

enum PageInput {
    static func prepare(_ data: Data, maxPixels: Int) throws -> PrintAppearancePreparation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .passThrough(.format, raw: nil)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return .passThrough(.format, raw: nil) }
        if let verdict = headerVerdict(source: source, properties: properties, width: width, height: height,
                                       maxPixels: maxPixels) {
            return .passThrough(verdict, raw: nil)
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let decoder = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, 0, options) else {
            return .passThrough(.format, raw: nil)
        }
        if let verdict = decodedVerdict(image, width: width, height: height) {
            return .passThrough(verdict, raw: image)
        }
        let headerGray = (properties[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelGray as String)
        if let luma = directLuma(image) {
            return .ready(PrintAppearancePage(checked: luma, width: width, height: height))
        }
        switch try redrawnLuma(image, mayBeColour: !headerGray && !isOpaqueOneChannel(image)) {
        case .transparent:
            return .passThrough(.transparency, raw: image)
        case .colour:
            return .passThrough(.colour, raw: image)
        case .luma(let luma):
            return .ready(PrintAppearancePage(checked: luma, width: width, height: height))
        }
    }

    /// デコードせずにヘッダだけで決まる素通しの理由
    static func headerVerdict(source: CGImageSource, properties: [CFString: Any], width: Int, height: Int,
                              maxPixels: Int) -> PrintAppearancePassReason? {
        if min(width, height) < N { return .small }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation != 1 { return .orientation }
        if let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue, depth != 8 { return .format }
        if let model = properties[kCGImagePropertyColorModel] as? String,
           model != (kCGImagePropertyColorModelGray as String), model != (kCGImagePropertyColorModelRGB as String) {
            return .format
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        if overflow || pixels > maxPixels { return .tooLarge }
        if !isAcceptedAspect(width: width, height: height) { return .aspect }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            return .format
        }
        return nil
    }

    /// 幅 / 高さが 0.5 以上 1.6 以下(整数で比べるので境界は厳密)
    static func isAcceptedAspect(width: Int, height: Int) -> Bool {
        2 * width >= height && 5 * width <= 8 * height
    }

    /// デコードした画像で決まる素通しの理由(透明度と色は描き直しで調べる)
    static func decodedVerdict(_ image: CGImage, width: Int, height: Int) -> PrintAppearancePassReason? {
        guard image.width == width, image.height == height, image.bitsPerComponent == 8,
              image.bitmapInfo.intersection(.floatComponents).isEmpty,
              let space = image.colorSpace else { return .format }
        if space.isHDR() || CGColorSpaceUsesITUR_2100TF(space) { return .format }
        switch space.model {
        case .monochrome, .rgb:
            return nil
        case .indexed:
            let base = space.baseColorSpace?.model
            return base == .monochrome || base == .rgb ? nil : .format
        default:
            return .format
        }
    }

    /// 不透明な 1 チャンネルの画像(アプリのグレーの判定と同じ)。描き直しても無彩色のままなので色を数えない
    static func isOpaqueOneChannel(_ image: CGImage) -> Bool {
        image.colorSpace?.model == .monochrome && image.alphaInfo == .none
            && image.bitsPerComponent <= 8 && image.bitsPerPixel == image.bitsPerComponent
    }

    /// 8 bit・不透明・1 チャンネル・Generic Gray Gamma 2.2 の画像の標本のバイト(行の詰め物を除く)。
    /// この画像を sRGB へ描き直すと v はそのまま v になるので、描き直しと同じ輝度になる
    static func directLuma(_ image: CGImage) -> [UInt8]? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 8, image.alphaInfo == .none,
              let space = image.colorSpace, space.model == .monochrome,
              (space.name as String?) == (CGColorSpace.genericGrayGamma2_2 as String),
              image.bitmapInfo.intersection(.floatComponents).isEmpty,
              let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height, bpr = image.bytesPerRow
        guard CFDataGetLength(data) >= bpr * (h - 1) + w else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h { memcpy(o.baseAddress! + y * w, base + y * bpr, w) }
        }
        return out
    }

    enum Redrawn {
        case luma([UInt8])
        case colour
        case transparent
    }

    /// sRGB RGBA へ 1 回描き直し、透明度・輝度・色を調べる
    static func redrawnLuma(_ image: CGImage, mayBeColour: Bool) throws -> Redrawn {
        let w = image.width, h = image.height
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw PrintAppearanceError.allocationFailed("描き直しの文脈 \(w)x\(h)")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bpr = context.bytesPerRow
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        if hasAlpha {
            for y in 0..<h {
                let row = base + y * bpr
                for x in 0..<w where row[x * 4 + 3] != 255 { return .transparent }
            }
        }
        let level = Params.printAppearance.colourLevel
        var out = [UInt8](repeating: 0, count: w * h)
        var colourPixels = 0
        out.withUnsafeMutableBufferPointer { o in
            let op = o.baseAddress!
            for y in 0..<h {
                let row = base + y * bpr
                for x in 0..<w {
                    let p = row + x * 4
                    op[y * w + x] = UInt8((299 * Int(p[0]) + 587 * Int(p[1]) + 114 * Int(p[2]) + 500) / 1000)
                    if Int(max(p[0], p[1], p[2])) - Int(min(p[0], p[1], p[2])) >= level { colourPixels += 1 }
                }
            }
        }
        if mayBeColour && Double(colourPixels) / Double(w * h) > Params.printAppearance.colourFrac { return .colour }
        return .luma(out)
    }

    // MARK: - 縮小

    static func reduce(_ page: PrintAppearanceGray, width: Int, height: Int) throws -> PrintAppearanceGray {
        guard width > 0, height > 0 else { throw PrintAppearanceError.invalidPage("縮小先の大きさ \(width)x\(height)") }
        if width == page.width && height == page.height { return page }
        let rowBytes = PrintAppearanceGray.alignedRowBytes(width)
        var pixels = Data(count: rowBytes * height)
        let error = page.pixels.withUnsafeBytes { src in
            pixels.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                      height: vImagePixelCount(page.height), width: vImagePixelCount(page.width),
                                      rowBytes: page.bytesPerRow)
                var d = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: rowBytes)
                return vImageScale_Planar8(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else { throw PrintAppearanceError.allocationFailed("vImageScale: \(error)") }
        return PrintAppearanceGray(width: width, height: height, bytesPerRow: rowBytes, pixels: pixels,
                                   changed: page.changed)
    }
}
