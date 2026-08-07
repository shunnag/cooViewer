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
        // 併走検証のため生成に時間がかかる状況を再現
        try? await Task.sleep(for: .milliseconds(80))
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

    func testConcurrentRequestsShareOneGeneration() async throws {
        // 併走する同一サムネイル要求は 1 回の生成を共有する(in-flight 共有)
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = CountingSource()
        let entry = try await source.entries()[0]
        async let first = cache.thumbnail(for: entry, in: source, bookKey: "dedup")
        async let second = cache.thumbnail(for: entry, in: source, bookKey: "dedup")
        let results = await (first, second)
        XCTAssertNotNil(results.0)
        XCTAssertNotNil(results.1)
        let loads = await source.loadCount
        XCTAssertEqual(loads, 1)
    }

    func testGenerationSurvivesCancelledWaiter() async throws {
        // 待ち手をキャンセルしても生成は完走し、後続要求が結果を得られる
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = CountingSource()
        let entry = try await source.entries()[0]
        let waiter = Task {
            await cache.thumbnail(for: entry, in: source, bookKey: "cancel")
        }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        let image = await cache.thumbnail(for: entry, in: source, bookKey: "cancel")
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

/// 複数ページのカウント付きスタブ(先読み検証用)
private actor MultiPageCountingSource: BookSource {
    // 実行ごとにユニークな本にする(ディスクキャッシュにヒットすると
    // ロード数の検証が空振りするため)
    nonisolated let url = URL(fileURLWithPath: "/stub/multi-\(UUID().uuidString)")
    nonisolated var supportsDateSort: Bool { false }
    private(set) var loadedIDs: Set<Int> = []

    func entries() async throws -> [PageEntry] {
        (0..<8).map {
            PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        loadedIDs.insert(entry.id)
        return try ImageDecoding.decode(
            TestFixtures.pngData(width: 10, height: 10), maxPixelSize: maxPixelSize)
    }
}

@MainActor
final class ThumbnailPrefetchTests: XCTestCase {
    func testPrefetchCoversCurrentAndAdjacentPages() async throws {
        let source = MultiPageCountingSource()
        let entries = try await source.entries()
        let book = Book(source: source, entries: entries)
        let model = ThumbnailOverlayModel()
        model.present(book: book)

        // 1 画面 4 セル(単ページ)で先頭画面を先読み → 画面 0 と 1 の 8 ページ全て
        let groups = entries.indices.map { [$0] }
        model.prefetchAdjacent(groups: groups, perPage: 4)
        await model.waitForPrefetch()
        let loaded = await source.loadedIDs
        XCTAssertEqual(loaded, Set(0..<8))
    }
}
