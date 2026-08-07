import CoreGraphics
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
