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
//
// 完成画像の色(設計書 §5。変えるのは明るさだけで、ファイルの色は保つ):
//   1 チャンネルのグレーのソース(ヘッダの色モデルがグレー、または不透明な 1 チャンネルのデコード)は
//     グレーの L' にする。描き直しは輝度を求めたら手放す。
//   それ以外(RGB と索引色)で色なしと判定したページは、描き直しをページに持たせて recolour まで保ち、
//     各画素に輝度の差 d = L' - L を足した sRGB の RGB にする(PageOutput.swift)。薄い色のインクで刷った
//     ページや、黄ばんだ紙のページの色を灰色にしないため。

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
        if let luma = try directLuma(image) {
            return .ready(PrintAppearancePage(checked: luma, width: width, height: height))
        }
        switch try redrawnLuma(image, mayBeColour: !headerGray && !isOpaqueOneChannel(image)) {
        case .transparent:
            return .passThrough(.transparency, raw: image)
        case .colour:
            return .passThrough(.colour, raw: image)
        case .luma(let luma, let redraw):
            return .ready(PrintAppearancePage(checked: luma, width: width, height: height, redraw: redraw))
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
    /// この画像を sRGB へ描き直すと v はそのまま v になるので、描き直しと同じ輝度になる。
    /// 輝度は仮想記憶の領域に置く(設計書 §2.3)
    static func directLuma(_ image: CGImage) throws -> PageBuffer? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 8, image.alphaInfo == .none,
              let space = image.colorSpace, space.model == .monochrome,
              (space.name as String?) == (CGColorSpace.genericGrayGamma2_2 as String),
              image.bitmapInfo.intersection(.floatComponents).isEmpty,
              let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height, bpr = image.bytesPerRow
        guard CFDataGetLength(data) >= bpr * (h - 1) + w else { return nil }
        let out = try PageBuffer(byteCount: w * h)
        let o = out.bytes
        for y in 0..<h { memcpy(o + y * w, base + y * bpr, w) }
        return out
    }

    enum Redrawn {
        /// 輝度と、色を戻すための描き直し(mayBeColour のときだけ。グレーのソースは nil)
        case luma(PageBuffer, SRGBRedraw?)
        case colour
        case transparent
    }

    /// sRGB RGBA へ 1 回描き直し、透明度・輝度・色を調べる。mayBeColour(RGB のソース)で色なしなら、
    /// 完成画像の色に使うので描き直しを返す。
    /// 描き直しと輝度は仮想記憶の領域に置く(設計書 §2.3)。行のバイト数は、文脈に領域を任せたときに
    /// CoreGraphics が選ぶ値(4 * 幅を 32 バイトに揃えたもの)と同じにし、描き方を変えない
    static func redrawnLuma(_ image: CGImage, mayBeColour: Bool) throws -> Redrawn {
        let w = image.width, h = image.height
        let bpr = (w * 4 + 31) & ~31
        let buffer = try PageBuffer(byteCount: bpr * h)
        // 文脈は領域を保持しないので、描いて読み終えるまで持ち主を保つ
        defer { withExtendedLifetime(buffer) {} }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: buffer.base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PrintAppearanceError.allocationFailed("描き直しの文脈 \(w)x\(h)")
        }
        let base = buffer.bytes
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
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
        let out = try PageBuffer(byteCount: w * h)
        var colourPixels = 0
        let op = out.bytes
        for y in 0..<h {
            let row = base + y * bpr
            for x in 0..<w {
                let p = row + x * 4
                op[y * w + x] = UInt8((299 * Int(p[0]) + 587 * Int(p[1]) + 114 * Int(p[2]) + 500) / 1000)
                if Int(max(p[0], p[1], p[2])) - Int(min(p[0], p[1], p[2])) >= level { colourPixels += 1 }
            }
        }
        if mayBeColour && Double(colourPixels) / Double(w * h) > Params.printAppearance.colourFrac { return .colour }
        return .luma(out, mayBeColour ? SRGBRedraw(buffer: buffer, bytesPerRow: bpr, width: w, height: h) : nil)
    }

    // MARK: - 縮小

    /// 出力と vImage の一時領域は仮想記憶に置く(設計書 §2.3。一時領域を渡しても結果は同じ)
    static func reduce(_ page: PrintAppearanceGray, width: Int, height: Int) throws -> PrintAppearanceGray {
        guard width > 0, height > 0 else { throw PrintAppearanceError.invalidPage("縮小先の大きさ \(width)x\(height)") }
        if width == page.width && height == page.height { return page }
        let rowBytes = PrintAppearanceGray.alignedRowBytes(width)
        let pixels = try PageMemory.zeroedData(byteCount: rowBytes * height) { dst in
            let error = page.pixels.withUnsafeBytes { src in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                      height: vImagePixelCount(page.height), width: vImagePixelCount(page.width),
                                      rowBytes: page.bytesPerRow)
                var d = vImage_Buffer(data: dst, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: rowBytes)
                let flags = vImage_Flags(kvImageHighQualityResampling)
                return withScaleTemp(vImageScale_Planar8(&s, &d, nil, flags | vImage_Flags(kvImageGetTempBufferSize))) {
                    vImageScale_Planar8(&s, &d, $0, flags)
                }
            }
            guard error == kvImageNoError else { throw PrintAppearanceError.allocationFailed("vImageScale: \(error)") }
        }
        return PrintAppearanceGray(width: width, height: height, bytesPerRow: rowBytes, pixels: pixels,
                                   changed: page.changed)
    }

    /// vImageScale の一時領域を仮想記憶に用意して scale を呼ぶ。size は kvImageGetTempBufferSize の答え
    /// (負なら誤りの番号として返す。0 なら一時領域なしで呼ぶ)
    static func withScaleTemp(_ size: vImage_Error, _ scale: (UnsafeMutableRawPointer?) -> vImage_Error) -> vImage_Error {
        guard size > 0 else { return size < 0 ? size : scale(nil) }
        guard let temp = try? PageBuffer(byteCount: size) else { return vImage_Error(kvImageMemoryAllocationError) }
        return withExtendedLifetime(temp) { scale(temp.base) }
    }
}
