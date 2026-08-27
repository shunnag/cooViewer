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

/// 1 回目だけ失敗し、以後は成功するスタブ(一時失敗の再挑戦検証用)
private actor FlakyOnceSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/flaky")
    nonisolated var supportsDateSort: Bool { false }
    private(set) var attemptCount = 0

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "flaky.png", pathInBook: "flaky.png",
                   fileURL: nil, creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        attemptCount += 1
        if attemptCount == 1 {
            // 併走する待ち手が同じ失敗生成に合流できる時間を確保する
            try? await Task.sleep(for: .milliseconds(60))
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return try ImageDecoding.decode(
            TestFixtures.pngData(width: 40, height: 60), maxPixelSize: maxPixelSize)
    }
}

/// 同時実行数を計測するスタブ(生成ゲートの検証用)
private actor ConcurrencyProbeSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/probe")
    nonisolated var supportsDateSort: Bool { false }
    private var active = 0
    private(set) var maxActive = 0

    func entries() async throws -> [PageEntry] {
        (0..<12).map {
            PageEntry(id: $0, name: "\($0).png", pathInBook: "\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        active += 1
        maxActive = max(maxActive, active)
        try? await Task.sleep(for: .milliseconds(40))
        active -= 1
        return try ImageDecoding.decode(
            TestFixtures.pngData(width: 20, height: 30), maxPixelSize: maxPixelSize)
    }
}

/// 最初の N 回だけ失敗し、以後は成功するスタブ(TTL 回復の検証用)
private actor FlakyNTimesSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/flaky-n")
    nonisolated var supportsDateSort: Bool { false }
    private var failuresRemaining: Int
    private(set) var attemptCount = 0

    init(failures: Int) {
        failuresRemaining = failures
    }

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "n.png", pathInBook: "n.png",
                   fileURL: nil, creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        attemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return try ImageDecoding.decode(
            TestFixtures.pngData(width: 40, height: 60), maxPixelSize: maxPixelSize)
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

/// 生成がソースへ届いた時点の優先度を記録するスタブ(urgent レーン検証用)
private actor PriorityRecordingSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/prio")
    nonisolated var supportsDateSort: Bool { false }
    private(set) var observed: TaskPriority?

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "a.png", pathInBook: "a.png",
                   fileURL: nil, creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        observed = Task.currentPriority  // 生成が源へ届いた時点の優先度
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

    // MARK: - urgent の 2 段目レーン(cooViewer-470)

    func testUrgentGenerationReachesSourceAtInteractivePriority() async throws {
        // urgent の生成タスクは userInitiated 起動 → 源へ届く時点でも userInitiated
        // 以上(基底が床なのでエスカレーションで下がらない)。直 await で決定論的
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = PriorityRecordingSource()
        let entry = try await source.entries()[0]
        _ = await cache.thumbnail(for: entry, in: source, bookKey: "u", urgent: true)
        let observed = await source.observed
        XCTAssertNotNil(observed)
        XCTAssertGreaterThanOrEqual(observed!, .userInitiated)
    }

    func testNonUrgentGenerationStaysBelowInteractive() async throws {
        // 先読み(urgent:false)は utility のまま。テスト本体から await すると
        // エスカレーションで判定が壊れるため、記録アクター越しにサイドチャネル観測
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = PriorityRecordingSource()
        let entry = try await source.entries()[0]
        let probe = Task.detached(priority: .utility) {
            _ = await cache.thumbnail(for: entry, in: source, bookKey: "n", urgent: false)
        }
        while await source.observed == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let observed = await source.observed
        XCTAssertNotNil(observed)
        XCTAssertLessThan(observed!, .userInitiated)
        probe.cancel()
        _ = await probe.value
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

    func testFailedGenerationIsNotRetriedAfterTwoFailures() async throws {
        // 生成失敗(壊れページ・パスワード付きネスト書庫等)は 2 回の完走失敗で
        // 恒久記録され、以後は画面に入り直すたびに展開し直さない(ネガティブ
        // キャッシュ)。1 回目は再挑戦を許す — 多数 PDF の同時オープン直後の
        // 一時失敗を恒久プレースホルダにしないため
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = FailingSource()
        let entry = try await source.entries()[0]

        let first = await cache.thumbnail(for: entry, in: source, bookKey: "bad")
        let second = await cache.thumbnail(for: entry, in: source, bookKey: "bad")
        let third = await cache.thumbnail(for: entry, in: source, bookKey: "bad")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertNil(third)
        let attempts = await source.attemptCount
        XCTAssertEqual(attempts, 2, "2 回完走失敗した後は再挑戦しないこと")
    }

    func testTransientFailureIsRetriedEvenWithMultipleWaiters() async throws {
        // 1 回の完走失敗では恒久記録しない。複数の待ち手が同じ失敗生成に
        // 合流していても失敗は 1 回として数える(待ち手単位で数えると
        // 1 回の失敗で即恒久化してしまう)
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = FlakyOnceSource()
        let entry = try await source.entries()[0]

        async let a = cache.thumbnail(for: entry, in: source, bookKey: "flaky")
        async let b = cache.thumbnail(for: entry, in: source, bookKey: "flaky")
        let firstResults = await (a, b)
        XCTAssertNil(firstResults.0)
        XCTAssertNil(firstResults.1)

        // 再挑戦は新しい生成として走り、今度は成功する
        let retried = await cache.thumbnail(for: entry, in: source, bookKey: "flaky")
        XCTAssertNotNil(retried)
        let attempts = await source.attemptCount
        XCTAssertEqual(attempts, 2)
    }

    func testPermanentFailureIsForgivenAfterTTL() async throws {
        // 恒久記録には有効期限があり、期限が切れたら勘定ごと赦して再挑戦する
        // (稀な一時要因で 2 回失敗したページがセッション中ずっと欠けたままに
        // ならないように)
        let cache = ThumbnailCache(diskRoot: diskRoot,
                                   failureTTL: .milliseconds(50))
        let source = FailingSource()
        let entry = try await source.entries()[0]

        _ = await cache.thumbnail(for: entry, in: source, bookKey: "ttl")  // 1 回目
        _ = await cache.thumbnail(for: entry, in: source, bookKey: "ttl")  // 2 回目 → 恒久
        _ = await cache.thumbnail(for: entry, in: source, bookKey: "ttl")  // 期限内 → 即 nil
        var attempts = await source.attemptCount
        XCTAssertEqual(attempts, 2, "期限内は再挑戦しないこと")

        try? await Task.sleep(for: .milliseconds(200))
        _ = await cache.thumbnail(for: entry, in: source, bookKey: "ttl")  // 赦し → 再挑戦
        attempts = await source.attemptCount
        XCTAssertEqual(attempts, 3, "期限切れ後は赦して再挑戦すること")
    }

    func testPageEventuallyLoadsAfterTransientFailures() async throws {
        // 「待っても表示されない」の再発防止: 一時失敗が続いて一旦恒久記録に
        // 達しても、TTL 後の再要求(セルの再挑戦・開き直し)で必ず回復する
        let cache = ThumbnailCache(diskRoot: diskRoot,
                                   failureTTL: .milliseconds(50))
        let source = FlakyNTimesSource(failures: 3)
        let entry = try await source.entries()[0]

        var image: CGImage?
        for _ in 0..<40 {
            image = await cache.thumbnail(for: entry, in: source, bookKey: "heal")
            if image != nil { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertNotNil(image, "一時失敗が続いても最終的に必ず表示されること")
    }

    func testGenerationConcurrencyIsGated() async throws {
        // 多数のセルが一斉に生成要求しても、実生成の同時実行は 4 に絞られる
        // (多数の PDF 文書の並列レンダリング暴走の防止)
        let cache = ThumbnailCache(diskRoot: diskRoot)
        let source = ConcurrencyProbeSource()
        let entries = try await source.entries()

        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask {
                    _ = await cache.thumbnail(for: entry, in: source, bookKey: "gate")
                }
            }
        }
        let peak = await source.maxActive
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThanOrEqual(peak, 4, "生成ゲート(limit 4)を超えないこと")
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
        let model = ThumbnailOverlayModel(defaults: defaults)

        // 1 画面 4 セル(2×2。セル 160pt が 2 列 2 行入るビューポート)で
        // present → 画面 0 と 1 の 8 ページ全て先読み(±3 画面の先読み検証)
        model.updateViewport(CGSize(width: 340, height: 490))
        model.present(book: book)
        await model.waitForPrefetch()
        let loaded = await source.loadedIDs
        XCTAssertEqual(loaded, Set(0..<8))
    }
}

/// 大量ページのスタブ(先読み上限の検証用)
private actor ManyPageCountingSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/many-\(UUID().uuidString)")
    nonisolated var supportsDateSort: Bool { false }
    private(set) var loadedIDs: Set<Int> = []

    func entries() async throws -> [PageEntry] {
        (0..<600).map {
            PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        loadedIDs.insert(entry.id)
        return try ImageDecoding.decode(
            TestFixtures.pngData(width: 10, height: 14), maxPixelSize: maxPixelSize)
    }
}

@MainActor
final class ThumbnailPrefetchCapTests: XCTestCase {
    func testPrefetchTargetsAreCapped() async throws {
        // 自動グリッドの大画面(102 セル/画面)では ±3 画面 = 408 対象になるが、
        // 先読みは近い順「現在画面の 2 面ぶん」(= 204 件)で打ち切られること
        // (メモリ LRU 400 を 1 波で追い越して可視画面分を追い出さないための
        // 上限。下限 180・上限 360)。「近い順」= 現在画面が全数含まれ、
        // 対象は ±3 画面の範囲内に収まることも併せて検証する
        let source = ManyPageCountingSource()
        let entries = try await source.entries()
        let book = Book(source: source, entries: entries)
        let suite = "thumb-cap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = ThumbnailOverlayModel(defaults: defaults)
        model.updateViewport(CGSize(width: 3000, height: 1500))  // 17×6 = 102 セル
        model.present(book: book)
        await model.waitForPrefetch()
        let loaded = await source.loadedIDs
        XCTAssertEqual(loaded.count, 204)  // 102 × 2 面
        XCTAssertTrue(loaded.isSuperset(of: Set(0..<102)),
                      "現在画面の全ページが先読みに含まれること(近い順)")
        XCTAssertLessThan(loaded.max() ?? 0, 408, "±3 画面の範囲内であること")
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
