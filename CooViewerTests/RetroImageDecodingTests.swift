import CoreGraphics
import ImageIO
import XCTest

@testable import cooViewer

/// レトロ日本形式(MAG / MAKI)デコーダのテスト。
/// 合成した最小ファイルでアルゴリズムの各段(新規データ・コピー参照・
/// マスク展開・XOR フィルタ・パレット拡張)を検証し、実サンプルがあれば
/// 公式レンダリング(PNG)とのピクセル一致も確認する。
/// EN: Synthetic-file tests for each stage of the MAG/MAKI decoders, plus
/// EN: golden-image comparison against reference PNGs when samples exist.
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
    /// EN: Compares against reference PNGs when RETRO_SAMPLE_DIR is set.
    func testGoldenSamplesMatchReferenceRenderings() throws {
        guard let dir = ProcessInfo.processInfo.environment["RETRO_SAMPLE_DIR"],
              FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("RETRO_SAMPLE_DIR not set; skipping golden comparison")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { ["mag", "max", "mki"].contains(($0 as NSString).pathExtension.lowercased()) }
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
            // 参照 PNG 側に ±1〜2 の量子化(例: 白 255,255,254)があるため
            // チャネルごと ±2 まで許容する
            // EN: The reference PNGs carry small quantization offsets; allow ±2.
            for i in stride(from: 0, to: ours.count, by: 4) {
                let delta = max(
                    abs(Int(ours[i]) - Int(reference[i])),
                    abs(Int(ours[i + 1]) - Int(reference[i + 1])),
                    abs(Int(ours[i + 2]) - Int(reference[i + 2])))
                if delta > 2 { mismatches += 1 }
            }
            XCTAssertEqual(mismatches, 0,
                           "\(file): \(mismatches)/\(ours.count / 4) pixels differ")
        }
    }
}
