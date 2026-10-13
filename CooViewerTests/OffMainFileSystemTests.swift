import AppKit
import os
import Washi
import XCTest

@testable import cooViewer

/// 遅いファイルシステムの偽物。呼び出しごとに delay 秒眠り、どのスレッドから
/// 呼ばれたかと最後の完了時刻を記録する(メインアクターを止めないことの検証用)。
/// slowParent を指定すると、その親の列挙だけが遅い
private final class SlowProbe: FileSystemProbing, @unchecked Sendable {
    struct Record: Sendable {
        var calls = 0
        var mainThreadCalls = 0
        var listings = 0
        var lastFinishedAt: Date?
    }

    let started = XCTestExpectation(description: "最初の照会が始まった")
    private let items: [String: [DirectoryItem]]
    private let existing: Set<String>
    private let delay: TimeInterval
    private let slowParent: URL?
    private let state = OSAllocatedUnfairLock(initialState: Record())

    /// items: 親パス → 項目(キー "*" は全ての親に使う)
    init(items: [String: [DirectoryItem]] = [:], existing: Set<String> = [],
         delay: TimeInterval, slowParent: URL? = nil) {
        self.items = items
        self.existing = existing
        self.delay = delay
        self.slowParent = slowParent
    }

    var record: Record { state.withLock { $0 } }

    private func slowCall(sleeps: Bool = true) {
        let onMain = Thread.isMainThread
        let first = state.withLock { record in
            record.calls += 1
            if onMain { record.mainThreadCalls += 1 }
            return record.calls == 1
        }
        if first { started.fulfill() }
        if sleeps { Thread.sleep(forTimeInterval: delay) }
        state.withLock { $0.lastFinishedAt = Date() }
    }

    func directoryItems(at directory: URL) throws -> [DirectoryItem] {
        state.withLock { $0.listings += 1 }
        slowCall(sleeps: slowParent == nil || slowParent == directory)
        return items[directory.path] ?? items["*"] ?? []
    }

    func fileExists(atPath path: String) -> Bool {
        slowCall()
        return existing.contains(path)
    }

    func itemKind(at url: URL) -> (exists: Bool, isDirectory: Bool) {
        slowCall()
        return (existing.contains(url.path), false)
    }

    func identity(at url: URL) -> BookFileIdentity {
        slowCall()
        return BookFileIdentity(modified: 123, size: 456)
    }
}

/// 最初の照会で止まり resume() まで返さない偽物(待ちの最中に状態を変える検証用。
/// SlowProbe の時間待ちと違い、タイミングに依存しない)。以後の照会は即時に返る
private final class PausedProbe: FileSystemProbing, @unchecked Sendable {
    let started = XCTestExpectation(description: "最初の照会が止まった")
    private let release = DispatchSemaphore(value: 0)
    private let items: [DirectoryItem]
    private let existing: Set<String>
    private let state = OSAllocatedUnfairLock(initialState: (pausePending: true, mainThreadCalls: 0))

    init(items: [DirectoryItem] = [], existing: Set<String> = []) {
        self.items = items
        self.existing = existing
    }

    var mainThreadCalls: Int { state.withLock { $0.mainThreadCalls } }

    func resume() { release.signal() }

    private func pauseOnFirstCall() {
        let onMain = Thread.isMainThread
        let first = state.withLock { state in
            if onMain { state.mainThreadCalls += 1 }
            let first = state.pausePending
            state.pausePending = false
            return first
        }
        guard first else { return }
        started.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }

    func directoryItems(at directory: URL) throws -> [DirectoryItem] {
        pauseOnFirstCall()
        return items
    }

    func fileExists(atPath path: String) -> Bool {
        pauseOnFirstCall()
        return existing.contains(path)
    }

    func itemKind(at url: URL) -> (exists: Bool, isDirectory: Bool) {
        pauseOnFirstCall()
        return (existing.contains(url.path), false)
    }

    func identity(at url: URL) -> BookFileIdentity {
        pauseOnFirstCall()
        return BookFileIdentity(modified: 123, size: 456)
    }
}

/// 名前だけを持つ本(ソート・構築の検証用。画像は読めない)
private struct NamedEntriesSource: BookSource {
    var url = URL(fileURLWithPath: "/stub/sort-off-main")
    var names: [String]
    var supportsDateSort: Bool { true }

    var pages: [PageEntry] {
        names.enumerated().map { index, name in
            PageEntry(id: index, name: name, pathInBook: name, fileURL: nil,
                      creationDate: Date(timeIntervalSince1970: Double(names.count - index)),
                      modificationDate: nil)
        }
    }

    func entries() async throws -> [PageEntry] { pages }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        throw BookSourceError.pageLoadFailed(entry.name)
    }
}

@MainActor
private func makeHistory() throws -> BookHistoryStore {
    BookHistoryStore(defaults: UserDefaults(suiteName: "test.cooViewer.off-main.\(UUID())")!,
                     directory: try TestFixtures.makeTempDir())
}

// MARK: - 同フォルダの本一覧

@MainActor
final class SiblingBooksOffMainTests: XCTestCase {
    /// 旧 siblingBooks(of:) と同じ計算(contentsOfDirectory + 項目ごとの
    /// fileExists(isDirectory:))。新実装との等価性の基準
    private func legacySiblings(parent: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path)
        else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                let url = parent.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return isDirectory.boolValue || SupportedTypes.isBookFile(url)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { parent.appendingPathComponent($0).path }
    }

    func testScanMatchesLegacyComputationOnRealFolder() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        // 隠しファイル・フォルダ・対応/非対応拡張子・日本語(合成済み/分解済み)・
        // 番号付き名・シンボリックリンク(フォルダ向き/ファイル向き)
        for name in [".hidden.zip", ".DS_Store", "01 巻.zip", "2巻.cbz", "10.zip",
                     "がぎ.pdf", "か\u{3099}き.epub", "readme.txt", "page.png", "第3巻.rar",
                     "flagged.zip"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        // hidden フラグ付き(ドット始まりではない)。旧実装は名前だけで隠し判定
        // したので含まれる。`.skipsHiddenFiles` を使うとこれが落ちて結果がずれる
        var flagged = root.appendingPathComponent("flagged.zip")
        var values = URLResourceValues()
        values.isHidden = true
        try flagged.setResourceValues(values)
        for name in ["folder A", "フォルダ 2", "folder 10", ".hiddenFolder"] {
            try manager.createDirectory(at: root.appendingPathComponent(name),
                                        withIntermediateDirectories: true)
        }
        try manager.createSymbolicLink(at: root.appendingPathComponent("link to folder"),
                                       withDestinationURL: root.appendingPathComponent("folder A"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("link.zip"),
                                       withDestinationURL: root.appendingPathComponent("10.zip"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("link.txt"),
                                       withDestinationURL: root.appendingPathComponent("readme.txt"))

        let scanned = await SiblingBooks.scan(parent: root, probe: FileManagerProbe())
        XCTAssertEqual(scanned, legacySiblings(parent: root))
        XCTAssertTrue(scanned.contains(root.appendingPathComponent("link to folder").path))
        XCTAssertTrue(scanned.contains(root.appendingPathComponent("flagged.zip").path))
        XCTAssertFalse(scanned.contains(root.appendingPathComponent("page.png").path))
        XCTAssertFalse(scanned.contains(root.appendingPathComponent(".hiddenFolder").path))
    }

    func testSlowListingDoesNotBlockMainActorAndMatchesSynchronousScan() async throws {
        let items = [DirectoryItem(name: "b.zip", isDirectory: false),
                     DirectoryItem(name: "a", isDirectory: true),
                     DirectoryItem(name: "c.txt", isDirectory: false)]
        let probe = SlowProbe(items: ["*": items], delay: 0.3)
        let controller = ReaderWindowController(window: nil, history: try makeHistory())
        controller.fileSystemProbe = probe
        let current = URL(fileURLWithPath: "/stub/parent/b.zip")

        let listing = Task { await controller.siblingBooks(of: current) }
        let second = Task { await controller.siblingBooks(of: current) }
        let mainTick = OSAllocatedUnfairLock<Date?>(initialState: nil)
        let tick = Task { @MainActor in mainTick.withLock { $0 = Date() } }
        let paths = await listing.value
        await tick.value
        let finished = try XCTUnwrap(probe.record.lastFinishedAt)
        let tickAt = try XCTUnwrap(mainTick.withLock { $0 })
        XCTAssertLessThan(tickAt, finished, "走査中にメインアクターの別タスクが走る")
        XCTAssertEqual(probe.record.mainThreadCalls, 0)
        let synchronous = await SiblingBooks.scan(parent: current.deletingLastPathComponent(),
                                                  probe: SlowProbe(items: ["*": items], delay: 0))
        XCTAssertEqual(paths, synchronous)
        XCTAssertEqual(paths, ["/stub/parent/a", "/stub/parent/b.zip"])

        // 同時要求は 1 回の走査へ合流し、完了後はキャッシュから同期で返る
        let coalesced = await second.value
        XCTAssertEqual(coalesced, paths)
        let cached = await controller.siblingBooks(of: current)
        XCTAssertEqual(cached, paths)
        XCTAssertEqual(probe.record.listings, 1)
    }

    func testOldFolderResultCannotOverwriteNewFolderCache() async throws {
        let old = URL(fileURLWithPath: "/fixture/old")
        let new = URL(fileURLWithPath: "/fixture/new")
        let probe = SlowProbe(items: ["*": [DirectoryItem(name: "book.zip", isDirectory: false)]],
                              delay: 0.3, slowParent: old)
        let controller = ReaderWindowController(window: nil, history: try makeHistory())
        controller.fileSystemProbe = probe
        let listing = Task { await controller.siblingBooks(of: old.appendingPathComponent("a.zip")) }
        await fulfillment(of: [probe.started], timeout: 2)
        let newPaths = await controller.siblingBooks(of: new.appendingPathComponent("a.zip"))
        XCTAssertEqual(newPaths, [new.appendingPathComponent("book.zip").path])
        let stale = await listing.value
        XCTAssertEqual(stale, [old.appendingPathComponent("book.zip").path])
        // 遅れて届いた旧フォルダの結果は新フォルダのキャッシュを上書きしない
        let cached = await controller.siblingBooks(of: new.appendingPathComponent("a.zip"))
        XCTAssertEqual(cached, newPaths)
        XCTAssertEqual(probe.record.listings, 2)
    }

    func testAdjacentNavigationIgnoresBookReplacedDuringListing() async throws {
        let probe = SlowProbe(items: ["*": [DirectoryItem(name: "book.zip", isDirectory: false),
                                            DirectoryItem(name: "next.zip", isDirectory: false)]],
                              delay: 0.3)
        let controller = ReaderWindowController(window: nil, history: try makeHistory())
        controller.fileSystemProbe = probe
        let first = try await Book.open(source: NamedEntriesSource(
            url: URL(fileURLWithPath: "/fixture/old/book.zip"), names: ["1.png"]))
        let replacement = try await Book.open(source: NamedEntriesSource(
            url: URL(fileURLWithPath: "/fixture/new/book.zip"), names: ["1.png"]))
        controller.replaceBook(first)
        let generation = controller.openGeneration
        let navigation = try XCTUnwrap(controller.openAdjacentBook(forward: true))
        await fulfillment(of: [probe.started], timeout: 2)
        controller.replaceBook(replacement)
        await navigation.value
        XCTAssertEqual(controller.openGeneration, generation, "一覧待ちの間に替わった本では開かない")
        XCTAssertTrue(controller.book === replacement)
    }

    /// 合本内の EPUB→EPUB 移動(openCollectionEPUB)は openGeneration も folderURL も
    /// 動かさず epubPresentEpoch だけ進める。一覧待ちの間にそれが起きた古い
    /// 「次/前の本」は開かず、呼び出し元が立てた復帰フラグも自分で畳む
    func testAdjacentNavigationIgnoresPresentationSupersededDuringListing() async throws {
        let probe = SlowProbe(items: ["*": [DirectoryItem(name: "book.zip", isDirectory: false),
                                            DirectoryItem(name: "next.zip", isDirectory: false)]],
                              delay: 0.3)
        let controller = ReaderWindowController(window: nil, history: try makeHistory())
        controller.fileSystemProbe = probe
        let book = try await Book.open(source: NamedEntriesSource(
            url: URL(fileURLWithPath: "/fixture/old/book.zip"), names: ["1.png"]))
        controller.replaceBook(book)
        let generation = controller.openGeneration
        // openCollectionEntry の巻端処理と同じく、要求前に復帰フラグが立つ
        controller.collectionNavigation.returnPending = true
        let navigation = try XCTUnwrap(controller.openAdjacentBook(forward: true))
        await fulfillment(of: [probe.started], timeout: 2)
        controller.epubPresentEpoch += 1  // 別の巻への横断ジャンプが確定した
        await navigation.value
        XCTAssertEqual(controller.openGeneration, generation,
                       "提示エポックが進んだ古い要求では次の本を開かない")
        XCTAssertTrue(controller.book === book)
        XCTAssertFalse(controller.collectionNavigation.returnPending,
                       "失効した要求が立てた復帰フラグを残さない(巻端ナビが塞がる)")
    }

    /// 失効した要求は、後発の次/前の本要求が立てた復帰フラグには触らない
    func testStaleAdjacentNavigationKeepsNewerRequestsReturnFlag() async throws {
        let probe = SlowProbe(items: ["*": [DirectoryItem(name: "book.zip", isDirectory: false)]],
                              delay: 0.3)
        let controller = ReaderWindowController(window: nil, history: try makeHistory())
        controller.fileSystemProbe = probe
        let book = try await Book.open(source: NamedEntriesSource(
            url: URL(fileURLWithPath: "/fixture/old/book.zip"), names: ["1.png"]))
        controller.replaceBook(book)
        controller.collectionNavigation.returnPending = true
        let stale = try XCTUnwrap(controller.openAdjacentBook(forward: true))
        await fulfillment(of: [probe.started], timeout: 2)
        controller.epubPresentEpoch += 1
        // 後発の要求(番号が進む)。走査は進行中のものへ合流する
        controller.collectionNavigation.returnPending = true
        controller.adjacentBookRequest &+= 1
        await stale.value
        XCTAssertTrue(controller.collectionNavigation.returnPending,
                      "後発要求のフラグは失効した要求が消さない")
    }

    /// 要求時に復帰フラグが立っていなかった要求は、走査中に別の所有者が立てた
    /// フラグを失効時に消さない(自分のものだけを畳む)
    func testStaleAdjacentNavigationDoesNotClearReturnItDidNotOwn() async throws {
        let probe = PausedProbe(items: [DirectoryItem(name: "book.zip", isDirectory: false),
                                        DirectoryItem(name: "next.zip", isDirectory: false)])
        let controller = ReaderWindowController(window: nil, history: try makeHistory())
        controller.fileSystemProbe = probe
        let book = try await Book.open(source: NamedEntriesSource(
            url: URL(fileURLWithPath: "/fixture/old/book.zip"), names: ["1.png"]))
        controller.replaceBook(book)
        XCTAssertFalse(controller.collectionNavigation.returnPending)
        let generation = controller.openGeneration
        let navigation = try XCTUnwrap(controller.openAdjacentBook(forward: true))
        await fulfillment(of: [probe.started], timeout: 2)
        controller.epubPresentEpoch += 1  // 合本内の横断ジャンプで失効
        controller.collectionNavigation.returnPending = true  // 別の所有者が立てた
        probe.resume()
        await navigation.value
        XCTAssertEqual(controller.openGeneration, generation, "旧走査から隣接本を開かない")
        XCTAssertTrue(controller.book === book)
        XCTAssertTrue(controller.collectionNavigation.returnPending,
                      "自分が立てていないフラグは消さない")
    }
}

// MARK: - EPUB 復元ゲートの実在確認待ち

@MainActor
final class EPUBRestoreOffMainTests: XCTestCase {
    private func makePublication(displayURL: URL) throws -> EPUBPublication {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/package.opf"
            media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
          unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">restore-test</dc:identifier>
            <dc:title>復元</dc:title><dc:language>ja</dc:language>
          </metadata>
          <manifest><item id="c" href="c.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c"/></spine>
        </package>
        """
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>本文</title></head>
          <body><p>本文</p></body></html>
        """
        return try EPUBPublication(data: TestFixtures.storedZip(entries: [
            (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
            (Array("META-INF/container.xml".utf8), Data(container.utf8)),
            (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
            (Array("OEBPS/c.xhtml".utf8), Data(chapter.utf8)),
        ]), displayURL: displayURL)
    }

    /// 復元ゲートの実在確認(死んだマウントでは SMB タイムアウトまで続く)を待つ間に
    /// 別の本の提示が確定したら、古い提示は確認ダイアログも復元も行わない。
    /// GoToLastPage=1(自動)で判定する: 修正前は保存位置を返し、修正後は nil
    func testSupersededPresentationSkipsRestoreAfterRecentCheck() async throws {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let originalArguments = arguments
        arguments["GoToLastPage"] = 1
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }

        let tempDir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let suite = UserDefaults(suiteName: "test.cooViewer.epub-restore-off-main.\(UUID())")!
        suite.set(1, forKey: "OpenRecentLimit")
        let epub = tempDir.appendingPathComponent("novel.epub")
        let other = tempDir.appendingPathComponent("other.zip")
        // 先行エントリ other は不在扱い(stat は止まる偽物に委ねる)
        let probe = PausedProbe(existing: [])
        let history = BookHistoryStore(defaults: suite,
                                       directory: tempDir.appendingPathComponent("BookStates"),
                                       fileSystem: probe)
        history.noteOpened(path: epub.path)
        history.noteClosedReflow(path: epub.path, spineIndex: 0, progression: 0.5)
        history.noteOpened(path: other.path)  // epub を上限(1)の外へ押し出す → 実在確認が走る
        let publication = try makePublication(displayURL: epub)
        let controller = ReaderWindowController(window: nil, history: history)

        let epoch = controller.epubPresentEpoch
        let restoring = Task {
            await controller.restoredEPUBLocator(for: epub, publication: publication,
                                                 epoch: epoch)
        }
        await fulfillment(of: [probe.started], timeout: 2)
        controller.epubPresentEpoch += 1  // 待ちの間に別の本が開かれた
        probe.resume()
        let stale = await restoring.value
        XCTAssertNil(stale, "後発の提示に替わった古い復元は位置を返さず、確認も出さない")

        // 対照: 提示が最新のままなら保存位置が返る(不在の先行エントリで繰り上がる)
        let current = await controller.restoredEPUBLocator(
            for: epub, publication: publication, epoch: controller.epubPresentEpoch)
        XCTAssertEqual(current?.progression, 0.5)
        XCTAssertEqual(probe.mainThreadCalls, 0)
    }
}

// MARK: - 最近の一覧

@MainActor
final class RecentsOffMainTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir()
        defaults = UserDefaults(suiteName: "test.cooViewer.recents-off-main.\(UUID())")!
        defaults.set(10, forKey: "OpenRecentLimit")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeBookFile(_ name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return CanonicalPath.normalize(url.path)
    }

    private func makeStore(probe: any FileSystemProbing) -> BookHistoryStore {
        BookHistoryStore(defaults: defaults,
                         directory: tempDir.appendingPathComponent("BookStates"),
                         fileSystem: probe)
    }

    func testAsyncFilteringEqualsLegacyFilter() async throws {
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        let c = try makeBookFile("c.zip")
        // 実在判定は注入した偽物に従う(ディスク上の実体ではなく)
        let probe = SlowProbe(existing: [a, c], delay: 0)
        let store = makeStore(probe: probe)
        store.noteOpened(path: a)
        store.noteOpened(path: b)
        store.noteOpened(path: c)
        store.noteClosed(path: c, pageIndex: 5)

        // 旧 recentBookPaths(): 実在する本だけを新しい順に表示上限まで
        let legacy = store.recentPaths().filter { probe.fileExists(atPath: $0) }
        XCTAssertEqual(legacy, [c, a])
        XCTAssertEqual(store.recentBookPaths(), [c, b, a], "未確認の間は一覧どおり")
        let filtered = await store.existingRecentBookPaths()
        XCTAssertEqual(filtered, legacy)
        XCTAssertEqual(store.recentBookPaths(), legacy, "確認後の同期一覧は結果を映す")
        let mostRecent = await store.mostRecentExistingBook()
        XCTAssertEqual(mostRecent?.path, c)
        XCTAssertEqual(mostRecent?.page, 5)
    }

    func testMostRecentExistingBookStopsAtFirstExistingEntry() async throws {
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        let c = try makeBookFile("c.zip")
        let probe = SlowProbe(existing: [a, b], delay: 0)
        let store = makeStore(probe: probe)
        for path in [a, b, c] { store.noteOpened(path: path) }  // c が最新(消えている)
        let mostRecent = await store.mostRecentExistingBook()
        XCTAssertEqual(mostRecent?.path, b)
        XCTAssertEqual(probe.record.calls, 2, "c(不在)→ b(実在)で止まり a は調べない")
        XCTAssertEqual(probe.record.mainThreadCalls, 0)
    }

    func testRecentLimitGateMatchesLegacyWithoutIOWithinLimit() async throws {
        defaults.set(2, forKey: "OpenRecentLimit")
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        let c = try makeBookFile("c.zip")
        let d = try makeBookFile("d.zip")
        let probe = SlowProbe(existing: [a, b, d], delay: 0)
        let store = makeStore(probe: probe)
        for path in [a, b, c, d] { store.noteOpened(path: path) }  // 新しい順: d c b a
        // 旧ゲート: 実在する一覧の上限 2 件 = [d, b]
        let inLimitD = await store.isWithinRecentLimit(path: d)
        let inLimitC = await store.isWithinRecentLimit(path: c)
        XCTAssertTrue(inLimitD)
        XCTAssertTrue(inLimitC, "素の位置が上限内なら実在確認なしで true")
        XCTAssertEqual(probe.record.calls, 0)
        let inLimitB = await store.isWithinRecentLimit(path: b)
        XCTAssertTrue(inLimitB, "前の c が消えているので繰り上がる")
        let inLimitA = await store.isWithinRecentLimit(path: a)
        XCTAssertFalse(inLimitA)
        let unknown = await store.isWithinRecentLimit(path: tempDir.appendingPathComponent("x.zip").path)
        XCTAssertFalse(unknown)
        XCTAssertEqual(probe.record.mainThreadCalls, 0)
    }

    func testMenuRebuildDoesNotCallExistenceCheckOnMainActor() async throws {
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        let probe = SlowProbe(existing: [a], delay: 0.3)
        let store = makeStore(probe: probe)
        store.noteOpened(path: a)
        store.noteOpened(path: b)
        let delegate = RecentBooksMenuDelegate(store: store)
        let menu = NSMenu()

        delegate.menuNeedsUpdate(menu)
        // 未確認の間は最後に分かっている状態=一覧どおり(遅い存在判定を待たない)
        XCTAssertEqual(menu.items.map { $0.representedObject as? String }, [b, a])
        XCTAssertEqual(probe.record.calls, 0)

        // 再確認が終わると消えた本が外れる(メインスレッドでは判定しない)
        for _ in 0..<100 where menu.items.count != 1 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(menu.items.map { $0.representedObject as? String }, [a])
        XCTAssertEqual(probe.record.mainThreadCalls, 0)
        XCTAssertEqual(probe.record.calls, 2)
    }

    /// 開けなかった本の不在を覚えると同期一覧から外れる。一覧自体は消さない
    /// (マウントし直せば戻る)
    func testNoteMissingHidesEntryWithoutDeletingIt() throws {
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        let store = makeStore(probe: SlowProbe(existing: [a, b], delay: 0))
        store.noteOpened(path: a)
        store.noteOpened(path: b)
        XCTAssertEqual(store.recentBookPaths(), [b, a])
        store.noteMissing(normalizedPath: a)
        XCTAssertEqual(store.recentBookPaths(), [b], "不在と分かった本は次のメニューから外れる")
        XCTAssertEqual(store.recentPaths(), [b, a], "一覧そのものは残す")
    }

    /// 最近の一覧から消えた本を選ぶと、開くフローの実在確認で止まる。黙って残らず、
    /// 一覧から外れる(フィードバックの音は GUI 依存のためここでは検証しない)
    func testOpeningMissingRecentMarksItAbsent() async throws {
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        let probe = SlowProbe(existing: [b], delay: 0)
        let store = makeStore(probe: probe)
        store.noteOpened(path: a)
        store.noteOpened(path: b)
        let controller = ReaderWindowController(window: nil, history: store)
        controller.fileSystemProbe = probe
        XCTAssertEqual(store.recentBookPaths(), [b, a], "未確認の間は一覧どおり")
        // Open Recent と同じく、一覧に保存された(正規化済み。/var/folders は
        // /private/var/... になる)パスをそのまま開く
        let stored = try XCTUnwrap(store.recentBookPaths().last)
        XCTAssertEqual(stored, a)
        await controller.openBook(at: URL(fileURLWithPath: stored)).value
        XCTAssertNil(controller.book)
        XCTAssertFalse(controller.isOpeningBook)
        XCTAssertEqual(store.recentBookPaths(), [b], "開けなかった本は次のメニューから外れる")
        XCTAssertEqual(store.recentPaths(), [b, a], "一覧そのものは消さない")
    }
}

// MARK: - 本の構築と並べ替えのメインアクター外実行

/// 最初の .literalName ソートを release まで止める(古い完了の競合を再現する)
private final class ControlledBookSorter: PageSorting, Sendable {
    let started = XCTestExpectation(description: "旧ソート開始")
    let release = DispatchSemaphore(value: 0)
    let ranOnMain = OSAllocatedUnfairLock(initialState: false)
    private let literalCalls = OSAllocatedUnfairLock(initialState: 0)

    func sorted(_ entries: [PageEntry], mode: SortMode) -> [PageEntry] {
        if Thread.isMainThread { ranOnMain.withLock { $0 = true } }
        let shouldPause = mode == .literalName && literalCalls.withLock { calls in
            calls += 1
            return calls == 1
        }
        if shouldPause {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        return PageSorter.sorted(entries, mode: mode)
    }
}

@MainActor
final class BookSortOffMainTests: XCTestCase {
    /// 自然順と文字コード順で並びが変わる名前(10 と 2 の順が逆になる)
    private let names = (1...40).map { "page \($0 * 7 % 41).png" }

    func testBookOpenPreparesAttributesAndSortAwayFromMainActor() async throws {
        let source = NamedEntriesSource(names: names)
        let probe = SlowProbe(delay: 0.3)
        let opening = Task { try await Book.open(source: source, probe: probe) }
        await fulfillment(of: [probe.started], timeout: 2)
        let mainTick = OSAllocatedUnfairLock<Date?>(initialState: nil)
        await Task { @MainActor in mainTick.withLock { $0 = Date() } }.value
        let book = try await opening.value
        XCTAssertEqual(book.entries, PageSorter.sorted(source.pages, mode: .name))
        XCTAssertEqual(book.cacheKey, Book.makeCacheKey(
            for: source.url, entries: source.pages,
            identity: BookFileIdentity(modified: 123, size: 456)))
        let tickAt = try XCTUnwrap(mainTick.withLock { $0 })
        let finished = try XCTUnwrap(probe.record.lastFinishedAt)
        XCTAssertLessThan(tickAt, finished, "stat 中にメインアクターの別タスクが走る")
        XCTAssertEqual(probe.record.mainThreadCalls, 0)
    }

    func testSortChangeMatchesPageSorterAndResetsToFirstPage() async throws {
        let source = NamedEntriesSource(names: names)
        let book = try await Book.open(source: source)
        XCTAssertEqual(book.entries, PageSorter.sorted(source.pages, mode: .name))
        book.goTo(index: 3)

        let applied = await book.setSortMode(.literalName).value
        XCTAssertTrue(applied)
        XCTAssertEqual(book.sortMode, .literalName)
        XCTAssertEqual(book.entries, PageSorter.sorted(source.pages, mode: .literalName))
        XCTAssertNotEqual(book.entries, PageSorter.sorted(source.pages, mode: .name))
        XCTAssertEqual(book.currentIndex, 0)
    }

    func testStaleSortResultIsIgnoredWhenModeChangesTwice() async throws {
        let source = NamedEntriesSource(names: names)
        let book = try await Book.open(source: source, sortMode: .literalName)

        // 連打: 先の要求(.name)の結果は捨て、後の要求(.literalName)だけ適用する
        let first = book.setSortMode(.name)
        let second = book.setSortMode(.literalName)
        XCTAssertEqual(book.sortMode, .literalName, "モードは即時に確定する")
        let firstApplied = await first.value
        let secondApplied = await second.value
        XCTAssertFalse(firstApplied, "古い結果は適用しない")
        XCTAssertTrue(secondApplied)
        XCTAssertEqual(book.entries, PageSorter.sorted(source.pages, mode: .literalName))
        XCTAssertEqual(book.currentIndex, 0)
    }

    func testSortModeRoundTripDiscardsStaleCompletion() async throws {
        let sorter = ControlledBookSorter()
        let source = NamedEntriesSource(names: names)
        let book = try await Book.open(source: source, sorter: sorter)
        book.goTo(index: 2)
        let oldSort = book.setSortMode(.literalName)
        await fulfillment(of: [sorter.started], timeout: 2)
        // 設計書 §7.3: 同じモードに戻っても、世代の違う旧結果は採用しない
        let secondSort = book.setSortMode(.creationDate)
        let finalSort = book.setSortMode(.literalName)
        let finalApplied = await finalSort.value
        XCTAssertTrue(finalApplied)
        let secondApplied = await secondSort.value
        XCTAssertFalse(secondApplied)
        book.goTo(index: 1)
        sorter.release.signal()
        let staleApplied = await oldSort.value
        XCTAssertFalse(staleApplied)
        XCTAssertEqual(book.sortMode, .literalName)
        XCTAssertEqual(book.entries, PageSorter.sorted(source.pages, mode: .literalName))
        XCTAssertEqual(book.currentIndex, 1, "旧ソートの完了で位置を巻頭へ戻さない")
        XCTAssertFalse(sorter.ranOnMain.withLock { $0 })
    }

    /// 計測用(COOVIEWER_TIMING=1 のときだけ実行。結果は標準出力へ)。
    /// 2 万件の本の構築で、同期 init がメインスレッドを占める時間と、
    /// open(メインアクター外で準備)中のメインアクターの最大停止時間を比べる
    func testBookConstructionMainThreadTiming() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COOVIEWER_TIMING"] == "1")
        let source = NamedEntriesSource(
            names: (0..<20_000).map { "第\($0 % 97)巻 page \($0 * 31 % 20_011).png" })
        let entries = source.pages

        let syncStart = ContinuousClock.now
        let syncBook = Book(source: source, entries: entries)
        let syncDuration = ContinuousClock.now - syncStart
        XCTAssertEqual(syncBook.pageCount, entries.count)

        // 1ms 周期のメインアクターの心拍で、open 中の最大停止時間を測る
        let gaps = OSAllocatedUnfairLock(initialState: [Duration]())
        let heartbeat = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
                let now = ContinuousClock.now
                let gap = now - last
                gaps.withLock { $0.append(gap) }
                last = now
            }
        }
        let openStart = ContinuousClock.now
        let book = try await Book.open(source: source)
        let openDuration = ContinuousClock.now - openStart
        heartbeat.cancel()
        XCTAssertEqual(book.pageCount, entries.count)
        let maxGap = gaps.withLock { $0.max() } ?? .zero
        print("""
            [timing] entries=\(entries.count) sync init (main thread) = \(syncDuration), \
            async open wall = \(openDuration), max main-actor gap during open = \(maxGap)
            """)
    }
}
