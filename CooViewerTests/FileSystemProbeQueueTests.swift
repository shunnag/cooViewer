import Foundation
import os
import XCTest

@testable import cooViewer

/// 死んだマウントの偽物。塞がる本体は FileManagerProbe と同じく専用キューを通し、
/// release が signal されるまで戻らない。本体へ入るたびに onEnter を呼び、
/// 同時に本体へ入っている数の最大値を記録する
private final class HungMountProbe: FileSystemProbing, Sendable {
    let queue: BlockingProbeQueue
    let release = DispatchSemaphore(value: 0)
    private let onEnter: @Sendable () -> Void
    private let inside = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))

    init(width: Int, onEnter: @escaping @Sendable () -> Void) {
        queue = BlockingProbeQueue(label: "test.cooViewer.hung-mount", width: width)
        self.onEnter = onEnter
    }

    var peakConcurrency: Int { inside.withLock { $0.peak } }

    private func hang() {
        inside.withLock { state in
            state.current += 1
            state.peak = max(state.peak, state.current)
        }
        onEnter()
        release.wait()
        inside.withLock { $0.current -= 1 }
    }

    func directoryItems(at directory: URL) async throws -> [DirectoryItem] {
        try await queue.run {
            self.hang()
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    func fileExists(atPath path: String) async -> Bool {
        await queue.run {
            self.hang()
            return path.hasSuffix(".zip")
        }
    }

    func itemKind(at url: URL) async -> (exists: Bool, isDirectory: Bool) {
        await queue.run {
            self.hang()
            return (true, url.pathExtension.isEmpty)
        }
    }

    func identity(at url: URL) async -> BookFileIdentity {
        await queue.run {
            self.hang()
            return BookFileIdentity(modified: 7, size: Int(url.lastPathComponent) ?? 0)
        }
    }
}

final class FileSystemProbeQueueTests: XCTestCase {
    /// 塞がる本体へ expected 件が入ったら満たされる(解放後に残りが入っても失敗にしない)
    private func makeProbe(width: Int, expectedEntries: Int) -> (HungMountProbe, XCTestExpectation) {
        let entered = XCTestExpectation(description: "\(expectedEntries) 件が塞がる本体へ入った")
        entered.expectedFulfillmentCount = expectedEntries
        entered.assertForOverFulfill = false
        return (HungMountProbe(width: width) { entered.fulfill() }, entered)
    }

    /// 協調プールの幅(= 論理コア数)を超える本数がぶら下がっても、無関係なタスクは走り、
    /// 塞がる本体へ同時に入るのはキューの幅までで、解放後は全結果が届く(設計書 §7.3)
    func testHungCallsDoNotStarveCooperativePoolAndDeliverResultsWhenReleased() async throws {
        let width = 4
        let hungCalls = max(8, ProcessInfo.processInfo.activeProcessorCount * 2)
        let (probe, entered) = makeProbe(width: width, expectedEntries: width)
        let paths = (0..<hungCalls).map { "/dead/mount/\($0)" + ($0.isMultiple(of: 2) ? ".zip" : ".txt") }
        let calls = paths.map { path in Task { await probe.fileExists(atPath: path) } }
        await fulfillment(of: [entered], timeout: 5)

        // 幅ぶんが本体で塞がり、残りはキューで(スレッドを持たずに)待っている間に
        // 無関係なタスクが完走する
        let unrelated = expectation(description: "無関係なタスクが完走した")
        let detached = Task.detached(priority: .userInitiated) { () -> Int in
            let values = await withTaskGroup(of: Int.self) { group in
                for value in 0..<4 { group.addTask { value } }
                return await group.reduce(0, +)
            }
            unrelated.fulfill()
            return values
        }
        await fulfillment(of: [unrelated], timeout: 5)
        let sum = await detached.value
        XCTAssertEqual(sum, 6)
        XCTAssertEqual(probe.peakConcurrency, width, "本体へ同時に入るのは幅まで")

        for _ in 0..<hungCalls { probe.release.signal() }
        var results: [Bool] = []
        for call in calls { results.append(await call.value) }
        XCTAssertEqual(results, paths.map { $0.hasSuffix(".zip") }, "解放後に各呼び出しの結果が届く")
        XCTAssertLessThanOrEqual(probe.peakConcurrency, width)
    }

    func testThrowingAndValueResultsCrossTheQueue() async throws {
        let (probe, entered) = makeProbe(width: 3, expectedEntries: 3)
        let listing = Task { try await probe.directoryItems(at: URL(fileURLWithPath: "/dead/mount")) }
        let identity = Task { await probe.identity(at: URL(fileURLWithPath: "/dead/mount/42")) }
        let kind = Task { await probe.itemKind(at: URL(fileURLWithPath: "/dead/mount/folder")) }
        await fulfillment(of: [entered], timeout: 5)
        for _ in 0..<3 { probe.release.signal() }
        do {
            _ = try await listing.value
            XCTFail("列挙の失敗は throw として届く")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadNoSuchFile)
        }
        let delivered = await identity.value
        XCTAssertEqual(delivered, BookFileIdentity(modified: 7, size: 42))
        let deliveredKind = await kind.value
        XCTAssertTrue(deliveredKind.exists)
        XCTAssertTrue(deliveredKind.isDirectory)
    }

    /// 既定実装は実フォルダで同じ結果を返す(キューを通しても結果も失敗も変わらない)
    func testFileManagerProbeMatchesDirectFileManagerResults() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("book.zip")
        try Data("hello".utf8).write(to: file)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let probe = FileManagerProbe()

        let items = try await probe.directoryItems(at: root)
        XCTAssertEqual(Set(items), [DirectoryItem(name: "book.zip", isDirectory: false),
                                    DirectoryItem(name: "folder", isDirectory: true)])
        XCTAssertEqual(Set(items), Set(try FileManagerProbe.blockingDirectoryItems(at: root)))
        let exists = await probe.fileExists(atPath: file.path)
        XCTAssertTrue(exists)
        let missing = await probe.fileExists(atPath: root.appendingPathComponent("none").path)
        XCTAssertFalse(missing)
        let fileKind = await probe.itemKind(at: file)
        XCTAssertEqual(fileKind.exists, true)
        XCTAssertEqual(fileKind.isDirectory, false)
        let folderKind = await probe.itemKind(at: folder)
        XCTAssertEqual(folderKind.exists, true)
        XCTAssertEqual(folderKind.isDirectory, true)
        let noneKind = await probe.itemKind(at: root.appendingPathComponent("none"))
        XCTAssertEqual(noneKind.exists, false)
        let identity = await probe.identity(at: file)
        XCTAssertEqual(identity, FileManagerProbe.blockingIdentity(at: file))
        XCTAssertEqual(identity.size, 5)
        XCTAssertNotEqual(identity.modified, 0)
        let absent = await probe.identity(at: root.appendingPathComponent("none"))
        XCTAssertEqual(absent, BookFileIdentity())

        // 通常ファイルをディレクトリとして列挙する失敗は FileManager のエラーのまま届く
        do {
            _ = try await probe.directoryItems(at: file)
            XCTFail("ファイルの列挙失敗は呼び出し元へ返す")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
    }
}
