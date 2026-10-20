import Foundation
import XCTest
@testable import cooViewer

final class ArchiveDecodedStateCacheTests: XCTestCase {
    func testRecentOwnersRemainAndBusyOwnerIsNeverReleased() async {
        let cache = ArchiveDecodedStateCache(limit: 2)
        let first = DecoderOwner(), second = DecoderOwner(), third = DecoderOwner()
        await cache.recordUse(first)
        await cache.recordUse(second)
        await cache.recordUse(first)
        await cache.recordUse(third)
        let firstCount = await first.releases, secondCount = await second.releases
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
        await first.setBusy(true)
        await cache.recordUse(second)
        let whileBusy = await first.releases
        XCTAssertEqual(whileBusy, 0)
        await first.setBusy(false)
        await cache.recordUse(second)
        await cache.recordUse(third)
        let afterIdle = await first.releases
        XCTAssertEqual(afterIdle, 1)
    }

    func testManyRetainedSourcesKeepFewIdleExtractorsAndRevisitCorrectly() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var sources: [ArchiveSource] = []
        for index in 0..<20 {
            let url = root.appendingPathComponent("book-\(index).zip")
            try TestFixtures.storedZip(entries: [(Array("page.avifs".utf8),
                TestFixtures.pngData(width: 40 + index, height: 60))]).write(to: url)
            let source = try ArchiveSource(url: url)
            let pages = try await source.entries()
            let image = try await source.image(for: pages[0], maxPixelSize: nil)
            XCTAssertEqual(image.width, 40 + index)
            sources.append(source)
        }
        var retained = 0
        for source in sources { retained += await source.extractorCount }
        XCTAssertLessThanOrEqual(retained, ArchiveDecodedStateCache.maximumIdleBooks)
        for index in [0, 19, 1, 18] {
            let pages = try await sources[index].entries()
            let image = try await sources[index].image(for: pages[0], maxPixelSize: nil)
            XCTAssertEqual(image.width, 40 + index)
        }
    }

    func testSolidSevenZipRevisitAfterEvictionKeepsPagesAndBytes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "solid", withExtension: "7z"))
        var sources: [ArchiveSource] = []
        var expected: [Data] = []
        var pageIDs: [[Int]] = []
        for _ in 0..<(ArchiveDecodedStateCache.maximumIdleBooks + 4) {
            let source = try ArchiveSource(url: fixture)
            let pages = try await source.entries()
            let bytes = await source.imageData(for: pages[0])
            expected.append(try XCTUnwrap(bytes))
            _ = try await source.image(for: pages[0], maxPixelSize: nil)
            pageIDs.append(pages.map(\.id))
            sources.append(source)
        }
        let last = sources.count - 1
        for index in [0, last, 1, last - 1] {
            let pages = try await sources[index].entries()
            XCTAssertEqual(pages.map(\.id), pageIDs[index])
            let bytes = await sources[index].imageData(for: pages[0])
            XCTAssertEqual(bytes, expected[index])
            let image = try await sources[index].image(for: pages[0], maxPixelSize: nil)
            XCTAssertEqual(image.width, 4)
        }
    }
}

private actor DecoderOwner: ArchiveDecodedStateOwner {
    private var busy = false
    private(set) var releases = 0
    func setBusy(_ value: Bool) { busy = value }
    func releaseIdleDecodedState() -> Bool {
        guard !busy else { return false }
        releases += 1
        return true
    }
}
