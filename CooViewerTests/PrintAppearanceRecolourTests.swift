import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PrintAppearanceKit

/// 完成画像の色の検査(設計書 §5): 網点処理が変えるのは明るさだけで、ファイルの色は保つ。
/// 1 チャンネルのグレーのソースはグレーの L'、RGB のソースは sRGB の描き直しに d = L' - L を足した RGB。
/// 画像はすべてテストの中で合成する。L' は CPU の厳密な経路のエンジンで作る(GPU に依存しない)
final class PrintAppearanceRecolourTests: XCTestCase {

    // MARK: - どちらの経路か

    /// 1 チャンネルのグレーのソース(Generic Gray 2.2、名前の付かないグレー、不透明なグレー + 透明度)は
    /// 描き直しを持たず、完成画像はエンジンの出力そのもののグレー
    func testGraySourcesTakeTheGrayPath() throws {
        let values = PrintAppearanceTestPages.screen(width: 300, height: 420, period: 4, angle: 45)
        let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearGray))
        var grayAlpha = [UInt8](repeating: 255, count: values.count * 2)
        for i in 0..<values.count { grayAlpha[2 * i] = values[i] }
        let files: [(String, Data)] = [
            ("Generic Gray 2.2", try Self.encode(Self.image(width: 300, height: 420, bitsPerPixel: 8,
                                                            space: Self.gray, alpha: .none, bytes: values))),
            ("名前の付かないグレー", try Self.encode(Self.image(width: 300, height: 420, bitsPerPixel: 8,
                                                         space: linear, alpha: .none, bytes: values))),
            ("グレー + 透明度", try Self.encode(Self.image(width: 300, height: 420, bitsPerPixel: 16,
                                                     space: Self.gray, alpha: .last, bytes: grayAlpha))),
        ]
        for (name, data) in files {
            let page = try Self.ready(data)
            XCTAssertFalse(page.keepsColour, name)
            XCTAssertNil(page.redraw, name)
            let processed = try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: .standard, threads: 4)
            guard case .gray(let gray) = try PrintAppearance.recolour(page, processed: processed) else {
                return XCTFail("\(name): グレーの経路にならない")
            }
            XCTAssertEqual(gray.pixels, processed.pixels, name)
            XCTAssertEqual(gray.changed, processed.changed, name)
        }
    }

    /// RGB のソース(RGB の PNG と JPEG、不透明な RGBA、索引色)は描き直しを持つ。持つのは輝度を求めたのと
    /// 同じ sRGB の描き直しで、輝度はその Y
    func testRGBSourcesKeepTheRedrawTheLumaCameFrom() throws {
        let values = PrintAppearanceTestPages.screen(width: 300, height: 420, period: 4, angle: 45)
        let tinted = PrintAppearanceTestPages.tinted(values, ink: PrintAppearanceTestPages.purpleInk,
                                                     paper: PrintAppearanceTestPages.whitePaper)
        var table = [UInt8]()
        for v in 0..<256 { table += [UInt8(v), UInt8(v), UInt8(v)] }
        let indexed = try XCTUnwrap(CGColorSpace(indexedBaseSpace: Self.sRGB, last: 255, colorTable: table))
        let files: [(String, Data)] = [
            ("RGB の PNG", try Self.encode(Self.rgbImage(tinted, width: 300, height: 420))),
            ("RGB の JPEG", try Self.encode(Self.rgbImage(tinted, width: 300, height: 420), as: .jpeg)),
            ("RGBA の PNG", try Self.encode(Self.image(width: 300, height: 420, bitsPerPixel: 32, space: Self.sRGB,
                                                      alpha: .premultipliedLast, bytes: tinted))),
            ("索引色の PNG", try Self.encode(Self.image(width: 300, height: 420, bitsPerPixel: 8, space: indexed,
                                                     alpha: .none, bytes: values))),
        ]
        for (name, data) in files {
            let page = try Self.ready(data)
            XCTAssertTrue(page.keepsColour, name)
            let redraw = try XCTUnwrap(page.redraw, name)
            let expected = try Self.independentRedraw(data)
            XCTAssertEqual(Self.rgb(redraw), expected, "\(name): 描き直しのバイト")
            for i in 0..<page.luma.count {
                let p = 3 * i
                guard Int(page.luma[i]) == Self.luma(expected[p], expected[p + 1], expected[p + 2]) else {
                    return XCTFail("\(name): 輝度が描き直しの Y と違う (\(i))")
                }
            }
        }
    }

    // MARK: - 色を戻す規則

    /// どのチャンネルも収める必要のない画素では Y(出力) == L'、L' == L の画素は描き直しのまま、
    /// 4 番目の欄は 255、行の詰め物は 0
    func testOutputLuminanceIsTheEngineOutput() throws {
        let (page, processed, output) = try Self.processTinted(ink: PrintAppearanceTestPages.purpleInk,
                                                               paper: PrintAppearanceTestPages.whitePaper)
        let redraw = try XCTUnwrap(page.redraw)
        let source = Self.rgb(redraw)
        let after = Self.bytes(processed)
        let out = Self.rgb(output)
        var unclipped = 0, moved = 0, same = 0
        for i in 0..<page.luma.count {
            let d = Int(after[i]) - Int(page.luma[i])
            let s = (Int(source[3 * i]), Int(source[3 * i + 1]), Int(source[3 * i + 2]))
            let o = (out[3 * i], out[3 * i + 1], out[3 * i + 2])
            if d == 0 {
                same += 1
                guard o == (UInt8(s.0), UInt8(s.1), UInt8(s.2)) else { return XCTFail("L' == L なのに描き直しと違う (\(i))") }
            }
            guard Self.inRange(s.0 + d), Self.inRange(s.1 + d), Self.inRange(s.2 + d) else { continue }
            unclipped += 1
            if d != 0 { moved += 1 }
            guard Self.luma(o.0, o.1, o.2) == Int(after[i]) else {
                return XCTFail("Y(出力) が L' と違う (\(i)): \(o) d \(d) L' \(after[i])")
            }
        }
        let total = page.luma.count
        XCTAssertGreaterThan(moved, total / 3, "輝度を変えた画素が少なすぎる(検査が空回りする)")
        XCTAssertGreaterThan(unclipped, total * 9 / 10)
        XCTAssertGreaterThan(same, 0)
        try Self.assertPaddingAndFourthByte(output)
    }

    /// R = G = B の RGB のページは R = G = B = L'(グレーの出力と同じ階調)
    func testNeutralRGBPageGivesEqualChannels() throws {
        let values = PrintAppearanceTestPages.screen(width: 1024, height: 1536, period: 4, angle: 45)
        let data = try Self.encode(Self.rgbImage(Self.neutral(values), width: 1024, height: 1536))
        let page = try Self.ready(data)
        XCTAssertTrue(page.keepsColour)
        XCTAssertEqual(page.luma, values)
        let processed = try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: .standard, threads: 4)
        let after = Self.bytes(processed)
        XCTAssertGreaterThan(zip(after, values).count(where: { $0 != $1 }), values.count / 3)
        guard case .rgb(let output) = try PrintAppearance.recolour(page, processed: processed) else {
            return XCTFail("RGB のソースが RGB にならない")
        }
        let out = Self.rgb(output)
        for i in 0..<values.count where out[3 * i] != after[i] || out[3 * i + 1] != after[i] || out[3 * i + 2] != after[i] {
            return XCTFail("R = G = B = L' にならない (\(i))")
        }
        XCTAssertTrue(output.changed)
    }

    /// 紫の 1 色刷り(色ありの画素が 0.5% 未満)とクリーム色の紙のページは、細かい網点がまとまっても
    /// 各画素のチャンネルの差(R - G、G - B)を保つ。0〜255 に収めた画素だけは除く
    func testTintedPagesKeepTheirChannelDifferences() throws {
        let pages: [(String, [UInt8], [UInt8], Bool)] = [
            ("紫の 1 色刷り", PrintAppearanceTestPages.purpleInk, PrintAppearanceTestPages.whitePaper, true),
            ("クリーム色の紙", PrintAppearanceTestPages.blackInk, PrintAppearanceTestPages.creamPaper, false),
        ]
        for (name, ink, paper, accent) in pages {
            let (page, processed, output) = try Self.processTinted(ink: ink, paper: paper, accent: accent)
            let source = Self.rgb(try XCTUnwrap(page.redraw))
            let after = Self.bytes(processed)
            let out = Self.rgb(output)
            var clipped = 0, moved = 0, tinted = 0
            for i in 0..<page.luma.count {
                let d = Int(after[i]) - Int(page.luma[i])
                let s = (Int(source[3 * i]), Int(source[3 * i + 1]), Int(source[3 * i + 2]))
                guard Self.inRange(s.0 + d), Self.inRange(s.1 + d), Self.inRange(s.2 + d) else {
                    clipped += 1
                    continue
                }
                if d != 0 { moved += 1 }
                if s.0 != s.1 || s.1 != s.2 { tinted += 1 }
                let o = (Int(out[3 * i]), Int(out[3 * i + 1]), Int(out[3 * i + 2]))
                guard o.0 - o.1 == s.0 - s.1, o.1 - o.2 == s.1 - s.2 else {
                    return XCTFail("\(name): チャンネルの差が変わった (\(i)): \(s) → \(o)")
                }
            }
            let total = page.luma.count
            XCTAssertGreaterThan(moved, total / 3, "\(name): 輝度を変えた画素が少なすぎる")
            XCTAssertGreaterThan(tinted, total * 9 / 10, "\(name): 色のついた画素が少なすぎる")
            XCTAssertLessThan(clipped, total / 20, "\(name): 収めた画素が多すぎる")
        }
    }

    /// 処理結果の大きさがページと違えば投げる
    func testRecolourRejectsAMismatchedSize() throws {
        let values = PrintAppearanceTestPages.flat(width: 200, height: 300, value: 128)
        let page = try Self.ready(try Self.encode(Self.rgbImage(Self.neutral(values), width: 200, height: 300)))
        let other = PrintAppearanceGray(copying: values, width: 300, height: 200, changed: false)
        XCTAssertThrowsError(try PrintAppearance.recolour(page, processed: other))
    }

    // MARK: - 縮小と画像化

    /// RGB の縮小は、各チャンネルにグレーの縮小をかけたのと同じバイト。4 番目の欄は 255、詰め物は 0、
    /// changed を引き継ぐ。同じ大きさなら入力のまま、不正な大きさは投げる
    func testRGBReduceEqualsTheGrayReducePerChannel() throws {
        let width = 1000, height = 1500, toWidth = 433, toHeight = 650
        var rng = SplitMix64(seed: 11)
        let rowBytes = PrintAppearanceRGB.alignedRowBytes(width)
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * height), count: 3)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 {
                    let v = UInt8(truncatingIfNeeded: rng.next() >> (8 * UInt64(c)))
                    bytes[y * rowBytes + 4 * x + c] = v
                    planes[c][y * width + x] = v
                }
                bytes[y * rowBytes + 4 * x + 3] = 255
            }
        }
        let rgb = PrintAppearanceRGB(width: width, height: height, bytesPerRow: rowBytes, pixels: Data(bytes),
                                     changed: true)
        let reduced = try PrintAppearance.reduce(rgb, width: toWidth, height: toHeight)
        XCTAssertEqual(reduced.width, toWidth)
        XCTAssertEqual(reduced.height, toHeight)
        XCTAssertEqual(reduced.bytesPerRow % 16, 0)
        XCTAssertTrue(reduced.changed)
        try Self.assertPaddingAndFourthByte(reduced)
        let out = Self.rgb(reduced)
        for c in 0..<3 {
            let plane = PrintAppearanceGray(copying: planes[c], width: width, height: height, changed: true)
            let expected = Self.bytes(try PrintAppearance.reduce(plane, width: toWidth, height: toHeight))
            for i in 0..<expected.count where out[3 * i + c] != expected[i] {
                return XCTFail("チャンネル \(c) がグレーの縮小と違う (\(i))")
            }
        }
        XCTAssertEqual(try PrintAppearance.reduce(rgb, width: width, height: height).pixels, rgb.pixels)
        XCTAssertThrowsError(try PrintAppearance.reduce(rgb, width: 0, height: 10))
    }

    /// RGB の完成画像は sRGB の 8 bit(4 番目は使わない)として包まれ、バイトはそのまま
    func testRGBImageIsSRGB() throws {
        let (_, _, output) = try Self.processTinted(ink: PrintAppearanceTestPages.blackInk,
                                                    paper: PrintAppearanceTestPages.creamPaper)
        let image = try XCTUnwrap(output.makeImage())
        XCTAssertEqual(image.width, output.width)
        XCTAssertEqual(image.height, output.height)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 32)
        XCTAssertEqual(image.alphaInfo, .noneSkipLast)
        XCTAssertEqual(image.bytesPerRow, output.bytesPerRow)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(image.dataProvider?.data as Data?, output.pixels)
        guard case .rgb = try PrintAppearance.reduce(PrintAppearanceOutput.rgb(output), width: 300, height: 450) else {
            return XCTFail("RGB の縮小が RGB にならない")
        }
    }

    // MARK: - 補助

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!

    /// 細かい網点(高さ 1536 px で周期 4 px)を 2 色で刷った RGB の PNG を、prepare・CPU の経路・recolour に通す。
    /// accent なら濃い紫の 1 行(色ありの画素、全体の 0.5% 未満)を加える
    private static func processTinted(ink: [UInt8], paper: [UInt8], accent: Bool = false) throws
        -> (PrintAppearancePage, PrintAppearanceGray, PrintAppearanceRGB) {
        let width = 1024, height = 1536
        let values = PrintAppearanceTestPages.screen(width: width, height: height, period: 4, angle: 45)
        var bytes = PrintAppearanceTestPages.tinted(values, ink: ink, paper: paper)
        if accent {
            for x in 0..<width {
                let i = 4 * (height / 3 * width + x)
                bytes[i] = 90
                bytes[i + 1] = 30
                bytes[i + 2] = 120
            }
        }
        let page = try ready(try encode(rgbImage(bytes, width: width, height: height)))
        XCTAssertTrue(page.keepsColour)
        let source = rgb(try XCTUnwrap(page.redraw))
        var expectedSource = [UInt8](repeating: 0, count: width * height * 3)
        var colourPixels = 0
        for i in 0..<(width * height) {
            let r = bytes[4 * i], g = bytes[4 * i + 1], b = bytes[4 * i + 2]
            expectedSource[3 * i] = r
            expectedSource[3 * i + 1] = g
            expectedSource[3 * i + 2] = b
            if Int(max(r, g, b)) - Int(min(r, g, b)) >= 32 { colourPixels += 1 }
        }
        XCTAssertEqual(source, expectedSource, "sRGB の PNG の描き直しはファイルの値そのもの")
        XCTAssertLessThanOrEqual(Double(colourPixels) / Double(width * height), 0.005)
        XCTAssertEqual(colourPixels > 0, accent)
        let processed = try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: .standard, threads: 4)
        guard case .rgb(let output) = try PrintAppearance.recolour(page, processed: processed) else {
            XCTFail("RGB のソースが RGB にならない")
            throw PrintAppearanceError.invalidPage("グレーになった")
        }
        XCTAssertEqual(output.width, width)
        XCTAssertEqual(output.height, height)
        XCTAssertEqual(output.changed, processed.changed)
        return (page, processed, output)
    }

    private static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        (299 * Int(r) + 587 * Int(g) + 114 * Int(b) + 500) / 1000
    }

    private static func inRange(_ v: Int) -> Bool { (0...255).contains(v) }

    private static func neutral(_ values: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: values.count * 4)
        for i in 0..<values.count { out[4 * i] = values[i]; out[4 * i + 1] = values[i]; out[4 * i + 2] = values[i] }
        return out
    }

    /// 描き直しの R, G, B(詰め物と 4 番目を除く)
    private static func rgb(_ redraw: SRGBRedraw) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: redraw.width * redraw.height * 3)
        for y in 0..<redraw.height {
            let row = redraw.base + y * redraw.bytesPerRow
            for x in 0..<redraw.width {
                let o = 3 * (y * redraw.width + x)
                out[o] = row[4 * x]
                out[o + 1] = row[4 * x + 1]
                out[o + 2] = row[4 * x + 2]
            }
        }
        return out
    }

    /// 完成画像の R, G, B(詰め物と 4 番目を除く)
    private static func rgb(_ page: PrintAppearanceRGB) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: page.width * page.height * 3)
        page.pixels.withUnsafeBytes { raw in
            for y in 0..<page.height {
                for x in 0..<page.width {
                    let i = y * page.bytesPerRow + 4 * x, o = 3 * (y * page.width + x)
                    out[o] = raw[i]
                    out[o + 1] = raw[i + 1]
                    out[o + 2] = raw[i + 2]
                }
            }
        }
        return out
    }

    private static func bytes(_ gray: PrintAppearanceGray) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(gray.width * gray.height)
        gray.pixels.withUnsafeBytes { raw in
            for y in 0..<gray.height { out += raw[(y * gray.bytesPerRow)..<(y * gray.bytesPerRow + gray.width)] }
        }
        return out
    }

    private static func assertPaddingAndFourthByte(_ page: PrintAppearanceRGB, file: StaticString = #filePath,
                                                   line: UInt = #line) throws {
        try page.pixels.withUnsafeBytes { raw in
            for y in 0..<page.height {
                let row = y * page.bytesPerRow
                for x in 0..<page.width where raw[row + 4 * x + 3] != 255 {
                    return XCTFail("4 番目の欄が 255 でない (\(x), \(y))", file: file, line: line)
                }
                for i in (4 * page.width)..<page.bytesPerRow where raw[row + i] != 0 {
                    return XCTFail("行の詰め物が 0 でない", file: file, line: line)
                }
            }
            if page.pixels.count != page.bytesPerRow * page.height {
                throw PrintAppearanceError.invalidPage("バイト数")
            }
        }
    }

    /// ImageIO の同じデコードを、別に作った sRGB RGBA(premultipliedLast)の文脈へ描いた R, G, B
    private static func independentRedraw(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let base = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        var out = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for y in 0..<image.height {
            let row = base + y * context.bytesPerRow
            for x in 0..<image.width {
                let o = 3 * (y * image.width + x)
                out[o] = row[4 * x]
                out[o + 1] = row[4 * x + 1]
                out[o + 2] = row[4 * x + 2]
            }
        }
        return out
    }

    private static func ready(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws
        -> PrintAppearancePage {
        switch try PrintAppearance.prepare(data, maxPixels: 16_000_000) {
        case .ready(let page):
            return page
        case .passThrough(let reason, _):
            XCTFail("処理するはずのページが素通し: \(reason)", file: file, line: line)
            throw PrintAppearanceError.invalidPage("素通しになった")
        }
    }

    private static func image(width: Int, height: Int, bitsPerPixel: Int, space: CGColorSpace,
                              alpha: CGImageAlphaInfo, bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: bitsPerPixel,
                                     bytesPerRow: width * bitsPerPixel / 8, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                                     decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// sRGB の RGBX(4 番目は使わない)
    private static func rgbImage(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        try image(width: width, height: height, bitsPerPixel: 32, space: sRGB, alpha: .noneSkipLast, bytes: bytes)
    }

    private static func encode(_ image: CGImage, as type: UTType = .png) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
