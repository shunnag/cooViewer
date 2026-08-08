import CoreGraphics
import XCTest
@testable import cooViewer

/// 常に失敗するスタブ(生成失敗のネガティブキャッシュ検証用)
private actor FailingSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/failing")
    nonisolated var supportsDateSort: Bool { false }
    private(set) var attemptCount = 0

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "broken.png", pathInBook: "broken.png",
                   fileURL: nil, creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        attemptCount += 1
        throw BookSourceError.pageLoadFailed(entry.name)
    }
}

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
        let file = diskRoot.appendingPathComponent("book1/0.heic")
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

    func testFailedGenerationIsNotRetried() async throws {
        // 生成失敗(壊れページ・パスワード付きネスト書庫等)は記録され、
        // 画面に入り直すたびに展開し直さない(ネガティブキャッシュ)
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = FailingSource()
        let entry = try await source.entries()[0]

        let first = await cache.thumbnail(for: entry, in: source, bookKey: "bad")
        let second = await cache.thumbnail(for: entry, in: source, bookKey: "bad")
        XCTAssertNil(first)
        XCTAssertNil(second)
        let attempts = await source.attemptCount
        XCTAssertEqual(attempts, 1, "失敗ページに再挑戦しないこと")
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
    func testPresentPrefetchesCurrentAndAdjacentScreens() async throws {
        let source = MultiPageCountingSource()
        let entries = try await source.entries()
        let book = Book(source: source, entries: entries)
        // 実 UserDefaults に依存しないよう専用スイートを注入する
        let defaults = UserDefaults(suiteName: "thumb-test-\(UUID().uuidString)")!
        defaults.set(["row": 2, "column": 2], forKey: "Thumbnail")
        let model = ThumbnailOverlayModel(defaults: defaults)

        // 1 画面 4 セル(単ページ)で present → 画面 0 と 1 の 8 ページ全て先読み
        model.present(book: book)
        await model.waitForPrefetch()
        let loaded = await source.loadedIDs
        XCTAssertEqual(loaded, Set(0..<8))
    }
}

@MainActor
final class ThumbnailCancellationTests: XCTestCase {
    func testAbandonedRequestIsCancelledBeforeSourceWork() async throws {
        // e0 の生成がソースを塞いでいる間に e1 を要求し、待ち手を即キャンセル
        // → e1 のソース呼び出しは実行されない(遠いページの早期破棄)
        let source = MultiPageCountingSourceForCancel()
        let entries = try await source.entries()
        let diskRoot = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: diskRoot) }
        let cache = ThumbnailCache(diskRoot: diskRoot)

        let blocker = Task {
            await cache.thumbnail(for: entries[0], in: source, bookKey: "cxl")
        }
        try? await Task.sleep(for: .milliseconds(30))  // e0 がソース占有中
        let abandoned = Task {
            await cache.thumbnail(for: entries[1], in: source, bookKey: "cxl")
        }
        try? await Task.sleep(for: .milliseconds(20))
        abandoned.cancel()
        _ = await blocker.value
        _ = await abandoned.value
        try? await Task.sleep(for: .milliseconds(100))
        let loaded = await source.loadedIDs
        XCTAssertTrue(loaded.contains(0))
        XCTAssertFalse(loaded.contains(1), "破棄済み要求のソース実行は行わない")
    }
}

/// 1 件目が長時間ソースを占有するスタブ(キャンセル脱落の検証用)
private actor MultiPageCountingSourceForCancel: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/cancel-\(UUID().uuidString)")
    nonisolated var supportsDateSort: Bool { false }
    private(set) var loadedIDs: Set<Int> = []

    func entries() async throws -> [PageEntry] {
        (0..<2).map {
            PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 実ソースと同じ脱落点
        loadedIDs.insert(entry.id)
        if entry.id == 0 {
            // 実書庫(XADMaster)と同様に actor を同期ブロックで占有する
            // (Task.sleep だと再入可能になり後続がすぐ実行されてしまう)
            usleep(200_000)
        }
        return try ImageDecoding.decode(
            TestFixtures.pngData(width: 10, height: 10), maxPixelSize: maxPixelSize)
    }
}

@MainActor
final class ThumbnailWaiterHandoffTests: XCTestCase {
    func testNewWaiterAfterAbandonmentRegenerates() async throws {
        // 待ち手ゼロでキャンセルされた生成の直後に来た新しい要求が、
        // キャンセル済みタスクに合流せず作り直して画像を得られること
        let source = MultiPageCountingSourceForCancel()
        let entries = try await source.entries()
        let diskRoot = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: diskRoot) }
        let cache = ThumbnailCache(diskRoot: diskRoot)

        let blocker = Task {
            await cache.thumbnail(for: entries[0], in: source, bookKey: "handoff")
        }
        try? await Task.sleep(for: .milliseconds(30))
        let abandoned = Task {
            await cache.thumbnail(for: entries[1], in: source, bookKey: "handoff")
        }
        try? await Task.sleep(for: .milliseconds(20))
        abandoned.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        // 破棄直後の再要求(先読みの世代交代/セルの再訪に相当)
        let image = await cache.thumbnail(
            for: entries[1], in: source, bookKey: "handoff")
        XCTAssertNotNil(image, "作り直した生成で画像が得られること")
        _ = await blocker.value
        _ = await abandoned.value
    }

    func testRapidCancelAndRerequestAlwaysYieldsImage() async throws {
        // サムネイル画面の素早い往復の再現: 同じキーへの要求→即キャンセル→
        // 再要求を繰り返しても、キャンセルしていない要求は必ず画像を得る
        // (旧世代の遅延キャンセル通知が新世代の生成を壊さないこと)
        let source = CountingSource()
        let entry = try await source.entries()[0]
        for round in 0..<10 {
            let diskRoot = try TestFixtures.makeTempDir()
            defer { try? FileManager.default.removeItem(at: diskRoot) }
            let cache = ThumbnailCache(diskRoot: diskRoot)
            let abandoned = Task {
                await cache.thumbnail(for: entry, in: source, bookKey: "rapid")
            }
            try? await Task.sleep(for: .milliseconds(5))
            abandoned.cancel()
            let image = await cache.thumbnail(
                for: entry, in: source, bookKey: "rapid")
            XCTAssertNotNil(image, "round \(round): 生き残った要求が画像を得ること")
            _ = await abandoned.value
        }
    }
}
