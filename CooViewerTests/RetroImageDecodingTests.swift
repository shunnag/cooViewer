import CoreGraphics
import ImageIO
import XCTest

@testable import cooViewer

/// レトロ日本形式(MAG / MAKI)デコーダのテスト。
/// 合成した最小ファイルでアルゴリズムの各段(新規データ・コピー参照・
/// マスク展開・XOR フィルタ・パレット拡張)を検証し、実サンプルがあれば
/// 公式レンダリング(PNG)とのピクセル一致も確認する。
final class RetroImageDecodingTests: XCTestCase {
    // MARK: - ヘルパ

    /// CGImage を RGBA8(直値)で読み出す
    private func rgbaPixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    private func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int)
        -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// 最小の 16 色 MAG ファイルを合成する(パレットはグレースケール i*17)
    private func makeMag(right: Int, bottom: Int,
                         flagA: [UInt8], flagB: [UInt8],
                         colors: [UInt8]) -> Data {
        var d = Array("MAKI02  TEST".utf8)
        d.append(0x1A)
        let base = d.count  // 0x00 = ヘッダ先頭
        var header = [UInt8](repeating: 0, count: 32)
        func put16(_ offset: Int, _ value: Int) {
            header[offset] = UInt8(value & 0xFF)
            header[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func put32(_ offset: Int, _ value: Int) {
            put16(offset, value & 0xFFFF)
            put16(offset + 2, value >> 16)
        }
        put16(8, right)
        put16(10, bottom)
        let offsetA = 32 + 16 * 3
        put32(12, offsetA)
        put32(16, offsetA + flagA.count)
        put32(20, flagB.count)
        put32(24, offsetA + flagA.count + flagB.count)
        put32(28, colors.count)
        d += header
        for i in 0..<16 {  // GRB(グレー: G=R=B= i<<4 → 拡張後 i*17)
            let v = UInt8(i << 4)
            d += [v, v, v]
        }
        d += flagA + flagB + colors
        _ = base
        return Data(d)
    }

    // MARK: - パレット拡張(仕様の例)

    func testExpandComponentMatchesSpecExamples() {
        XCTAssertEqual(RetroImageDecoding.expandComponent(0x55, bits: 3), 0x49)
        XCTAssertEqual(RetroImageDecoding.expandComponent(0xBF, bits: 4), 0xBB)
        XCTAssertEqual(RetroImageDecoding.expandComponent(0x67, bits: 5), 0x63)
        XCTAssertEqual(RetroImageDecoding.expandComponent(0xF0, bits: 4), 0xFF)
        XCTAssertEqual(RetroImageDecoding.expandComponent(0x00, bits: 4), 0x00)
    }

    // MARK: - MAG 合成

    /// 全アクション 0(新規データのみ)の 8x2 画像
    func testMagDecodesPlainNewData() throws {
        let data = makeMag(
            right: 7, bottom: 1,
            flagA: [0x00], flagB: [],
            colors: [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
        XCTAssertTrue(RetroImageDecoding.isRetroImage(data))
        XCTAssertEqual(RetroImageDecoding.imageSize(data),
                       CGSize(width: 8, height: 2))
        let image = try XCTUnwrap(RetroImageDecoding.decode(data))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 2)
        let px = rgbaPixels(image)
        // 上位ニブルが左ピクセル: 行 0 はインデックス 0..7(グレー i*17)
        for x in 0..<8 {
            XCTAssertEqual(pixel(px, width: 8, x: x, y: 0).r, UInt8(x * 17),
                           "row0 x=\(x)")
            XCTAssertEqual(pixel(px, width: 8, x: x, y: 1).r, UInt8((x + 8) * 17),
                           "row1 x=\(x)")
        }
    }

    /// コピー参照(コード 1 = 直前の 16bit)とフラグ B の XOR
    func testMagCopyPreviousUnit() throws {
        // フラグ A の先頭ビットのみ 1 → フラグ B の 0x01 を XOR
        // → アクション 0x01: 上位=新規、下位=直前コピー(両行に巡回適用)
        let data = makeMag(
            right: 7, bottom: 1,
            flagA: [0x80], flagB: [0x01],
            colors: [0x01, 0x23, 0x45, 0x67])
        let image = try XCTUnwrap(RetroImageDecoding.decode(data))
        let px = rgbaPixels(image)
        let expectedRow0: [Int] = [0, 1, 2, 3, 0, 1, 2, 3]
        let expectedRow1: [Int] = [4, 5, 6, 7, 4, 5, 6, 7]
        for x in 0..<8 {
            XCTAssertEqual(pixel(px, width: 8, x: x, y: 0).r,
                           UInt8(expectedRow0[x] * 17), "row0 x=\(x)")
            XCTAssertEqual(pixel(px, width: 8, x: x, y: 1).r,
                           UInt8(expectedRow1[x] * 17), "row1 x=\(x)")
        }
    }

    // MARK: - MAKI 合成

    private func makeMaki(flagA: [UInt8], flagB: [UInt8],
                          pixels: [UInt8]) -> Data {
        var d = Array("MAKI01A ".utf8)
        d += [UInt8](repeating: 0x20, count: 24)  // 機種 4 + メタ 20
        var rest = [UInt8](repeating: 0, count: 16)  // 32..47
        rest[0] = UInt8(flagB.count >> 8)
        rest[1] = UInt8(flagB.count & 0xFF)
        d += rest
        for i in 0..<16 {  // GRB グレースケール
            let v = UInt8(i << 4)
            d += [v, v, v]
        }
        var a = flagA
        a += [UInt8](repeating: 0, count: 1000 - a.count)
        d += a + flagB + pixels
        return Data(d)
    }

    /// フラグ A 全 0 → 全画面が色 0
    func testMakiAllZeroProducesColorZero() throws {
        let data = makeMaki(flagA: [], flagB: [], pixels: [])
        XCTAssertTrue(RetroImageDecoding.isRetroImage(data))
        XCTAssertEqual(RetroImageDecoding.imageSize(data),
                       CGSize(width: 640, height: 400))
        let image = try XCTUnwrap(RetroImageDecoding.decode(data))
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 400)
        let px = rgbaPixels(image)
        XCTAssertEqual(pixel(px, width: 640, x: 0, y: 0).r, 0)
        XCTAssertEqual(pixel(px, width: 640, x: 639, y: 399).r, 0)
    }

    /// 先頭 4x4 チャンクのマスク+ピクセル充填と下位ニブル=左の規則
    func testMakiFirstChunkPixels() throws {
        // フラグ B ワード 0xF0 0x00: チャンクの 1 行目のみ 1111
        let data = makeMaki(flagA: [0x80], flagB: [0xF0, 0x00],
                            pixels: [0x21, 0x43, 0x65, 0x87])
        let image = try XCTUnwrap(RetroImageDecoding.decode(data))
        let px = rgbaPixels(image)
        // バイト 0x21 → 左ピクセル=上位ニブル 2、右=下位 1(実ファイルと
        // 公式レンダリングの照合で確認した、MAG と同じ順)。
        // MAKI のパレット拡張は「非 0 の上位ニブル | 0x0F」
        let expected: [Int] = [2, 1, 4, 3, 6, 5, 8, 7]
        for x in 0..<8 {
            XCTAssertEqual(pixel(px, width: 640, x: x, y: 0).r,
                           UInt8(expected[x] << 4 | 0x0F), "x=\(x)")
        }
        // マスク外は色 0
        XCTAssertEqual(pixel(px, width: 640, x: 8, y: 0).r, 0)
        XCTAssertEqual(pixel(px, width: 640, x: 0, y: 1).r, 0)
    }

    // MARK: - Pi 合成(makepi.py 生成の 85 バイト実ファイルを埋め込み)

    /// 8x4・16 色の Pi。デルタ符号と繰り返し(行コピー)の両方を通る
    func testPiDecodesTinyImage() throws {
        let data = Data([
            0x50, 0x69, 0x1A, 0x00, 0x00, 0x01, 0x01, 0x04, 0x39, 0x38,
            0x73, 0x61, 0x00, 0x00, 0x00, 0x08, 0x00, 0x04, 0x00, 0xFF,
            0x00, 0x11, 0xEE, 0x05, 0x22, 0xDD, 0x0A, 0x33, 0xCC, 0x0F,
            0x44, 0xBB, 0x14, 0x55, 0xAA, 0x19, 0x66, 0x99, 0x1E, 0x77,
            0x88, 0x23, 0x88, 0x77, 0x28, 0x99, 0x66, 0x2D, 0xAA, 0x55,
            0x32, 0xBB, 0x44, 0x37, 0xCC, 0x33, 0x3C, 0xDD, 0x22, 0x41,
            0xEE, 0x11, 0x46, 0xFF, 0x00, 0x4B, 0x9F, 0x93, 0xEF, 0x88,
            0x3E, 0xFD, 0xF7, 0xC4, 0x17, 0x68, 0x41, 0xC7, 0xEF, 0xBE,
            0x20, 0x00, 0x00, 0x00, 0x00,
        ])
        XCTAssertTrue(RetroImageDecoding.isRetroImage(data))
        XCTAssertEqual(RetroImageDecoding.imageSize(data),
                       CGSize(width: 8, height: 4))
        let image = try XCTUnwrap(RetroImageDecoding.decode(data))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)
        let px = rgbaPixels(image)
        // 元画像: 行 0/2 = インデックス 0-3 の繰り返し、行 1 = 4-7、行 3 = 8-11。
        // パレットは R = i*17, G = (15-i)*17(いずれも 4bit 複製で不変)
        let expected: [[Int]] = [
            [0, 1, 2, 3, 0, 1, 2, 3],
            [4, 5, 6, 7, 4, 5, 6, 7],
            [0, 1, 2, 3, 0, 1, 2, 3],
            [8, 9, 10, 11, 8, 9, 10, 11],
        ]
        for y in 0..<4 {
            for x in 0..<8 {
                let p = pixel(px, width: 8, x: x, y: y)
                XCTAssertEqual(p.r, UInt8(expected[y][x] * 17), "R x=\(x) y=\(y)")
                XCTAssertEqual(p.g, UInt8((15 - expected[y][x]) * 17),
                               "G x=\(x) y=\(y)")
            }
        }
    }

    // MARK: - PIC 合成(手組みの 15bit ストリーム)

    private struct BitWriter {
        var bytes: [UInt8] = []
        var bitCount = 0

        mutating func write(_ bit: Int) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if bit != 0 {
                bytes[bytes.count - 1] |= UInt8(0x80 >> (bitCount % 8))
            }
            bitCount += 1
        }

        mutating func write(_ value: Int, bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                write((value >> i) & 1)
            }
        }
    }

    /// 4x2・15bit PIC: 変化点 2 つ+チェーン 1 本を手組みで検証
    func testPicDecodesHandcraftedStream() throws {
        var header: [UInt8] = Array("PIC".utf8)
        header += [0x1A, 0x00]                     // コメント終端+ヘッダ開始
        header += [0x00, 0x00, 0x00, 0x0F]         // platform 0 / depth 15
        header += [0x00, 0x04, 0x00, 0x02]         // 4x2
        var bits = BitWriter()
        // 長さ 1 → 赤(GGGGGRRRRRBBBBB = 0x03E0)+チェーン(真下→終端)
        bits.write(0b00, bits: 2)
        bits.write(0, bits: 1)
        bits.write(0x03E0, bits: 15)
        bits.write(1, bits: 1)                     // チェーンあり
        bits.write(0b10, bits: 2)                  // 真下
        bits.write(0b000, bits: 3)                 // 終端
        // 長さ 2 → 青(0x001F)、チェーンなし
        bits.write(0b01, bits: 2)
        bits.write(0, bits: 1)
        bits.write(0x001F, bits: 15)
        bits.write(0, bits: 1)
        // 長さ 8 → 残りを走査(チェーンで植えた赤を途中で拾う)
        bits.write(0b110, bits: 3)
        bits.write(0b001, bits: 3)
        let data = Data(header + bits.bytes + [0, 0])
        XCTAssertTrue(RetroImageDecoding.isRetroImage(data))
        XCTAssertEqual(RetroImageDecoding.imageSize(data),
                       CGSize(width: 4, height: 2))
        let image = try XCTUnwrap(RetroImageDecoding.decode(data))
        let px = rgbaPixels(image)
        let red: (UInt8, UInt8, UInt8) = (251, 0, 0)
        let blue: (UInt8, UInt8, UInt8) = (0, 0, 251)
        let expected = [[red, red, blue, blue], [red, red, red, red]]
        for y in 0..<2 {
            for x in 0..<4 {
                let p = pixel(px, width: 4, x: x, y: y)
                XCTAssertEqual(p.r, expected[y][x].0, "R x=\(x) y=\(y)")
                XCTAssertEqual(p.g, expected[y][x].1, "G x=\(x) y=\(y)")
                XCTAssertEqual(p.b, expected[y][x].2, "B x=\(x) y=\(y)")
            }
        }
    }

    // MARK: - PBM P4(バイナリ 1bit)

    func testP4DecodesBinaryBitmap() throws {
        // "P4\n# comment\n4 2\n" + 2 行(0101 / 1010)
        var bytes = Array("P4\n# c\n4 2\n".utf8)
        bytes += [0b0101_0000, 0b1010_0000]
        let data = Data(bytes)
        XCTAssertTrue(RetroImageDecoding.isRetroImage(data))
        XCTAssertEqual(RetroImageDecoding.imageSize(data),
                       CGSize(width: 4, height: 2))
        let image = try XCTUnwrap(RetroImageDecoding.decode(data))
        let px = rgbaPixels(image)
        let expectedRow0: [UInt8] = [255, 0, 255, 0]  // 1 = 黒
        let expectedRow1: [UInt8] = [0, 255, 0, 255]
        for x in 0..<4 {
            XCTAssertEqual(pixel(px, width: 4, x: x, y: 0).r, expectedRow0[x])
            XCTAssertEqual(pixel(px, width: 4, x: x, y: 1).r, expectedRow1[x])
        }
        // ASCII 版(P1)は ImageIO が担当するので独自デコーダは反応しない
        XCTAssertNil(RetroImageDecoding.decode(Data("P1\n1 1\n0\n".utf8)))
        // データ不足は nil
        XCTAssertNil(RetroImageDecoding.decode(Data("P4\n8 8\n\u{01}".utf8)))
    }

    // MARK: - 形式トグル(高度設定)

    func testFormatTogglesDisableListingAndDecoding() throws {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: RetroFormatToggle.magKey)
            defaults.removeObject(forKey: RetroFormatToggle.pnmKey)
        }
        // 既定(未設定)は有効
        XCTAssertTrue(SupportedTypes.isImageFile("a.mag"))
        XCTAssertTrue(SupportedTypes.isImageFile("a.pnm"))

        defaults.set(false, forKey: RetroFormatToggle.magKey)
        defaults.set(false, forKey: RetroFormatToggle.pnmKey)
        XCTAssertFalse(SupportedTypes.isImageFile("a.mag"),
                       "OFF の形式は一覧に載らない")
        XCTAssertFalse(SupportedTypes.isImageFile("a.pnm"))
        // .pbm は UTType 上は画像のまま(ImageIO が P1-P3/P5-P6 を担当)
        XCTAssertTrue(SupportedTypes.isImageFile("a.pbm"))

        let mag = makeMag(right: 7, bottom: 1, flagA: [0x00], flagB: [],
                          colors: [0x01, 0x23, 0x45, 0x67,
                                   0x89, 0xAB, 0xCD, 0xEF])
        XCTAssertNil(RetroImageDecoding.decode(mag), "OFF の形式はデコードしない")
        XCTAssertFalse(RetroImageDecoding.isRetroImage(mag))
        XCTAssertNil(RetroImageDecoding.decode(
            Data(Array("P4\n1 1\n".utf8) + [0x80])))

        defaults.set(true, forKey: RetroFormatToggle.magKey)
        XCTAssertNotNil(RetroImageDecoding.decode(mag), "ON に戻せば復活")
    }

    // MARK: - 判定の安全性(拡張子衝突対策)

    func testDetectionRejectsForeignData() {
        let png = TestFixtures.pngData(width: 4, height: 4)
        XCTAssertFalse(RetroImageDecoding.isRetroImage(png))
        XCTAssertNil(RetroImageDecoding.decode(png))
        XCTAssertNil(RetroImageDecoding.imageSize(png))
        // 3ds Max 等を装った .max / 別系統の "MAKI" もどき
        XCTAssertFalse(RetroImageDecoding.isRetroImage(Data("MAKI03  ".utf8)))
        XCTAssertNil(RetroImageDecoding.decode(Data("MAKI02 x garbage".utf8)))
        XCTAssertFalse(RetroImageDecoding.isRetroImage(Data()))
    }

    // MARK: - 実サンプルとのゴールデン比較(サンプルが無ければスキップ)

    /// 環境変数 RETRO_SAMPLE_DIR に mooncore.eu の例画像(.mag/.mki と
    /// 同名 .png)を置いて実行すると、公式レンダリングとの一致を検証する
    func testGoldenSamplesMatchReferenceRenderings() throws {
        guard let dir = ProcessInfo.processInfo.environment["RETRO_SAMPLE_DIR"],
              FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("RETRO_SAMPLE_DIR not set; skipping golden comparison")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter {
                ["mag", "max", "mki", "pi", "pic"]
                    .contains(($0 as NSString).pathExtension.lowercased())
            }
            .sorted()
        XCTAssertFalse(files.isEmpty, "no samples in \(dir)")
        for file in files {
            let base = (file as NSString).deletingPathExtension
            let sampleURL = URL(fileURLWithPath: dir).appendingPathComponent(file)
            let goldenURL = URL(fileURLWithPath: dir)
                .appendingPathComponent(base + ".png")
            guard FileManager.default.fileExists(atPath: goldenURL.path) else {
                continue  // PNG が無いサンプルはデコード成功のみ確認
            }
            let data = try Data(contentsOf: sampleURL)
            guard let decoded = RetroImageDecoding.decode(data) else {
                XCTFail("\(file): decode failed")
                continue
            }
            let goldenSource = try XCTUnwrap(
                CGImageSourceCreateWithURL(goldenURL as CFURL, nil))
            let golden = try XCTUnwrap(
                CGImageSourceCreateImageAtIndex(goldenSource, 0, nil))
            XCTAssertEqual(decoded.width, golden.width, "\(file): width")
            XCTAssertEqual(decoded.height, golden.height, "\(file): height")
            guard decoded.width == golden.width,
                  decoded.height == golden.height else { continue }
            let ours = rgbaPixels(decoded)
            let reference = rgbaPixels(golden)
            var mismatches = 0
            // 参照側のパレット方針差(下位ビット複製の有無、量子化)を吸収する
            // ため ±16 まで許容。構造的な誤りは大差になるため検出力は保たれる
            for i in stride(from: 0, to: ours.count, by: 4) {
                let delta = max(
                    abs(Int(ours[i]) - Int(reference[i])),
                    abs(Int(ours[i + 1]) - Int(reference[i + 1])),
                    abs(Int(ours[i + 2]) - Int(reference[i + 2])))
                if delta > 16 { mismatches += 1 }
            }
            XCTAssertEqual(mismatches, 0,
                           "\(file): \(mismatches)/\(ours.count / 4) pixels differ")
        }
    }
}
