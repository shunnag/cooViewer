import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PrintAppearanceKit

/// 網点処理が受け付けるページの規則の検査(設計書 §5): 形式・大きさ・縦横比・上限・向き・透明度・色の判定、
/// エンジンへ渡す輝度、処理済みのページの縮小と画像化。画像はすべてテストの中で合成し、ImageIO で符号化する。
/// 符号化した結果のヘッダが想定どおりかも確かめる(ImageIO が別の形で書くと検査が素通りになるため)
final class PrintAppearanceInputTests: XCTestCase {

    // MARK: - 形式ごとの判定

    /// 8 bit の Generic Gray 2.2 の PNG は処理する。輝度は標本のバイトそのもの
    func testGrayPNGIsReadyWithSampleBytes() throws {
        let values = Self.ramp(width: 200, height: 300)
        let data = try Self.encode([Self.grayImage(values, width: 200, height: 300)], as: .png)
        try Self.assertHeader(data, depth: 8, model: "Gray")
        let page = try Self.ready(data)
        XCTAssertEqual(page.width, 200)
        XCTAssertEqual(page.height, 300)
        XCTAssertEqual(page.luma, values)
    }

    /// グレーの JPEG は処理する(デコードした標本のバイトが輝度になる)
    func testGrayJPEGIsReady() throws {
        let values = Self.ramp(width: 200, height: 300)
        let data = try Self.encode([Self.grayImage(values, width: 200, height: 300)], as: .jpeg,
                                   properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        try Self.assertHeader(data, depth: 8, model: "Gray")
        let page = try Self.ready(data)
        let decoded = try Self.decodedGrayBytes(data)
        XCTAssertEqual(page.luma, decoded)
    }

    /// 無彩色の RGB の PNG は処理する。sRGB へ描き直した R = G = B の輝度は元の値と同じ
    func testNeutralRGBPNGIsReadyWithSameValues() throws {
        let values = Self.ramp(width: 200, height: 300)
        let data = try Self.encode([Self.rgbImage(neutral: values, width: 200, height: 300)], as: .png)
        try Self.assertHeader(data, depth: 8, model: "RGB")
        XCTAssertEqual(try Self.ready(data).luma, values)
    }

    /// 無彩色の RGB の JPEG は処理する(色差の符号化の揺れは色の判定に届かない)
    func testNeutralRGBJPEGIsReady() throws {
        let values = Self.ramp(width: 200, height: 300)
        let data = try Self.encode([Self.rgbImage(neutral: values, width: 200, height: 300)], as: .jpeg,
                                   properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
        try Self.assertHeader(data, depth: 8, model: "RGB")
        let luma = try Self.ready(data).luma
        var difference = 0
        for i in 0..<values.count { difference += abs(Int(luma[i]) - Int(values[i])) }
        XCTAssertLessThanOrEqual(Double(difference) / Double(values.count), 2, "非可逆の符号化の誤差の平均")
    }

    /// 8 bit の索引色(灰色のパレット)の PNG は処理する
    func testIndexedGrayPNGIsReady() throws {
        let values = Self.ramp(width: 200, height: 300)
        let data = try Self.encode([Self.indexedGrayImage(values, width: 200, height: 300)], as: .png)
        try Self.assertHeader(data, depth: 8, model: "RGB", indexed: true)
        XCTAssertEqual(try Self.ready(data).luma, values)
    }

    /// 透明度の欄があっても、すべて不透明なら処理する(RGBA とグレー + 透明度)
    func testOpaqueImagesWithAlphaChannelAreReady() throws {
        let values = Self.ramp(width: 200, height: 300)
        let rgba = try Self.encode([Self.rgbImage(neutral: values, width: 200, height: 300,
                                                  alpha: .premultipliedLast)], as: .png)
        try Self.assertHeader(rgba, depth: 8, model: "RGB", hasAlpha: true)
        XCTAssertEqual(try Self.ready(rgba).luma, values)
        var grayAlpha = [UInt8](repeating: 255, count: 200 * 300 * 2)
        for i in 0..<(200 * 300) { grayAlpha[2 * i] = values[i] }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let gray = try Self.encode([Self.image(width: 200, height: 300, bitsPerComponent: 8, bitsPerPixel: 16,
                                               bytesPerRow: 400, space: space, alpha: .last, bytes: grayAlpha)],
                                   as: .png)
        try Self.assertHeader(gray, depth: 8, model: "Gray", hasAlpha: true)
        XCTAssertEqual(try Self.ready(gray).luma, values)
    }

    /// 透明度が 255 未満の画素が 1 つでもあれば素通し(デコードした画像を渡す)
    func testAlphaBelow255PassesThroughWithRaw() throws {
        var rgba = Self.rgba(neutral: Self.ramp(width: 200, height: 300))
        rgba[4 * 12_345 + 3] = 254
        let data = try Self.encode([Self.image(width: 200, height: 300, bitsPerComponent: 8, bitsPerPixel: 32,
                                               bytesPerRow: 800, space: Self.sRGB, alpha: .last, bytes: rgba)],
                                   as: .png)
        try Self.assertHeader(data, depth: 8, model: "RGB", hasAlpha: true)
        try Self.assertPassThrough(data, .transparency, rawDecoded: true)
    }

    /// ヘッダがグレーのページ(遅延デコードで輝度の領域へ直接描く)でも、デコードの後に決まる素通しの raw は
    /// 従来と同じ呼び出しの全面のデコード結果(設計書 §2.3)
    func testGrayHeaderPassThroughRawIsTheFullDecode() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        var bytes = [UInt8](repeating: 255, count: 200 * 300 * 2)
        let values = Self.ramp(width: 200, height: 300)
        for i in 0..<values.count { bytes[2 * i] = values[i] }
        bytes[2 * 12_345 + 1] = 200
        let data = try Self.encode([Self.image(width: 200, height: 300, bitsPerComponent: 8, bitsPerPixel: 16,
                                               bytesPerRow: 400, space: space, alpha: .last, bytes: bytes)],
                                   as: .png)
        try Self.assertHeader(data, depth: 8, model: "Gray", hasAlpha: true)
        guard case .passThrough(.transparency, let raw?) = try PrintAppearance.prepare(data, maxPixels: 16_000_000)
        else { return XCTFail("透明度のあるグレーのページがデコード結果付きの素通しにならない") }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let expected = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        XCTAssertEqual(raw.width, expected.width)
        XCTAssertEqual(raw.bitsPerPixel, expected.bitsPerPixel)
        XCTAssertEqual(raw.alphaInfo, expected.alphaInfo)
        XCTAssertEqual(raw.dataProvider?.data as Data?, expected.dataProvider?.data as Data?)
    }

    /// 1 bit のスキャンは素通し(デコードの前に決まる)
    func testOneBitPassesThrough() throws {
        let rowBytes = 25
        var bits = [UInt8](repeating: 0, count: rowBytes * 300)
        for i in 0..<bits.count { bits[i] = UInt8(truncatingIfNeeded: i * 37) }
        let image = try Self.image(width: 200, height: 300, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                                   space: CGColorSpaceCreateDeviceGray(), alpha: .none, bytes: bits)
        let data = try Self.encode([image], as: .png)
        try Self.assertHeader(data, depth: 1, model: "Gray")
        try Self.assertPassThrough(data, .format, rawDecoded: false)
    }

    /// 16 bit は素通し
    func testSixteenBitPassesThrough() throws {
        var bytes = [UInt8](repeating: 0x80, count: 200 * 300 * 2)
        for i in 0..<(200 * 300) { bytes[2 * i] = UInt8(i % 256) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let data = try Self.encode([Self.image(width: 200, height: 300, bitsPerComponent: 16, bitsPerPixel: 16,
                                               bytesPerRow: 400, space: space, alpha: .none, bytes: bytes)], as: .png)
        try Self.assertHeader(data, depth: 16, model: "Gray")
        try Self.assertPassThrough(data, .format, rawDecoded: false)
    }

    /// CMYK は素通し
    func testCMYKPassesThrough() throws {
        var bytes = [UInt8](repeating: 0, count: 200 * 300 * 4)
        for i in 0..<(200 * 300) { bytes[4 * i + 3] = UInt8(i % 256) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK))
        let data = try Self.encode([Self.image(width: 200, height: 300, bitsPerComponent: 8, bitsPerPixel: 32,
                                               bytesPerRow: 800, space: space, alpha: .none, bytes: bytes)],
                                   as: .jpeg)
        try Self.assertHeader(data, depth: 8, model: "CMYK")
        try Self.assertPassThrough(data, .format, rawDecoded: false)
    }

    /// EXIF の向きが 1 以外なら素通し
    func testOrientedImagePassesThrough() throws {
        let data = try Self.encode([Self.grayImage(Self.ramp(width: 200, height: 300), width: 200, height: 300)],
                                   as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        try Self.assertHeader(data, depth: 8, model: "Gray", orientation: 6)
        try Self.assertPassThrough(data, .orientation, rawDecoded: false)
    }

    /// 2 フレームの画像は素通し
    func testTwoFrameImagePassesThrough() throws {
        let image = try Self.grayImage(Self.ramp(width: 200, height: 300), width: 200, height: 300)
        let data = try Self.encode([image, image], as: .tiff)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        try Self.assertPassThrough(data, .format, rawDecoded: false)
    }

    /// HDR の色空間(PQ)は素通し(デコードの後に決まる)
    func testHDRColourSpacePassesThrough() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
        let data = try Self.encode([Self.image(width: 200, height: 300, bitsPerComponent: 8, bitsPerPixel: 32,
                                               bytesPerRow: 800, space: space, alpha: .noneSkipLast,
                                               bytes: Self.rgba(neutral: Self.ramp(width: 200, height: 300)))],
                                   as: .png)
        try Self.assertHeader(data, depth: 8, model: "RGB")
        try Self.assertPassThrough(data, .format, rawDecoded: true)
    }

    /// ImageIO で読めないバイト列は素通し
    func testUnreadableDataPassesThrough() throws {
        try Self.assertPassThrough(Data(), .format, rawDecoded: false)
        try Self.assertPassThrough(Data((0..<1000).map { UInt8($0 % 251) }), .format, rawDecoded: false)
    }

    /// 名前の付かないグレー(線形のグレー)は sRGB への描き直しで輝度を求め、色なしとして処理する
    func testUnnamedGrayIsRedrawn() throws {
        let values = Self.ramp(width: 200, height: 300)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearGray))
        let data = try Self.encode([Self.image(width: 200, height: 300, bitsPerComponent: 8, bitsPerPixel: 8,
                                               bytesPerRow: 200, space: space, alpha: .none, bytes: values)],
                                   as: .png)
        try Self.assertHeader(data, depth: 8, model: "Gray")
        let luma = try Self.ready(data).luma
        XCTAssertNotEqual(luma, values, "線形の値は sRGB の符号値に描き直される")
        XCTAssertEqual(luma[try XCTUnwrap(values.firstIndex(of: 0))], 0)
        XCTAssertEqual(luma[try XCTUnwrap(values.firstIndex(of: 255))], 255)
    }

    // MARK: - 大きさ・縦横比・上限

    /// 辺が 128 px 未満は素通し、128 px は処理する(縦・横とも)
    func testSmallEdgeBoundary() throws {
        for (w, h, expectReady) in [(127, 200, false), (128, 200, true), (200, 127, false), (200, 128, true)] {
            let data = try Self.grayPNG(width: w, height: h)
            if expectReady {
                XCTAssertNoThrow(try Self.ready(data), "\(w)x\(h)")
            } else {
                try Self.assertPassThrough(data, .small, rawDecoded: false)
            }
        }
    }

    /// 幅 / 高さは 0.5 以上 1.6 以下だけを処理する(境界の値は処理する)
    func testAspectBoundaries() throws {
        for (w, h, expectReady) in [(245, 500, false), (250, 500, true), (800, 500, true), (805, 500, false)] {
            let data = try Self.grayPNG(width: w, height: h)
            if expectReady {
                XCTAssertNoThrow(try Self.ready(data), "\(w)x\(h)")
            } else {
                try Self.assertPassThrough(data, .aspect, rawDecoded: false)
            }
        }
        XCTAssertTrue(PageInput.isAcceptedAspect(width: 1, height: 2))
        XCTAssertFalse(PageInput.isAcceptedAspect(width: 49, height: 100))
        XCTAssertTrue(PageInput.isAcceptedAspect(width: 8, height: 5))
        XCTAssertFalse(PageInput.isAcceptedAspect(width: 161, height: 100))
    }

    /// 画素数が上限を超えると素通し、ちょうど上限なら処理する
    func testPixelCeiling() throws {
        let data = try Self.grayPNG(width: 300, height: 400)
        guard case .passThrough(.tooLarge, let raw) = try PrintAppearance.prepare(data, maxPixels: 300 * 400 - 1) else {
            return XCTFail("上限を超えたのに素通しにならない")
        }
        XCTAssertNil(raw)
        guard case .ready = try PrintAppearance.prepare(data, maxPixels: 300 * 400) else {
            return XCTFail("上限ちょうどなのに処理しない")
        }
    }

    /// 上限の既定値はマシンの物理メモリで決まる
    func testDefaultCeilingFollowsPhysicalMemory() {
        let expected = ProcessInfo.processInfo.physicalMemory < UInt64(16) << 30 ? 9_000_000 : 16_000_000
        XCTAssertEqual(PrintAppearance.defaultMaxPixels, expected)
    }

    // MARK: - 色の判定

    /// 色のある画素(最大と最小の差が 32 以上)の割合が 0.5% ちょうどなら処理し、それを超えると素通し
    func testColourFractionBoundary() throws {
        // 200 x 200 = 40000 画素の 0.5% は 200 画素
        for (colourPixels, expectColour) in [(200, false), (201, true)] {
            var rgba = Self.rgba(neutral: [UInt8](repeating: 230, count: 40_000))
            for i in 0..<colourPixels { rgba[4 * (i * 191 % 40_000)] = 255; rgba[4 * (i * 191 % 40_000) + 2] = 120 }
            let data = try Self.encode([Self.image(width: 200, height: 200, bitsPerComponent: 8, bitsPerPixel: 32,
                                                   bytesPerRow: 800, space: Self.sRGB, alpha: .noneSkipLast,
                                                   bytes: rgba)], as: .png)
            if expectColour {
                try Self.assertPassThrough(data, .colour, rawDecoded: true)
            } else {
                XCTAssertNoThrow(try Self.ready(data))
            }
        }
    }

    /// 色の差は 32 以上を数え、31 は数えない
    func testColourLevelBoundary() throws {
        for (spread, expectColour) in [(31, false), (32, true)] {
            var rgba = Self.rgba(neutral: [UInt8](repeating: 128, count: 40_000))
            for i in 0..<2_000 { rgba[4 * (i * 7)] = UInt8(128 + spread) }
            let data = try Self.encode([Self.image(width: 200, height: 200, bitsPerComponent: 8, bitsPerPixel: 32,
                                                   bytesPerRow: 800, space: Self.sRGB, alpha: .noneSkipLast,
                                                   bytes: rgba)], as: .png)
            if expectColour {
                try Self.assertPassThrough(data, .colour, rawDecoded: true)
            } else {
                XCTAssertNoThrow(try Self.ready(data))
            }
        }
    }

    /// ヘッダの色モデルがグレー、または不透明な 1 チャンネルの画像は色を数えない。
    /// 数える指定なら色ありになる画像でも、数えない指定では輝度を返す
    func testGrayHeaderNeverCountsColour() throws {
        var rgba = Self.rgba(neutral: [UInt8](repeating: 128, count: 40_000))
        for i in 0..<4_000 { rgba[4 * (i * 9)] = 255 }
        let image = try Self.image(width: 200, height: 200, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 800,
                                   space: Self.sRGB, alpha: .noneSkipLast, bytes: rgba)
        guard case .colour = try PageInput.redrawnLuma(image, mayBeColour: true) else {
            return XCTFail("色を数える指定なのに色ありにならない")
        }
        guard case .luma(let luma, let redraw) = try PageInput.redrawnLuma(image, mayBeColour: false) else {
            return XCTFail("色を数えない指定なのに輝度を返さない")
        }
        XCTAssertNil(redraw, "グレーのソースは描き直しを保たない")
        let weighted: Int = 299 * 255 + 587 * 128 + 114 * 128 + 500
        XCTAssertEqual(luma.bytes[9], UInt8(weighted / 1000))
        XCTAssertEqual(luma.bytes[1], 128)
        let gray = try Self.grayImage(Self.ramp(width: 200, height: 300), width: 200, height: 300)
        XCTAssertTrue(PageInput.isOpaqueOneChannel(gray))
        XCTAssertFalse(PageInput.isOpaqueOneChannel(image))
    }

    /// 色のあるページなどデコードの後に決まる素通しは、ImageIO の同じ呼び出しのデコード結果を渡す
    func testRawIsTheFullDecode() throws {
        var rgba = Self.rgba(neutral: Self.ramp(width: 200, height: 300))
        for i in 0..<(200 * 300) where i % 3 == 0 { rgba[4 * i] = 255 }
        let data = try Self.encode([Self.image(width: 200, height: 300, bitsPerComponent: 8, bitsPerPixel: 32,
                                               bytesPerRow: 800, space: Self.sRGB, alpha: .noneSkipLast,
                                               bytes: rgba)], as: .png)
        guard case .passThrough(.colour, let raw?) = try PrintAppearance.prepare(data, maxPixels: 16_000_000) else {
            return XCTFail("色のあるページがデコード結果付きの素通しにならない")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let expected = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        XCTAssertEqual(raw.width, expected.width)
        XCTAssertEqual(raw.height, expected.height)
        XCTAssertEqual(raw.bitsPerPixel, expected.bitsPerPixel)
        XCTAssertEqual(raw.colorSpace?.name, expected.colorSpace?.name)
        XCTAssertEqual(raw.dataProvider?.data as Data?, expected.dataProvider?.data as Data?)
    }

    // MARK: - 縮小と画像化

    /// 縮小は指定の大きさへ。行は 16 バイト境界、詰め物は 0、一様な値は保たれ、changed を引き継ぐ
    func testReduceToCappedSize() throws {
        let source = try Self.gray(flat: 77, width: 1000, height: 1500, changed: true)
        let reduced = try PrintAppearance.reduce(source, width: 433, height: 650)
        XCTAssertEqual(reduced.width, 433)
        XCTAssertEqual(reduced.height, 650)
        XCTAssertEqual(reduced.bytesPerRow % 16, 0)
        XCTAssertGreaterThanOrEqual(reduced.bytesPerRow, 433)
        XCTAssertTrue(reduced.changed)
        reduced.pixels.withUnsafeBytes { raw in
            for y in 0..<650 {
                for x in 0..<433 where raw[y * reduced.bytesPerRow + x] != 77 {
                    return XCTFail("一様な値が変わった (\(x), \(y))")
                }
                for x in 433..<reduced.bytesPerRow where raw[y * reduced.bytesPerRow + x] != 0 {
                    return XCTFail("行の詰め物が 0 でない")
                }
            }
        }
    }

    /// 縮小は平均の明るさを保つ(高品質の再標本化)
    func testReduceKeepsMeanTone() throws {
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 512, height: 1024), width: 512,
                                           height: 1024)
        let gray = PrintAppearanceGray(copying: page.luma, width: 512, height: 1024, changed: false)
        let reduced = try PrintAppearance.reduce(gray, width: 256, height: 512)
        let before = page.luma.reduce(0.0) { $0 + Double($1) } / Double(page.luma.count)
        var sum = 0.0
        reduced.pixels.withUnsafeBytes { raw in
            for y in 0..<512 { for x in 0..<256 { sum += Double(raw[y * reduced.bytesPerRow + x]) } }
        }
        XCTAssertEqual(sum / Double(256 * 512), before, accuracy: 1.5)
        XCTAssertFalse(reduced.changed)
    }

    func testReduceToSameSizeAndInvalidSize() throws {
        let source = try Self.gray(flat: 10, width: 300, height: 400, changed: false)
        let same = try PrintAppearance.reduce(source, width: 300, height: 400)
        XCTAssertEqual(same.pixels, source.pixels)
        XCTAssertThrowsError(try PrintAppearance.reduce(source, width: 0, height: 400))
    }

    /// 出力は Generic Gray 2.2 の 8 bit 画像として包まれ、バイトはそのまま
    func testGrayImageIsGenericGray22() throws {
        let values = Self.ramp(width: 333, height: 200)
        let gray = PrintAppearanceGray(copying: values, width: 333, height: 200, changed: true)
        let image = try XCTUnwrap(gray.makeImage())
        XCTAssertEqual(image.width, 333)
        XCTAssertEqual(image.height, 200)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 8)
        XCTAssertEqual(image.alphaInfo, .none)
        XCTAssertEqual(image.bytesPerRow, gray.bytesPerRow)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.genericGrayGamma2_2)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        for y in 0..<200 {
            XCTAssertEqual(Array(data[(y * gray.bytesPerRow)..<(y * gray.bytesPerRow + 333)]),
                           Array(values[(y * 333)..<(y * 333 + 333)]))
        }
    }

    // MARK: - 補助

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 0...255 を繰り返す値(画素ごとに異なる)
    private static func ramp(width: Int, height: Int) -> [UInt8] {
        (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 / width) }
    }

    private static func rgba(neutral values: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: values.count * 4)
        for i in 0..<values.count { out[4 * i] = values[i]; out[4 * i + 1] = values[i]; out[4 * i + 2] = values[i] }
        return out
    }

    private static func image(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int,
                              space: CGColorSpace, alpha: CGImageAlphaInfo, bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent,
                                     bitsPerPixel: bitsPerPixel, bytesPerRow: bytesPerRow, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                                     decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func grayImage(_ values: [UInt8], width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        return try image(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                         space: space, alpha: .none, bytes: values)
    }

    private static func rgbImage(neutral values: [UInt8], width: Int, height: Int,
                                 alpha: CGImageAlphaInfo = .noneSkipLast) throws -> CGImage {
        try image(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: sRGB, alpha: alpha, bytes: rgba(neutral: values))
    }

    private static func indexedGrayImage(_ values: [UInt8], width: Int, height: Int) throws -> CGImage {
        var table = [UInt8]()
        for v in 0..<256 { table += [UInt8(v), UInt8(v), UInt8(v)] }
        let space = try XCTUnwrap(CGColorSpace(indexedBaseSpace: sRGB, last: 255, colorTable: table))
        return try image(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                         space: space, alpha: .none, bytes: values)
    }

    private static func grayPNG(width: Int, height: Int) throws -> Data {
        try encode([grayImage(ramp(width: width, height: height), width: width, height: height)], as: .png)
    }

    private static func gray(flat value: UInt8, width: Int, height: Int, changed: Bool) throws -> PrintAppearanceGray {
        PrintAppearanceGray(copying: [UInt8](repeating: value, count: width * height), width: width, height: height,
                            changed: changed)
    }

    private static func encode(_ images: [CGImage], as type: UTType,
                               properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString,
                                                                         images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 合成したファイルのヘッダが想定どおりか
    private static func assertHeader(_ data: Data, depth: Int, model: String, indexed: Bool = false,
                                     hasAlpha: Bool = false, orientation: Int = 1,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1, file: file, line: line)
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((p[kCGImagePropertyDepth] as? NSNumber)?.intValue, depth, "深さ", file: file, line: line)
        XCTAssertEqual(p[kCGImagePropertyColorModel] as? String, model, "色モデル", file: file, line: line)
        XCTAssertEqual((p[kCGImagePropertyIsIndexed] as? NSNumber)?.boolValue ?? false, indexed, "索引色",
                       file: file, line: line)
        XCTAssertEqual((p[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false, hasAlpha, "透明度",
                       file: file, line: line)
        XCTAssertEqual((p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, orientation, "向き",
                       file: file, line: line)
    }

    private static func ready(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws
        -> PrintAppearancePage {
        switch try PrintAppearance.prepare(data, maxPixels: 16_000_000) {
        case .ready(let page):
            XCTAssertEqual(page.luma.count, page.width * page.height, file: file, line: line)
            return page
        case .passThrough(let reason, _):
            XCTFail("処理するはずのページが素通し: \(reason)", file: file, line: line)
            throw PrintAppearanceError.invalidPage("素通しになった")
        }
    }

    private static func assertPassThrough(_ data: Data, _ expected: PrintAppearancePassReason, rawDecoded: Bool,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        switch try PrintAppearance.prepare(data, maxPixels: 16_000_000) {
        case .ready:
            XCTFail("素通しのはずのページを処理する(\(expected))", file: file, line: line)
        case .passThrough(let reason, let raw):
            XCTAssertEqual(reason, expected, file: file, line: line)
            XCTAssertEqual(raw != nil, rawDecoded, "デコード結果の有無", file: file, line: line)
        }
    }

    /// ImageIO がデコードした 1 チャンネルの標本のバイト(行の詰め物を除く)
    private static func decodedGrayBytes(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerPixel, 8)
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        var out = [UInt8]()
        for y in 0..<image.height {
            out += bytes[(y * image.bytesPerRow)..<(y * image.bytesPerRow + image.width)]
        }
        return out
    }
}
