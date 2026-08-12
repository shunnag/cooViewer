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

    func testSuperResolverTileOriginsCoverImage() {
        // 内容領域 240px 単位で端まで覆う(継ぎ目マージンは入力側で確保)
        XCTAssertEqual(MLSuperResolver.contentSide, 240)
        let origins = MLSuperResolver.tileOrigins(width: 500, height: 250)
        XCTAssertEqual(origins.count, 6)  // 3 列 × 2 行
        XCTAssertTrue(origins.contains { $0.x == 480 && $0.y == 240 })
        XCTAssertEqual(MLSuperResolver.tileOrigins(width: 240, height: 240).count, 1)
        XCTAssertTrue(MLSuperResolver.tileOrigins(width: 100, height: 0).isEmpty)
    }

    func testMaximumLevelBehavior() {
        // 等倍系(ルーペ・原寸)では「最高」は「強」へ落ちる
        XCTAssertEqual(NoiseReductionLevel.maximum.cappedForOriginalSize, .strong)
        XCTAssertEqual(NoiseReductionLevel.strong.cappedForOriginalSize, .strong)
        XCTAssertEqual(NoiseReductionLevel.light.cappedForOriginalSize, .light)
        // 超解像のキャッシュファイル名はキーのハッシュ(キー毎に一意・拡張子 heic)
        let url1 = MLSuperResolver.cacheFileURL(for: "a|100x200|sr4")
        let url2 = MLSuperResolver.cacheFileURL(for: "b|100x200|sr4")
        XCTAssertNotEqual(url1, url2)
        XCTAssertEqual(url1.pathExtension, "heic")
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

    @MainActor
    func testResampleActivityNotification() async throws {
        // リサンプル開始で true、完了で false が通知される
        // (ページバー横の進行インジケーターの駆動源)
        let view = ReaderView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        var events: [Bool] = []
        view.onResampleActivityChanged = { events.append($0) }
        view.setPages([blockyImage(size: 64)], readsFromLeft: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(events.first, true, "リサンプル予約と同時に開始通知")
        for _ in 0..<100 where events.last != false {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(events.last, false, "完了で終了通知")
        // 空表示への切替は即座に false(空の本・本を閉じた場合)
        events.removeAll()
        view.setPages([], readsFromLeft: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(events.last, false,
            "リサンプル不要でも false を再通知(コントローラの表示予約の解除手段)")
        // 全ページ事前引き当て済み(キャッシュ命中)でも false が来る
        events.removeAll()
        let source = blockyImage(size: 64)
        let targets = try XCTUnwrap(view.predictedResampleSizes(
            for: [CGSize(width: source.width, height: source.height)]))
        let done = try XCTUnwrap(ImageResampler.cgResample(
            source, width: Int(targets[0].width), height: Int(targets[0].height)))
        view.setPages([source], readsFromLeft: false,
                      preResampled: [(targets[0], done)])
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(events.last, false,
            "事前引き当てで完了済みならスピナー予約は即解除される")
    }

    @MainActor
    func testRenderQualityMapping() {
        // 描画品質(補間 5 段階)⇔ 旧互換 2 キーの相互変換
        let suiteName = "RenderQualityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.renderQuality, .standard)  // 既定
        store.renderQuality = .mlSuperRes
        // Interpolation は旧互換の 0-3 のまま(1.x と共有するため未知値を書かない)
        XCTAssertEqual(defaults.integer(forKey: "Interpolation"), 3)
        XCTAssertEqual(defaults.integer(forKey: "NoiseReductionLevel"), 4)
        XCTAssertEqual(store.renderQuality, .mlSuperRes)
        store.renderQuality = .mlDenoise
        XCTAssertEqual(defaults.integer(forKey: "NoiseReductionLevel"), 3)
        store.renderQuality = .none
        XCTAssertEqual(defaults.integer(forKey: "Interpolation"), 1)
        XCTAssertEqual(defaults.integer(forKey: "NoiseReductionLevel"), 0)
        store.renderQuality = .high
        XCTAssertEqual(defaults.integer(forKey: "Interpolation"), 3)
        XCTAssertEqual(store.renderQuality, .high)
        // 旧設定の「低」(2)は標準として読む。CI 弱・中(旧 NR 1-2)は
        // 基礎補間の段階で表示(パイプラインでは従来どおり効く)
        defaults.set(2, forKey: "Interpolation")
        XCTAssertEqual(store.renderQuality, .standard)
        defaults.set(2, forKey: "NoiseReductionLevel")
        XCTAssertEqual(store.renderQuality, .standard)
    }

    @MainActor
    func testToggleInterpolationNoneRestoresQuality() {
        // f キーのトグルは ML 段階も含めた品質単位で往復する
        let suiteName = "RenderQualityToggle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        store.renderQuality = .mlSuperRes
        store.toggleInterpolationNone()
        XCTAssertEqual(store.renderQuality, .none)
        XCTAssertEqual(defaults.integer(forKey: "NoiseReductionLevel"), 0)
        store.toggleInterpolationNone()
        XCTAssertEqual(store.renderQuality, .mlSuperRes)
        // 直前の記録が無いときは「高」へ復帰
        let fresh = UserDefaults(suiteName: suiteName + "-b")!
        defer { fresh.removePersistentDomain(forName: suiteName + "-b") }
        let freshStore = SettingsStore(defaults: fresh)
        fresh.set(1, forKey: "Interpolation")
        freshStore.toggleInterpolationNone()
        XCTAssertEqual(freshStore.renderQuality, .high)
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
        store.noiseReductionLevel = .maximum
        XCTAssertEqual(defaults.integer(forKey: "NoiseReductionLevel"), 4)
        XCTAssertEqual(store.noiseReductionLevel, .maximum)
        // 範囲外の保存値は既定へフォールバック
        defaults.set(99, forKey: "NoiseReductionLevel")
        XCTAssertEqual(store.noiseReductionLevel, .none)
    }
}
