import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import XCTest
@testable import cooViewer

final class PDFSourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    /// 200x100pt・2 ページの PDF(中央に赤矩形)を生成する。
    private func makePDF() throws -> URL {
        let url = tempDir.appendingPathComponent("test.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 80, y: 30, width: 40, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testEntriesMatchPageCountInOrder() async throws {
        let source = try PDFSource(url: makePDF())
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)
        // 名前順ソートでページ順が保たれる擬似パス
        XCTAssertEqual(entries.map(\.pathInBook), ["000000", "000001"])
        XCTAssertEqual(entries.map(\.containerPath), ["", ""])
    }

    func testRendersAtPointSizeWithWhiteBackground() async throws {
        let source = try PDFSource(url: makePDF())
        let entry = try await source.entries()[0]
        let image = try await source.image(for: entry, maxPixelSize: nil)
        // ポイント原寸 = 実効 72dpi(仕様書 §4.14)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)

        let pixels = try XCTUnwrap(pixelData(of: image))
        // 左下隅は白背景、中央は赤(色空間変換の誤差を許容)
        XCTAssertEqual(pixel(pixels, image, x: 2, y: 2), [255, 255, 255])
        let center = pixel(pixels, image, x: 100, y: 50)
        XCTAssertGreaterThan(center[0], 200)
        XCTAssertLessThan(center[1], 80)
        XCTAssertLessThan(center[2], 80)
    }

    func testDisplayRenderingIsDoubleResolution() async throws {
        // 表示経路(大きい maxPixelSize)はベクトルから 2 倍でラスタライズ
        let source = try PDFSource(url: makePDF())
        let entry = try await source.entries()[0]
        let image = try await source.image(for: entry, maxPixelSize: 4096)
        XCTAssertEqual(image.width, 400)   // 200pt x2
        XCTAssertEqual(image.height, 200)
    }

    func testThumbnailRespectsMaxPixelSize() async throws {
        let source = try PDFSource(url: makePDF())
        let entry = try await source.entries()[0]
        let image = try await source.image(for: entry, maxPixelSize: 50)
        XCTAssertEqual(image.width, 50)
        XCTAssertEqual(image.height, 25)
    }

    // MARK: - ピクセル読み出し

    private func pixelData(of image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }

    /// RGBA(premultipliedLast)前提で (x,y) の RGB を返す。y は上原点。
    private func pixel(_ data: Data, _ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let offset = y * image.bytesPerRow + x * 4
        return [data[offset], data[offset + 1], data[offset + 2]]
    }
}

extension PDFSourceTests {
    /// 異なる画像を埋め込み、文書内部の画像キャッシュをページごとに増やす(設計書 §5、§7.6)。
    private func makeImagePDF(pageCount: Int) throws -> URL {
        let url = tempDir.appendingPathComponent("images.pdf")
        var box = CGRect(x: 0, y: 0, width: 80, height: 120)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<pageCount {
            let data = TestFixtures.pngData(width: 80, height: 120,
                                            red: CGFloat(index + 1) / CGFloat(pageCount + 1),
                                            green: 0.25, blue: 0.75)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testDistinctImagePagesRecycleWithinBudget() async throws {
        let limit = PDFPageRenderer.distinctPageLimit
        let count = limit * 3 + 2
        let source = try PDFSource(url: makeImagePDF(pageCount: count))
        let entries = try await source.entries()
        for (index, entry) in entries.enumerated() {
            _ = try await source.image(for: entry, maxPixelSize: nil)
            let stats = await source.debugRendererStatistics()
            XCTAssertEqual(stats.display.count, 1)
            XCTAssertEqual(stats.display.first?.distinctPageCount, index % limit + 1)
            XCTAssertEqual(stats.display.first?.recycleCount, index / limit)
            XCTAssertEqual(stats.display.first?.recycleFailureCount, 0)
        }
    }

    func testCurrentPageStaysWarmAtBudgetForLoupeAndRerender() async throws {
        let limit = PDFPageRenderer.distinctPageLimit
        let source = try PDFSource(url: makeImagePDF(pageCount: limit + 1))
        let entries = try await source.entries()
        for entry in entries.prefix(limit) {
            _ = try await source.image(for: entry, maxPixelSize: nil)
        }
        let before = await source.debugRendererStatistics()
        for _ in 0..<3 {
            _ = try await source.loupeImage(for: entries[limit - 1], pixelScale: 3)
            _ = try await source.image(for: entries[limit - 1], maxPixelSize: 256)
        }
        let after = await source.debugRendererStatistics()
        XCTAssertEqual(after.display, before.display)
        _ = try await source.image(for: entries[limit], maxPixelSize: nil)
        let switched = await source.debugRendererStatistics()
        XCTAssertEqual(switched.display.first?.recycleCount, 1)
        XCTAssertEqual(switched.display.first?.distinctPageCount, 1)
    }

    func testParallelDistinctImagePagesStayWithinEachRendererBudget() async throws {
        let limit = PDFPageRenderer.distinctPageLimit
        let count = limit * 6
        let source = try PDFSource(url: makeImagePDF(pageCount: count))
        let entries = try await source.entries()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { _ = try await source.image(for: entry, maxPixelSize: nil) }
            }
            try await group.waitForAll()
        }
        let stats = await source.debugRendererStatistics()
        XCTAssertTrue((1...3).contains(stats.display.count))
        XCTAssertTrue(stats.display.allSatisfy { (1...limit).contains($0.distinctPageCount) })
        XCTAssertEqual(stats.display.reduce(0) { $0 + $1.distinctPageCount + $1.recycleCount * limit }, count)
        XCTAssertEqual(stats.display.reduce(0) { $0 + $1.recycleFailureCount }, 0)
    }

    func testRepeatedPagesBelowBudgetDoNotRecycle() async throws {
        let source = try PDFSource(url: makeImagePDF(pageCount: 2))
        let entries = try await source.entries()
        for _ in 0..<20 {
            for entry in entries { _ = try await source.image(for: entry, maxPixelSize: nil) }
        }
        let stats = await source.debugRendererStatistics()
        XCTAssertEqual(stats.display.first?.distinctPageCount, 2)
        XCTAssertEqual(stats.display.first?.recycleCount, 0)
    }

    func testPixelsAreEqualAfterDocumentRecycle() async throws {
        let limit = PDFPageRenderer.distinctPageLimit
        let source = try PDFSource(url: makeImagePDF(pageCount: limit))
        let entries = try await source.entries()
        let before = try await source.image(for: entries[0], maxPixelSize: nil)
        for entry in entries.dropFirst() {
            _ = try await source.image(for: entry, maxPixelSize: nil)
        }
        let after = try await source.image(for: entries[0], maxPixelSize: nil)
        XCTAssertEqual(after.width, before.width)
        XCTAssertEqual(after.height, before.height)
        XCTAssertEqual(try XCTUnwrap(pixelData(of: after)), try XCTUnwrap(pixelData(of: before)))
        let stats = await source.debugRendererStatistics()
        XCTAssertEqual(stats.display.first?.recycleCount, 1)
    }

    func testThumbnailCacheUsesAndReleasesSeparateRenderer() async throws {
        let source = try PDFSource(url: makeImagePDF(pageCount: 12))
        let entries = try await source.entries()
        _ = try await source.image(for: entries[0], maxPixelSize: nil)
        let before = await source.debugRendererStatistics()
        let cache = ThumbnailCache(diskRoot: tempDir.appendingPathComponent("thumbnails"))
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask {
                    let image = await cache.thumbnail(for: entry, in: source, bookKey: "pdf")
                    XCTAssertNotNil(image)
                }
            }
        }
        let after = await source.debugRendererStatistics()
        XCTAssertEqual(after.display, before.display)
        XCTAssertGreaterThan(after.thumbnailBatches, 0)
        XCTAssertFalse(after.thumbnailActive)
        // 新しい一群も専用文書を作り、表示の温存状態を使わない(設計書 §5)。
        _ = try await PageRequestIntent.$isThumbnail.withValue(true) {
            try await source.image(for: entries[1], maxPixelSize: 50)
        }
        let nextBatch = await source.debugRendererStatistics()
        XCTAssertEqual(nextBatch.thumbnailBatches, after.thumbnailBatches + 1)
        XCTAssertFalse(nextBatch.thumbnailActive)
    }

    func testEncryptedFileAndMemoryPDFRecycleWithoutAnotherUnlock() async throws {
        let count = PDFPageRenderer.distinctPageLimit + 2
        let document = try XCTUnwrap(PDFDocument(url: makeImagePDF(pageCount: count)))
        let data = try XCTUnwrap(document.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "sesame",
            PDFDocumentWriteOption.ownerPasswordOption: "sesame",
        ]))
        let url = tempDir.appendingPathComponent("recycle-locked.pdf")
        try data.write(to: url)
        for memoryBacked in [false, true] {
            let source = try memoryBacked ? PDFSource(data: data) : PDFSource(url: url)
            let locked = await source.isEncrypted()
            XCTAssertTrue(locked)
            let accepted = await source.checkAndSetPassword("sesame")
            XCTAssertEqual(accepted, .accepted)
            let entries = try await source.entries()
            let before = try await source.image(for: entries[0], maxPixelSize: nil)
            for entry in entries.dropFirst() {
                _ = try await source.image(for: entry, maxPixelSize: nil)
            }
            let after = try await source.image(for: entries[0], maxPixelSize: nil)
            XCTAssertEqual(try XCTUnwrap(pixelData(of: after)), try XCTUnwrap(pixelData(of: before)))
            let stats = await source.debugRendererStatistics()
            XCTAssertEqual(stats.display.first?.recycleCount, 1)
            let protected = await source.containsProtectedContent()
            XCTAssertTrue(protected)
            let thumbnail = try await PageRequestIntent.$isThumbnail.withValue(true) {
                try await source.image(for: entries[0], maxPixelSize: 50)
            }
            XCTAssertEqual(thumbnail.height, 50)
        }
    }

    func testFailedThumbnailRenderReleasesBatch() async throws {
        let source = try PDFSource(url: makePDF())
        let invalid = PageEntry(id: -1, name: "invalid", pathInBook: "invalid",
                                fileURL: nil, creationDate: nil, modificationDate: nil)
        do {
            _ = try await PageRequestIntent.$isThumbnail.withValue(true) {
                try await source.image(for: invalid, maxPixelSize: 50)
            }
            XCTFail("無効なページは失敗する")
        } catch BookSourceError.pageLoadFailed(let name) {
            XCTAssertEqual(name, "invalid")
        }
        let stats = await source.debugRendererStatistics()
        XCTAssertFalse(stats.thumbnailActive)
        XCTAssertEqual(stats.thumbnailBatches, 1)
        XCTAssertTrue(stats.display.isEmpty)
    }

    func testUnavailableThumbnailRendererDoesNotDisableDisplayPoolGrowth() async throws {
        let url = try makePDF()
        let data = try Data(contentsOf: url)
        let source = try PDFSource(url: url)
        let entry = try await source.entries()[0]
        try FileManager.default.removeItem(at: url)
        let thumbnail = try await PageRequestIntent.$isThumbnail.withValue(true) {
            try await source.image(for: entry, maxPixelSize: 50)
        }
        XCTAssertEqual(thumbnail.width, 50)
        try data.write(to: url, options: .atomic)
        _ = try await source.image(for: entry, maxPixelSize: nil)
        let stats = await source.debugRendererStatistics()
        XCTAssertEqual(stats.display.count, 1)
        XCTAssertEqual(stats.thumbnailBatches, 0)
    }

    func testRecycleFailureKeepsOldDocumentAndRetriesAfterRecovery() async throws {
        let limit = PDFPageRenderer.distinctPageLimit
        let url = try makeImagePDF(pageCount: limit + 2)
        let original = try Data(contentsOf: url)
        let source = try PDFSource(url: url)
        let entries = try await source.entries()
        for entry in entries.prefix(limit) {
            _ = try await source.image(for: entry, maxPixelSize: nil)
        }
        // ページ数が違う差し替えは再生成で採用せず、旧文書の読み取りを継続する(設計書 §7.4)。
        let replacement = try makePDF()
        try Data(contentsOf: replacement).write(to: url, options: .atomic)
        _ = try await source.image(for: entries[limit], maxPixelSize: nil)
        let failed = await source.debugRendererStatistics()
        XCTAssertEqual(failed.display.first?.recycleCount, 0)
        XCTAssertEqual(failed.display.first?.recycleFailureCount, 1)
        let parallel = await source.currentlySupportsParallelPageLoads()
        XCTAssertTrue(parallel)
        try original.write(to: url, options: .atomic)
        _ = try await source.image(for: entries[limit + 1], maxPixelSize: nil)
        let recovered = await source.debugRendererStatistics()
        XCTAssertEqual(recovered.display.first?.recycleCount, 1)
        XCTAssertEqual(recovered.display.first?.distinctPageCount, 1)
    }

    /// ページ毎に赤矩形の位置が違う PDF(並列レンダリングの取り違え検出用)
    private func makeMarkedPDF(pageCount: Int) throws -> URL {
        let url = tempDir.appendingPathComponent("marked.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: CGFloat(page) * 40, y: 30, width: 40, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// レンダラープールでの並列描画がページを取り違えないこと
    func testParallelRendersReturnCorrectPages() async throws {
        let source = try PDFSource(url: makeMarkedPDF(pageCount: 4))
        let entries = try await source.entries()
        let supportsParallel = await source.currentlySupportsParallelPageLoads()
        XCTAssertTrue(supportsParallel)
        // 4 ページ x 2 周を同時に要求し、各結果の赤矩形位置でページを検証
        try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for round in 0..<2 {
                for (index, entry) in entries.enumerated() {
                    _ = round
                    group.addTask {
                        (index, try await source.image(for: entry, maxPixelSize: nil))
                    }
                }
            }
            for try await (index, image) in group {
                XCTAssertEqual(image.width, 200)
                let pixels = try XCTUnwrap(self.pixelData(of: image))
                // ページ n の赤矩形は x = 40n..40n+40(中心をサンプリング)
                let center = self.pixel(pixels, image, x: index * 40 + 20, y: 50)
                XCTAssertGreaterThan(center[0], 200, "page \(index) red marker")
                XCTAssertLessThan(center[1], 80, "page \(index) red marker")
            }
        }
    }

    /// 暗号化 PDF: 解除後はプールのレンダラーにもパスワードが引き継がれること
    func testEncryptedPDFRendersAfterUnlock() async throws {
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 40, height: 60))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 60).fill()
        image.unlockFocus()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let data = try XCTUnwrap(document.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "sesame",
            PDFDocumentWriteOption.ownerPasswordOption: "sesame",
        ]))
        let url = tempDir.appendingPathComponent("locked.pdf")
        try data.write(to: url)

        let source = try PDFSource(url: url)
        let encrypted = await source.isEncrypted()
        XCTAssertTrue(encrypted)
        let unlocked = await source.checkAndSetPassword("sesame")
        XCTAssertEqual(unlocked, .accepted)
        let entries = try await source.entries()
        // 並列に複数要求してもプール(独立文書)側の解錠で描画できること
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await source.image(for: entries[0], maxPixelSize: nil)
                }
            }
            for try await rendered in group {
                XCTAssertGreaterThan(rendered.width, 0)
            }
        }
    }

    func testLoupeImageRendersAtRequestedScale() async throws {
        let source = try PDFSource(url: makePDFForLoupe())
        let entry = try await source.entries()[0]
        let image = try await source.loupeImage(for: entry, pixelScale: 4)
        XCTAssertEqual(image.width, 800)   // 200pt x4
        XCTAssertEqual(image.height, 400)
    }

    private func makePDFForLoupe() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
