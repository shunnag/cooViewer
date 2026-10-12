import XCTest
@testable import cooViewer

final class ImageDecodingTests: XCTestCase {
    func testDecodeFullSize() throws {
        let data = TestFixtures.pngData(width: 32, height: 16)
        let image = try ImageDecoding.decode(data)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 16)
    }

    func testDecodeWithMaxPixelSizeDownsamples() throws {
        let data = TestFixtures.pngData(width: 32, height: 16)
        let image = try ImageDecoding.decode(data, maxPixelSize: 8)
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)
    }

    func testDecodeGarbageThrows() {
        XCTAssertThrowsError(try ImageDecoding.decode(Data([0xDE, 0xAD, 0xBE, 0xEF])))
    }
}

@MainActor
final class PageCacheTests: XCTestCase {
    /// 16x16 RGBA ≈ 1KB のテスト画像
    private func image() -> CGImage {
        try! ImageDecoding.decode(TestFixtures.pngData(width: 16, height: 16))
    }

    private var oneCost: Int {
        let sample = image()
        return sample.bytesPerRow * sample.height
    }

    func testEvictsOldestWhenOverByteLimit() {
        let cache = PageCache(byteLimit: oneCost * 2)  // 2 枚分
        cache.insert(image(), for: 1)
        cache.insert(image(), for: 2)
        cache.insert(image(), for: 3)
        let first = cache.image(for: 1)
        let second = cache.image(for: 2)
        let third = cache.image(for: 3)
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
    }

    func testAccessMovesEntryToMostRecentlyUsed() {
        let cache = PageCache(byteLimit: oneCost * 2)
        cache.insert(image(), for: 1)
        cache.insert(image(), for: 2)
        _ = cache.image(for: 1)          // 1 を MRU に
        cache.insert(image(), for: 3)    // 2 が追い出される
        let first = cache.image(for: 1)
        let second = cache.image(for: 2)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }

    func testByteLimitReductionEvicts() {
        let cache = PageCache(byteLimit: oneCost * 3)
        cache.insert(image(), for: 1)
        cache.insert(image(), for: 2)
        cache.insert(image(), for: 3)
        cache.setByteLimit(oneCost)
        let count = cache.count
        XCTAssertEqual(count, 1)
        let third = cache.image(for: 3)  // 最新のみ残る
        XCTAssertNotNil(third)
    }

    func testSingleOversizedImageIsKept() {
        // 上限を超える 1 枚でも保持する(再デコードの繰り返し防止)
        let cache = PageCache(byteLimit: 1)
        cache.insert(image(), for: 1)
        let first = cache.image(for: 1)
        XCTAssertNotNil(first)
    }

    /// 圧迫段階で実効上限を下げて追い出し、normal まで保ち、戻すときは中身を触らない(設計書 §5)
    func testMemoryPressureLowersEffectiveLimitUntilNormal() {
        let cache = PageCache(byteLimit: oneCost * 8, pressure: FixedMemoryPressure(),
                              center: NotificationCenter())
        for id in 1...8 { cache.insert(image(), for: id) }
        XCTAssertEqual(cache.byteLimit, oneCost * 8)

        cache.applyMemoryPressure(.warning)
        XCTAssertEqual(cache.byteLimit, oneCost * 4)
        XCTAssertEqual(cache.configuredByteLimit, oneCost * 8)
        XCTAssertEqual(cache.count, 4)
        XCTAssertNil(cache.image(for: 4))
        XCTAssertNotNil(cache.image(for: 8))
        // 圧迫中の挿入は下げた上限を超えない
        for id in 9...12 { cache.insert(image(), for: id) }
        XCTAssertLessThanOrEqual(cache.currentCost, oneCost * 4)

        cache.applyMemoryPressure(.critical)
        XCTAssertEqual(cache.byteLimit, oneCost * 2)
        XCTAssertEqual(cache.count, 2)

        cache.applyMemoryPressure(.normal)
        XCTAssertEqual(cache.byteLimit, oneCost * 8)
        XCTAssertEqual(cache.count, 2, "復帰で埋め直しも追い出しもしない")
    }

    func testCreatedUnderPressureStartsLoweredAndFollowsNotification() async {
        let center = NotificationCenter()
        let cache = PageCache(byteLimit: oneCost * 8, pressure: FixedMemoryPressure(.warning),
                              center: center)
        XCTAssertEqual(cache.byteLimit, oneCost * 4)
        center.post(name: MemoryPressureMonitor.didChangeNotification,
                    object: FixedMemoryPressure(.critical))
        // 観測は MainActor へ跳ぶ Task なので完了を待つ
        for _ in 0..<200 where cache.byteLimit != oneCost * 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(cache.byteLimit, oneCost * 2)
    }

    /// 明示設定は設定上の上限を定めるだけで、圧迫中は実効上限が引き続き下がる
    func testExplicitLimitChangeKeepsPressureFactor() {
        let cache = PageCache(byteLimit: oneCost * 4, pressure: FixedMemoryPressure(.warning),
                              center: NotificationCenter())
        cache.setByteLimit(oneCost * 2)
        XCTAssertEqual(cache.configuredByteLimit, oneCost * 2)
        XCTAssertEqual(cache.byteLimit, oneCost)
        cache.applyMemoryPressure(.normal)
        XCTAssertEqual(cache.byteLimit, oneCost * 2)
    }
}

final class ImageResamplerTests: XCTestCase {
    private func image(width: Int, height: Int) -> CGImage {
        try! ImageDecoding.decode(TestFixtures.pngData(width: width, height: height))
    }

    func testDownscaleProducesExactTargetSize() async {
        let source = image(width: 100, height: 100)
        let result = await ImageResampler.shared.resample(
            source, to: CGSize(width: 50, height: 50),
            cacheKey: "t-down", upscaleWithMetalFX: false)
        XCTAssertEqual(result?.width, 50)
        XCTAssertEqual(result?.height, 50)
    }

    func testUpscaleWithMetalFXProducesExactTargetSize() async {
        // MetalFX 非対応環境では CG フォールバックで同サイズになる
        let source = image(width: 40, height: 60)
        let result = await ImageResampler.shared.resample(
            source, to: CGSize(width: 80, height: 120),
            cacheKey: "t-up", upscaleWithMetalFX: true)
        XCTAssertEqual(result?.width, 80)
        XCTAssertEqual(result?.height, 120)
    }

    func testOverTwoTimesUpscalePreservesSizeAndColor() async throws {
        // 2 倍超の段階適用でも色が化けないこと(テクスチャ内チェーンの回帰防止)
        let source = try ImageDecoding.decode(
            TestFixtures.pngData(width: 20, height: 20, red: 0.9, green: 0.2, blue: 0.2))
        let resampled = await ImageResampler.shared.resample(
            source, to: CGSize(width: 100, height: 100),
            cacheKey: "t-up5x", upscaleWithMetalFX: true)
        let result = try XCTUnwrap(resampled)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
        let data = try XCTUnwrap(result.dataProvider?.data as Data?)
        let offset = 50 * result.bytesPerRow + 50 * (result.bitsPerPixel / 8)
        XCTAssertGreaterThan(Int(data[offset]), 180)      // R
        XCTAssertLessThan(Int(data[offset + 1]), 120)     // G
        XCTAssertLessThan(Int(data[offset + 2]), 120)     // B
    }

    func testDownscalePreservesColor() async throws {
        // GPU(Lanczos)縮小経路でも色が化けないこと
        let source = try ImageDecoding.decode(
            TestFixtures.pngData(width: 100, height: 100, red: 0.9, green: 0.2, blue: 0.2))
        let resampled = await ImageResampler.shared.resample(
            source, to: CGSize(width: 50, height: 50),
            cacheKey: "t-down-color", upscaleWithMetalFX: false)
        let result = try XCTUnwrap(resampled)
        let data = try XCTUnwrap(result.dataProvider?.data as Data?)
        let offset = 25 * result.bytesPerRow + 25 * (result.bitsPerPixel / 8)
        XCTAssertGreaterThan(Int(data[offset]), 180)      // R
        XCTAssertLessThan(Int(data[offset + 1]), 120)     // G
        XCTAssertLessThan(Int(data[offset + 2]), 120)     // B
    }

    /// 上半分が赤・下半分が青の画像(メモリ先頭行=画像上端)
    private func twoToneImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG の描画座標は下原点: y 上半分の矩形がメモリ先頭側(画像上端)になる
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return context.makeImage()!
    }

    func testDownscaleKeepsOrientation() async throws {
        // CIImage 経路で上下が反転しないこと(向きの回帰防止)
        let source = twoToneImage(width: 64, height: 64)
        let resampled = await ImageResampler.shared.resample(
            source, to: CGSize(width: 32, height: 32),
            cacheKey: "t-down-orient", upscaleWithMetalFX: false)
        let result = try XCTUnwrap(resampled)
        let data = try XCTUnwrap(result.dataProvider?.data as Data?)
        let pixelBytes = result.bitsPerPixel / 8
        let top = 4 * result.bytesPerRow + 16 * pixelBytes
        let bottom = 28 * result.bytesPerRow + 16 * pixelBytes
        XCTAssertGreaterThan(Int(data[top]), 150, "上端は赤のはず")
        XCTAssertLessThan(Int(data[top + 2]), 100)
        XCTAssertGreaterThan(Int(data[bottom + 2]), 150, "下端は青のはず")
        XCTAssertLessThan(Int(data[bottom]), 100)
    }

    func testSameSizeReturnsOriginal() async {
        let source = image(width: 30, height: 30)
        let result = await ImageResampler.shared.resample(
            source, to: CGSize(width: 30, height: 30),
            cacheKey: "t-same", upscaleWithMetalFX: false)
        XCTAssertTrue(result === source)
    }

    func testCacheReturnsSameInstance() async {
        let source = image(width: 64, height: 64)
        let first = await ImageResampler.shared.resample(
            source, to: CGSize(width: 32, height: 32),
            cacheKey: "t-cache", upscaleWithMetalFX: false)
        let second = await ImageResampler.shared.resample(
            source, to: CGSize(width: 32, height: 32),
            cacheKey: "t-cache", upscaleWithMetalFX: false)
        XCTAssertTrue(first === second)
    }

    func testByteLimitEvictsOldestKeepsNewest() async {
        // 32x32 RGBA(4KB)2 枚分の上限に 3 枚入れると最古が落ちる
        let resampler = ImageResampler(byteLimit: 32 * 32 * 4 * 2 + 512)
        let source = image(width: 64, height: 64)
        let first = await resampler.resample(
            source, to: CGSize(width: 32, height: 32),
            cacheKey: "e1", upscaleWithMetalFX: false)
        _ = await resampler.resample(
            source, to: CGSize(width: 32, height: 32),
            cacheKey: "e2", upscaleWithMetalFX: false)
        let third = await resampler.resample(
            source, to: CGSize(width: 32, height: 32),
            cacheKey: "e3", upscaleWithMetalFX: false)
        // 最新はキャッシュ命中(同一インスタンス)、最古は作り直しになる
        let thirdAgain = await resampler.resample(
            source, to: CGSize(width: 32, height: 32),
            cacheKey: "e3", upscaleWithMetalFX: false)
        XCTAssertTrue(third === thirdAgain)
        let firstAgain = await resampler.resample(
            source, to: CGSize(width: 32, height: 32),
            cacheKey: "e1", upscaleWithMetalFX: false)
        XCTAssertFalse(first === firstAgain)
    }
}

/// 各キャッシュが圧迫段階で実効上限を下げ・保ち・戻すことの検証(設計書 §5)。
/// 実圧迫は使わず、注入した提供者と通知センターだけで駆動する
final class ImageResamplerPressureTests: XCTestCase {
    private func image(side: Int) -> CGImage {
        try! ImageDecoding.decode(TestFixtures.pngData(width: side, height: side))
    }

    /// 1 枚ぶんのキャッシュコスト(64px の RGBA 縮小結果)
    private var oneCost: Int {
        let sample = ImageResampler.cgResample(image(side: 128), width: 64, height: 64)!
        return sample.bytesPerRow * sample.height
    }

    private func fill(_ resampler: ImageResampler, keys: Range<Int>) async {
        for key in keys {
            _ = await resampler.resample(image(side: 128), to: CGSize(width: 64, height: 64),
                                         cacheKey: "p\(key)", upscaleWithMetalFX: false)
        }
    }

    func testWarningAndCriticalLowerLimitAndEvict() async {
        let cost = oneCost
        let resampler = ImageResampler(byteLimit: cost * 8, pressure: FixedMemoryPressure(),
                                       center: NotificationCenter())
        await fill(resampler, keys: 0..<8)
        var stats = await resampler.stats()
        XCTAssertEqual(stats.count, 8)
        XCTAssertEqual(stats.limitBytes, cost * 8)

        await resampler.applyMemoryPressure(.warning)
        stats = await resampler.stats()
        XCTAssertEqual(stats.limitBytes, cost * 4)
        XCTAssertEqual(stats.count, 4, "実効上限まで古い順に追い出す")
        // 圧迫中の追加は下げた上限を超えない
        await fill(resampler, keys: 8..<12)
        stats = await resampler.stats()
        XCTAssertLessThanOrEqual(stats.usedBytes, cost * 4)

        await resampler.applyMemoryPressure(.critical)
        stats = await resampler.stats()
        XCTAssertEqual(stats.limitBytes, cost * 2)
        XCTAssertEqual(stats.count, 2)

        // normal: 設定上限へ戻すだけで中身は触らない
        await resampler.applyMemoryPressure(.normal)
        stats = await resampler.stats()
        XCTAssertEqual(stats.limitBytes, cost * 8)
        XCTAssertEqual(stats.count, 2)
    }

    func testCreatedUnderPressureStartsLoweredAndFollowsNotifications() async {
        let cost = oneCost
        let center = NotificationCenter()
        let resampler = ImageResampler(byteLimit: cost * 8, pressure: FixedMemoryPressure(.critical),
                                       center: center)
        var stats = await resampler.stats()
        XCTAssertEqual(stats.limitBytes, cost * 2)

        // 通知の object が提供者。actor へ跳ぶので完了を待ってから読む
        center.post(name: MemoryPressureMonitor.didChangeNotification, object: FixedMemoryPressure(.normal))
        for _ in 0..<200 where await resampler.stats().limitBytes != cost * 8 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        stats = await resampler.stats()
        XCTAssertEqual(stats.limitBytes, cost * 8)
    }
}

final class PreresamplePolicyTests: XCTestCase {
    func testPageBudgetCapsAtMaxPages() {
        // 30MB/ページ・16GB 機: 予算 2GB → 68 ページ相当だが上限 64
        XCTAssertEqual(PreresamplePolicy.pageBudget(
            bytesPerPage: 30 << 20, physicalMemory: 16 << 30,
            usesML: false, conserveEnergy: false, memoryPressure: .normal), 64)
    }

    func testPageBudgetShrinksForLargePages() {
        // 200MB/ページ(6K 級ウインドウ)→ 4GB / 200MB = 20 ページ
        XCTAssertEqual(PreresamplePolicy.pageBudget(
            bytesPerPage: 200 << 20, physicalMemory: 64 << 30,
            usesML: false, conserveEnergy: false, memoryPressure: .normal), 20)
    }

    func testPageBudgetFloorsAtOne() {
        // 2GB 機: 予算 256MB < 400MB/ページ → 最低 1 ページは先読みする
        XCTAssertEqual(PreresamplePolicy.pageBudget(
            bytesPerPage: 400 << 20, physicalMemory: 2 << 30,
            usesML: false, conserveEnergy: false, memoryPressure: .normal), 1)
        XCTAssertEqual(PreresamplePolicy.pageBudget(
            bytesPerPage: 0, physicalMemory: 8 << 30,
            usesML: false, conserveEnergy: false, memoryPressure: .normal), 1)
    }

    /// 通常時(非 ML・省エネなし・圧迫なし)の予算
    private func normalBudget(_ physicalMemory: UInt64) -> Int {
        PreresamplePolicy.byteBudget(physicalMemory: physicalMemory, usesML: false,
                                     conserveEnergy: false, memoryPressure: .normal)
    }

    func testByteBudgetScalesWithMemory() {
        // 8GB 機 1GB・16GB 機 2GB(いずれも 1/8)、大容量機は 4GB で頭打ち
        XCTAssertEqual(normalBudget(8 << 30), 1 << 30)
        XCTAssertEqual(normalBudget(16 << 30), 2 << 30)
        XCTAssertEqual(normalBudget(64 << 30), 4 << 30)
    }

    /// 圧迫中の先読み予算はリサンプル LRU の実効上限と同じ係数で縮み、LRU(物理の 1/5・
    /// 最大 12GB)の実効上限を超えない(先読み結果が互いに追い出し合わない。設計書 §5)
    func testPreresampleBudgetShrinksWithMemoryPressureAndFitsLoweredLRU() {
        XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: 8 << 30, usesML: false,
                                                    conserveEnergy: false, memoryPressure: .warning),
                       512 << 20)
        XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: 8 << 30, usesML: false,
                                                    conserveEnergy: false, memoryPressure: .critical),
                       256 << 20)
        XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: 64 << 30, usesML: true,
                                                    conserveEnergy: false, memoryPressure: .critical),
                       (4 << 30) / 16 / 4)
        // 100MB/ページ・8GB 機: 通常 10 ページ → critical では 2 ページ
        XCTAssertEqual(PreresamplePolicy.pageBudget(bytesPerPage: 100 << 20, physicalMemory: 8 << 30,
                                                    usesML: false, conserveEnergy: false,
                                                    memoryPressure: .normal), 10)
        XCTAssertEqual(PreresamplePolicy.pageBudget(bytesPerPage: 100 << 20, physicalMemory: 8 << 30,
                                                    usesML: false, conserveEnergy: false,
                                                    memoryPressure: .critical), 2)
        for memory: UInt64 in [8 << 30, 16 << 30, 64 << 30, 128 << 30] {
            let lruConfigured = min(12 << 30, Int(clamping: memory) / 5)
            for level in MemoryPressureLevel.allCases {
                XCTAssertLessThanOrEqual(
                    PreresamplePolicy.byteBudget(physicalMemory: memory, usesML: false,
                                                 conserveEnergy: false, memoryPressure: level),
                    MemoryBudgetPolicy.effectiveLimit(configured: lruConfigured, level: level),
                    "\(memory >> 30) GB \(level)")
            }
        }
    }

    func testDecodeAheadCoversResamplePrefetch() {
        // リサンプル先読み 24 ページ → +4 で 28 を確保(I/O と ML の直列化防止)
        XCTAssertEqual(PreresamplePolicy.decodeAhead(
            resamplePages: 24, decodedPageBytes: 100 << 20,
            pageCacheByteLimit: 2 << 30, mediaFloor: 12), 28)
        // PageCache 予算の 1/3 が広ければそちらを採る:
        // 2.4GB/3 = 819MB ÷ 24MB = 34 ページ > 12+4
        XCTAssertEqual(PreresamplePolicy.decodeAhead(
            resamplePages: 12, decodedPageBytes: 24 << 20,
            pageCacheByteLimit: Int(2.4 * Double(1 << 30)), mediaFloor: 12), 34)
        // 媒体別下限(ネットワーク 20)を下回らない
        XCTAssertEqual(PreresamplePolicy.decodeAhead(
            resamplePages: 1, decodedPageBytes: 500 << 20,
            pageCacheByteLimit: 1 << 30, mediaFloor: 20), 20)
        // 上限は maxPages
        XCTAssertEqual(PreresamplePolicy.decodeAhead(
            resamplePages: 64, decodedPageBytes: 1 << 20,
            pageCacheByteLimit: 16 << 30, mediaFloor: 12),
            PreresamplePolicy.maxPages)
    }

    func testPreresamplePageLimitsByQualityAndEnergy() {
        // (ML, 省エネ) → 枚数 / 見開き数(設計書 §5)
        XCTAssertEqual(PreresamplePolicy.pageLimit(usesML: false, conserveEnergy: false), 64)
        XCTAssertEqual(PreresamplePolicy.pageLimit(usesML: false, conserveEnergy: true), 4)
        XCTAssertEqual(PreresamplePolicy.pageLimit(usesML: true, conserveEnergy: false), 4)
        XCTAssertEqual(PreresamplePolicy.pageLimit(usesML: true, conserveEnergy: true), 2)
        XCTAssertEqual(PreresamplePolicy.spreadLimit(usesML: false, conserveEnergy: false), 64)
        XCTAssertEqual(PreresamplePolicy.spreadLimit(usesML: false, conserveEnergy: true), 1)
        XCTAssertEqual(PreresamplePolicy.spreadLimit(usesML: true, conserveEnergy: false), 2)
        XCTAssertEqual(PreresamplePolicy.spreadLimit(usesML: true, conserveEnergy: true), 1)
    }

    func testPreresampleMemoryBudgetScalesWithPageLimit() {
        for memory: UInt64 in [2 << 30, 8 << 30, 64 << 30] {
            let normal = normalBudget(memory)
            for usesML in [false, true] {
                for conserve in [false, true] {
                    let limit = PreresamplePolicy.pageLimit(usesML: usesML, conserveEnergy: conserve)
                    XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: memory, usesML: usesML,
                                                                conserveEnergy: conserve,
                                                                memoryPressure: .normal),
                                   normal / (PreresamplePolicy.maxPages / limit),
                                   "ML=\(usesML) conserve=\(conserve)")
                    // 小さなページでは枚数上限、巨大ページでは予算が効く
                    XCTAssertEqual(PreresamplePolicy.pageBudget(bytesPerPage: 1 << 20,
                        physicalMemory: memory, usesML: usesML, conserveEnergy: conserve,
                        memoryPressure: .normal), limit)
                }
            }
        }
        XCTAssertEqual(PreresamplePolicy.pageBudget(bytesPerPage: 400 << 20,
            physicalMemory: 2 << 30, usesML: false, conserveEnergy: true, memoryPressure: .normal), 1)
        XCTAssertEqual(PreresamplePolicy.pageBudget(bytesPerPage: 400 << 20,
            physicalMemory: 2 << 30, usesML: true, conserveEnergy: false, memoryPressure: .normal), 1)
    }

    func testPreresampleSpreadsFollowSpreadAndPageLimits() {
        let predicted = [[2, 3], [4, 5], [6, 7]]
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess(predicted, usesML: false, conserveEnergy: false), predicted)
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess(predicted, usesML: false, conserveEnergy: true), [[2, 3]])
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess(predicted, usesML: true, conserveEnergy: false),
                       [[2, 3], [4, 5]])
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess(predicted, usesML: true, conserveEnergy: true), [[2, 3]])
        // 単ページ始まりでも見開き数で数える(ML 通常は 2 見開き、省エネは 1 見開き)
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess([[1], [2, 3], [4, 5]], usesML: true, conserveEnergy: false),
                       [[1], [2, 3]])
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess([[1], [2, 3], [4, 5]], usesML: false, conserveEnergy: true),
                       [[1]])
        // 見開きは分割しない: 枚数予算に収まらない見開きは丸ごと落として打ち切る
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess([[1, 2, 3]], usesML: true, conserveEnergy: true), [])
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess([[1, 2, 3, 4, 5]], usesML: false, conserveEnergy: true), [])
        XCTAssertEqual(PreresamplePolicy.spreadsToProcess([], usesML: true, conserveEnergy: true), [])
    }

    func testPreresampleModeGate() {
        typealias Mode = PreresamplePolicy.Mode
        // 不可視は常に停止、可視かつ非前面または省エネは次の見開きだけ、残る 1 通りだけが通常
        for appActive in [false, true] {
            for conserve in [false, true] {
                XCTAssertEqual(PreresamplePolicy.mode(windowVisible: false, appActive: appActive,
                                                      conserveEnergy: conserve), Mode.paused)
            }
        }
        XCTAssertEqual(PreresamplePolicy.mode(windowVisible: true, appActive: false, conserveEnergy: false),
                       Mode.conserving)
        XCTAssertEqual(PreresamplePolicy.mode(windowVisible: true, appActive: false, conserveEnergy: true),
                       Mode.conserving)
        XCTAssertEqual(PreresamplePolicy.mode(windowVisible: true, appActive: true, conserveEnergy: true),
                       Mode.conserving)
        XCTAssertEqual(PreresamplePolicy.mode(windowVisible: true, appActive: true, conserveEnergy: false),
                       Mode.normal)
    }

    func testNoiseReductionLevelsUsingML() {
        XCTAssertEqual(NoiseReductionLevel.allCases.filter(\.usesMachineLearning), [.strong, .maximum])
    }

    func testConserveEnergyDecodeAheadHalvesWithExistingMinimum() {
        XCTAssertEqual(PreresamplePolicy.decodeAhead(resamplePages: 24,
            decodedPageBytes: 100 << 20, pageCacheByteLimit: 2 << 30,
            mediaFloor: 12, conserveEnergy: true), 14)
        XCTAssertEqual(PreresamplePolicy.decodeAhead(resamplePages: 0,
            decodedPageBytes: 0, pageCacheByteLimit: 0,
            mediaFloor: 2, conserveEnergy: true), 2)
    }

    func testDecodeBehindIsQuarterOfAhead() {
        XCTAssertEqual(PreresamplePolicy.decodeBehind(ahead: 12), 3)
        XCTAssertEqual(PreresamplePolicy.decodeBehind(ahead: 33), 8)
        XCTAssertEqual(PreresamplePolicy.decodeBehind(ahead: 64), 16)
        XCTAssertEqual(PreresamplePolicy.decodeBehind(ahead: 4), 3)  // 下限 3
    }
}

@MainActor
final class MetalFXUpscalerTests: XCTestCase {
    func testSpatialUpscaleDoubles() throws {
        guard let upscaler = MetalFXUpscaler() else {
            throw XCTSkip("MetalFX が使えない環境")
        }
        let source = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 64))
        let result = upscaler.upscale(source, to: CGSize(width: 128, height: 128))
        XCTAssertEqual(result?.width, 128)
        XCTAssertEqual(result?.height, 128)
    }

    func testUpscalePreservesColor() throws {
        // Metal テクスチャ⇄CIImage のバイトオーダー解釈ズレによる色化けの回帰防止
        guard let upscaler = MetalFXUpscaler() else {
            throw XCTSkip("MetalFX が使えない環境")
        }
        let source = try ImageDecoding.decode(
            TestFixtures.pngData(width: 64, height: 64, red: 0.9, green: 0.2, blue: 0.2))
        let result = try XCTUnwrap(upscaler.upscale(source, to: CGSize(width: 128, height: 128)))
        let data = try XCTUnwrap(result.dataProvider?.data as Data?)
        let offset = 64 * result.bytesPerRow + 64 * (result.bitsPerPixel / 8)
        let red = Int(data[offset])
        let green = Int(data[offset + 1])
        let blue = Int(data[offset + 2])
        XCTAssertGreaterThan(red, 180, "R が主成分のはず (R\(red) G\(green) B\(blue))")
        XCTAssertLessThan(green, 120)
        XCTAssertLessThan(blue, 120)
    }

    func testUpscalePreservesColorForThumbnailDecodedInput() throws {
        // アプリの実経路: ImageIO サムネイルデコード(premultipliedFirst)の入力でも
        // 色が化けないこと(MTKTextureLoader のバイト順誤読の回帰防止)
        guard let upscaler = MetalFXUpscaler() else {
            throw XCTSkip("MetalFX が使えない環境")
        }
        let source = try ImageDecoding.decode(
            TestFixtures.pngData(width: 64, height: 64, red: 0.9, green: 0.2, blue: 0.2),
            maxPixelSize: 4096)
        let result = try XCTUnwrap(upscaler.upscale(source, to: CGSize(width: 128, height: 129)))
        let data = try XCTUnwrap(result.dataProvider?.data as Data?)
        let offset = 64 * result.bytesPerRow + 64 * (result.bitsPerPixel / 8)
        XCTAssertGreaterThan(Int(data[offset]), 180)      // R
        XCTAssertLessThan(Int(data[offset + 1]), 120)     // G
        XCTAssertLessThan(Int(data[offset + 2]), 120)     // B
    }

    func testNonUpscaleReturnsNil() throws {
        guard let upscaler = MetalFXUpscaler() else {
            throw XCTSkip("MetalFX が使えない環境")
        }
        let source = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 64))
        XCTAssertNil(upscaler.upscale(source, to: CGSize(width: 32, height: 32)))
    }
}

final class SVGSupportTests: XCTestCase {
    func testSVGDecodesViaAppKitFallback() throws {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">\
        <rect width="40" height="20" fill="#e63333"/></svg>
        """.utf8)
        let image = try ImageDecoding.decode(svg, maxPixelSize: 200)
        XCTAssertEqual(image.width, 200)   // ベクトルは指定解像度でラスタライズ
        XCTAssertEqual(image.height, 100)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let offset = 50 * image.bytesPerRow + 100 * (image.bitsPerPixel / 8)
        XCTAssertGreaterThan(Int(data[offset]), 180)   // R
        XCTAssertLessThan(Int(data[offset + 1]), 120)  // G
    }

    func testSVGIsListedAndAIIsExcluded() {
        XCTAssertTrue(SupportedTypes.isImageFile("cover.svg"))
        XCTAssertFalse(SupportedTypes.isImageFile("artwork.ai"))
    }
}

final class AnimatedImageTests: XCTestCase {
    /// 3 フレームの GIF を生成してフレームと表示時間を検証
    func testLoadsGIFFramesAndDelays() throws {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, "com.compuserve.gif" as CFString, 3, nil)!
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.15]
        ] as CFDictionary
        for shade in [0.2, 0.5, 0.8] {
            let frame = try ImageDecoding.decode(TestFixtures.pngData(
                width: 10, height: 10, red: shade, green: shade, blue: shade))
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        CGImageDestinationFinalize(destination)

        let animation = try XCTUnwrap(AnimatedImage.load(from: data as Data))
        XCTAssertEqual(animation.frames.count, 3)
        XCTAssertEqual(animation.delays.count, 3)
        XCTAssertEqual(animation.delays[0], 0.15, accuracy: 0.02)
        XCTAssertEqual(animation.duration, 0.45, accuracy: 0.05)
    }

    func testSingleFrameReturnsNil() {
        XCTAssertNil(AnimatedImage.load(
            from: TestFixtures.pngData(width: 10, height: 10)))
    }

    func testAvifsExtensionIsAccepted() {
        XCTAssertTrue(SupportedTypes.isImageFile("clip.avifs"))
    }
}

/// ページ名の表示(ファイル名のみ ⇔ 本の中の相対パス)
final class PageEntryDisplayTitleTests: XCTestCase {
    private func entry(name: String, path: String) -> PageEntry {
        PageEntry(id: 0, name: name, pathInBook: path,
                  fileURL: nil, creationDate: nil, modificationDate: nil)
    }

    func testRelativePathShownForSubfolderAndArchiveEntries() {
        let sub = entry(name: "a.png", path: "chapter-1/a.png")
        XCTAssertEqual(sub.displayTitle(relativePath: false), "a.png")
        XCTAssertEqual(sub.displayTitle(relativePath: true), "chapter-1/a.png")
    }

    func testRootEntryFallsBackToName() {
        let root = entry(name: "a.png", path: "a.png")
        XCTAssertEqual(root.displayTitle(relativePath: true), "a.png")
    }

    func testPseudoPathSourceAlwaysShowsName() {
        // PDF の擬似パス(0 埋めページ番号)はパス表示にしない
        let pdf = entry(name: "3", path: "000002")
        XCTAssertEqual(pdf.displayTitle(relativePath: true), "3")
    }

    func testNestedPDFKeepsContainerPath() {
        // 書庫内 PDF のページは容器パスを残す(巻をまたいで区別できるように)
        let nested = entry(name: "Page 4", path: "vol1.pdf/000003")
        XCTAssertEqual(nested.displayTitle(relativePath: false), "Page 4")
        XCTAssertEqual(nested.displayTitle(relativePath: true), "vol1.pdf/Page 4")
    }
}

/// 書庫の拡張子判定(仕様書 §2.1 の archiveTypes、§2.3 の番号系列、設計書 §2.4)
final class ArchiveExtensionTests: XCTestCase {
    func testComicBookSevenZipArchives() {
        XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.cb7")))
        XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.CB7")))
        XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.7z")))
        XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.cb7.001")))
    }

    func testStuffItArchives() {
        for ext in ["sit", "sitx", "sea", "hqx"] {
            XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.\(ext)")))
            XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.\(ext.uppercased())")))
        }
        XCTAssertFalse(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.bin")))
    }

    func testSplitVolumesAreArchives() {
        XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.r00")))
        XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.z01")))
        XCTAssertTrue(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.7z.001")))
        XCTAssertFalse(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.png")))
        XCTAssertFalse(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.r1")))
        XCTAssertFalse(SupportedTypes.isArchive(URL(fileURLWithPath: "/a/b.abc")))
    }
}

/// コレクションフォルダのドリルダウン先選択(§2.4 の設計変更。
/// 明示オープン時のみ使われる — ナビゲーションはドリルしない)
@MainActor
final class InnerBookSelectionTests: XCTestCase {
    func testInnerBookPicksFirstBookByName() throws {
        let dir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x50, 0x4B]).write(to: dir.appendingPathComponent("01_first.zip"))
        try Data([0x50, 0x4B]).write(to: dir.appendingPathComponent("02_mid.zip"))
        let sub = dir.appendingPathComponent("03_last")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data([0x89]).write(to: sub.appendingPathComponent("page.png"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("note.txt"))

        XCTAssertEqual(
            ReaderWindowController.innerBook(in: dir)?.lastPathComponent,
            "01_first.zip", "名前順の最初の本を選ぶ")
    }

    func testInnerBookSkipsFoldersWithoutBookContent() throws {
        let dir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 画像も本も含まないフォルダ(.app 内部のような行き止まり)は飛ばす
        let junk = dir.appendingPathComponent("00_junk")
        try FileManager.default.createDirectory(
            at: junk.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("x".utf8).write(
            to: junk.appendingPathComponent("Contents/Info.plist"))
        // パッケージ(.app)は中に画像があっても候補にしない
        let app = dir.appendingPathComponent("01_tool.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try Data([0x89]).write(to: app.appendingPathComponent("icon.png"))
        // 深くに画像を含むフォルダは候補になる
        let real = dir.appendingPathComponent("02_series")
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("vol1"), withIntermediateDirectories: true)
        try Data([0x89]).write(to: real.appendingPathComponent("vol1/p1.png"))

        XCTAssertEqual(
            ReaderWindowController.innerBook(in: dir)?.lastPathComponent,
            "02_series", "行き止まりフォルダとパッケージを飛ばして本のあるフォルダへ")
    }

    func testInnerBookIgnoresNonBooks() throws {
        let dir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("note.txt"))
        XCTAssertNil(ReaderWindowController.innerBook(in: dir))
    }
}
