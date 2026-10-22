import Foundation
import CoreGraphics
import os
import XCTest
@testable import cooViewer

/// 合本の読書窓と予算を、型登録やネットワークを使わず合成書庫で検証する(設計書 §5)。
final class CollectionSpoolWindowTests: XCTestCase {
    private struct Collection {
        let source: NestedFolderSource
        let pages: [PageEntry]
        let probes: [SpoolEngineProbe]
        let order: OSAllocatedUnfairLock<[(Int, Int32)]>
        let sequence = OSAllocatedUnfairLock(initialState: UInt64(0))

        func page(_ child: Int) -> PageEntry { pages.first { $0.pathInBook.hasPrefix(String(format: "%03d.7z/", child)) }! }
        func note(_ child: Int, forward: Bool = true) async {
            await source.noteReadingPosition(current: page(child), next: probes.indices.contains(child + 1) ? page(child + 1) : nil,
                previous: child > 0 ? page(child - 1) : nil, forward: forward,
                sequence: sequence.withLock { $0 += 1; return $0 })
        }
    }

    private func collection(_ count: Int = 6, applyProfile: Bool = true, pdfNeighbor: Bool = false, pagesPerChild: Int = 2,
                            declaredSizes: [[Int64?]]? = nil,
                            block: (@Sendable (Int, Int32) -> Void)? = nil,
                            primaryBlock: (@Sendable (Int, Int32) -> Void)? = nil) async throws -> Collection {
        let root = try TestFixtures.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var data = TestFixtures.pngData(width: 4, height: 6)
        data.append(Data(count: (1 << 19) - data.count))
        let order = OSAllocatedUnfairLock(initialState: [(Int, Int32)]())
        let probes = (0..<count).map { child in
            SpoolEngineProbe(data: data, declaredSizes: declaredSizes?[child], beforeSpoolRead: { entry in
                order.withLock { $0.append((child, entry)) }
                block?(child, entry)
            }, beforePrimaryRead: { entry in primaryBlock?(child, entry) })
        }
        for child in 0..<count { try Data([0]).write(to: root.appendingPathComponent(String(format: "%03d.7z", child))) }
        if pdfNeighbor {
            let url = root.appendingPathComponent("002a.pdf")
            var box = CGRect(x: 0, y: 0, width: 40, height: 60)
            let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
        }
        let factory = ArchiveEngineFactory(openFile: { _, path, _ in
            let child = Int((path as NSString).lastPathComponent.prefix(3))!
            return SpoolTestArchiveEngine(groups: Array(repeating: 0, count: pagesPerChild), probe: probes[child])
        }, openData: { _, _, _ in nil })
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false), engineFactory: factory)
        await source.configureSpooling(sizeLimit: 4 << 20)
        if applyProfile { await source.applyMediaProfile(MediaProfile(mediaClass: .network, spoolOverride: true)) }
        let pages = try await source.entries()
        XCTAssertEqual(pages.count, count * pagesPerChild + (pdfNeighbor ? 1 : 0))
        return Collection(source: source, pages: pages, probes: probes, order: order)
    }

    func testUserInitiatedNeighborPrefetchKeepsCurrentWindowAndSpool() async throws {
        let started = expectation(description: "現在巻の途中で停止")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let c = try await collection(3, pagesPerChild: 4) { child, id in
            if child == 0, id == 1 { started.fulfill(); _ = release.wait(timeout: .now() + 10) }
        }
        await c.note(0)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        let current = await c.source.archiveChild(for: c.page(0))!
        let prefetch = Task.detached(priority: .userInitiated) {
            try await c.source.image(for: c.page(1), maxPixelSize: nil)
        }
        let image = try await prefetch.value
        XCTAssertEqual(image.width, 4)
        XCTAssertFalse(current.needsInteractiveSpoolPreparation, "次巻の先読みは現在巻を取り消さない")
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.probes[0].state.withLock { $0.spoolReads }, [0, 1, 2, 3])
        let next = await c.source.archiveChild(for: c.page(1))!
        let stats = await next.spoolStats()
        XCTAssertEqual(stats.spooled, 4)
        // 次巻は先読みで進んだ主エンジンを引き継ぐため、専用エンジンの記録に現れない場合がある。
        XCTAssertEqual(c.order.withLock { Array($0.prefix(4).map(\.0)) }, [0, 0, 0, 0])
        XCTAssertEqual(c.probes[2].state.withLock { $0.spoolReads }, [])
    }

    func testUnstartableCurrentSpoolLeavesNextChildRunning() async throws {
        let started = expectation(description: "次巻の途中で停止")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let c = try await collection(2, pagesPerChild: 4,
            declaredSizes: [Array(repeating: Int64(8 << 20), count: 4), Array(repeating: Int64(1 << 19), count: 4)]) { child, id in
            if child == 1, id == 1 { started.fulfill(); _ = release.wait(timeout: .now() + 10) }
        }
        await c.note(0)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        let display = Task.detached(priority: .userInitiated) {
            try await PageRequestIntent.$isDisplay.withValue(true) {
                try await c.source.image(for: c.page(0), maxPixelSize: nil)
            }
        }
        let image = try await display.value
        XCTAssertEqual(image.width, 4)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        let next = await c.source.archiveChild(for: c.page(1))!
        let stats = await next.spoolStats()
        XCTAssertEqual(stats.spooled, 4, "現在巻が予算不足でも次巻の展開を完走する")
        XCTAssertEqual(c.probes[1].state.withLock { $0.spoolReads }, [0, 1, 2, 3])
        XCTAssertEqual(c.probes[0].state.withLock { $0.spoolReads }, [])
    }

    func testTwoBooksSharingSourceCanReverseReadingWindow() async throws {
        let reversed = expectation(description: "後の本の逆方向通知を採用")
        let c = try await collection { child, id in
            if child == 2, id == 0 { reversed.fulfill() }
        }
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        _ = await c.source.waitForSpoolCompletion()
        let prepared = Book.PreparedEntries(sortedEntries: c.pages, cacheKey: "shared-source")
        let first = await MainActor.run {
            let book = Book(source: c.source, prepared: prepared)
            book.readMode = .rightToLeftSingle
            book.prefetchAhead = 0
            book.prefetchBehind = 0
            return book
        }
        _ = await first.currentSpread()
        _ = await c.source.waitForSpoolCompletion()
        let index = try XCTUnwrap(c.pages.firstIndex { $0.id == c.page(3).id })
        await MainActor.run { first.goTo(index: index) }
        _ = await first.currentSpread()
        _ = await c.source.waitForSpoolCompletion()

        let second = await MainActor.run {
            let book = Book(source: c.source, prepared: prepared)
            book.readMode = .rightToLeftSingle
            book.prefetchAhead = 0
            book.prefetchBehind = 0
            book.goTo(index: index + 1)
            _ = book.moveHalfPrevious()
            return book
        }
        _ = await second.currentSpread()
        await fulfillment(of: [reversed], timeout: 3)
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.probes[2].state.withLock { $0.spoolReads }, [0, 1])
    }

    func testCollectionSpoolsCurrentAndNextChildWithFullBudget() async throws {
        let c = try await collection(200)
        await c.note(10)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        let count = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(count, 4)
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [10, 10, 11, 11])
        XCTAssertEqual(c.probes.reduce(0) { $0 + $1.state.withLock { $0.reopenCalls } }, 2)
    }

    func testLandingMovesWindowAndStartsSpoolBeforeForwardingWithoutWaitingForOtherChild() async throws {
        let oldBusy = expectation(description: "別の子 actor を停止")
        let landing = expectation(description: "着地先のスプールを開始")
        let displayed = expectation(description: "別の子が停止中でも表示")
        let oldRelease = DispatchSemaphore(value: 0)
        let spoolRelease = DispatchSemaphore(value: 0)
        defer { oldRelease.signal(); spoolRelease.signal() }
        let c = try await collection(block: { child, id in
            if child == 2, id == 0 { landing.fulfill(); _ = spoolRelease.wait(timeout: .now() + 10) }
        }, primaryBlock: { child, id in
            if child == 0, id == 0 { oldBusy.fulfill(); _ = oldRelease.wait(timeout: .now() + 10) }
        })
        let old = await c.source.archiveChild(for: c.page(0))!
        let oldPages = try await old.entries()
        let busy = Task.detached(priority: .utility) { await old.imageData(for: oldPages[0]) }
        await fulfillment(of: [oldBusy], timeout: 3)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        let display = Task(priority: .userInitiated) {
            let image = try await PageRequestIntent.$isDisplay.withValue(true) {
                try await c.source.image(for: c.page(2), maxPixelSize: nil)
            }
            displayed.fulfill()
            return image
        }
        await fulfillment(of: [landing], timeout: 3)
        let child = await c.source.archiveChild(for: c.page(2))!
        for _ in 0..<10_000 {
            if await child.spoolWaiterCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(c.probes[2].state.withLock { $0.primaryReads }, [])
        spoolRelease.signal()
        await fulfillment(of: [displayed], timeout: 3)
        let image = try await display.value
        XCTAssertEqual(image.width, 4)
        oldRelease.signal()
        _ = await busy.value
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [2, 2, 3, 3])
    }

    func testCurrentChildPromotesBackgroundSpoolAndKeepsPrefix() async throws {
        let started = expectation(description: "背景の後半を停止")
        let release = DispatchSemaphore(value: 0)
        let once = OSAllocatedUnfairLock(initialState: false)
        defer { release.signal() }
        let c = try await collection { child, id in
            if child == 0, id == 1, once.withLock({ if $0 { return false }; $0 = true; return true }) {
                started.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
        }
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        let child = await c.source.archiveChild(for: c.page(0))!
        let directory = await child.spoolDirectoryForTesting
        await c.note(0)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        let finalDirectory = await child.spoolDirectoryForTesting
        XCTAssertEqual(directory, finalDirectory)
        XCTAssertEqual(c.probes[0].state.withLock { $0.spoolReads.filter { $0 == 0 } }, [0])
        XCTAssertEqual(c.probes[0].state.withLock { $0.spoolPriorities.last }, .userInitiated)
    }

    func testLandingHonorsCollectionZeroBudgetWithoutAutomaticSpool() async throws {
        let c = try await collection()
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 0)
        let image = try await PageRequestIntent.$isDisplay.withValue(true) {
                try await c.source.image(for: c.page(2), maxPixelSize: nil)
            }
        XCTAssertEqual(image.width, 4)
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertTrue(c.order.withLock { $0.isEmpty })
        let child = await c.source.archiveChild(for: c.page(2))!
        let stats = await child.spoolStats()
        let directory = await child.spoolDirectoryForTesting
        XCTAssertEqual(stats.spooled, 0)
        XCTAssertNil(directory)
        XCTAssertEqual(c.probes[2].state.withLock { $0.primaryReads }, [0])
    }

    func testWindowSweepsAreSequentialCurrentFirst() async throws {
        let started = expectation(description: "現在の子を停止")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let c = try await collection { child, entry in
            if child == 2, entry == 0 { started.fulfill(); _ = release.wait(timeout: .now() + 10) }
        }
        await c.note(2)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [2])
        XCTAssertEqual(c.probes[3].state.withLock { $0.reopenCalls }, 0)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [2, 2, 3, 3])
    }

    func testBackwardNoteSpoolsPreviousInsteadOfNext() async throws {
        let c = try await collection()
        await c.note(3, forward: false)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [3, 3, 2, 2])
    }

    func testBackwardWindowStopsOutOfWindowNeighborAfterCurrentFinished() async throws {
        let started = expectation(description: "子2の二枚目で停止")
        let release = DispatchSemaphore(value: 0)
        let once = OSAllocatedUnfairLock(initialState: false)
        defer { release.signal() }
        let c = try await collection(3, pagesPerChild: 4) { child, id in
            if child == 2, id == 1, once.withLock({ if $0 { return false }; $0 = true; return true }) {
                started.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        await c.note(1)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        let current = await c.source.archiveChild(for: c.page(1))!
        let neighbor = await c.source.archiveChild(for: c.page(2))!
        XCTAssertTrue(current.hasFinishedSpool)
        // 完了済みの子1を先頭に保ったまま、窓を [1, 2] から [1, 0] へ動かす。
        await c.note(1, forward: false)
        for _ in 0..<1_000 {
            if !neighbor.hasRunningSpool { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(neighbor.hasRunningSpool, "旧窓の完了を待つ前に子2を取り消す")
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.probes[2].state.withLock { $0.spoolReads }, [0, 1], "窓外の子は現在のエントリ境界で止める")
        XCTAssertEqual(c.probes[0].state.withLock { $0.spoolReads }, [0, 1, 2, 3])
    }

    func testDisplayRacingWindowMoveDoesNotOrphanChildSpool() async throws {
        let gate = SourceReadGate(limit: 2)
        try await ArchiveSource.$testingInteractiveSpoolGate.withValue(gate) {
            for request in 0..<3 {
                let blocked = expectation(description: "子3の主展開で表示準備を待たせる")
                let displayStarted = expectation(description: "子3への表示要求を配送")
                let release = DispatchSemaphore(value: 0)
                let once = OSAllocatedUnfairLock(initialState: false)
                defer { release.signal() }
                let c = try await collection(pagesPerChild: 4, primaryBlock: { child, _ in
                    if child == 3, once.withLock({ if $0 { return false }; $0 = true; return true }) {
                        blocked.fulfill()
                        _ = release.wait(timeout: .now() + 10)
                    }
                })
                await c.source.configureSpooling(sizeLimit: 64 << 20)
                await c.note(0)
                await c.source.beginBackgroundPreparation(spoolSizeLimit: 64 << 20)
                _ = await c.source.waitForSpoolCompletion()
                let child = await c.source.archiveChild(for: c.page(3))!
                // 元データ経路では先読み済みページの短期キャッシュを避ける。
                let displayPage = try XCTUnwrap(c.pages.first {
                    $0.pathInBook.hasPrefix("003.7z/") && (request != 2 || $0.id != c.page(3).id)
                })
                let prefetch = Task.detached(priority: .userInitiated) {
                    _ = try await c.source.image(for: c.page(3), maxPixelSize: nil)
                }
                await fulfillment(of: [blocked], timeout: 3)
                let display = Task.detached(priority: .userInitiated) {
                    displayStarted.fulfill()
                    try await PageRequestIntent.$isDisplay.withValue(true) {
                        switch request {
                        case 0: _ = try await c.source.image(for: displayPage, maxPixelSize: nil)
                        case 1: _ = try await c.source.loupeImage(for: displayPage, pixelScale: 1)
                        default: _ = await c.source.imageData(for: displayPage)
                        }
                    }
                }
                await fulfillment(of: [displayStarted], timeout: 3)
                // 表示準備を子3の actor に配送してから、別の巻への通知で世代を変える。
                try await Task.sleep(for: .milliseconds(300))
                await c.note(5)
                release.signal()
                _ = try await prefetch.value
                _ = try await display.value
                _ = await c.source.waitForSpoolCompletion()
                await child.waitForSpoolCompletion()
                let stats = await child.spoolStats()
                XCTAssertEqual(c.probes[3].state.withLock { $0.reopenCalls }, 0, "要求経路\(request): 窓外で未登録スプールを始めない")
                XCTAssertEqual(stats.bytes, 0)
                XCTAssertFalse(child.hasRunningSpool)
            }
            let counts = await gate.debugCounts()
            XCTAssertEqual(counts.active, 0)
        }
    }

    func testReadingPositionIgnoresStaleAndDuplicateSequences() async throws {
        let c = try await collection()
        await c.source.noteReadingPosition(current: c.page(3), next: c.page(4), previous: c.page(2), forward: false, sequence: 2)
        await c.source.noteReadingPosition(current: c.page(0), next: c.page(1), previous: nil, forward: true, sequence: 1)
        await c.source.noteReadingPosition(current: c.page(4), next: c.page(5), previous: c.page(3), forward: true, sequence: 2)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [3, 3, 2, 2])
        await c.source.noteReadingPosition(current: c.page(4), next: c.page(5), previous: c.page(3), forward: true, sequence: 3)
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [3, 3, 2, 2, 4, 4, 5, 5])
    }

    func testDirectionFlipWithinChildSwapsSecondSweep() async throws {
        let started = expectation(description: "現在の子を停止")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let c = try await collection { child, entry in
            if child == 3, entry == 0 { started.fulfill(); _ = release.wait(timeout: .now() + 10) }
        }
        await c.note(3)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        await c.note(3, forward: false)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [3, 3, 2, 2])
    }

    func testMovingWindowPausesOldCurrentAndEvictsLeastRecentOutsideWindow() async throws {
        let started = expectation(description: "古い現在巻を停止")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let c = try await collection { child, entry in
            if child == 2, entry == 0 { started.fulfill(); _ = release.wait(timeout: .now() + 10) }
        }
        await c.note(0)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 2 << 20)
        _ = await c.source.waitForSpoolCompletion()
        let first = await c.source.archiveChild(for: c.page(0))!
        let firstDirectory = await first.spoolDirectoryForTesting
        let second = await c.source.archiveChild(for: c.page(1))!
        let secondDirectory = await second.spoolDirectoryForTesting
        await c.note(2)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDirectory!.path))
        let oldCurrent = await c.source.archiveChild(for: c.page(2))!
        await c.note(4)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        let oldStats = await oldCurrent.spoolStats()
        XCTAssertTrue(oldStats.paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDirectory!.path))
        var bytes: Int64 = 0
        for child in c.probes.indices {
            let archive = await c.source.archiveChild(for: c.page(child))!
            bytes += await archive.spoolStats().bytes
        }
        XCTAssertLessThanOrEqual(bytes, 2 << 20)
        XCTAssertEqual(c.probes[3].state.withLock { $0.reopenCalls }, 0)
        XCTAssertEqual(c.probes[4].state.withLock { $0.spoolReads }, [0, 1])
        XCTAssertEqual(c.probes[5].state.withLock { $0.spoolReads }, [0, 1])
    }

    func testWindowSkipsNonArchiveNeighbor() async throws {
        let c = try await collection(pdfNeighbor: true)
        let neighbor = try XCTUnwrap(c.pages.first { $0.pathInBook.hasPrefix("002a.pdf/") })
        await c.source.noteReadingPosition(current: c.page(2), next: neighbor, previous: c.page(1), forward: true, sequence: 1)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [2, 2])
    }

    func testBeginBeforePositionStartsFirstArchiveChildOnBackgroundLane() async throws {
        let started = expectation(description: "背景スプール")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let c = try await collection { child, entry in
            if child == 0, entry == 0 { started.fulfill(); _ = release.wait(timeout: .now() + 10) }
        }
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        let background = await ArchiveSource.backgroundSpoolGate.debugCounts()
        let interactive = await ArchiveSource.interactiveSpoolGate.debugCounts()
        XCTAssertEqual(background.active, 1)
        XCTAssertEqual(interactive.active, 0)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [0, 0])
    }

    func testNotePositionBeforeBeginDefersUntilBegin() async throws {
        let c = try await collection()
        await c.note(2)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(c.order.withLock { $0.isEmpty })
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.order.withLock { $0.map(\.0) }, [2, 2, 3, 3])
    }
    func testUserInitiatedRequestForFarChildKeepsCurrentSpool() async throws {
        let started = expectation(description: "読書中の巻を停止")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let c = try await collection(pagesPerChild: 4) { child, id in
            if child == 0, id == 1 { started.fulfill(); _ = release.wait(timeout: .now() + 10) }
        }
        await c.note(0)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        let current = await c.source.archiveChild(for: c.page(0))!
        let thumbnail = Task.detached(priority: .userInitiated) {
            try await c.source.image(for: c.page(4), maxPixelSize: 100)
        }
        _ = try await thumbnail.value
        XCTAssertFalse(current.needsInteractiveSpoolPreparation)
        let prefetch = Task.detached(priority: .userInitiated) {
            try await c.source.image(for: c.page(4), maxPixelSize: nil)
        }
        _ = try await prefetch.value
        XCTAssertFalse(current.needsInteractiveSpoolPreparation)
        XCTAssertEqual(c.probes[4].state.withLock { $0.reopenCalls }, 0)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.probes[0].state.withLock { $0.spoolReads }, [0, 1, 2, 3])
        XCTAssertEqual(c.probes[4].state.withLock { $0.spoolReads }, [])
    }

    func testDisplayStartedChildIsRegisteredAndEvictable() async throws {
        let c = try await collection()
        await c.source.configureSpooling(sizeLimit: 1 << 20)
        _ = try await PageRequestIntent.$isDisplay.withValue(true) {
            try await c.source.image(for: c.page(0), maxPixelSize: nil)
        }
        _ = await c.source.waitForSpoolCompletion()
        let first = await c.source.archiveChild(for: c.page(0))!
        let savedDirectory = await first.spoolDirectoryForTesting
        let directory = try XCTUnwrap(savedDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        await c.note(4)
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let stats = await first.spoolStats()
        XCTAssertEqual(stats.bytes, 0)
    }

    func testFailedFarLandingLeavesNextChildSpoolRunning() async throws {
        let started = expectation(description: "次巻を展開中")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let small = Array(repeating: Int64?(1 << 19), count: 4)
        var sizes = Array(repeating: small, count: 6)
        sizes[4] = Array(repeating: Int64?(2 << 20), count: 4)
        let c = try await collection(pagesPerChild: 4, declaredSizes: sizes) { child, id in
            if child == 1, id == 1 { started.fulfill(); _ = release.wait(timeout: .now() + 10) }
        }
        await c.note(0)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        let next = await c.source.archiveChild(for: c.page(1))!
        await c.note(4)
        _ = try await PageRequestIntent.$isDisplay.withValue(true) {
            try await c.source.image(for: c.page(4), maxPixelSize: nil)
        }
        let nextStats = await next.spoolStats()
        XCTAssertTrue(nextStats.active)
        XCTAssertTrue(next.hasRunningSpool, "総予算内でも残予算で開始できなければ次巻を取り消さない")
        XCTAssertEqual(c.probes[4].state.withLock { $0.reopenCalls }, 0)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.probes[1].state.withLock { $0.spoolReads }, [0, 1, 2, 3])
        XCTAssertEqual(c.probes[1].state.withLock { $0.reopenCalls }, 1)
    }

    func testLandingSpoolDoesNotRestartWhenWindowBudgetDiffers() async throws {
        let started = expectation(description: "着地先の二枚目で停止")
        let release = DispatchSemaphore(value: 0)
        let once = OSAllocatedUnfairLock(initialState: false)
        defer { release.signal() }
        let c = try await collection(pagesPerChild: 4) { child, id in
            if child == 2, id == 1, once.withLock({ if $0 { return false }; $0 = true; return true }) {
                started.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
        }
        let display = Task(priority: .userInitiated) {
            try await PageRequestIntent.$isDisplay.withValue(true) {
                try await c.source.image(for: c.page(2), maxPixelSize: nil)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        _ = try await display.value
        await c.source.beginBackgroundPreparation(spoolSizeLimit: (4 << 20) - 1)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        XCTAssertEqual(c.probes[2].state.withLock { $0.reopenCalls }, 1)
        XCTAssertEqual(c.probes[2].state.withLock { $0.spoolReads }, [0, 1, 2, 3])
        XCTAssertEqual(c.probes[2].state.withLock { $0.primaryReads }, [])
    }

    func testLoweredSettingsLimitDuringWindowKeepsCollectionTotal() async throws {
        let started = expectation(description: "次巻の二枚目を展開中")
        let release = DispatchSemaphore(value: 0)
        let once = OSAllocatedUnfairLock(initialState: false)
        defer { release.signal() }
        let c = try await collection(3, pagesPerChild: 4) { child, id in
            if child == 1, id == 1, once.withLock({ if $0 { return false }; $0 = true; return true }) {
                started.fulfill(); _ = release.wait(timeout: .now() + 10)
            }
        }
        await c.note(0)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 4 << 20)
        await fulfillment(of: [started], timeout: 3)
        // ReaderWindowController.applySpoolSettings と同じ順序で上限を下げる
        await c.source.configureSpooling(sizeLimit: 3 << 20)
        await c.source.beginBackgroundPreparation(spoolSizeLimit: 3 << 20)
        release.signal()
        _ = await c.source.waitForSpoolCompletion()
        var total: Int64 = 0
        for index in 0..<3 {
            let child = await c.source.archiveChild(for: c.page(index))!
            await child.waitForSpoolCompletion()
            total += await child.spoolStats().bytes
        }
        XCTAssertLessThanOrEqual(total, 3 << 20, "合本の総量は下げた上限に収まる")
        XCTAssertEqual(c.probes[0].state.withLock { $0.spoolReads }, [0, 1, 2, 3])
        XCTAssertEqual(c.probes[1].state.withLock { $0.spoolReads }, [0, 1], "展開中の一枚を終えて境界で止める")
        XCTAssertEqual(c.probes[2].state.withLock { $0.spoolReads }, [])
    }

    func testUnresolvedCollectionProfileDoesNotDemandStartChildren() async throws {
        let c = try await collection(applyProfile: false)
        _ = try await PageRequestIntent.$isDisplay.withValue(true) {
            try await c.source.image(for: c.page(4), maxPixelSize: nil)
        }
        for index in c.probes.indices {
            XCTAssertEqual(c.probes[index].state.withLock { $0.reopenCalls }, 0)
        }
    }

    func testNeverPolicyFirstCollectionDisplayCreatesNoSpoolDirectories() async throws {
        let c = try await collection()
        await c.source.applyMediaProfile(MediaProfile(mediaClass: .network, spoolOverride: false))
        _ = try await PageRequestIntent.$isDisplay.withValue(true) {
            try await c.source.image(for: c.page(4), maxPixelSize: nil)
        }
        for index in c.probes.indices {
            let child = await c.source.archiveChild(for: c.page(index))!
            let directory = await child.spoolDirectoryForTesting
            XCTAssertNil(directory)
            XCTAssertEqual(c.probes[index].state.withLock { $0.reopenCalls }, 0)
        }
    }


}
