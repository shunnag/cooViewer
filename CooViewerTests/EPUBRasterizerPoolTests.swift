import AppKit
import Washi
import XCTest
@testable import cooViewer

/// 単一画像へ還元できない FXL を実 WebKit で描画し、複数冊の寿命競合を検査する。
@MainActor
final class EPUBRasterizerPoolTests: XCTestCase {
    func testConcurrentPublicationsAllProduceTheirOwnImages() async throws {
        let sources = try (0..<3).map { channel in
            let publication = try makePublication(channel: channel)
            return try EPUBSource(publication: publication, url: publication.url)
        }
        var jobs: [Task<CGImage, any Error>] = []
        for source in sources {
            let entry = try await source.entries()[0]
            jobs.append(Task { try await source.image(for: entry, maxPixelSize: 96) })
        }
        for (channel, job) in jobs.enumerated() {
            switch await job.result {
            case .success(let image):
                XCTAssertGreaterThan(image.width, 0)
                XCTAssertLessThanOrEqual(max(image.width, image.height), 96)
                XCTAssertEqual(dominantChannel(image), channel)
            case .failure(let error):
                XCTFail("別冊の開始が描画\(channel)を中断した: \(error)")
            }
        }
        withExtendedLifetime(sources) {}
    }

    func testUnusedSourceDeinitDoesNotCancelAnotherSourcesRenders() async throws {
        let publication = try makePublication(channel: 0)
        let source = try EPUBSource(publication: publication, url: publication.url)
        var unused: EPUBSource? = try EPUBSource(publication: publication, url: publication.url)
        weak var unusedReference = unused
        let entry = try await source.entries()[0]
        let jobs = (0..<6).map { _ in
            Task { try await source.image(for: entry, maxPixelSize: 96) }
        }
        // 最初の完成で、共有レンダラが存在し、後続の要求が投入済みと分かる。
        _ = try await jobs[0].value
        XCTAssertNotNil(unusedReference)
        unused = nil
        XCTAssertNil(unusedReference)
        await Task.yield()
        for job in jobs.dropFirst() {
            switch await job.result {
            case .success(let image): XCTAssertEqual(dominantChannel(image), 0)
            case .failure(let error): XCTFail("未使用ソースの破棄が描画を中断した: \(error)")
            }
        }
        withExtendedLifetime(source) {}
    }

    func testCancelledRequestDoesNotPreventLaterPublicationFromRendering() async throws {
        let sources = try (0..<4).map { channel in
            let publication = try makePublication(channel: channel % 3)
            return try EPUBSource(publication: publication, url: publication.url)
        }
        var jobs: [Task<CGImage, any Error>] = []
        for (index, source) in sources.enumerated() {
            let entry = try await source.entries()[0]
            let job = Task { try await source.image(for: entry, maxPixelSize: 96) }
            if index == 2 { job.cancel() }
            jobs.append(job)
        }
        for (index, job) in jobs.enumerated() {
            switch await job.result {
            case .success(let image):
                XCTAssertNotEqual(index, 2)
                XCTAssertEqual(dominantChannel(image), index % 3)
            case .failure(let error):
                XCTAssertEqual(index, 2, "後続要求の描画枠を失わない: \(error)")
                XCTAssertTrue(error is CancellationError)
            }
        }
        withExtendedLifetime(sources) {}
    }

    private func dominantChannel(_ image: CGImage) -> Int? {
        var pixel = [UInt8](repeating: 0, count: 4)
        return pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (0..<3).max { buffer[$0] < buffer[$1] }
        }
    }

    private func makePublication(channel: Int) throws -> EPUBPublication {
        let container = """
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/package.opf"
            media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">rasterizer-\(channel)</dc:identifier>
            <dc:title>描画\(channel)</dc:title><dc:language>ja</dc:language>
            <meta property="rendition:layout">pre-paginated</meta>
          </metadata>
          <manifest><item id="page" href="page.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="page"/></spine>
        </package>
        """
        let color = (0..<3).map { $0 == channel ? "240" : "32" }.joined(separator: ",")
        let page = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
          <meta name="viewport" content="width=64, height=96"/>
          <style>html,body { margin:0; width:100%; height:100%; background:rgb(\(color)); }
            p { margin:0; font-size:8px; }</style>
        </head><body><p>FXL \(channel)</p></body></html>
        """
        let data = TestFixtures.storedZip(entries: [
            (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
            (Array("META-INF/container.xml".utf8), Data(container.utf8)),
            (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
            (Array("OEBPS/page.xhtml".utf8), Data(page.utf8)),
        ])
        let publication = try EPUBPublication(data: data,
            displayURL: URL(fileURLWithPath: "/test/rasterizer-\(channel).epub"))
        XCTAssertNil(try publication.fixedLayoutInfo(forSpineIndex: 0).simpleImagePath)
        return publication
    }
}
