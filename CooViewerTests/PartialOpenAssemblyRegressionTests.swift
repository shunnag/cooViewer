import AppKit
import Darwin
import KaitoKit
import os
import XCTest
@testable import cooViewer

final class PartialOpenAssemblyRegressionTests: XCTestCase {
    @MainActor
    func testArchiveAssemblyFailureDoesNotOfferPartialConsent() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = TestFixtures.storedZip(entries: [
            (Array("page.png".utf8), TestFixtures.pngData(width: 4, height: 6))
        ])
        let url = root.appendingPathComponent("outer.zip")
        try TestFixtures.storedZip(entries: ["a.zip", "b.zip"].map { (Array($0.utf8), child) }).write(to: url)
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let factory = ArchiveEngineFactory(openFile: { kind, path, role in
            if URL(fileURLWithPath: path).lastPathComponent.hasSuffix("b.zip") { throw KaitoError.io(EACCES) }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
        let source = try ArchiveSource(url: url, engineFactory: factory, retryPolicy: policy)
        let suite = "test.cooViewer.archive-partial-consent.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookHistoryStore(defaults: defaults, directory: root.appendingPathComponent("states"))
        let controller = ReaderWindowController(window: nil, history: store)
        controller.workspaceNotificationCenter = NotificationCenter()
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        defer { controller.replaceBook(nil) }
        XCTAssertNotNil(controller.failedOpen)
        XCTAssertFalse(controller.canOpenWithoutUnreadableVolumes)
        XCTAssertTrue(controller.partialOpenButtonPresentation.hidden)
        let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.openWithoutUnreadableVolumes(_:)),
            keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item))
    }

    func testUncheckedChildrenBecomeNamedCardsWithoutBeingOpened() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = TestFixtures.storedZip(entries: [
            (Array("page.png".utf8), TestFixtures.pngData(width: 4, height: 6))
        ])
        for name in ["a.zip", "b.zip", "c.zip", "d.zip"] { try zip.write(to: root.appendingPathComponent(name)) }
        let control = PartialAssemblyOpenControl(failing: ["b.zip"])
        let prepared = AssemblyTestGate()
        let unchecked = AssemblyTestGate()
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .zero
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        policy.beforeChildAttempt = { path in
            if path == "b.zip" { await prepared.wait() }
            if path == "c.zip" || path == "d.zip" { await unchecked.wait() }
            try Task.checkCancellation()
        }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: policy)
        await source.setAssemblyProgressHandler { done, _ in
            if done == 1 { Task { await prepared.open() } }
        }
        do { _ = try await source.entries(); XCTFail("未確認の巻を失敗として残す") }
        catch {
            let failure = try XCTUnwrap(error as? AssemblyFailure)
            XCTAssertEqual(failure.unchecked, 2)
        }
        let before = control.calls
        let entries = try await source.partialEntries()
        await unchecked.open()
        XCTAssertEqual(entries.map(\.pathInBook), ["a.zip/page.png", "b.zip", "c.zip", "d.zip"])
        XCTAssertEqual(entries.compactMap(\.unreadableVolume).map(\.relativePath), ["b.zip", "c.zip", "d.zip"])
        XCTAssertNil(entries[2].unreadableVolume?.cause)
        XCTAssertNil(entries[3].unreadableVolume?.cause)
        XCTAssertEqual(control.calls, before)
        XCTAssertNil(control.calls["c.zip"])
        XCTAssertNil(control.calls["d.zip"])
    }

    func testPartialAssemblyKeepsSortedCardsAndRetriesOnlyMissingChildren() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = TestFixtures.pngData(width: 4, height: 6)
        let zip = TestFixtures.storedZip(entries: [(Array("page.png".utf8), png)])
        for name in ["a.zip", "b.zip", "c.zip", "d.zip", "e.zip"] {
            try zip.write(to: root.appendingPathComponent(name))
        }
        for name in ["00.png", "z.png"] { try png.write(to: root.appendingPathComponent(name)) }
        try Data("broken".utf8).write(to: root.appendingPathComponent("corrupt.zip"))
        let control = PartialAssemblyOpenControl(failing: ["b.zip", "d.zip"])
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: policy)
        do { _ = try await source.entries(); XCTFail("失敗を完全本として扱わない") }
        catch { XCTAssertTrue(error is AssemblyFailure) }
        let before = control.calls
        let partial = try await source.partialEntries()
        XCTAssertEqual(partial.map(\.pathInBook),
            ["00.png", "a.zip/page.png", "b.zip", "c.zip/page.png", "d.zip", "e.zip/page.png", "z.png"])
        let cards = partial.filter { $0.unreadableVolume != nil }
        XCTAssertEqual(cards.map(\.id), [2_999_999, 5_999_999])
        XCTAssertEqual(Set(partial.map(\.id)).count, partial.count)
        XCTAssertEqual(cards.map { $0.unreadableVolume?.cause }, [.diskFull, .diskFull])
        for entry in cards { _ = try await source.image(for: entry, maxPixelSize: 80) }
        _ = try await source.partialEntries()
        XCTAssertEqual(control.calls, before)
        let recorded = await source.cardChildren
        XCTAssertEqual(recorded.map(\.relativePath), ["b.zip", "d.zip"])
        control.recover()
        let complete = try await source.entries()
        let baseline = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            retryPolicy: policy)
        let expected = try await baseline.entries()
        XCTAssertEqual(complete, expected)
        for name in ["a.zip", "c.zip", "corrupt.zip", "e.zip"] {
            XCTAssertEqual(control.calls[name], before[name], name)
        }
        for name in ["b.zip", "d.zip"] {
            XCTAssertEqual(control.calls[name], (before[name] ?? 0) + 1, name)
        }
        let remainingCards = await source.cardChildren
        XCTAssertTrue(remainingCards.isEmpty)
    }

    func testCardsKeepVolumeNamePositionInUndatedGroupUnderDateSorts() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = TestFixtures.pngData(width: 4, height: 6)
        let zip = TestFixtures.storedZip(entries: [(Array("page.png".utf8), png)])
        for (index, name) in ["a.zip", "b.zip", "c.zip"].enumerated() {
            let url = root.appendingPathComponent(name)
            try zip.write(to: url)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(3000 - index)),
                .modificationDate: Date(timeIntervalSince1970: Double(4000 - index))], ofItemAtPath: url.path)
        }
        try png.write(to: root.appendingPathComponent("z.png"))
        let control = PartialAssemblyOpenControl(failing: ["b.zip"])
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: policy)
        do { _ = try await source.entries(); XCTFail("失敗した巻を残す") } catch { XCTAssertTrue(error is AssemblyFailure) }
        let entries = try await source.partialEntries()
        let card = try XCTUnwrap(entries.first { $0.unreadableVolume != nil })
        XCTAssertNil(card.creationDate)
        XCTAssertNil(card.modificationDate)
        for mode in [SortMode.creationDate, .modificationDate] {
            let sorted = PageSorter.sorted(entries, mode: mode)
            XCTAssertEqual(sorted.map(\.pathInBook), ["z.png", "a.zip/page.png", "b.zip", "c.zip/page.png"])
        }
    }

    func testCompleteEntriesAndCacheKeyRetainStageTwoDateSemantics() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = TestFixtures.pngData(width: 4, height: 6)
        let names = ["a.zip", "b.zip", "c.zip"]
        for (index, name) in names.enumerated() {
            let url = root.appendingPathComponent(name)
            try TestFixtures.storedZip(entries: [(Array("page.png".utf8), png)]).write(to: url)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(3000 - index)),
                .modificationDate: Date(timeIntervalSince1970: Double(4000 - index))], ofItemAtPath: url.path)
        }
        try png.write(to: root.appendingPathComponent("z.png"))
        let folder = try FolderSource(url: root, readSubFolders: false)
        let entries = try await NestedFolderSource(folder: folder, retryPolicy: .immediate).entries()
        // 段階2の実ページは巻の日時を継承しない。固定した旧エントリと比較し、既存キャッシュの互換性を守る(設計書 §2.4、§7.4)。
        var expected = names.enumerated().map { ordinal, name in
            PageEntry(id: (ordinal + 1) * 1_000_000, name: "page.png", pathInBook: name + "/page.png",
                fileURL: nil, creationDate: nil, modificationDate: nil)
        }
        expected += try await folder.entries()
        XCTAssertEqual(entries, expected)
        let identity = BookFileIdentity(modified: 1234, size: 5678)
        for mode in [SortMode.name, .creationDate, .modificationDate] {
            let old = Book.prepare(url: root, entries: expected, sortMode: mode, identity: identity)
            let current = Book.prepare(url: root, entries: entries, sortMode: mode, identity: identity)
            XCTAssertEqual(current.sortedEntries, old.sortedEntries)
            XCTAssertEqual(current.cacheKey, old.cacheKey)
        }
    }

    func testPartialSpoolingReservesMissingArchiveBudgetUntilCompletion() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = TestFixtures.pngData(width: 4, height: 6)
        for (name, pages) in [("a.zip", ["1.png", "2.png"]), ("b.zip", ["1.png"])] {
            try TestFixtures.storedZip(entries: pages.map { (Array($0.utf8), png) })
                .write(to: root.appendingPathComponent(name))
        }
        try Data("broken".utf8).write(to: root.appendingPathComponent("c.pdf"))
        try writeExcludedAndSkippedArchives(in: root, png: png)
        let control = PartialAssemblyOpenControl(failing: ["b.zip"])
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            unlocker: NestedUnlocker(provider: { _, _ in nil }, vault: nil), engineFactory: control.factory, retryPolicy: policy)
        do { _ = try await source.entries(); XCTFail("失敗した巻を残す") } catch { XCTAssertTrue(error is AssemblyFailure) }
        let partial = try await source.partialEntries()
        XCTAssertEqual(partial.compactMap(\.unreadableVolume).map(\.relativePath), ["b.zip"])
        await source.applyMediaProfile(MediaProfile(mediaClass: .slowLocal, spoolOverride: true))
        let budget = Int64(png.count * 3 - 1)
        await source.beginBackgroundPreparation(spoolSizeLimit: budget)
        let partialCount = await source.waitForSpoolCompletion()
        XCTAssertEqual(partialCount, 0)
        control.recover()
        _ = try await source.entries()
        await source.beginBackgroundPreparation(spoolSizeLimit: budget)
        let completeCount = await source.waitForSpoolCompletion()
        XCTAssertEqual(completeCount, 1)
        XCTAssertLessThanOrEqual(Int64(completeCount * png.count), budget)
    }

    func testCompleteSpoolDivisorExcludesCorruptCancelledAndEmptyArchives() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = TestFixtures.pngData(width: 4, height: 6)
        try TestFixtures.storedZip(entries: ["1.png", "2.png"].map { (Array($0.utf8), png) })
            .write(to: root.appendingPathComponent("a.zip"))
        try writeExcludedAndSkippedArchives(in: root, png: png)
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            unlocker: NestedUnlocker(provider: { _, _ in nil }, vault: nil), retryPolicy: .immediate)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["a.zip/1.png", "a.zip/2.png"])
        let excluded = await source.excludedChildCount()
        XCTAssertEqual(excluded, 2)
        await source.applyMediaProfile(MediaProfile(mediaClass: .slowLocal, spoolOverride: true))
        await source.beginBackgroundPreparation(spoolSizeLimit: Int64(png.count * 2))
        let count = await source.waitForSpoolCompletion()
        XCTAssertEqual(count, 2)
    }

    func testSpoolDivisorCountsOnlyArchiveCards() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = TestFixtures.pngData(width: 4, height: 6)
        try TestFixtures.storedZip(entries: ["1.avifs", "2.avifs"].map { (Array($0.utf8), png) })
            .write(to: root.appendingPathComponent("a.zip"))
        for name in ["b.zip", "c.pdf"] { try Data().write(to: root.appendingPathComponent(name)) }
        var policy = AssemblyRetryPolicy.immediate
        policy.beforeChildAttempt = { path in
            if path == "b.zip" || path == "c.pdf" { throw KaitoError.io(ENOSPC) }
        }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
                                        retryPolicy: policy)
        do { _ = try await source.entries(); XCTFail("失敗した巻を残す") }
        catch { XCTAssertTrue(error is AssemblyFailure) }
        let partial = try await source.partialEntries()
        XCTAssertEqual(partial.compactMap(\.unreadableVolume).map(\.relativePath), ["b.zip", "c.pdf"])
        await source.applyMediaProfile(MediaProfile(mediaClass: .slowLocal, spoolOverride: true))
        // 書庫カードの枠を予約しない場合は、この予算でも 2 ページがスプールされてしまう。
        await source.beginBackgroundPreparation(spoolSizeLimit: Int64(png.count * 2))
        let reservedCount = await source.waitForSpoolCompletion()
        XCTAssertEqual(reservedCount, 0)
        // 書庫カードだけなら分母は 2。PDF まで数えると 2 ページ分の予算に届かない。
        await source.beginBackgroundPreparation(spoolSizeLimit: Int64(png.count * 4))
        let count = await source.waitForSpoolCompletion()
        XCTAssertEqual(count, 2)
    }

    func testCardCauseUsesFirstMatchingFailure() async throws {
        let url = URL(fileURLWithPath: "/synthetic/図面集/A-002.zip", isDirectory: false)
        let failures = [SourceReadFailure.ReadFailureCause.accessDenied, .diskFull].map {
            ChildReadFailure(relativePath: "A-002.zip", url: url, cause: $0, retryClass: .persistent)
        }
        let (source, _) = await NestedFolderSource.syntheticFailure(failures: failures)
        let entries = try await source.partialEntries()
        XCTAssertEqual(entries.first { $0.pathInBook == "A-002.zip" }?.unreadableVolume?.cause, .accessDenied)
    }

    func testContainerFileURLForCardDoesNotNeedExistingFile() async throws {
        let (source, _) = await NestedFolderSource.syntheticFailure()
        let entries = try await source.partialEntries()
        let card = try XCTUnwrap(entries.first { $0.unreadableVolume != nil })
        let url = await source.containerFileURL(for: card)
        XCTAssertTrue(url.isFileURL)
        XCTAssertFalse(url.hasDirectoryPath)
        XCTAssertEqual(url.path, source.url.path + "/" + card.pathInBook)
    }

    private func writeExcludedAndSkippedArchives(in root: URL, png: Data) throws {
        try Data("broken".utf8).write(to: root.appendingPathComponent("corrupt.zip"))
        try TestFixtures.storedZip(entries: []).write(to: root.appendingPathComponent("empty.zip"))
        let payload = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let page = payload.appendingPathComponent("secret.png")
        try png.write(to: page)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-j", "-P", "test-password", root.appendingPathComponent("locked.zip").path, page.path]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
    }

    func testChildReachingStrideCannotUseTheReservedCardID() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.zip", "b.zip"] { try Data().write(to: root.appendingPathComponent(name)) }
        let factory = ArchiveEngineFactory(openFile: { _, path, _ in
            if URL(fileURLWithPath: path).lastPathComponent == "b.zip" { throw KaitoError.io(ENOSPC) }
            return StrideBoundaryArchiveEngine()
        }, openData: { _, _, _ in nil })
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: factory, retryPolicy: policy)
        do { _ = try await source.entries(); XCTFail("失敗した巻のカードを残す") }
        catch { XCTAssertTrue(error is AssemblyFailure) }
        let entries = try await source.partialEntries()
        let stride = NestedFolderSource.nestedIDStride
        XCTAssertEqual(entries.count, stride)
        XCTAssertEqual(entries[0].id, stride)
        XCTAssertEqual(entries[stride - 2].id, 2 * stride - 2)
        XCTAssertEqual(entries.last?.id, 3 * stride - 1)
        XCTAssertFalse(entries.contains { $0.id == 2 * stride - 1 })
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    }
}

/// 実ファイルを百万個作らず、登録経路そのものの境界を検証する(設計書 §7.4、§2.4)。
private final class StrideBoundaryArchiveEngine: ArchiveEngine {
    init() {}
    init?(file path: String, role: ArchiveReaderRole) {}
    init?(data: Data, role: ArchiveReaderRole) {}
    func numberOfEntries() -> Int32 { Int32(NestedFolderSource.nestedIDStride + 2) }
    func name(ofEntry index: Int32) -> String? { "page.png" }
    func contents(ofEntry index: Int32) -> Data? { nil }
    func uncompressedSize(ofEntry index: Int32) -> Int64 { 1 }
    func entryHasSize(_ index: Int32) -> Bool { true }
    func entryIsDirectory(_ index: Int32) -> Bool { false }
    func entryIsEncrypted(_ index: Int32) -> Bool { false }
    func isEncrypted() -> Bool { false }
    func setPassword(_ password: String) {}
    func solidGroup(ofEntry index: Int32) -> Int32 { -1 }
    static var defaultZipLazyLocalHeaders: Bool { true }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {}
}

private final class PartialAssemblyOpenControl: Sendable {
    private struct State {
        var failing: Set<String>
        var calls: [String: Int] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>
    init(failing: Set<String>) { state = .init(initialState: State(failing: failing)) }
    var calls: [String: Int] { state.withLock { $0.calls } }
    func recover() { state.withLock { $0.failing = [] } }

    var factory: ArchiveEngineFactory {
        ArchiveEngineFactory(openFile: { kind, path, role in
            guard role == .primary else { return try ArchiveEngineFactory.live.openFile(kind, path, role) }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let fails = self.state.withLock {
                $0.calls[name, default: 0] += 1
                return $0.failing.contains(name)
            }
            // 恒久的な権限拒否ではなく、同意と回復が必要な環境要因を再現する(設計書 §7.4)。
            if fails { throw KaitoError.io(ENOSPC) }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
    }
}
