import CoreGraphics
import Darwin
import KaitoKit
import os
import XCTest
@testable import cooViewer

final class AssemblyRecoveryTests: XCTestCase {
    func testQueuedRecoveryWinsOverCutoffInEitherNotificationOrder() async throws {
        for cutoffFirst in [true, false] {
            let timer = expectation(description: "期限通知を準備")
            let paused = expectation(description: "通知ループを停止")
            let cutoffQueued = expectation(description: "期限通知がキューに入る")
            let successQueued = expectation(description: "回復通知がキューに入る")
            let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
            let retryGate = AssemblyTestGate()
            let markerGate = AssemblyTestGate()
            let loopGate = AssemblyTestGate()
            let attempts = OSAllocatedUnfairLock(initialState: 0)
            var policy = AssemblyRetryPolicy.immediate
            policy.failureCutoff = .seconds(5)
            policy.now = { clock.now }
            policy.sleep = { try await clock.sleep($0) }
            let configured = policy
            let build = Task {
                try await AssemblyPreparation.run(candidates: candidates(2), total: 2,
                    sourceURL: source.url, lanes: 2, policy: configured,
                    onComplete: { ordinal, _ in
                        if ordinal == 1 { paused.fulfill(); await loopGate.wait() }
                    }, onEventEnqueued: { event in
                        if case .cutoff = event { cutoffQueued.fulfill() }
                        if case .completed(0, .success) = event { successQueued.fulfill() }
                    }) { candidate in
                        if candidate.ordinal == 0 {
                            let attempt = attempts.withLock { $0 += 1; return $0 }
                            if attempt == 1 { throw KaitoError.io(EMFILE) }
                            await retryGate.wait()
                        } else { await markerGate.wait() }
                        return prepared(candidate.ordinal)
                    }
            }
            await fulfillment(of: [timer], timeout: 2)
            await markerGate.open()
            await fulfillment(of: [paused], timeout: 1)
            if cutoffFirst {
                clock.advance(.seconds(5))
                await fulfillment(of: [cutoffQueued], timeout: 1)
                await retryGate.open()
                await fulfillment(of: [successQueued], timeout: 1)
            } else {
                await retryGate.open()
                await fulfillment(of: [successQueued], timeout: 1)
                clock.advance(.seconds(5))
                await fulfillment(of: [cutoffQueued], timeout: 1)
            }
            await loopGate.open()
            let results = try await build.value
            XCTAssertEqual(results.keys.sorted(), [0, 1])
            XCTAssertEqual(results.keys.sorted().flatMap { index -> [String] in
                guard case .ready(let child) = results[index] else { return [] }
                return child.entries.map(\.pathInBook)
            }, ["0.png", "1.png"])
        }
    }

    func testUnreachableProbeWaitsForPasswordAnswerAndVerification() async throws {
        let prompting = expectation(description: "入力待ちを開始")
        let probeQueued = expectation(description: "到達不能を通知")
        let probeApplied = expectation(description: "到達不能の後の通知も処理済み")
        let verifying = expectation(description: "回答を子で検証")
        let probeGate = AssemblyTestGate()
        let answerGate = AssemblyTestGate()
        let markerGate = AssemblyTestGate()
        let verificationGate = AssemblyTestGate()
        let clock = AssemblyTestClock { _ in }
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let encrypted = RecoveryPasswordSource(gate: verificationGate, verifying: verifying)
        let unlocker = NestedUnlocker(provider: { _, _ in
            prompts.withLock { $0 += 1 }
            prompting.fulfill()
            await answerGate.wait()
            return NestedPasswordAnswer(password: "pw", saveRequested: false)
        })
        var policy = AssemblyRetryPolicy.immediate
        policy.delays = []
        policy.networkExtraDelay = nil
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        policy.reachabilityProbe = { _ in await probeGate.wait(); return false }
        let configured = policy
        let build = Task {
            defer { returned.withLock { $0 = true } }
            do {
                _ = try await AssemblyPreparation.run(candidates: candidates(3), total: 3,
                    sourceURL: source.url, lanes: 3, policy: configured,
                    onComplete: { ordinal, _ in if ordinal == 2 { probeApplied.fulfill() } },
                    onEventEnqueued: { event in if case .probe(false) = event { probeQueued.fulfill() } }) { candidate in
                        if candidate.ordinal == 0 { throw KaitoError.io(EIO) }
                        if candidate.ordinal == 1 {
                            _ = try await unlocker.unlockForAssembly(encrypted, name: "secret.zip",
                                persistenceKey: .file(path: encrypted.url.path))
                        } else { await markerGate.wait() }
                        return prepared(candidate.ordinal)
                    }
                XCTFail("到達不能の失敗を返す")
                return nil as AssemblyFailure?
            } catch { return error as? AssemblyFailure }
        }
        await fulfillment(of: [prompting], timeout: 2)
        await probeGate.open()
        await fulfillment(of: [probeQueued], timeout: 1)
        await markerGate.open()
        await fulfillment(of: [probeApplied], timeout: 1)
        clock.advance(.seconds(20))
        XCTAssertFalse(returned.withLock { $0 })
        await answerGate.open()
        await fulfillment(of: [verifying], timeout: 1)
        XCTAssertFalse(returned.withLock { $0 })
        await verificationGate.open()
        let failure = await build.value
        XCTAssertEqual(failure?.volumeUnavailable, true)
        XCTAssertEqual(failure?.failures.map(\.relativePath), ["0.zip"])
        let accepted = await encrypted.accepted
        XCTAssertTrue(accepted)
        let reused = try await unlocker.unlockForAssembly(RecoveryPasswordSource(gate: verificationGate),
            name: "next.zip", persistenceKey: .file(path: "/synthetic/next.zip"))
        XCTAssertTrue(reused)
        XCTAssertEqual(prompts.withLock { $0 }, 1)
    }

    func testRecoveredChildDisarmsCutoffWhileAnotherChildIsStillPending() async throws {
        let timer = expectation(description: "最初の失敗で期限を設定")
        let disarmed = expectation(description: "回復で期限を解除")
        let gated = expectation(description: "別の子は準備中")
        let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
        let retryGate = AssemblyTestGate()
        let otherGate = AssemblyTestGate()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { duration in
            do { try await clock.sleep(duration) }
            catch {
                if duration == .seconds(5) { disarmed.fulfill() }
                throw error
            }
        }
        let configured = policy
        let build = Task {
            try await AssemblyPreparation.run(candidates: candidates(2), total: 2,
                sourceURL: source.url, lanes: 2, policy: configured) { candidate in
                if candidate.ordinal == 0 {
                    let attempt = attempts.withLock { $0 += 1; return $0 }
                    if attempt == 1 { throw KaitoError.io(EMFILE) }
                    await retryGate.wait()
                } else {
                    gated.fulfill()
                    await otherGate.wait()
                }
                return prepared(candidate.ordinal)
            }
        }
        await fulfillment(of: [timer, gated], timeout: 2)
        await retryGate.open()
        await fulfillment(of: [disarmed], timeout: 1)
        clock.advance(.seconds(20))
        await otherGate.open()
        let results = try await build.value
        XCTAssertEqual(results.keys.sorted(), [0, 1])
        XCTAssertEqual(results.keys.sorted().flatMap { index -> [String] in
            guard case .ready(let child) = results[index] else { return [] }
            return child.entries.map(\.pathInBook)
        }, ["0.png", "1.png"])
    }

    func testWorkersAndProbeInheritUtilityCallerPriority() async throws {
        let done = expectation(description: "低優先度の構築完了")
        let priorities = OSAllocatedUnfairLock(initialState: [String: TaskPriority]())
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.delays = []
        policy.networkExtraDelay = nil
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        policy.reachabilityProbe = { _ in
            priorities.withLock { $0["probe"] = Task.currentPriority }
            return false
        }
        let configured = policy
        let build = Task.detached(priority: .utility) {
            defer { done.fulfill() }
            do {
                _ = try await AssemblyPreparation.run(candidates: candidates(1), total: 1,
                    sourceURL: source.url, lanes: 1, policy: configured) { _ in
                    priorities.withLock { $0["worker"] = Task.currentPriority }
                    throw KaitoError.io(EIO)
                }
                XCTFail("読み取り失敗を返す")
            } catch { XCTAssertTrue(error is AssemblyFailure) }
        }
        // value を先に待つと優先度継承が昇格させるため、観測が終わるまで join しない(設計書 §7.4)。
        await fulfillment(of: [done], timeout: 2)
        await build.value
        XCTAssertEqual(priorities.withLock { $0["worker"] }, .utility)
        XCTAssertEqual(priorities.withLock { $0["probe"] }, .utility)
    }

    func testInteractivePasswordWaitPausesCutoffUntilAllChildrenRecover() async throws {
        let timer = expectation(description: "入力開始前に期限を設定")
        let paused = expectation(description: "入力中は期限を停止")
        let prompting = expectation(description: "回答を非同期に待機")
        let recovered = expectation(description: "失敗した子が回復")
        let beginPrompt = AssemblyTestGate()
        let answerGate = AssemblyTestGate()
        let retryGate = AssemblyTestGate()
        let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let unlocker = NestedUnlocker(provider: { _, _ in
            prompting.fulfill()
            await answerGate.wait()
            return NestedPasswordAnswer(password: "pw", saveRequested: false)
        })
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { duration in
            do { try await clock.sleep(duration) }
            catch {
                if duration == .seconds(5) { paused.fulfill() }
                throw error
            }
        }
        let configured = policy
        let build = Task {
            defer { returned.withLock { $0 = true } }
            return try await AssemblyPreparation.run(candidates: candidates(2), total: 2,
                sourceURL: source.url, lanes: 2, policy: configured,
                onComplete: { ordinal, _ in if ordinal == 0 { recovered.fulfill() } }) { candidate in
                if candidate.ordinal == 0 {
                    let attempt = attempts.withLock { $0 += 1; return $0 }
                    if attempt == 1 { throw KaitoError.io(EMFILE) }
                    await retryGate.wait()
                } else {
                    await beginPrompt.wait()
                    let unlocked = try await unlocker.unlockForAssembly(source, name: "secret.zip",
                        persistenceKey: .file(path: source.url.path))
                    XCTAssertTrue(unlocked)
                }
                return prepared(candidate.ordinal)
            }
        }
        await fulfillment(of: [timer], timeout: 2)
        await beginPrompt.open()
        await fulfillment(of: [prompting, paused], timeout: 1)
        clock.advance(.seconds(20))
        XCTAssertFalse(returned.withLock { $0 })
        await retryGate.open()
        await fulfillment(of: [recovered], timeout: 1)
        await answerGate.open()
        let results = try await build.value
        XCTAssertEqual(results.count, 2)
    }

    func testAbortedPreparationNeverPromptsAfterDelayedChildReturns() async throws {
        let timer = expectation(description: "失敗の期限")
        let delayed = expectation(description: "暗号化の問い合わせ前に停止")
        let late = expectation(description: "打切り後に遅い子が戻る")
        let clock = AssemblyTestClock { if $0 == .seconds(5) { timer.fulfill() } }
        let gate = AssemblyTestGate()
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        let unlocker = NestedUnlocker(provider: { _, _ in prompts.withLock { $0 += 1 }; return nil })
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        let configured = policy
        let build = Task {
            do {
                _ = try await AssemblyPreparation.run(candidates: candidates(2), total: 2,
                    sourceURL: source.url, lanes: 2, policy: configured) { candidate in
                    if candidate.ordinal == 0 { throw KaitoError.io(EACCES) }
                    delayed.fulfill()
                    await gate.wait()
                    defer { late.fulfill() }
                    _ = try await unlocker.unlockForAssembly(source, name: "late.zip",
                        persistenceKey: .file(path: source.url.path))
                    return .skipped
                }
                XCTFail("期限切れ")
            } catch {
                XCTAssertEqual((error as? AssemblyFailure)?.unchecked, 1)
            }
        }
        await fulfillment(of: [timer, delayed], timeout: 2)
        clock.advance(.seconds(5))
        await build.value
        await gate.open()
        await fulfillment(of: [late], timeout: 1)
        XCTAssertEqual(prompts.withLock { $0 }, 0)
    }

    func testCutoffResumesWithRemainingTimeAfterInteractiveAnswer() async throws {
        let timer = expectation(description: "当初の期限")
        let paused = expectation(description: "対話中は期限を停止")
        let prompting = expectation(description: "入力待ち")
        let resumed = expectation(description: "残り三秒で再開")
        let finished = expectation(description: "残り時間で打切り")
        let clock = AssemblyTestClock { duration in
            if duration == .seconds(5) { timer.fulfill() }
            if duration == .seconds(3) { resumed.fulfill() }
        }
        let beginPrompt = AssemblyTestGate()
        let answerGate = AssemblyTestGate()
        let hung = AssemblyTestGate()
        let returned = OSAllocatedUnfairLock(initialState: false)
        let unlocker = NestedUnlocker(provider: { _, _ in
            prompting.fulfill()
            await answerGate.wait()
            return NestedPasswordAnswer(password: "pw", saveRequested: false)
        })
        var policy = AssemblyRetryPolicy.immediate
        policy.failureCutoff = .seconds(5)
        policy.now = { clock.now }
        policy.sleep = { duration in
            do { try await clock.sleep(duration) }
            catch {
                if duration == .seconds(5) { paused.fulfill() }
                throw error
            }
        }
        let configured = policy
        let build = Task {
            defer { returned.withLock { $0 = true }; finished.fulfill() }
            do {
                _ = try await AssemblyPreparation.run(candidates: candidates(3), total: 3,
                    sourceURL: source.url, lanes: 3, policy: configured) { candidate in
                    if candidate.ordinal == 0 { throw KaitoError.io(EACCES) }
                    if candidate.ordinal == 1 {
                        await beginPrompt.wait()
                        _ = try await unlocker.unlockForAssembly(source, name: "secret.zip",
                            persistenceKey: .file(path: source.url.path))
                    } else { await hung.wait() }
                    return prepared(candidate.ordinal)
                }
                XCTFail("未解決の失敗を返す")
                return nil as AssemblyFailure?
            } catch { return error as? AssemblyFailure }
        }
        await fulfillment(of: [timer], timeout: 2)
        clock.advance(.seconds(2))
        await beginPrompt.open()
        await fulfillment(of: [prompting, paused], timeout: 1)
        clock.advance(.seconds(20))
        await answerGate.open()
        await fulfillment(of: [resumed], timeout: 1)
        clock.advance(.seconds(2))
        XCTAssertFalse(returned.withLock { $0 })
        clock.advance(.seconds(1))
        await fulfillment(of: [finished], timeout: 1)
        if !returned.withLock({ $0 }) { await hung.open() }
        let failure = await build.value
        XCTAssertEqual(failure?.failures.map(\.relativePath), ["0.zip"])
        XCTAssertEqual(failure?.unchecked, 1)
        await hung.open()
    }

    func testMemoryBackedArchiveNeverProbesItsSyntheticURL() async throws {
        let probes = OSAllocatedUnfairLock(initialState: [URL]())
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.delays = []
        policy.networkExtraDelay = nil
        policy.now = { clock.now }
        policy.sleep = { try await clock.sleep($0) }
        policy.beforeChildAttempt = { _ in throw KaitoError.io(EIO) }
        policy.reachabilityProbe = { url in probes.withLock { $0.append(url) }; return false }
        let archive = try ArchiveSource(data: TestFixtures.storedZip(entries: [
            (Array("inner.zip".utf8), TestFixtures.storedZip(entries: []))
        ]), name: "/synthetic/not-on-disk.zip", nestingDepth: 0, unlocker: NestedUnlocker(),
            persistenceKey: .file(path: "/real/parent.zip"), retryPolicy: policy)
        do { _ = try await archive.entries(); XCTFail("子の環境失敗を集約する") }
        catch {
            let failure = try XCTUnwrap(error as? AssemblyFailure)
            XCTAssertFalse(failure.volumeUnavailable)
            XCTAssertEqual(failure.failures.map(\.relativePath), ["inner.zip"])
            XCTAssertEqual(failure.unchecked, 0)
        }
        XCTAssertTrue(probes.withLock { $0.isEmpty })
    }
}

private let source = RecoveryBookSource()

private func candidates(_ count: Int) -> [AssemblyCandidate] {
    (0..<count).map { .init(ordinal: $0, relativePath: "\($0).zip", url: source.url.appendingPathComponent("\($0).zip")) }
}

private func prepared(_ ordinal: Int) -> AssemblyChildPreparation {
    .ready(.init(source: source, entries: [PageEntry(id: ordinal, name: "\(ordinal).png",
        pathInBook: "\(ordinal).png", fileURL: nil, creationDate: nil, modificationDate: nil)], excludedCount: 0))
}

private struct RecoveryBookSource: BookSource {
    let url = URL(fileURLWithPath: "/synthetic/recovery")
    let supportsDateSort = false
    func entries() async throws -> [PageEntry] { [] }
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        throw BookSourceError.pageLoadFailed(entry.name)
    }
}

private actor RecoveryPasswordSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/synthetic/locked.zip")
    nonisolated let supportsDateSort = false
    private let gate: AssemblyTestGate
    private let verifying: XCTestExpectation?
    private(set) var accepted = false

    init(gate: AssemblyTestGate, verifying: XCTestExpectation? = nil) {
        self.gate = gate
        self.verifying = verifying
    }
    func entries() async throws -> [PageEntry] { [] }
    func isEncrypted() async -> Bool { !accepted }
    func checkAndSetPassword(_ password: String) async -> PasswordCheck {
        verifying?.fulfill()
        await gate.wait()
        accepted = password == "pw"
        return accepted ? .accepted : .rejected
    }
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        throw BookSourceError.pageLoadFailed(entry.name)
    }
}
