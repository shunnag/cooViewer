import AppKit
import XCTest
@testable import Washi

/// cooViewer-oxr.2: 非表示ウインドウでも FXL ラスタライズが完了すること。
@MainActor
final class EPUBPageRasterizerTests: XCTestCase {
    func testSingleImageFixedLayoutPageReturns() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.fxlComicEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-rasterizer-image.epub"))
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertNotNil(info.simpleImagePath)
        try await assertRasterizedPage(publication: publication,
                                       viewport: CGSize(width: 1200, height: 1920))
    }

    func testComplexFixedLayoutPageReturns() async throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(Self.complexFixedLayoutEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-rasterizer-complex.epub"))
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertNil(info.simpleImagePath)
        try await assertRasterizedPage(publication: publication,
                                       viewport: CGSize(width: 600, height: 800))
    }

    private func assertRasterizedPage(publication: EPUBPublication,
                                      viewport: CGSize) async throws {
        let rasterizer = EPUBPageRasterizer(publication: publication)
        defer { rasterizer.invalidate() }
        let race = RenderRace()
        let renderTask = Task(priority: .userInitiated) { @MainActor in
            do {
                let image = try await rasterizer.renderPage(
                    atSpineIndex: 0, maxPixelSize: 300)
                race.finish(with: .image(image))
            } catch {
                race.finish(with: .error(error))
            }
        }
        let watchdogTask = Task(priority: .userInitiated) { @MainActor in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            race.finish(with: .timedOut)
        }

        let outcome = await race.wait()
        renderTask.cancel()
        watchdogTask.cancel()
        let image: CGImage
        switch outcome {
        case let .image(renderedImage):
            image = renderedImage
        case let .error(error):
            throw error
        case .timedOut:
            XCTFail("renderPage did not return")
            return
        }

        let longEdge = max(image.width, image.height)
        XCTAssertEqual(longEdge, 300, accuracy: 2)
        let expectedAspectRatio = viewport.width / viewport.height
        let actualAspectRatio = CGFloat(image.width) / CGFloat(image.height)
        XCTAssertEqual(actualAspectRatio, expectedAspectRatio, accuracy: 0.02)
        XCTAssertTrue(Self.containsNonBlackPixel(image),
                      "ラスタライズ結果が全面黒ではないこと")
    }

    /// 8x8 へ縮小して複数地点を読み、全画素が黒の画像を検出する。
    private static func containsNonBlackPixel(_ image: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return false }
        return stride(from: 0, to: pixels.count, by: 4).contains { offset in
            pixels[offset] > 8 || pixels[offset + 1] > 8 || pixels[offset + 2] > 8
        }
    }

    private static func complexFixedLayoutEntries() -> [(name: String, data: Data)] {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:rasterizer-complex</dc:identifier>
                <dc:title>Complex fixed-layout page</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-03T00:00:00Z</meta>
                <meta property="rendition:layout">pre-paginated</meta>
              </metadata>
              <manifest>
                <item id="page" href="page.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="page"/></spine>
            </package>
            """
        let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head>
                <title>複雑固定ページ</title>
                <meta name="viewport" content="width=600, height=800"/>
                <style>html,body{margin:0;width:600px;height:800px;background:#fff}
                p{margin:48px;font-size:42px;color:#111}</style>
              </head>
              <body>
                <p>固定レイアウトの本文</p>
                <svg xmlns="http://www.w3.org/2000/svg" width="360" height="240"
                     viewBox="0 0 360 240">
                  <rect x="20" y="20" width="320" height="200" fill="#2878d0"/>
                </svg>
              </body>
            </html>
            """
        return [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/page.xhtml", Data(xhtml.utf8)),
        ]
    }
}

@MainActor
private final class RenderRace {
    enum Outcome {
        case image(CGImage)
        case error(any Error)
        case timedOut
    }

    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(with outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
