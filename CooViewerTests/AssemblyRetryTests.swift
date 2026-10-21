import Darwin
import KaitoKit
import os
import XCTest
@testable import cooViewer

final class AssemblyRetryTests: XCTestCase {
    func testPermanentCollectionChildClassificationPreservesEnvironmentalErrors() {
        let permanent = [ENOENT, ENOTDIR, ELOOP, EACCES, EPERM]
        let environmental = [EIO, ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN,
            EHOSTUNREACH, ENXIO, ECONNRESET, EMFILE, ENFILE, EAGAIN, ENOMEM, ESTALE, ENOSPC, EROFS]
        for code in permanent + environmental {
            for error in [KaitoError.io(code) as any Error,
                          NSError(domain: NSPOSIXErrorDomain, code: Int(code))] {
                XCTAssertEqual(SourceReadFailure.isPermanentCollectionChildFailure(wrap(error)),
                               permanent.contains(code), "errno \(code)")
                let cocoa = NSError(domain: NSCocoaErrorDomain, code: 260,
                    userInfo: [NSUnderlyingErrorKey: error])
                XCTAssertEqual(SourceReadFailure.isPermanentCollectionChildFailure(cocoa), permanent.contains(code))
            }
        }
        for code in [4, 260, 257] {
            XCTAssertTrue(SourceReadFailure.isPermanentCollectionChildFailure(
                NSError(domain: NSCocoaErrorDomain, code: code)))
        }
        let inner = AssemblyFailure(failures: [.init(relativePath: "inner.zip", url: url,
            error: KaitoError.io(ENOENT))], total: 1, sourceURL: url)
        XCTAssertFalse(SourceReadFailure.isPermanentCollectionChildFailure(wrap(inner)))
    }

    func testClassificationTableAndUnderlyingErrors() {
        let table: [(Int32, RetryClass, ReadFailureCause)] = [
            (EMFILE, .transient, .repeatedFailure), (ENFILE, .transient, .repeatedFailure),
            (EAGAIN, .transient, .repeatedFailure), (ENOMEM, .transient, .repeatedFailure),
            (EIO, .network, .connectionLost), (ETIMEDOUT, .network, .connectionLost),
            (ENOTCONN, .network, .connectionLost), (ENETDOWN, .network, .connectionLost),
            (ENETUNREACH, .network, .connectionLost), (EHOSTDOWN, .network, .connectionLost),
            (EHOSTUNREACH, .network, .connectionLost), (ENXIO, .network, .connectionLost),
            (ECONNRESET, .network, .connectionLost), (ESTALE, .reopen, .fileChanged),
            (ENOENT, .persistent, .notFound), (ENOTDIR, .persistent, .notFound),
            (EACCES, .persistent, .accessDenied), (EPERM, .persistent, .accessDenied),
            (ENOSPC, .persistent, .diskFull), (EROFS, .persistent, .accessDenied),
            (ELOOP, .persistent, .repeatedFailure)
        ]
        for (code, kind, cause) in table {
            for error in [KaitoError.io(code) as any Error,
                          NSError(domain: NSPOSIXErrorDomain, code: Int(code))] {
                XCTAssertEqual(SourceReadFailure.retryClass(error), kind, "errno \(code)")
                XCTAssertEqual(SourceReadFailure.cause(error), cause, "errno \(code)")
                XCTAssertTrue(SourceReadFailure.mustPropagate(error))
                let wrapped = wrap(wrap(error))
                XCTAssertEqual(SourceReadFailure.retryClass(wrapped), kind)
                XCTAssertEqual(SourceReadFailure.cause(wrapped), cause)
            }
        }
        for code in [4, 257, 260, 263, 640, 256, 258, 268] {
            let error = NSError(domain: NSCocoaErrorDomain, code: code)
            XCTAssertEqual(SourceReadFailure.retryClass(error), .persistent)
            XCTAssertTrue(SourceReadFailure.mustPropagate(error))
        }
        for code in [259, 261, 262, 264] {
            let error = NSError(domain: NSCocoaErrorDomain, code: code)
            XCTAssertEqual(SourceReadFailure.retryClass(error), .structural)
            XCTAssertFalse(SourceReadFailure.mustPropagate(error))
        }
        XCTAssertEqual(SourceReadFailure.retryClass(BookSourceError.temporarilyUnavailable(url)), .transient)
        XCTAssertEqual(SourceReadFailure.retryClass(wrap(CancellationError())), .cancelled)
        XCTAssertEqual(SourceReadFailure.retryClass(KaitoError.malformed("broken")), .structural)
        XCTAssertEqual(SourceReadFailure.cause(NSError(domain: NSCocoaErrorDomain, code: 4)), .notFound)
        XCTAssertEqual(SourceReadFailure.cause(NSError(domain: NSCocoaErrorDomain, code: 257)), .accessDenied)
        XCTAssertEqual(SourceReadFailure.cause(NSError(domain: NSCocoaErrorDomain, code: 640)), .diskFull)
        let deep = (0..<4).reduce(KaitoError.io(EMFILE) as any Error) { error, _ in wrap(error) }
        XCTAssertEqual(SourceReadFailure.retryClass(deep), .transient)
        XCTAssertEqual(SourceReadFailure.retryClass(wrap(deep)), .structural)
    }

    func testRetrySucceedsOnThirdAttemptAndReleasesBeforeEachRetry() async throws {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        var policy = AssemblyRetryPolicy.immediate
        policy.releaseIdleHandles = { events.withLock { $0.append("release") } }
        let value = try await AssemblyRetry.run(policy: policy, budget: .init(policy: policy)) {
            let attempt = attempts.withLock { $0 += 1; return $0 }
            events.withLock { $0.append("attempt\(attempt)") }
            if attempt < 3 { throw KaitoError.io(EMFILE) }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(events.withLock { $0 }, ["attempt1", "release", "attempt2", "release", "attempt3"])
    }

    func testOnlyNetworkGetsOneExtraAttempt() async {
        for (error, expected) in [(KaitoError.io(EACCES), 1), (.io(EMFILE), 4),
                                  (.io(ESTALE), 4), (.io(EIO), 5), (.malformed("broken"), 1)] {
            let count = OSAllocatedUnfairLock(initialState: 0)
            let policy = AssemblyRetryPolicy.immediate
            do {
                let _: Int = try await AssemblyRetry.run(policy: policy, budget: .init(policy: policy)) {
                    count.withLock { $0 += 1 }
                    throw error
                }
                XCTFail("失敗を返す")
            } catch {}
            XCTAssertEqual(count.withLock { $0 }, expected)
        }
    }

    func testExhaustedBudgetDoesNotSleepOrAttemptAgain() async {
        let calls = OSAllocatedUnfairLock(initialState: (attempts: 0, sleeps: 0))
        var policy = AssemblyRetryPolicy.default
        policy.maxTotalSleep = .zero
        policy.sleep = { _ in calls.withLock { $0.sleeps += 1 } }
        let budget = AssemblyRetryBudget(policy: policy)
        do {
            let _: Int = try await AssemblyRetry.run(policy: policy, budget: budget) {
                calls.withLock { $0.attempts += 1 }
                throw KaitoError.io(EMFILE)
            }
            XCTFail("予算切れ")
        } catch {}
        XCTAssertEqual(calls.withLock { $0.attempts }, 1)
        XCTAssertEqual(calls.withLock { $0.sleeps }, 0)
        XCTAssertTrue(budget.sawResourceShortage)
    }

    func testSleepBudgetIsSharedAcrossChildren() async {
        let calls = OSAllocatedUnfairLock(initialState: (attempts: 0, sleeps: 0))
        var policy = AssemblyRetryPolicy.default
        policy.delays = [.seconds(1)]
        policy.maxTotalSleep = .seconds(1)
        policy.sleep = { _ in calls.withLock { $0.sleeps += 1 } }
        let budget = AssemblyRetryBudget(policy: policy)
        for _ in 0..<2 {
            do {
                let _: Int = try await AssemblyRetry.run(policy: policy, budget: budget) {
                    calls.withLock { $0.attempts += 1 }
                    throw KaitoError.io(EMFILE)
                }
            } catch {}
        }
        XCTAssertEqual(calls.withLock { $0.attempts }, 3)
        XCTAssertEqual(calls.withLock { $0.sleeps }, 1)
        XCTAssertEqual(budget.remainingSleep, .zero)
    }

    func testAssemblyFailureIsPreservedAndNeverRetriedEvenWhenWrapped() async throws {
        let original = KaitoError.io(ESTALE)
        let failure = AssemblyFailure(failures: [.init(relativePath: "inner.zip", url: url, error: original)],
            total: 1, sourceURL: url, underlyingError: original)
        XCTAssertTrue(SourceReadFailure.mustPropagate(failure))
        XCTAssertEqual((failure as NSError).userInfo[NSUnderlyingErrorKey] as? KaitoError, original)
        XCTAssertEqual(SourceReadFailure.cause(failure), .fileChanged)
        for error in [failure as any Error, wrap(failure)] {
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let policy = AssemblyRetryPolicy.immediate
            do {
                let _: Int = try await AssemblyRetry.run(policy: policy, budget: .init(policy: policy)) {
                    calls.withLock { $0 += 1 }
                    throw error
                }
                XCTFail("内側の失敗を保持する")
            } catch { XCTAssertNotNil(SourceReadFailure.assemblyFailure(in: error)) }
            XCTAssertEqual(calls.withLock { $0 }, 1)
        }
    }

    func testCancellationDuringSleepStopsAttempts() async {
        let sleeping = expectation(description: "再試行待機へ到達")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let pause = RetryTestPause()
        var policy = AssemblyRetryPolicy.default
        policy.sleep = { _ in
            sleeping.fulfill()
            await pause.wait()
            try Task.checkCancellation()
        }
        let capturedPolicy = policy
        let task = Task {
            try await AssemblyRetry.run(policy: capturedPolicy, budget: .init(policy: capturedPolicy)) {
                attempts.withLock { $0 += 1 }
                throw KaitoError.io(EMFILE)
            } as Int
        }
        await fulfillment(of: [sleeping], timeout: 2)
        task.cancel()
        await pause.resume()
        do { _ = try await task.value; XCTFail("取消し") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
    }

    func testProbeTimeoutReturnsWithoutWaitingForBlockedProbe() async throws {
        let pause = RetryTestPause()
        var policy = AssemblyRetryPolicy.immediate
        policy.probeTimeout = .zero
        policy.reachabilityProbe = { _ in await pause.wait(); return true }
        let reachable = try await AssemblyRetry.sourceIsReachable(url, policy: policy)
        XCTAssertFalse(reachable)
        await pause.resume()
    }

    private var url: URL { URL(fileURLWithPath: "/synthetic/book.zip") }
    private func wrap(_ error: any Error) -> NSError {
        NSError(domain: "test.wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: error])
    }
}

private actor RetryTestPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    func wait() async {
        if resumed { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
