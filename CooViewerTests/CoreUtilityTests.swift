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

final class PageCacheTests: XCTestCase {
    /// 16x16 RGBA ≈ 1KB のテスト画像
    private func image() -> CGImage {
        try! ImageDecoding.decode(TestFixtures.pngData(width: 16, height: 16))
    }

    private var oneCost: Int {
        let sample = image()
        return sample.bytesPerRow * sample.height
    }

    func testEvictsOldestWhenOverByteLimit() async {
        let cache = PageCache(byteLimit: oneCost * 2)  // 2 枚分
        await cache.insert(image(), for: 1)
        await cache.insert(image(), for: 2)
        await cache.insert(image(), for: 3)
        let first = await cache.image(for: 1)
        let second = await cache.image(for: 2)
        let third = await cache.image(for: 3)
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
    }

    func testAccessMovesEntryToMostRecentlyUsed() async {
        let cache = PageCache(byteLimit: oneCost * 2)
        await cache.insert(image(), for: 1)
        await cache.insert(image(), for: 2)
        _ = await cache.image(for: 1)          // 1 を MRU に
        await cache.insert(image(), for: 3)    // 2 が追い出される
        let first = await cache.image(for: 1)
        let second = await cache.image(for: 2)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }

    func testByteLimitReductionEvicts() async {
        let cache = PageCache(byteLimit: oneCost * 3)
        await cache.insert(image(), for: 1)
        await cache.insert(image(), for: 2)
        await cache.insert(image(), for: 3)
        await cache.setByteLimit(oneCost)
        let count = await cache.count
        XCTAssertEqual(count, 1)
        let third = await cache.image(for: 3)  // 最新のみ残る
        XCTAssertNotNil(third)
    }

    func testSingleOversizedImageIsKept() async {
        // 上限を超える 1 枚でも保持する(再デコードの繰り返し防止)
        let cache = PageCache(byteLimit: 1)
        await cache.insert(image(), for: 1)
        let first = await cache.image(for: 1)
        XCTAssertNotNil(first)
    }

    func testTrimToHalfDropsOldEntries() async {
        let cache = PageCache(byteLimit: oneCost * 4)
        for id in 1...4 {
            await cache.insert(image(), for: id)
        }
        await cache.trimToHalf()
        let count = await cache.count
        XCTAssertEqual(count, 2)
        let newest = await cache.image(for: 4)
        XCTAssertNotNil(newest)
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

/// 分割書庫の拡張子判定(仕様書 §2.3 の番号系列)
final class SplitVolumeExtensionTests: XCTestCase {
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
