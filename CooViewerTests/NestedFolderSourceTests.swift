import PDFKit
import os
import XCTest

@testable import cooViewer

/// フォルダ内の書庫/PDF の統合(旧ネスト COImageLoader のフォルダ版)のテスト。
final class NestedFolderSourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func png(width: Int) -> Data {
        TestFixtures.pngData(width: width, height: 60)
    }

    private func zipData(_ entries: [(String, Data)]) -> Data {
        TestFixtures.storedZip(entries: entries.map { (Array($0.0.utf8), $0.1) })
    }

    private func makePDFData(pageCount: Int) throws -> Data {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 40, height: 60))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 40, height: 60).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: index)
        }
        return try XCTUnwrap(document.dataRepresentation())
    }

    func testPrefetchVolumeKeySeparatesChildrenAndFolderImages() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("00.avifs"))
        try zipData([("a.avifs", png(width: 41)), ("b.avifs", png(width: 42))])
            .write(to: tempDir.appendingPathComponent("10.zip"))
        try zipData([("a.avifs", png(width: 43))]).write(to: tempDir.appendingPathComponent("20.zip"))
        let source = NestedFolderSource(folder: try FolderSource(url: tempDir, readSubFolders: false))
        let pages = try await source.entries()
        XCTAssertEqual(pages.map { source.prefetchVolumeKey(for: $0) }, [0, 1, 1, 2])
        let card = PageEntry(id: 3_999_999, name: "missing.zip", pathInBook: "missing.zip", fileURL: nil,
                             creationDate: nil, modificationDate: nil)
        XCTAssertEqual(source.prefetchVolumeKey(for: card), 3)
    }

    /// 画像だけのフォルダは従来どおり FolderSource(並列・日付ソート可)のまま
    func testPlainImageFolderStaysFolderSource() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("a.png"))
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        XCTAssertTrue(source is FolderSource)
        XCTAssertTrue(source.supportsDateSort)
    }

    /// 書庫/PDF を含むフォルダは統合ソースになり、パス単純順で 1 冊に組まれること
    func testFolderWithBooksMergesTheirPages() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("00.png"))
        try zipData([("p1.png", png(width: 41)), ("p2.png", png(width: 42))])
            .write(to: tempDir.appendingPathComponent("10_inner.zip"))
        try png(width: 43).write(to: tempDir.appendingPathComponent("20.png"))
        try makePDFData(pageCount: 2)
            .write(to: tempDir.appendingPathComponent("30_vol.pdf"))

        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        XCTAssertTrue(source is NestedFolderSource)
        XCTAssertFalse(source.supportsDateSort,
                       "ネスト書庫を含む本は日付ソート不可(旧 canSortByDate 規則)")

        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), [
            "00.png",
            "10_inner.zip/p1.png", "10_inner.zip/p2.png",
            "20.png",
            "30_vol.pdf/000000", "30_vol.pdf/000001",
        ])
        // 外側画像は元 id、ネストは 1M 刻みの序数域
        XCTAssertEqual(entries.map(\.id),
                       [0, 1_000_000, 1_000_001, 1, 2_000_000, 2_000_001])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)

        // 各エントリの画像内容(幅マーカー。PDF はレンダリングできること)
        for (entry, width) in [(entries[0], 40), (entries[1], 41),
                               (entries[2], 42), (entries[3], 43)] {
            let image = try await source.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, width, entry.pathInBook)
        }
        let pdfPage = try await source.image(for: entries[4], maxPixelSize: nil)
        XCTAssertGreaterThan(pdfPage.width, 0)

        // 外側画像は実ファイル URL を保持(ゴミ箱/Finder 機能用)。ネストは nil
        XCTAssertNotNil(entries[0].fileURL)
        XCTAssertNil(entries[1].fileURL)
    }

    /// 壊れた書庫は黙って飛ばし、残りは無傷なこと(仕様書 §4.17)
    func testCorruptArchiveInFolderIsSkipped() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("00.png"))
        try Data([0x50, 0x4B, 0xFF]).write(to: tempDir.appendingPathComponent("broken.zip"))
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["00.png"])
    }

    /// 並列の子構築でも解錠は直列化され、同じパスワードの 2 冊目は
    /// 入力を再利用してダイアログが 1 回で済むこと(多重プロンプト防止)
    func testParallelChildBuildSerializesUnlockPrompts() async throws {
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        for name in ["lockedA.zip", "lockedB.zip"] {
            let plain = tempDir.appendingPathComponent("p-\(name).png")
            try png(width: 41).write(to: plain)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-j", "-P", "sesame",
                                 tempDir.appendingPathComponent(name).path, plain.path]
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(at: plain)
        }
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false,
            nestedPasswordProvider: { _, _ in
                prompts.withLock { $0 += 1 }
                return NestedPasswordAnswer(password: "sesame", saveRequested: false)
            })
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(prompts.withLock { $0 }, 1,
                       "並列構築でもプロンプトは 1 回(直列化+既知パスワード再利用)")
    }

    /// 分割書庫の続き巻(.002 等)は候補にしない(画像だけなら FolderSource のまま)
    func testSplitVolumeContinuationDoesNotTriggerMerging() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("a.png"))
        try Data([0x00]).write(to: tempDir.appendingPathComponent("video.002"))
        try Data([0x00]).write(to: tempDir.appendingPathComponent("part.r00"))
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        XCTAssertTrue(source is FolderSource,
                      "続き巻だけならフォルダは従来どおり(並列・日付ソート維持)")
    }

    // 採番・並列幅の検証は OS の UTI 登録状態に依存しない拡張子を使う。
    private func writeAssemblyLaneCollection() throws {
        for index in 0..<20 {
            let name = String(format: "%02d.zip", index)
            try zipData([("b.avifs", png(width: 42)), ("a.avifs", png(width: 41))])
                .write(to: tempDir.appendingPathComponent(name))
        }
    }

    func testAssemblyEntriesIndependentOfLaneCount() async throws {
        try writeAssemblyLaneCollection()
        let folder = try FolderSource(url: tempDir, readSubFolders: false)
        let serial = NestedFolderSource(folder: folder, retryPolicy: .immediate)
        let parallel = NestedFolderSource(folder: folder, retryPolicy: .immediate)
        await parallel.applyMediaProfile(MediaProfile(mediaClass: .network))
        let one = try await NestedFolderSource.$testingAssemblyLanes.withValue(1) {
            try await serial.entries()
        }
        let sixteen = try await NestedFolderSource.$testingAssemblyLanes.withValue(16) {
            try await parallel.entries()
        }
        XCTAssertEqual(one, sixteen)
        XCTAssertEqual(one.count, 40)
        XCTAssertEqual(one.map(\.id), (1...20).flatMap { [$0 * 1_000_000, $0 * 1_000_000 + 1] })
    }

    func testBuildUsesProfileAppliedBeforeEntries() async throws {
        try writeAssemblyLaneCollection()
        let ready = expectation(description: "ネットワーク媒体は最初から16レーンで組み立てる")
        let gate = AssemblyTestGate()
        let entered = OSAllocatedUnfairLock(initialState: 0)
        var policy = AssemblyRetryPolicy.immediate
        policy.beforeChildAttempt = { _ in
            let count = entered.withLock { $0 += 1; return $0 }
            if count == 16 { ready.fulfill() }
            await gate.wait()
        }
        let source = NestedFolderSource(folder: try FolderSource(url: tempDir, readSubFolders: false),
                                        retryPolicy: policy)
        await source.applyMediaProfile(MediaProfile(mediaClass: .network))
        let build = Task { try await source.entries() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(entered.withLock { $0 }, 16)
        await gate.open()
        let entries = try await build.value
        XCTAssertEqual(entries.count, 40)
    }

    func testWindowParallelQueryUsesOnlyReferencedChildren() async throws {
        for name in ["a.zip", "b.zip", "solid.7z"] {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        let factory = ArchiveEngineFactory(openFile: { _, path, _ in
            WindowQueryArchiveEngine(serial: path.hasSuffix("solid.7z"))
        }, openData: { _, _, _ in nil })
        let source: any BookSource = NestedFolderSource(
            folder: try FolderSource(url: tempDir, readSubFolders: false),
            engineFactory: factory, retryPolicy: .immediate)
        let entries = try await source.entries()
        let zipIDs = entries.filter { $0.pathInBook.hasPrefix("a.zip/") || $0.pathInBook.hasPrefix("b.zip/") }.map(\.id)
        let solidIDs = entries.filter { $0.pathInBook.hasPrefix("solid.7z/") }.map(\.id)
        XCTAssertEqual(zipIDs.count, 4)
        XCTAssertEqual(solidIDs.count, 2)
        let zipParallel = await source.currentlySupportsParallelPageLoads(forEntryIDs: zipIDs + zipIDs)
        let solidParallel = await source.currentlySupportsParallelPageLoads(forEntryIDs: zipIDs + solidIDs)
        let wholeParallel = await source.currentlySupportsParallelPageLoads()
        XCTAssertTrue(zipParallel)
        XCTAssertFalse(solidParallel)
        XCTAssertFalse(wholeParallel)
    }

    private func makeWindowQueryCollection() async throws -> (NestedFolderSource, [PageEntry]) {
        let solid = try XCTUnwrap(Bundle(for: NestedFolderSourceTests.self)
            .url(forResource: "solid", withExtension: "7z"))
        try FileManager.default.copyItem(at: solid, to: tempDir.appendingPathComponent("solid.7z"))
        for name in ["a.zip", "b.zip"] {
            try zipData([("page.avifs", png(width: 41))]).write(to: tempDir.appendingPathComponent(name))
        }
        try png(width: 42).write(to: tempDir.appendingPathComponent("folder.avifs"))
        let source = NestedFolderSource(folder: try FolderSource(url: tempDir, readSubFolders: false),
                                        retryPolicy: .immediate)
        return (source, try await source.entries())
    }

    func testWindowParallelQueryIgnoresSolidChildOutsideWindow() async throws {
        let (source, entries) = try await makeWindowQueryCollection()
        let ids = entries.filter { $0.pathInBook.hasPrefix("a.zip/") || $0.pathInBook.hasPrefix("b.zip/") }.map(\.id)
        XCTAssertEqual(ids.count, 2)
        let erased: any BookSource = source
        let parallel = await erased.currentlySupportsParallelPageLoads(forEntryIDs: ids + ids)
        let whole = await erased.currentlySupportsParallelPageLoads()
        XCTAssertTrue(parallel)
        XCTAssertFalse(whole)
    }

    func testWindowParallelQueryIsSerialWhenSolidChildInWindow() async throws {
        let (source, entries) = try await makeWindowQueryCollection()
        XCTAssertTrue(entries.contains { $0.pathInBook.hasPrefix("solid.7z/") })
        let erased: any BookSource = source
        let parallel = await erased.currentlySupportsParallelPageLoads(forEntryIDs: entries.map(\.id))
        XCTAssertFalse(parallel)
    }

    func testWindowParallelQueryTreatsFolderImagesAndCardsAsParallel() async throws {
        let (source, entries) = try await makeWindowQueryCollection()
        let folder = try XCTUnwrap(entries.first { $0.pathInBook == "folder.avifs" })
        let folderParallel = await source.currentlySupportsParallelPageLoads(forEntryIDs: [folder.id, -1])
        XCTAssertTrue(folderParallel)
        let (partial, _) = await NestedFolderSource.syntheticFailure()
        let cards = try await partial.partialEntries().filter { $0.unreadableVolume != nil }
        XCTAssertEqual(cards.count, 2)
        let cardParallel = await partial.currentlySupportsParallelPageLoads(forEntryIDs: cards.map(\.id) + [-1])
        XCTAssertTrue(cardParallel)
        let emptyParallel = await source.currentlySupportsParallelPageLoads(forEntryIDs: [])
        XCTAssertTrue(emptyParallel)
    }

    private func makeSplitRARCollection(
        names: [String] = ["x.part1.rar", "x.part2.rar", "x.part3.rar"]
    ) throws -> NestedFolderSource {
        for name in names {
            try Data([0]).write(to: tempDir.appendingPathComponent(name))
        }
        try zipData([("page.avifs", png(width: 41))]).write(to: tempDir.appendingPathComponent("z.zip"))
        return NestedFolderSource(folder: try FolderSource(url: tempDir, readSubFolders: false),
                                  retryPolicy: .immediate)
    }

    func testSplitRARContinuationsAreSkippedNotExcluded() async throws {
        let source = try makeSplitRARCollection()
        let entries = try await source.entries()
        let excluded = await source.excludedChildCount()
        let cards = await source.cardChildren
        XCTAssertEqual(excluded, 1)
        XCTAssertTrue(cards.isEmpty)
        XCTAssertEqual(entries.map(\.pathInBook), ["z.zip/page.avifs"])
    }

    func testSkippedRARContinuationsKeepLaterChildPageIDs() async throws {
        let source = try makeSplitRARCollection()
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.id), [4_000_000])
    }

    func testGrowingRARPartNumbersKeepLaterChildPageIDs() async throws {
        let source = try makeSplitRARCollection(names: [
            "x.part1.rar", "x.part2.rar", "x.part10.rar", "x.part12.rar",
        ])
        let entries = try await source.entries()
        let excluded = await source.excludedChildCount()
        XCTAssertEqual(excluded, 1)
        XCTAssertEqual(entries.map(\.pathInBook), ["z.zip/page.avifs"])
        XCTAssertEqual(entries.map(\.id), [5_000_000])
    }

    func testRARCaseVariantsFollowVolumeLookupAndKeepChildIDs() async throws {
        let caseSensitive = (try? tempDir.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
        let source = try makeSplitRARCollection(names: [
            "Prefix.part1.rar", "prefix.part2.rar", "marker.part1.rar", "marker.PART2.rar",
            "extension.part1.rar", "extension.part2.RAR", "padding.part1.rar", "padding.part02.rar",
        ])
        let entries = try await source.entries()
        let excluded = await source.excludedChildCount()
        XCTAssertEqual(excluded, caseSensitive ? 8 : 5)
        XCTAssertEqual(entries.map(\.pathInBook), ["z.zip/page.avifs"])
        XCTAssertEqual(entries.map(\.id), [9_000_000])
    }

    func testCanonicalRARPartNamesKeepLaterChildIDs() async throws {
        let source = try makeSplitRARCollection(names: ["caf\u{00E9}.part1.rar", "cafe\u{0301}.part2.rar"])
        let entries = try await source.entries()
        let excluded = await source.excludedChildCount()
        XCTAssertEqual(excluded, 1)
        XCTAssertEqual(entries.map(\.pathInBook), ["z.zip/page.avifs"])
        XCTAssertEqual(entries.map(\.id), [3_000_000])
    }

    /// パスワード入力をキャンセルした合本ソースを(EPUB 往復の復帰のように)
    /// 使い回したとき、provider を付け替えても再度尋ねないこと。
    /// openBookFlow の復帰時ソース再利用はこの契約(キャンセル記憶と構築済み
    /// エントリ列が setProvider をまたいで保たれる)に依存する(cooViewer-a1a)
    func testReusedSourceDoesNotRepromptAfterCancel() async throws {
        let plain = tempDir.appendingPathComponent("p1.png")
        try png(width: 41).write(to: plain)
        let lockedURL = tempDir.appendingPathComponent("locked.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", "-P", "sesame", lockedURL.path, plain.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.removeItem(at: plain)
        try png(width: 40).write(to: tempDir.appendingPathComponent("00.png"))

        let prompts = OSAllocatedUnfairLock(initialState: 0)
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false,
            nestedPasswordProvider: { _, _ in
                prompts.withLock { $0 += 1 }
                return nil  // ユーザーのキャンセル
            })
        let first = try await source.entries()
        XCTAssertEqual(first.map(\.pathInBook), ["00.png"],
                       "解除できない子は黙って外れること(§4.17)")
        let excluded = await source.excludedChildCount()
        XCTAssertEqual(excluded, 1)
        XCTAssertEqual(prompts.withLock { $0 }, 1)

        // 復帰の再利用契約: 新しい provider を付け替えて entries を取り直しても
        // 再度尋ねず、エントリ列は構築時のまま凍結されていること。
        // 凍結の検証のためフォルダへ画像を 1 枚追加してから取り直す —
        // 再構築が走れば現れてしまう(プロンプト抑止だけでは隠れる破れの検出)
        try png(width: 42).write(to: tempDir.appendingPathComponent("99.png"))
        await source.attachNestedPasswordProvider { _, _ in
            prompts.withLock { $0 += 1 }
            return NestedPasswordAnswer(password: "sesame", saveRequested: false)
        }
        let second = try await source.entries()
        XCTAssertEqual(second.map(\.pathInBook), ["00.png"],
                       "エントリ列は構築時のまま(再構築されていないこと)")
        XCTAssertEqual(prompts.withLock { $0 }, 1, "復帰で再度尋ねないこと")
    }

    /// 暗号化された書庫は provider へ問い合わせて解除されること
    func testEncryptedArchiveInFolderUnlockedViaProvider() async throws {
        // zip CLI で暗号化 ZIP を作る
        let plain = tempDir.appendingPathComponent("p1.png")
        try png(width: 41).write(to: plain)
        let lockedURL = tempDir.appendingPathComponent("locked.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", "-P", "sesame", lockedURL.path, plain.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.removeItem(at: plain)  // 平文は消して zip だけ残す

        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false,
            nestedPasswordProvider: { _, _ in
                NestedPasswordAnswer(password: "sesame", saveRequested: false)
            })
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["locked.zip/p1.png"])
        let image = try await source.image(for: entries[0], maxPixelSize: nil)
        XCTAssertEqual(image.width, 41)
    }

    /// ページの実体ファイル: フォルダ直下の画像はその画像、子の本のページは
    /// 子の書庫ファイル(Finder 表示・ファイル情報の対象)
    func testContainerFileURLMapsPagesToTheirFiles() async throws {
        let image = tempDir.appendingPathComponent("00.png")
        try png(width: 40).write(to: image)
        let archive = tempDir.appendingPathComponent("10_inner.zip")
        try zipData([("p1.png", png(width: 41))]).write(to: archive)

        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)

        // /var と /private/var の違いを吸収するため解決済みパスで比較する
        let imageURL = await source.containerFileURL(for: entries[0])
        XCTAssertEqual(imageURL.resolvingSymlinksInPath().path,
                       image.resolvingSymlinksInPath().path,
                       "単体画像はその画像ファイル")
        let nestedURL = await source.containerFileURL(for: entries[1])
        XCTAssertEqual(nestedURL.resolvingSymlinksInPath().path,
                       archive.resolvingSymlinksInPath().path,
                       "書庫内ページは書庫本体")
    }

    /// 組み立て進捗が (0,総数)→…→(総数,総数) で単調に通知されること
    /// (オープン進捗 HUD の情報源)
    func testAssemblyProgressReportsMonotonicCounts() async throws {
        for name in ["a.zip", "b.zip", "c.zip"] {
            try zipData([("p1.png", png(width: 40))])
                .write(to: tempDir.appendingPathComponent(name))
        }
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        let collector = ProgressCollector()
        await source.setAssemblyProgressHandler { done, total in
            collector.append(done: done, total: total)
        }
        _ = try await source.entries()

        let events = collector.events
        XCTAssertEqual(events.first?.done, 0, "開始時に 0/総数 を通知")
        XCTAssertEqual(events.last?.done, 3)
        XCTAssertTrue(events.allSatisfy { $0.total == 3 })
        XCTAssertEqual(events.map(\.done), events.map(\.done).sorted(),
                       "完了数は単調増加")
    }

    func testAssemblyProgressCountsUnreadableChildrenAsProcessed() async throws {
        try zipData([("p1.png", png(width: 40))])
            .write(to: tempDir.appendingPathComponent("a.zip"))
        try Data("broken archive".utf8).write(to: tempDir.appendingPathComponent("b.zip"))
        try Data("broken PDF".utf8).write(to: tempDir.appendingPathComponent("c.pdf"))
        let source = try await BookSourceFactory.make(for: tempDir, readSubFolders: false)
        let collector = ProgressCollector()
        await source.setAssemblyProgressHandler { done, total in
            collector.append(done: done, total: total)
        }
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 1, "読めた子のページは残す")
        XCTAssertEqual(collector.events.map(\.done), [0, 1, 2, 3])
        XCTAssertTrue(collector.events.allSatisfy { $0.total == 3 })
    }
}

/// 進捗コールバックの記録(actor 外から呼ばれるためロックで保護)
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(done: Int, total: Int)] = []

    func append(done: Int, total: Int) {
        lock.lock()
        stored.append((done, total))
        lock.unlock()
    }

    var events: [(done: Int, total: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// UTI 登録や実復号から独立して、窓の並列可否を実際の書庫ソース経由で検証する。
private final class WindowQueryArchiveEngine: ArchiveEngine {
    private let serial: Bool
    init(serial: Bool) { self.serial = serial }
    init?(file path: String, role: ArchiveReaderRole) { return nil }
    init?(data: Data, role: ArchiveReaderRole) { return nil }
    func numberOfEntries() -> Int32 { 2 }
    func name(ofEntry index: Int32) -> String? { "page-\(index).avifs" }
    func contents(ofEntry index: Int32) -> Data? { nil }
    func uncompressedSize(ofEntry index: Int32) -> Int64 { 1 }
    func entryHasSize(_ index: Int32) -> Bool { true }
    func entryIsDirectory(_ index: Int32) -> Bool { false }
    func entryIsEncrypted(_ index: Int32) -> Bool { false }
    func isEncrypted() -> Bool { false }
    func setPassword(_ password: String) {}
    func solidGroup(ofEntry index: Int32) -> Int32 { serial ? 0 : -1 }
    static var defaultZipLazyLocalHeaders: Bool { true }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {}
}
