import CoreGraphics
import XCTest
@testable import cooViewer

/// 圧縮ノイズ低減(NoiseReducer / ImageResampler 統合)のテスト
final class NoiseReductionTests: XCTestCase {
    /// 8×8 ブロックごとに明度がわずかに揺れる「ブロックノイズ風」画像。
    /// 実際の JPEG ノイズと同様、段差は小振幅(±2% 程度)にする
    /// (大きな段差は「本物のエッジ」として保存・鮮鋭化されてしまう)
    private func blockyImage(size: Int = 64, block: Int = 8) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt64 = 0x1234_5678
        for by in stride(from: 0, to: size, by: block) {
            for bx in stride(from: 0, to: size, by: block) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let gray = CGFloat(0.48 + Double(seed % 100) / 2500.0)
                context.setFillColor(CGColor(gray: gray, alpha: 1))
                context.fill(CGRect(x: bx, y: by, width: block, height: block))
            }
        }
        return context.makeImage()!
    }

    /// ブロック境界(8 の倍数の列)をまたぐ隣接ピクセルの平均輝度差
    private func boundaryContrast(_ image: CGImage) -> Double {
        let data = image.dataProvider!.data! as Data
        let bytesPerRow = image.bytesPerRow
        let pixelBytes = image.bitsPerPixel / 8
        var total = 0.0
        var count = 0
        for y in 0..<image.height {
            for x in stride(from: 8, to: image.width, by: 8) {
                let left = Int(data[y * bytesPerRow + (x - 1) * pixelBytes])
                let right = Int(data[y * bytesPerRow + x * pixelBytes])
                total += Double(abs(left - right))
                count += 1
            }
        }
        return total / Double(count)
    }

    func testMediumReductionSoftensBlockBoundaries() throws {
        guard let reducer = NoiseReducer() else {
            throw XCTSkip("Metal が使えない環境")
        }
        let source = blockyImage()
        let before = boundaryContrast(source)
        let reduced = try XCTUnwrap(reducer.reduce(source, level: .medium))
        XCTAssertEqual(reduced.width, source.width)
        XCTAssertEqual(reduced.height, source.height)
        let after = boundaryContrast(reduced)
        XCTAssertLessThan(after, before * 0.9,
            "ブロック境界の段差が下がるはず(前 \(before) 後 \(after))")
    }

    func testLightIsGentlerThanMedium() throws {
        // 弱(旧弱と旧強の中間)は中より段差の残りが多い=弱い
        guard let reducer = NoiseReducer() else {
            throw XCTSkip("Metal が使えない環境")
        }
        let source = blockyImage()
        let light = boundaryContrast(
            try XCTUnwrap(reducer.reduce(source, level: .light)))
        let medium = boundaryContrast(
            try XCTUnwrap(reducer.reduce(source, level: .medium)))
        XCTAssertGreaterThan(light, medium)
    }

    func testMLTileOriginsCoverImage() {
        // 128 で割り切れないサイズも端まで覆う
        let origins = MLNoiseReducer.tileOrigins(width: 300, height: 130)
        XCTAssertEqual(origins.count, 6)  // 3 列 × 2 行
        XCTAssertTrue(origins.contains { $0.x == 256 && $0.y == 128 })
        XCTAssertEqual(MLNoiseReducer.tileOrigins(width: 128, height: 128).count, 1)
        XCTAssertTrue(MLNoiseReducer.tileOrigins(width: 0, height: 100).isEmpty)
    }

    func testNoneLevelReturnsOriginal() throws {
        guard let reducer = NoiseReducer() else {
            throw XCTSkip("Metal が使えない環境")
        }
        let source = blockyImage()
        XCTAssertTrue(reducer.reduce(source, level: .none) === source)
    }

    func testResamplerCachesSeparatelyPerReductionLevel() async {
        // 同サイズでもノイズ低減指定があれば処理され、レベル別にキャッシュされる
        let resampler = ImageResampler(byteLimit: 8 << 20)
        let source = blockyImage()
        let size = CGSize(width: source.width, height: source.height)
        let plain = await resampler.resample(
            source, to: size, cacheKey: "nr-t", upscaleWithMetalFX: false)
        XCTAssertTrue(plain === source)  // 低減なし+同サイズは素通し
        let reduced = await resampler.resample(
            source, to: size, cacheKey: "nr-t", upscaleWithMetalFX: false,
            noiseReduction: .strong)
        XCTAssertNotNil(reduced)
        XCTAssertFalse(reduced === source)
        let reducedAgain = await resampler.resample(
            source, to: size, cacheKey: "nr-t", upscaleWithMetalFX: false,
            noiseReduction: .strong)
        XCTAssertTrue(reduced === reducedAgain)  // キャッシュ命中
    }

    func testJPEGFileDetection() {
        XCTAssertTrue(SupportedTypes.isJPEGFile("page01.jpg"))
        XCTAssertTrue(SupportedTypes.isJPEGFile("PAGE01.JPEG"))
        XCTAssertTrue(SupportedTypes.isJPEGFile("a.jfif"))
        XCTAssertFalse(SupportedTypes.isJPEGFile("page01.png"))
        XCTAssertFalse(SupportedTypes.isJPEGFile("page01.webp"))
        XCTAssertFalse(SupportedTypes.isJPEGFile("jpg"))  // 拡張子なし
    }

    @MainActor
    func testSettingsAccessors() {
        let suiteName = "NoiseReductionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.noiseReductionLevel, .none)     // 既定オフ
        XCTAssertEqual(store.noiseReductionScope, .displayOnly)
        store.noiseReductionLevel = .strong
        store.noiseReductionScope = .everywhere
        XCTAssertEqual(store.noiseReductionLevel, .strong)
        XCTAssertEqual(defaults.integer(forKey: "NoiseReductionLevel"), 3)
        store.noiseReductionLevel = .medium
        XCTAssertEqual(defaults.integer(forKey: "NoiseReductionLevel"), 2)
        XCTAssertEqual(store.noiseReductionScope, .everywhere)
        XCTAssertTrue(store.noiseReductionScope.includesLoupe)
        XCTAssertTrue(store.noiseReductionScope.includesOriginalSize)
        // 範囲外の保存値は既定へフォールバック
        defaults.set(99, forKey: "NoiseReductionLevel")
        XCTAssertEqual(store.noiseReductionLevel, .none)
    }
}
