import CoreGraphics
import XCTest
@testable import cooViewer

/// ソースへのロード回数を数えるスタブ(キャッシュヒットの検証用)
private actor CountingSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/counting")
    nonisolated var supportsDateSort: Bool { false }
    private(set) var loadCount = 0

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "a.png", pathInBook: "a.png",
                   fileURL: nil, creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        loadCount += 1
        return try ImageDecoding.decode(
            TestFixtures.pngData(width: 40, height: 60), maxPixelSize: maxPixelSize)
    }
}

final class ThumbnailCacheTests: XCTestCase {
    private var diskRoot: URL!

    override func setUpWithError() throws {
        diskRoot = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: diskRoot)
    }

    func testSecondRequestHitsMemoryCache() async throws {
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = CountingSource()
        let entry = try await source.entries()[0]

        let first = await cache.thumbnail(for: entry, in: source, bookKey: "book1")
        let second = await cache.thumbnail(for: entry, in: source, bookKey: "book1")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let loads = await source.loadCount
        XCTAssertEqual(loads, 1)

        // ディスクにも書かれている
        let file = diskRoot.appendingPathComponent("book1/0.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFreshInstanceHitsDiskCache() async throws {
        let source = CountingSource()
        let entry = try await source.entries()[0]
        _ = await ThumbnailCache(diskRoot: diskRoot)
            .thumbnail(for: entry, in: source, bookKey: "book1")

        // メモリを持たない新インスタンス=ディスクから復元(ソースは呼ばれない)
        let fresh = ThumbnailCache(diskRoot: diskRoot)
        let image = await fresh.thumbnail(for: entry, in: source, bookKey: "book1")
        XCTAssertNotNil(image)
        let loads = await source.loadCount
        XCTAssertEqual(loads, 1)
    }

    func testTrimDiskCacheRemovesOldBooks() async throws {
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = CountingSource()
        let entry = try await source.entries()[0]
        _ = await cache.thumbnail(for: entry, in: source, bookKey: "oldbook")

        let bookDir = diskRoot.appendingPathComponent("oldbook")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -40 * 86400)],
            ofItemAtPath: bookDir.path)
        await cache.trimDiskCache(olderThanDays: 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookDir.path))
    }
}
