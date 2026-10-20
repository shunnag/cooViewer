import Darwin
import KaitoKit
import os
import XCTest
@testable import cooViewer

final class AssemblyCollectionTests: XCTestCase {
    func testDanglingSymlinkChildIsExcludedWithoutRetryWait() async throws {
        let root = try directory(names: ["good.zip"], pageName: "page.avifs")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bad.zip"),
            withDestinationURL: root.appendingPathComponent("gone.zip"))
        try await checkPermanentChildExcluded(folder: FolderSource(url: root, readSubFolders: false))
    }

    func testUnreadableChildIsExcludedWithoutRetryWait() async throws {
        try XCTSkipIf(geteuid() == 0, "root は読取権限の拒否を再現できない")
        let root = try directory(names: ["good.zip", "bad.zip"], pageName: "page.avifs")
        let bad = root.appendingPathComponent("bad.zip")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bad.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bad.path) }
        try await checkPermanentChildExcluded(folder: FolderSource(url: root, readSubFolders: false))
    }

    func testChildVanishedAfterEnumerationIsExcludedWithoutRetryWait() async throws {
        let root = try directory(names: ["good.zip", "bad.zip"], pageName: "page.avifs")
        let folder = try FolderSource(url: root, readSubFolders: false)
        try FileManager.default.removeItem(at: root.appendingPathComponent("bad.zip"))
        try await checkPermanentChildExcluded(folder: folder)
    }

    func testPermanentErrnosAndCocoaChildFailuresAreSilentlyExcluded() async throws {
        let root = try directory(names: ["good.zip", "bad.zip"], pageName: "page.avifs")
        let errors: [any Error] = [ENOENT, ENOTDIR, ELOOP, EACCES, EPERM].map { KaitoError.io($0) }
            + [4, 260, 257].map { NSError(domain: NSCocoaErrorDomain, code: $0) }
        for error in errors {
            let factory = ArchiveEngineFactory(openFile: { kind, path, role in
                if path.hasSuffix("/bad.zip") { throw error }
                return try ArchiveEngineFactory.live.openFile(kind, path, role)
            }, openData: { _, _, _ in nil })
            try await checkPermanentChildExcluded(folder: FolderSource(url: root, readSubFolders: false),
                                                  engineFactory: factory)
        }
    }

    func testEnvironmentalChildFailuresStillProduceAssemblyFailure() async throws {
        let root = try directory(names: ["good.zip", "bad.zip"], pageName: "page.avifs")
        for code in [EIO, ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN,
                     EHOSTUNREACH, ENXIO, ECONNRESET, EMFILE, ENFILE, EAGAIN, ENOMEM, ESTALE, ENOSPC] {
            let control = OpenControl(failures: ["bad.zip": (code, 100)])
            var policy = AssemblyRetryPolicy.immediate
            policy.reachabilityProbe = { _ in true }
            let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
                engineFactory: control.factory, retryPolicy: policy)
            let failure = try await assemblyFailure(source)
            XCTAssertEqual(failure.failures.map(\.relativePath), ["bad.zip"], "errno \(code)")
            XCTAssertFalse(failure.volumeUnavailable)
            let excluded = await source.excludedChildCount()
            XCTAssertEqual(excluded, 0)
        }
    }

    func testUnreachableCollectionWinsOverPermanentChildExclusion() async throws {
        let root = try directory(names: ["good.zip", "bad.zip"], pageName: "page.avifs")
        for code in [ENOENT, EACCES] {
            let control = OpenControl(failures: ["bad.zip": (code, 100)])
            let gate = AssemblyTestGate()
            let probing = expectation(description: "親フォルダへの到達を確認中")
            let clock = AssemblyTestClock { _ in }
            var policy = AssemblyRetryPolicy.immediate
            policy.now = { clock.now }
            policy.sleep = { try await clock.sleep($0) }
            policy.reachabilityProbe = { _ in probing.fulfill(); await gate.wait(); return false }
            let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
                engineFactory: control.factory, retryPolicy: policy)
            let finished = OSAllocatedUnfairLock(initialState: false)
            let build = Task {
                defer { finished.withLock { $0 = true } }
                return try await source.entries()
            }
            await fulfillment(of: [probing], timeout: 2)
            XCTAssertFalse(finished.withLock { $0 })
            await gate.open()
            do { _ = try await build.value; XCTFail("保存先の失敗を返す") }
            catch {
                let failure = try XCTUnwrap(error as? AssemblyFailure)
                XCTAssertTrue(failure.volumeUnavailable)
                XCTAssertEqual(failure.failures.first?.relativePath, "bad.zip")
            }
            let excluded = await source.excludedChildCount()
            XCTAssertEqual(excluded, 0)
        }
    }

    func testCollectionReachabilityTimeoutWinsOverNotFoundChildExclusion() async throws {
        let root = try directory(names: ["good.zip", "bad.zip"], pageName: "page.avifs")
        let control = OpenControl(failures: ["bad.zip": (ENOENT, 100)])
        let gate = AssemblyTestGate()
        var policy = AssemblyRetryPolicy.immediate
        policy.probeTimeout = .zero
        policy.reachabilityProbe = { _ in await gate.wait(); return true }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: policy)
        let failure = try await assemblyFailure(source)
        await gate.open()
        XCTAssertTrue(failure.volumeUnavailable)
        XCTAssertTrue(failure.reachabilityTimedOut)
        XCTAssertEqual(failure.failures.first?.cause, .notFound)
        let excluded = await source.excludedChildCount()
        XCTAssertEqual(excluded, 0)
    }

    // 型情報サービスの有無に左右されず、子の除外と待機だけを検証する(設計書 §7.4)。
    private func checkPermanentChildExcluded(folder: FolderSource,
                                            engineFactory: ArchiveEngineFactory = .live) async throws {
        XCTAssertEqual(folder.nestedBookCandidates.map(\.relativePath), ["bad.zip", "good.zip"])
        let retrySleeps = OSAllocatedUnfairLock(initialState: 0)
        let retries = OSAllocatedUnfairLock(initialState: 0)
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.default
        policy.now = { clock.now }
        policy.sleep = { duration in
            if [.milliseconds(250), .milliseconds(750), .milliseconds(1500), .seconds(3)].contains(duration) {
                retrySleeps.withLock { $0 += 1 }
            }
            try await clock.sleep(duration)
        }
        let source = NestedFolderSource(folder: folder, engineFactory: engineFactory, retryPolicy: policy)
        await source.setAssemblyRetryHandler { _ in retries.withLock { $0 += 1 } }
        let finished = expectation(description: "10秒の期限や再試行待機なしで開く")
        let start = ContinuousClock.now
        let build = Task {
            defer { finished.fulfill() }
            return try await source.entries()
        }
        await fulfillment(of: [finished], timeout: 2)
        // 退行時も仮想時計の待ち手を残さず、失敗として回収する(設計書 §7.4)。
        clock.advance(.seconds(10))
        let pages = try await build.value
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
        XCTAssertEqual(pages.map(\.pathInBook), ["good.zip/page.avifs"])
        XCTAssertTrue(pages.allSatisfy { $0.unreadableVolume == nil })
        let canOpenPartial = await source.canOpenPartial
        let excluded = await source.excludedChildCount()
        XCTAssertFalse(canOpenPartial)
        XCTAssertEqual(excluded, 1)
        XCTAssertEqual(retrySleeps.withLock { $0 }, 0)
        XCTAssertEqual(retries.withLock { $0 }, 0)
    }

    func testPartialEntriesKeepSortedCardsWithoutReadingAndCompleteRetryKeepsIDs() async throws {
        let root = try directory(names: ["10.zip", "30.zip", "50.zip"])
        try TestFixtures.storedZip(entries: ["page.png", "page2.png"].map {
            (Array($0.utf8), TestFixtures.pngData(width: 40, height: 60))
        }).write(to: root.appendingPathComponent("30.zip"))
        try TestFixtures.pngData(width: 40, height: 60).write(to: root.appendingPathComponent("20.png"))
        let control = OpenControl(failures: ["10.zip": (ENOSPC, 100), "50.zip": (ENOSPC, 100)])
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: policy)
        _ = try await assemblyFailure(source)
        let before = ["10.zip", "30.zip", "50.zip"].map { control.calls($0) }
        let partial = try await source.partialEntries()
        XCTAssertEqual(partial.map(\.pathInBook), ["10.zip", "20.png", "30.zip/page.png", "30.zip/page2.png", "50.zip"])
        XCTAssertEqual(partial.map(\.id), [1_999_999, 0, 2_000_000, 2_000_001, 3_999_999])
        XCTAssertEqual(partial.compactMap(\.unreadableVolume).map(\.cause), [.diskFull, .diskFull])
        XCTAssertEqual(Set(partial.map(\.id)).count, partial.count)
        let cards = await source.cardChildren
        XCTAssertEqual(cards.count, 2)
        let image = try await source.image(for: partial[0], maxPixelSize: nil)
        XCTAssertEqual(image.width, 700)
        _ = await source.containerFileURL(for: partial[2])
        _ = await source.archiveEngineKind(for: partial[2])
        _ = await source.containsProtectedContent()
        _ = await source.preparsedReflowPublication(for: root.appendingPathComponent("none.epub"))
        _ = try await source.partialEntries()
        for entry in partial where entry.pathInBook.hasPrefix("30.zip/") {
            _ = try await source.image(for: entry, maxPixelSize: nil)
        }
        XCTAssertEqual(["10.zip", "30.zip", "50.zip"].map { control.calls($0) }, before)
        _ = try await assemblyFailure(source)
        XCTAssertGreaterThan(control.calls("10.zip"), before[0])
        XCTAssertEqual(control.calls("30.zip"), before[1])
        // 再失敗後も表示中の実ページの所在を保つ(設計書 §7.4)。
        let kept = try await source.image(for: partial[2], maxPixelSize: nil)
        XCTAssertEqual(kept.width, 40)
        control.recover()
        let complete = try await source.entries()
        let baseline = try await NestedFolderSource(folder: FolderSource(url: root, readSubFolders: false),
                                                    retryPolicy: .immediate).entries()
        XCTAssertEqual(complete, baseline)
        XCTAssertEqual(control.calls("30.zip"), 1)
        let remaining = await source.cardChildren
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPartialEntriesIncludeUncheckedChildrenAndFolderImage() async throws {
        let root = try directory(names: ["a.zip", "b.zip", "c.zip"])
        try TestFixtures.pngData(width: 40, height: 60).write(to: root.appendingPathComponent("0.png"))
        let gate = AssemblyTestGate()
        let control = OpenControl(failures: ["a.zip": (ENOSPC, 100)])
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .zero
        policy.beforeChildAttempt = { name in if name != "a.zip" { await gate.wait() } }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: policy)
        let failure = try await assemblyFailure(source)
        XCTAssertEqual(failure.unchecked, 2)
        let entries = try await source.partialEntries()
        XCTAssertEqual(entries.map(\.pathInBook), ["0.png", "a.zip", "b.zip", "c.zip"])
        XCTAssertEqual(entries[1].unreadableVolume?.cause, .diskFull)
        XCTAssertNotNil(entries[2].unreadableVolume)
        XCTAssertNil(entries[2].unreadableVolume?.cause)
        XCTAssertNotNil(entries[3].unreadableVolume)
        XCTAssertNil(entries[3].unreadableVolume?.cause)
        XCTAssertEqual(control.calls("b.zip"), 0)
        XCTAssertEqual(control.calls("c.zip"), 0)
        await gate.open()
    }

    func testCardReservationRejectsTheLastOffsetOfEachMillionPageDomain() {
        let stride = NestedFolderSource.nestedIDStride
        for offset in [0, stride - 2] { XCTAssertTrue(NestedFolderSource.acceptsPageOffset(offset)) }
        for offset in [stride - 1, stride, Int.max] { XCTAssertFalse(NestedFolderSource.acceptsPageOffset(offset)) }
        for ordinal in 1...5 {
            let largestRealID = ordinal * stride + stride - 2
            let cardID = ordinal * stride + stride - 1
            XCTAssertLessThan(largestRealID, cardID)
            XCTAssertLessThan(cardID, (ordinal + 1) * stride)
        }
    }

    func testMillionPageChildNeverAllocatesTheReservedCardID() {
        let stride = NestedFolderSource.nestedIDStride
        var count = 0
        var last = 0
        var collides = false
        // 登録と同じ割当関数で百万ページ分を走査し、巨大画像 fixture を要さず境界を検証する(設計書 §7.4)。
        for offset in 0..<(stride + 2) {
            if let id = NestedFolderSource.realPageID(ordinal: 2, offset: offset) {
                count += 1
                last = id
                if id == 2 * stride + stride - 1 { collides = true }
            }
        }
        XCTAssertEqual(count, stride - 1)
        XCTAssertEqual(last, 2_999_998)
        XCTAssertFalse(collides)
    }

    func testFolderRecoversWithinBudgetWithIdenticalEntriesAndRetryNotification() async throws {
        let root = try directory(names: ["a.zip", "b.zip", "c.zip"])
        let control = OpenControl(failures: ["b.zip": (EMFILE, 2)])
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: .immediate)
        let retried = OSAllocatedUnfairLock(initialState: [String]())
        await source.setAssemblyRetryHandler { name in retried.withLock { $0.append(name) } }
        let pages = try await source.entries()
        let baseline = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
                                           retryPolicy: .immediate)
        let expected = try await baseline.entries()
        XCTAssertEqual(pages, expected)
        XCTAssertEqual(control.calls("b.zip"), 3)
        XCTAssertEqual(retried.withLock { $0 }, ["b.zip"])
    }

    func testSingleTransientBlipDoesNotNotifyRetryHUD() async throws {
        let root = try directory(names: ["a.zip"])
        let control = OpenControl(failures: ["a.zip": (EMFILE, 1)])
        let notified = OSAllocatedUnfairLock(initialState: [String]())
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: .immediate)
        await source.setAssemblyRetryHandler { path in notified.withLock { $0.append(path) } }
        _ = try await source.entries()
        XCTAssertEqual(notified.withLock { $0 }, [])
        XCTAssertEqual(control.calls("a.zip"), 2)
    }

    func testFolderCollectsEveryFailureAndReopensOnlyFailedOrdinals() async throws {
        let root = try directory(names: ["a.zip", "b.zip", "c.zip"])
        let control = OpenControl(failures: ["a.zip": (EMFILE, 100), "c.zip": (ENOSPC, 100)])
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: .immediate)
        let failure = try await assemblyFailure(source)
        XCTAssertEqual(failure.failures.map(\.relativePath), ["a.zip", "c.zip"])
        XCTAssertEqual(failure.failures.map(\.cause), [.repeatedFailure, .diskFull])
        XCTAssertEqual(failure.total, 3)
        XCTAssertEqual(failure.unchecked, 0)
        XCTAssertFalse(failure.volumeUnavailable)
        XCTAssertEqual(control.calls("b.zip"), 1)
        let previousA = control.calls("a.zip")
        control.recover()
        let recovered = try await source.entries()
        XCTAssertEqual(recovered.map(\.id), [1_000_000, 2_000_000, 3_000_000])
        XCTAssertEqual(control.calls("a.zip"), previousA + 1)
        XCTAssertEqual(control.calls("b.zip"), 1)
        XCTAssertEqual(control.calls("c.zip"), 2)
        let image = try await source.image(for: XCTUnwrap(recovered.dropFirst().first), maxPixelSize: nil)
        XCTAssertEqual(image.width, 40)
    }

    func testInnerAssemblyFailureSurvivesFolderAndArchiveNestingWithoutOuterRetries() async throws {
        let root = try directory(names: [])
        let inner = TestFixtures.storedZip(entries: [(Array("deep.zip".utf8), zip())])
        try inner.write(to: root.appendingPathComponent("outer.zip"))
        let control = OpenControl(failures: ["0-deep.zip": (ESTALE, 100)])
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: .immediate)
        let failure = try await assemblyFailure(source)
        XCTAssertEqual(failure.failures.map(\.relativePath), ["outer.zip"])
        XCTAssertEqual(failure.failures.first?.cause, .fileChanged)
        XCTAssertEqual(control.calls("outer.zip"), 1, "外側の階層で再試行を掛け算しない")
        XCTAssertEqual(control.calls("0-deep.zip"), 4)
        let innerFailure = (failure as NSError).userInfo[NSUnderlyingErrorKey] as? AssemblyFailure
        XCTAssertEqual(innerFailure?.failures.first?.relativePath, "deep.zip")
    }

    func testArchiveCollectsFailuresAndKeepsCandidateIDsAfterRecovery() async throws {
        let root = try directory(names: [])
        let outer = root.appendingPathComponent("outer.zip")
        try TestFixtures.storedZip(entries: ["a.zip", "b.zip", "c.zip"].map {
            (Array($0.utf8), zip())
        }).write(to: outer)
        let control = OpenControl(failures: ["0-a.zip": (EMFILE, 100), "2-c.zip": (EACCES, 100)])
        let source = try ArchiveSource(url: outer, engineFactory: control.factory, retryPolicy: .immediate)
        let failure = try await assemblyFailure(source)
        XCTAssertEqual(failure.failures.map(\.relativePath), ["a.zip", "c.zip"])
        XCTAssertEqual(failure.total, 3)
        control.recover()
        let pages = try await source.entries()
        XCTAssertEqual(pages.map(\.id), [1_000_000, 2_000_000, 3_000_000])
        let expected = try await ArchiveSource(url: outer, retryPolicy: .immediate).entries()
        XCTAssertEqual(pages, expected)
    }

    func testFailureCutoffCountsUncheckedAndNextBuildCompletes() async throws {
        let names = (0..<12).map { String(format: "%02d.zip", $0) }
        let root = try directory(names: names)
        let control = OpenControl(failures: Dictionary(uniqueKeysWithValues: names.map { ($0, (ENOSPC, 100)) }))
        let gate = AssemblyTestGate()
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .zero
        // 既に届いた失敗は全件集約するため、未確認に数えたい他の子は実際に止める(設計書 §7.4)。
        policy.beforeChildAttempt = { path in
            if path != names[0] { await gate.wait(); try Task.checkCancellation() }
        }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: policy)
        let failure = try await assemblyFailure(source)
        XCTAssertEqual(failure.failures.count, 1)
        XCTAssertEqual(failure.unchecked, 11)
        XCTAssertEqual(failure.total, 12)
        control.recover()
        await gate.open()
        let pages = try await source.entries()
        XCTAssertEqual(pages.count, 12)
    }

    func testUnreachableCollectionStopsAndProbesOnlyOnce() async throws {
        let names = (0..<12).map { String(format: "%02d.zip", $0) }
        let root = try directory(names: names)
        let control = OpenControl(failures: Dictionary(uniqueKeysWithValues: names.map { ($0, (ENOENT, 100)) }))
        let probes = OSAllocatedUnfairLock(initialState: 0)
        var policy = AssemblyRetryPolicy.immediate
        policy.reachabilityProbe = { _ in probes.withLock { $0 += 1 }; return false }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: control.factory, retryPolicy: policy)
        let failure = try await assemblyFailure(source)
        XCTAssertTrue(failure.volumeUnavailable)
        XCTAssertGreaterThan(failure.unchecked, 0)
        XCTAssertEqual(failure.failures.count + failure.unchecked, 12)
        XCTAssertEqual(probes.withLock { $0 }, 1)
        for name in names.dropFirst(4) { XCTAssertEqual(control.calls(name), 0, name) }
    }

    func testStructuralExclusionsIncludeDescendants() async throws {
        let root = try directory(names: ["good.zip"])
        try Data("broken".utf8).write(to: root.appendingPathComponent("bad.zip"))
        let inner = TestFixtures.storedZip(entries: [(Array("bad.zip".utf8), Data("broken".utf8)),
                                                    (Array("page.png".utf8), TestFixtures.pngData(width: 40, height: 60))])
        try inner.write(to: root.appendingPathComponent("inner.zip"))
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
                                        retryPolicy: .immediate)
        let pages = try await source.entries()
        XCTAssertEqual(pages.count, 2)
        let excluded = await source.excludedChildCount()
        XCTAssertEqual(excluded, 2)
    }

    func testLockedSkippedChildrenAreCountedForFolderAndArchive() async throws {
        let root = try directory(names: ["good.zip"])
        let page = root.appendingPathComponent("page.png")
        try TestFixtures.pngData(width: 40, height: 60).write(to: page)
        let locked = root.appendingPathComponent("locked.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-j", "-P", "sesame", locked.path, page.path]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        try FileManager.default.removeItem(at: page)
        let folder = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
                                        retryPolicy: .immediate)
        let pages = try await folder.entries()
        XCTAssertEqual(pages.count, 1)
        let folderExclusions = await folder.excludedChildCount()
        XCTAssertEqual(folderExclusions, 1)
        let outer = root.appendingPathComponent("outer.zip")
        try TestFixtures.storedZip(entries: [(Array("locked.zip".utf8), Data(contentsOf: locked))])
            .write(to: outer)
        let archive = try ArchiveSource(url: outer, retryPolicy: .immediate)
        let archivePages = try await archive.entries()
        XCTAssertTrue(archivePages.isEmpty)
        let archiveExclusions = await archive.excludedChildCount()
        XCTAssertEqual(archiveExclusions, 1)
    }

    func testResourceShortageDrainsFourLanesThenRefillsSerially() async throws {
        let names = (0..<8).map { String(format: "%02d.zip", $0) }
        let root = try directory(names: names)
        let lanes = LaneControl(names: names)
        var policy = AssemblyRetryPolicy.immediate
        policy.delays = []
        policy.beforeChildAttempt = { try await lanes.attempt($0) }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            retryPolicy: policy)
        let firstFailure = expectation(description: "最初の資源不足を回収")
        await source.setAssemblyProgressHandler { done, _ in
            if done == 1 { firstFailure.fulfill() }
        }
        let build = Task { try await source.entries() }
        await fulfillment(of: [lanes.initialStarted], timeout: 2)
        await lanes.gates[0].open()
        await fulfillment(of: [firstFailure], timeout: 2)
        for index in 1..<4 { await lanes.gates[index].open() }
        for index in 4..<8 {
            await fulfillment(of: [lanes.started[index]], timeout: 2)
            await lanes.gates[index].open()
        }
        do { _ = try await build.value; XCTFail("失敗した子を残す") }
        catch { XCTAssertTrue(error is AssemblyFailure) }
        XCTAssertEqual(lanes.peakInitial, 4)
        XCTAssertEqual(lanes.peakRefill, 1)
        XCTAssertFalse(lanes.refilledBeforeInitialDrained)
    }

    func testBuildCancellationIsNotAggregated() async throws {
        let root = try directory(names: ["a.zip"])
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let factory = ArchiveEngineFactory(openFile: { _, _, _ in
            calls.withLock { $0 += 1 }
            throw CancellationError()
        }, openData: { _, _, _ in nil })
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: factory, retryPolicy: .immediate)
        do { _ = try await source.entries(); XCTFail("取消しを返す") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    private func assemblyFailure(_ source: any BookSource) async throws -> AssemblyFailure {
        do {
            _ = try await source.entries()
            XCTFail("環境要因の失敗を集約して返す")
            throw KaitoError.malformed("missing failure")
        } catch { return try XCTUnwrap(error as? AssemblyFailure, "\(error)") }
    }

    private func directory(names: [String], pageName: String = "page.png") throws -> URL {
        let root = try TestFixtures.makeTempDir()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for name in names { try zip(pageName: pageName).write(to: root.appendingPathComponent(name)) }
        return root
    }

    private func zip(pageName: String = "page.png") -> Data {
        TestFixtures.storedZip(entries: [(Array(pageName.utf8), TestFixtures.pngData(width: 40, height: 60))])
    }
}

private final class LaneControl: Sendable {
    private struct State {
        var initialActive = 0
        var refillActive = 0
        var peakInitial = 0
        var peakRefill = 0
        var refilledBeforeInitialDrained = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let gates: [AssemblyTestGate]
    let started: [XCTestExpectation]
    let initialStarted = XCTestExpectation(description: "初期の4レーンが開く")

    init(names: [String]) {
        gates = names.map { _ in AssemblyTestGate() }
        started = names.map { XCTestExpectation(description: $0) }
        initialStarted.expectedFulfillmentCount = 4
    }
    var peakInitial: Int { state.withLock { $0.peakInitial } }
    var peakRefill: Int { state.withLock { $0.peakRefill } }
    var refilledBeforeInitialDrained: Bool { state.withLock { $0.refilledBeforeInitialDrained } }
    func attempt(_ path: String) async throws {
        let index = Int((path as NSString).deletingPathExtension)!
        self.state.withLock {
            if index < 4 {
                $0.initialActive += 1
                $0.peakInitial = max($0.peakInitial, $0.initialActive)
            } else {
                $0.refillActive += 1
                $0.peakRefill = max($0.peakRefill, $0.refillActive)
                $0.refilledBeforeInitialDrained = $0.refilledBeforeInitialDrained || $0.initialActive > 0
            }
        }
        defer {
            self.state.withLock {
                if index < 4 { $0.initialActive -= 1 } else { $0.refillActive -= 1 }
            }
        }
        self.started[index].fulfill()
        if index < 4 { self.initialStarted.fulfill() }
        await self.gates[index].wait()
        try Task.checkCancellation()
        if index == 0 { throw KaitoError.io(EMFILE) }
    }

}

private final class OpenControl: Sendable {
    private struct State {
        var failures: [String: (Int32, Int)]
        var calls: [String: Int] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>
    init(failures: [String: (Int32, Int)]) { state = .init(initialState: State(failures: failures)) }
    func recover() { state.withLock { $0.failures.removeAll() } }
    func calls(_ name: String) -> Int { state.withLock { $0.calls[name, default: 0] } }
    var factory: ArchiveEngineFactory {
        ArchiveEngineFactory(openFile: { kind, path, role in
            guard role == .primary else { return try ArchiveEngineFactory.live.openFile(kind, path, role) }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let code: Int32? = self.state.withLock {
                $0.calls[name, default: 0] += 1
                guard let (code, remaining) = $0.failures[name], remaining > 0 else { return nil }
                $0.failures[name] = (code, remaining - 1)
                return code
            }
            if let code { throw KaitoError.io(code) }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
    }
}
