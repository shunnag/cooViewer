import Darwin
import KaitoKit
import os
import XCTest
@testable import cooViewer

final class AssemblyAbortTests: XCTestCase {
    func testFolderCutoffDoesNotJoinHungChildAndDropsLateResult() async throws {
        let root = try directory()
        for name in ["bad.zip", "hung.zip"] { try emptyZip().write(to: root.appendingPathComponent(name)) }
        let gate = AssemblyTestGate()
        let hung = expectation(description: "子を非同期停止")
        let late = expectation(description: "旧世代の子が戻る")
        let timer = expectation(description: "非ゼロの cutoff を開始")
        let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
        let state = OSAllocatedUnfairLock(initialState: (fail: true, paused: false, calls: [String: Int]()))
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        policy.beforeChildAttempt = { path in
            let stop = state.withLock {
                if path == "hung.zip", !$0.paused { $0.paused = true; return true }
                return false
            }
            if stop {
                hung.fulfill()
                await gate.wait()
                late.fulfill()
                try Task.checkCancellation()
            }
        }
        let factory = ArchiveEngineFactory(openFile: { kind, path, role in
            let name = URL(fileURLWithPath: path).lastPathComponent
            let fail = state.withLock { $0.calls[name, default: 0] += 1; return $0.fail && name == "bad.zip" }
            if fail { throw KaitoError.io(EACCES) }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
                                        engineFactory: factory, retryPolicy: policy)
        let finished = expectation(description: "停止した子を待たずに失敗する")
        let returned = OSAllocatedUnfairLock(initialState: false)
        let build = Task {
            let failure = await Self.failure(source)
            returned.withLock { $0 = true }
            finished.fulfill()
            return failure
        }
        await fulfillment(of: [hung, timer], timeout: 2)
        clock.advance(.seconds(5))
        await fulfillment(of: [finished], timeout: 1)
        if !returned.withLock({ $0 }) { await gate.open() }
        let failure = await build.value
        XCTAssertEqual(failure?.failures.map(\.relativePath), ["bad.zip"])
        XCTAssertEqual(failure?.unchecked, 1)
        XCTAssertEqual(state.withLock { $0.calls["hung.zip", default: 0] }, 0)
        state.withLock { $0.fail = false }
        let recovered = try await source.entries()
        await gate.open()
        await fulfillment(of: [late], timeout: 1)
        let cached = try await source.entries()
        XCTAssertEqual(cached, recovered)
        XCTAssertEqual(state.withLock { $0.calls["bad.zip", default: 0] }, 2)
        XCTAssertEqual(state.withLock { $0.calls["hung.zip", default: 0] }, 1)
        let exclusions = await source.excludedChildCount()
        XCTAssertEqual(exclusions, 0)
    }

    func testArchiveCutoffDoesNotJoinHungChild() async throws {
        let root = try directory()
        let outer = root.appendingPathComponent("outer.zip")
        try nestedZip().write(to: outer)
        let hung = expectation(description: "書庫内の子を停止")
        let timer = expectation(description: "書庫の cutoff を開始")
        let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
        let gate = AssemblyTestGate()
        let state = OSAllocatedUnfairLock(initialState: (fail: true, paused: false, paths: [URL]()))
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        policy.beforeChildAttempt = { path in
            let stop = state.withLock {
                if path == "hung.zip", !$0.paused { $0.paused = true; return true }
                return false
            }
            if stop { hung.fulfill(); await gate.wait(); try Task.checkCancellation() }
        }
        let factory = ArchiveEngineFactory(openFile: { kind, path, role in
            let fail = state.withLock {
                if path.hasSuffix("-bad.zip") { $0.paths.append(URL(fileURLWithPath: path)); return $0.fail }
                return false
            }
            if fail { throw KaitoError.io(EACCES) }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
        let source = try ArchiveSource(url: outer, engineFactory: factory, retryPolicy: policy)
        let finished = expectation(description: "書庫も子を join しない")
        let returned = OSAllocatedUnfairLock(initialState: false)
        let build = Task {
            let result = await Self.failure(source)
            returned.withLock { $0 = true }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [timer, hung], timeout: 2)
        clock.advance(.seconds(5))
        await fulfillment(of: [finished], timeout: 1)
        if !returned.withLock({ $0 }) { await gate.open() }
        let result = await build.value
        XCTAssertEqual(result?.failures.map(\.relativePath), ["bad.zip"])
        XCTAssertEqual(result?.unchecked, 2)
        state.withLock { $0.fail = false }
        let recovered = try await source.entries()
        let roots = state.withLock { $0.paths.map { $0.deletingLastPathComponent() } }
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(Set(roots).count, 2, "打ち切った構築と一時ファイルを共有しない")
        XCTAssertFalse(FileManager.default.fileExists(atPath: roots[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: roots[1].path))
        XCTAssertEqual(roots.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
        await gate.open()
        let cached = try await source.entries()
        XCTAssertEqual(cached, recovered)
    }

    func testFailedArchiveBuildReclaimsDiskNestedRootOnRetryAndRelease() async throws {
        let root = try directory()
        let outer = root.appendingPathComponent("outer.zip")
        try TestFixtures.storedZip(entries: [(Array("inner.zip".utf8), emptyZip())]).write(to: outer)
        let clock = AssemblyTestClock { _ in }
        let paths = OSAllocatedUnfairLock(initialState: [URL]())
        var policy = AssemblyRetryPolicy.immediate
        policy.maxTotalSleep = .zero
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let factory = ArchiveEngineFactory(openFile: { kind, path, role in
            if path.hasSuffix("-inner.zip") {
                let first = paths.withLock { $0.append(URL(fileURLWithPath: path)); return $0.count == 1 }
                if first { throw KaitoError.io(EMFILE) }
            }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
        var archive: ArchiveSource? = try ArchiveSource(url: outer, engineFactory: factory, retryPolicy: policy)
        let failure = await Self.failure(try XCTUnwrap(archive))
        XCTAssertEqual(failure?.failures.first?.retryClass, .transient)
        XCTAssertEqual(failure?.unchecked, 0)
        let pages = try await XCTUnwrap(archive).entries()
        XCTAssertTrue(pages.isEmpty)
        let roots = paths.withLock { $0.map { $0.deletingLastPathComponent().standardizedFileURL } }
        XCTAssertEqual(roots.count, 2, "予算ゼロの初回失敗と再構築だけが子を開く")
        XCTAssertEqual(Set(roots).count, 2)
        for directory in roots {
            XCTAssertTrue(directory.lastPathComponent.hasPrefix("\(ProcessInfo.processInfo.processIdentifier)-"))
            XCTAssertTrue(directory.lastPathComponent.hasSuffix("-nested"))
        }
        let owned = Set(roots)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: ArchiveSource.spoolRoot(), includingPropertiesForKeys: nil)
            .map(\.standardizedFileURL).filter { owned.contains($0) }
        XCTAssertEqual(remaining, [roots[1]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.withLock { $0[1].path }))

        let removed = expectation(description: "解放後に展開領域も削除される")
        let descriptor = open(roots[1].path, O_EVTONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .delete, queue: .global(qos: .utility))
        watcher.setEventHandler { @Sendable in removed.fulfill() }
        watcher.setCancelHandler { @Sendable in close(descriptor) }
        watcher.activate()
        defer { watcher.cancel() }
        weak var released = archive
        archive = nil
        await fulfillment(of: [removed], timeout: 1)
        XCTAssertNil(released)
        XCTAssertFalse(FileManager.default.fileExists(atPath: roots[1].path))
    }

    func testAbortDoesNotJoinOrCancelSharedInnerArchiveBuild() async throws {
        let root = try directory()
        try TestFixtures.storedZip(entries: [(Array("deep.zip".utf8), emptyZip())])
            .write(to: root.appendingPathComponent("inner.zip"))
        try emptyZip().write(to: root.appendingPathComponent("bad.zip"))
        let gate = AssemblyTestGate()
        let inside = expectation(description: "内側の共有 build を停止")
        let resumed = expectation(description: "外側を止めても内側は完了できる")
        let timer = expectation(description: "外側の期限")
        let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        policy.beforeChildAttempt = { path in
            if path == "bad.zip" { throw KaitoError.io(EACCES) }
            if path == "deep.zip" {
                inside.fulfill()
                await gate.wait()
                XCTAssertFalse(Task.isCancelled, "共有の内側 build を外側から取り消さない")
                resumed.fulfill()
            }
        }
        let shared = try ArchiveSource(url: root.appendingPathComponent("inner.zip"), retryPolicy: policy)
        let otherReader = Task { try await shared.entries() }
        await fulfillment(of: [inside], timeout: 2)
        let configured = policy
        let done = expectation(description: "内側の entries を待たずに返る")
        let returned = OSAllocatedUnfairLock(initialState: false)
        let build = Task {
            defer { returned.withLock { $0 = true }; done.fulfill() }
            do {
                _ = try await AssemblyPreparation.run(candidates: [
                    .init(ordinal: 0, relativePath: "bad.zip", url: root.appendingPathComponent("bad.zip")),
                    .init(ordinal: 1, relativePath: "inner.zip", url: shared.url)
                ], total: 2, sourceURL: root, lanes: 2, policy: configured) { candidate in
                    if candidate.ordinal == 0 { throw KaitoError.io(EACCES) }
                    // 別の読者も待つ既存ソースには、専有する子の破棄経路を使わない(設計書 §2.4、§7.4)。
                    _ = try await shared.entries()
                    return .skipped
                }
                XCTFail("外側を期限で打ち切る")
                return nil as AssemblyFailure?
            } catch { return error as? AssemblyFailure }
        }
        await fulfillment(of: [timer], timeout: 2)
        clock.advance(.seconds(5))
        await fulfillment(of: [done], timeout: 1)
        if !returned.withLock({ $0 }) { await gate.open() }
        let result = await build.value
        XCTAssertEqual(result?.unchecked, 1)
        await gate.open()
        await fulfillment(of: [resumed], timeout: 1)
        let pages = try await otherReader.value
        XCTAssertTrue(pages.isEmpty)
    }

    func testFolderAbortStopsOwnedDepthTwoArchiveBeforeItsPasswordPrompt() async throws {
        let root = try directory()
        let plain = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: plain)
        let locked = root.appendingPathComponent("B.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-j", "-P", "pw", locked.path, plain.path]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        try TestFixtures.storedZip(entries: [(Array("B.zip".utf8), Data(contentsOf: locked))])
            .write(to: root.appendingPathComponent("A.zip"))
        try FileManager.default.removeItem(at: locked)
        try emptyZip().write(to: root.appendingPathComponent("bad.zip"))
        let inside = expectation(description: "二段目の暗号化子を準備前に停止")
        let cancelled = expectation(description: "二段目まで取消しを伝播")
        let resumed = expectation(description: "旧世代の子が戻る")
        let timer = expectation(description: "外側の期限")
        let gate = AssemblyTestGate()
        let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        policy.beforeChildAttempt = { path in
            if path == "bad.zip" { throw KaitoError.io(EACCES) }
            if path == "B.zip" {
                await withTaskCancellationHandler {
                    inside.fulfill()
                    await gate.wait()
                    XCTAssertTrue(Task.isCancelled)
                    resumed.fulfill()
                } onCancel: { cancelled.fulfill() }
            }
        }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false), retryPolicy: policy)
        await source.attachNestedPasswordProvider { _, _ in
            prompts.withLock { $0 += 1 }
            return NestedPasswordAnswer(password: "pw", saveRequested: false)
        }
        let done = expectation(description: "外側が失敗応答する")
        let returned = OSAllocatedUnfairLock(initialState: false)
        let build = Task {
            let result = await Self.failure(source)
            returned.withLock { $0 = true }
            done.fulfill()
            return result
        }
        await fulfillment(of: [inside, timer], timeout: 2)
        clock.advance(.seconds(5))
        await fulfillment(of: [done, cancelled], timeout: 1)
        if !returned.withLock({ $0 }) { await gate.open() }
        let failure = await build.value
        XCTAssertEqual(failure?.failures.map(\.relativePath), ["bad.zip"])
        XCTAssertEqual(failure?.unchecked, 1)
        await gate.open()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(prompts.withLock { $0 }, 0)
    }

    func testArchiveCutoffStartsAtFirstAttemptBeforeRetryBudgetFinishes() async throws {
        let root = try directory()
        let outer = root.appendingPathComponent("outer.zip")
        try nestedZip().write(to: outer)
        let retry = expectation(description: "最初の失敗の再試行待ち")
        let cutoff = expectation(description: "最初の失敗から期限を開始")
        let clock = AssemblyTestClock {
            if $0 == .seconds(20) { retry.fulfill() }
            if $0 == .seconds(5) { cutoff.fulfill() }
        }
        var policy = AssemblyRetryPolicy.immediate
        policy.delays = [.seconds(20)]
        policy.maxTotalSleep = .seconds(30)
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let opened = OSAllocatedUnfairLock(initialState: [String]())
        policy.beforeChildAttempt = { path in
            opened.withLock { $0.append(path) }
            throw KaitoError.io(EMFILE)
        }
        let source = try ArchiveSource(url: outer, retryPolicy: policy)
        let finished = expectation(description: "全再試行を待たずに返る")
        let build = Task { let result = await Self.failure(source); finished.fulfill(); return result }
        await fulfillment(of: [retry, cutoff], timeout: 2)
        clock.advance(.seconds(5))
        await fulfillment(of: [finished], timeout: 1)
        let result = await build.value
        XCTAssertEqual(result?.unchecked, 2)
        XCTAssertEqual(result?.failures.first?.retryClass, .transient)
        XCTAssertEqual(opened.withLock { $0 }, ["bad.zip"])
    }

    func testArchiveUnreachableProbeChecksFileAndNeverStartsRemainingChildren() async throws {
        let root = try directory()
        let outer = root.appendingPathComponent("outer.zip")
        try nestedZip().write(to: outer)
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let probes = OSAllocatedUnfairLock(initialState: [URL]())
        let factory = ArchiveEngineFactory(openFile: { kind, path, role in
            calls.withLock { $0.append(URL(fileURLWithPath: path).lastPathComponent) }
            if path.hasSuffix("-bad.zip") { throw KaitoError.io(EIO) }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
        var policy = AssemblyRetryPolicy.immediate
        policy.delays = []
        policy.networkExtraDelay = nil
        policy.reachabilityProbe = { url in probes.withLock { $0.append(url) }; return false }
        let source = try ArchiveSource(url: outer, engineFactory: factory, retryPolicy: policy)
        let result = await Self.failure(source)
        XCTAssertEqual(result?.volumeUnavailable, true)
        XCTAssertEqual(result?.unchecked, 2)
        XCTAssertEqual(probes.withLock { $0 }, [outer])
        XCTAssertEqual(calls.withLock { $0 }, ["outer.zip", "0-bad.zip"])
    }

    func testSynchronousArchiveReadDelaysAbortResponseUntilReadReturns() async throws {
        let root = try directory()
        let outer = root.appendingPathComponent("outer.zip")
        try nestedZip().write(to: outer)
        let reading = expectation(description: "同期の展開内で停止")
        let timer = expectation(description: "期限を設定")
        let expired = expectation(description: "仮想時計の期限が経過")
        let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
        let readGate = AssemblySynchronousReadGate()
        let returned = OSAllocatedUnfairLock(initialState: false)
        let opened = OSAllocatedUnfairLock(initialState: [String]())
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { duration in
            try await clock.sleep(duration)
            if duration == .seconds(5) { expired.fulfill() }
        }
        policy.beforeChildAttempt = { path in
            opened.withLock { $0.append(path) }
            if path == "bad.zip" { throw KaitoError.io(EACCES) }
        }
        let factory = ArchiveEngineFactory(openFile: { kind, path, role in
            guard let engine = try ArchiveEngineFactory.live.openFile(kind, path, role) else { return nil }
            if path == outer.path {
                return AssemblyReadHookEngine(engine: engine) { index in
                    if index == 1 { reading.fulfill(); readGate.wait() }
                }
            }
            return engine
        }, openData: { _, _, _ in nil })
        let source = try ArchiveSource(url: outer, engineFactory: factory, retryPolicy: policy)
        let finished = expectation(description: "read が戻ると失敗応答する")
        let build = Task {
            let result = await Self.failure(source)
            returned.withLock { $0 = true }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [reading, timer], timeout: 2)
        clock.advance(.seconds(5))
        await fulfillment(of: [expired], timeout: 1)
        XCTAssertFalse(returned.withLock { $0 }, "同期 read 中は親 actor が失敗応答を返せない")
        readGate.open()
        await fulfillment(of: [finished], timeout: 1)
        let failure = await build.value
        XCTAssertEqual(failure?.failures.map(\.relativePath), ["bad.zip"])
        XCTAssertEqual(failure?.unchecked, 2)
        XCTAssertEqual(failure?.total, 3)
        XCTAssertEqual(opened.withLock { $0 }, ["bad.zip", "hung.zip"])
    }

    private static func failure(_ source: any BookSource) async -> AssemblyFailure? {
        do { _ = try await source.entries(); XCTFail("集約失敗を返す"); return nil }
        catch { XCTAssertTrue(error is AssemblyFailure, "\(error)"); return error as? AssemblyFailure }
    }
    private func directory() throws -> URL {
        let root = try TestFixtures.makeTempDir()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func emptyZip() -> Data { TestFixtures.storedZip(entries: []) }
    private func nestedZip() -> Data {
        TestFixtures.storedZip(entries: ["bad.zip", "hung.zip", "never.zip"].map { (Array($0.utf8), emptyZip()) })
    }
}

/// 同期エンジンの停止だけは同期ゲートで再現し、非同期準備の停止と区別する(設計書 §2.4、§7.4)。
private final class AssemblySynchronousReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        while !isOpen { condition.wait() }
    }
    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class AssemblyReadHookEngine: ArchiveEngine {
    private let engine: any ArchiveEngine
    private let read: (Int32) -> Void
    init(engine: any ArchiveEngine, read: @escaping (Int32) -> Void) {
        self.engine = engine
        self.read = read
    }
    init?(file path: String, role: ArchiveReaderRole) { return nil }
    init?(data: Data, role: ArchiveReaderRole) { return nil }
    func numberOfEntries() -> Int32 { engine.numberOfEntries() }
    func name(ofEntry index: Int32) -> String? { engine.name(ofEntry: index) }
    func contents(ofEntry index: Int32) -> Data? { try? readContents(ofEntry: index) }
    func readContents(ofEntry index: Int32) throws -> Data {
        read(index)
        return try engine.readContents(ofEntry: index)
    }
    func uncompressedSize(ofEntry index: Int32) -> Int64 { engine.uncompressedSize(ofEntry: index) }
    func entryHasSize(_ index: Int32) -> Bool { engine.entryHasSize(index) }
    func entryIsDirectory(_ index: Int32) -> Bool { engine.entryIsDirectory(index) }
    func entryIsEncrypted(_ index: Int32) -> Bool { engine.entryIsEncrypted(index) }
    func isEncrypted() -> Bool { engine.isEncrypted() }
    func setPassword(_ password: String) { engine.setPassword(password) }
    func solidGroup(ofEntry index: Int32) -> Int32 { engine.solidGroup(ofEntry: index) }
    func discardDecodedState() { engine.discardDecodedState() }
    static var defaultZipLazyLocalHeaders: Bool { KaitoKitEngine.defaultZipLazyLocalHeaders }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) { KaitoKitEngine.setDefaultZipLazyLocalHeaders(enabled) }
}

actor AssemblyTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

final class AssemblyTestClock: Sendable {
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var now = ContinuousClock.now
        var waiters: [UUID: Waiter] = [:]
        var cancelled: Set<UUID> = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onSleep: @Sendable (Duration) -> Void
    init(onSleep: @escaping @Sendable (Duration) -> Void) { self.onSleep = onSleep }
    var now: ContinuousClock.Instant { state.withLock { $0.now } }
    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock {
                    if $0.cancelled.remove(id) != nil { return true }
                    $0.waiters[id] = Waiter(deadline: $0.now.advanced(by: duration), continuation: continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { onSleep(duration) }
            }
        } onCancel: {
            let continuation = self.state.withLock {
                $0.cancelled.insert(id)
                return $0.waiters.removeValue(forKey: id)?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
    func advance(_ duration: Duration) {
        let ready = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let ids = state.waiters.filter { $0.value.deadline <= state.now }.map(\.key)
            return ids.compactMap { state.waiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in ready { continuation.resume() }
    }
}
