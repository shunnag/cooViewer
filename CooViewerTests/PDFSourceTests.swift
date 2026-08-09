import AppKit
import CoreGraphics
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
        XCTAssertTrue(unlocked)
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
