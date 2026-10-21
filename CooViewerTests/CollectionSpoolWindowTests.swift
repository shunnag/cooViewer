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

    private func collection(_ count: Int = 6, pdfNeighbor: Bool = false, block: (@Sendable (Int, Int32) -> Void)? = nil) async throws -> Collection {
        let root = try TestFixtures.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var data = TestFixtures.pngData(width: 4, height: 6)
        data.append(Data(count: (1 << 19) - data.count))
        let order = OSAllocatedUnfairLock(initialState: [(Int, Int32)]())
        let probes = (0..<count).map { child in
            SpoolEngineProbe(data: data, beforeSpoolRead: { entry in
                order.withLock { $0.append((child, entry)) }
                block?(child, entry)
            })
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
            return SpoolTestArchiveEngine(groups: [0, 0], probe: probes[child])
        }, openData: { _, _, _ in nil })
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false), engineFactory: factory)
        await source.applyMediaProfile(MediaProfile(mediaClass: .network, spoolOverride: true))
        let pages = try await source.entries()
        XCTAssertEqual(pages.count, count * 2 + (pdfNeighbor ? 1 : 0))
        return Collection(source: source, pages: pages, probes: probes, order: order)
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
}
