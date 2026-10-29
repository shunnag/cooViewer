import CoreGraphics
import XCTest
@testable import cooViewer

final class PDFDisplayColorBookTests: XCTestCase {
    /// PDF も画面移動で表示キャッシュを失効させ、同じページを新しい RGB で描く(設計書 §5)。
    @MainActor
    func testScreenChangeInvalidatesCachedPDFPage() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("page.pdf")
        var box = CGRect(x: 0, y: 0, width: 80, height: 120)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let source = try PDFSource(url: url)
        let entries = try await source.entries()
        let book = Book(source: source, prepared: .init(sortedEntries: entries, cacheKey: "pdf-profile"))
        var previous: CGImage?
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.sRGB] {
            let target = DisplayColorTarget(rgb: try XCTUnwrap(CGColorSpace(name: name)))
            XCTAssertTrue(book.updateDisplayColorTarget(target))
            let result = await book.image(at: 0)
            let image = try XCTUnwrap(result)
            XCTAssertEqual(image.colorSpace, target.rgb)
            XCTAssertFalse(image === previous)
            let cached = await book.image(at: 0)
            XCTAssertTrue(cached === image)
            XCTAssertFalse(book.updateDisplayColorTarget(target))
            previous = image
        }
    }
}
