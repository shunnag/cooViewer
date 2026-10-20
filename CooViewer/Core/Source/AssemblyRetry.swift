import Foundation
import KaitoKit
import os

struct AssemblyRetryPolicy: Sendable {
    var delays: [Duration] = [.milliseconds(250), .milliseconds(750), .milliseconds(1500)]
    var networkExtraDelay: Duration? = .seconds(3)
    var maxTotalSleep: Duration = .seconds(10)
    var releaseIdleHandles: @Sendable () -> Void = { _ = FileAccessPolicy.releaseIdleCachedHandles() }
    var failureCutoff: Duration = .seconds(10)
    var probeTimeout: Duration = .seconds(2)
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var beforeChildAttempt: @Sendable (String) async throws -> Void = { _ in }
    var reachabilityProbe: @Sendable (URL) async -> Bool = { url in
        await FileManagerProbe.queue(for: url).run {
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    static let `default` = AssemblyRetryPolicy()
    static let immediate = AssemblyRetryPolicy(delays: [.zero, .zero, .zero], networkExtraDelay: .zero)
}

/// 同じ合本の子が並列に失敗しても、待機予算と資源不足の観測を共有する(設計書 §7.4)。
final class AssemblyRetryBudget: @unchecked Sendable {
    private struct State {
        var remaining: Duration
        var sawResourceShortage = false
    }
    private let state: OSAllocatedUnfairLock<State>

    init(policy: AssemblyRetryPolicy) {
        state = OSAllocatedUnfairLock(initialState: State(remaining: max(.zero, policy.maxTotalSleep)))
    }

    var sawResourceShortage: Bool { state.withLock { $0.sawResourceShortage } }
    var remainingSleep: Duration { state.withLock { $0.remaining } }

    fileprivate func noteResourceShortage() { state.withLock { $0.sawResourceShortage = true } }

    fileprivate func reserve(_ delay: Duration) -> Bool {
        state.withLock {
            guard $0.remaining > .zero, delay >= .zero, delay <= $0.remaining else { return false }
            // ゼロ待機の試験方針は実時間を消費しない(設計書 §7.4)。
            $0.remaining -= delay
            return true
        }
    }
}

enum AssemblyRetry {
    static func run<T: Sendable>(
        policy: AssemblyRetryPolicy, budget: AssemblyRetryBudget,
        onRetry: (@Sendable (Int) async -> Void)? = nil,
        onFailure: (@Sendable (any Error) -> Void)? = nil,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var retry = 0
        var usedNetworkExtra = false
        while true {
            try Task.checkCancellation()
            if retry > 0 {
                policy.releaseIdleHandles()
                await onRetry?(retry + 1)
                try Task.checkCancellation()
            }
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                let kind = SourceReadFailure.retryClass(error)
                if kind == .transient { budget.noteResourceShortage() }
                onFailure?(error)
                // 内側が使った予算を外側で掛け算しない(設計書 §2.4、§7.4)。
                guard SourceReadFailure.assemblyFailure(in: error) == nil,
                      kind == .transient || kind == .network || kind == .reopen else { throw error }
                let delay: Duration
                if retry < policy.delays.count { delay = policy.delays[retry] }
                else if kind == .network, !usedNetworkExtra, let extra = policy.networkExtraDelay {
                    delay = extra
                    usedNetworkExtra = true
                } else { throw error }
                guard budget.reserve(delay) else { throw error }
                try await policy.sleep(delay)
                retry += 1
            }
        }
    }

    static func sourceIsReachable(_ url: URL, policy: AssemblyRetryPolicy) async throws -> Bool {
        let result = AssemblyProbeResult()
        let priority = Task.currentPriority
        let probe = Task.detached(priority: priority) { result.finish(await policy.reachabilityProbe(url)) }
        let timeout = Task.detached(priority: priority) {
            do {
                try await policy.sleep(policy.probeTimeout)
                result.finish(false)
            } catch {}
        }
        defer { probe.cancel(); timeout.cancel() }
        let reachable = await withTaskCancellationHandler {
            await result.value()
        } onCancel: { result.finish(false) }
        try Task.checkCancellation()
        return reachable
    }
}

/// OS のプローブ自体が応答しなくても timeout で待ち手を解放する(設計書 §7.4)。
private final class AssemblyProbeResult: Sendable {
    private struct State {
        var result: Bool?
        var continuation: CheckedContinuation<Bool, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready: Bool? = state.withLock {
                if let result = $0.result { return result }
                $0.continuation = continuation
                return nil as Bool?
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func finish(_ result: Bool) {
        let continuation = state.withLock {
            guard $0.result == nil else { return nil as CheckedContinuation<Bool, Never>? }
            $0.result = result
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}


struct AssemblyPreparedChild: Sendable {
    let source: any BookSource
    let entries: [PageEntry]
    let excludedCount: Int
}

enum AssemblyChildPreparation: Sendable {
    case ready(AssemblyPreparedChild)
    case excluded
    case skipped
}

struct AssemblyCandidate: Sendable {
    let ordinal: Int
    let relativePath: String
    let url: URL
}

/// 直列解錠タスクへも入力待ちの通知を引き継ぎ、利用者の回答時間を期限に算入しない(設計書 §2.4、§7.4)。
enum AssemblyInteraction {
    @TaskLocal static var handler: (@Sendable (Bool) -> Void)?
}

/// 親の取消しを actor の再開待ちにせず子へ伝え、深いネストの遅い入力依頼も止める(設計書 §2.4、§7.4)。
private final class AssemblyWorkerCancellation: Sendable {
    private struct State {
        var cancelled = false
        var tasks: [Int: Task<Void, Never>] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func insert(_ task: Task<Void, Never>, ordinal: Int) {
        let cancelled = state.withLock {
            if $0.cancelled { return true }
            $0.tasks[ordinal] = task
            return false
        }
        if cancelled { task.cancel() }
    }

    func remove(_ ordinal: Int) { state.withLock { _ = $0.tasks.removeValue(forKey: ordinal) } }

    func cancel() {
        let tasks = state.withLock {
            $0.cancelled = true
            let tasks = Array($0.tasks.values)
            $0.tasks.removeAll()
            return tasks
        }
        for task in tasks { task.cancel() }
    }
}

/// 期限後は子を join せず、閉じた通知口で遅い結果を捨てる(設計書 §2.4、§7.4)。
/// 共有ソースの構築は取り消さず、試行が専有する子だけを呼び出し元で破棄する。
enum AssemblyPreparation {
    enum Event: Sendable {
        case failedAttempt(Int, any Error, ContinuousClock.Instant)
        case retry(Int, Int)
        case completed(Int, Result<AssemblyChildPreparation, any Error>)
        case interactiveUnlock(Int, Bool, ContinuousClock.Instant)
        case cutoff(UUID)
        case probe(Bool)
        case abortCheck(UUID)
    }

    /// 新しく生成してまだ公開していない子だけに使い、共有ソースの待ち手の取消しとは分ける(設計書 §2.4、§7.4)。
    static func entriesForOwnedChild(_ child: any BookSource) async throws -> [PageEntry] {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let entries = try await child.entries()
            try Task.checkCancellation()
            return entries
        } onCancel: {
            if let archive = child as? ArchiveSource {
                archive.abandonAssembly()
            }
        }
    }

    /// 全員が回復した構築は経過時間に関係なく成功させる。合本失敗は未解決の失敗か
    /// 打ち切りによる未確認の子が残る場合だけとし、両方が空の失敗を投げない(設計書 §7.4)。
    static func run(
        candidates: [AssemblyCandidate], total: Int, sourceURL: URL, lanes: Int,
        policy: AssemblyRetryPolicy, probeSource: Bool = true,
        onRetry: (@Sendable (String) async -> Void)? = nil,
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil,
        onComplete: (@Sendable (Int, AssemblyChildPreparation) async -> Void)? = nil,
        onEventEnqueued: (@Sendable (Event) -> Void)? = nil,
        operation: @escaping @Sendable (AssemblyCandidate) async throws -> AssemblyChildPreparation
    ) async throws -> [Int: AssemblyChildPreparation] {
        let (events, sink) = AsyncStream<Event>.makeStream()
        let emit: @Sendable (Event) -> Void = { event in
            // 投入済みの順序を観測し、回復と期限の競合を実時間に頼らず検証する(設計書 §7.4)。
            if case .enqueued = sink.yield(event) { onEventEnqueued?(event) }
        }
        let priority = Task.currentPriority
        let enclosingInteraction = AssemblyInteraction.handler
        let budget = AssemblyRetryBudget(policy: policy)
        let cancellation = AssemblyWorkerCancellation()
        let byOrdinal = Dictionary(uniqueKeysWithValues: candidates.map { ($0.ordinal, $0) })
        var workers: [Int: Task<Void, Never>] = [:]
        var auxiliaries: [Task<Void, Never>] = []
        var cutoffTask: Task<Void, Never>?
        defer {
            sink.finish()
            cutoffTask?.cancel()
            cancellation.cancel()
            for auxiliary in auxiliaries { auxiliary.cancel() }
        }
        var results: [Int: AssemblyChildPreparation] = [:]
        var failures: [Int: any Error] = [:]
        var attempts: [Int: any Error] = [:]
        var firstFailure: (any Error)?
        var deadline: ContinuousClock.Instant?
        var cutoffID: UUID?
        var interactiveUnlocks: Set<Int> = []
        var promptBeganAt: ContinuousClock.Instant?
        var pausedAt: ContinuousClock.Instant?
        var probed = false
        var probing = false
        var pendingVolumeUnavailable = false
        var volumeUnavailable = false
        var abortCheckID: UUID?
        var aborted = false
        var next = 0
        var completed = total - candidates.count
        func requestAbortCheck() {
            guard abortCheckID == nil else { return }
            let id = UUID()
            abortCheckID = id
            // 先に届いた回復・対話通知を反映してから打ち切りを確定する(設計書 §2.4、§7.4)。
            emit(.abortCheck(id))
        }
        func cancelCutoffTimer() {
            cutoffTask?.cancel()
            cutoffTask = nil
            cutoffID = nil
        }
        func armCutoffTimer() {
            cancelCutoffTimer()
            guard let deadline, interactiveUnlocks.isEmpty else { return }
            let id = UUID()
            cutoffID = id
            let remaining = max(.zero, deadline - policy.now())
            cutoffTask = Task.detached(priority: priority) {
                do {
                    try await policy.sleep(remaining)
                    emit(.cutoff(id))
                } catch {}
            }
        }
        func startChild() {
            let candidate = candidates[next]
            next += 1
            let worker = Task.detached(priority: priority) {
                do {
                    let result = try await AssemblyInteraction.$handler.withValue({ active in
                        emit(.interactiveUnlock(candidate.ordinal, active, policy.now()))
                        enclosingInteraction?(active)
                    }) {
                        try await AssemblyRetry.run(policy: policy, budget: budget,
                            onRetry: { attempt in emit(.retry(candidate.ordinal, attempt)) },
                            onFailure: { error in
                                emit(.failedAttempt(candidate.ordinal, error, policy.now()))
                            }) {
                                try await policy.beforeChildAttempt(candidate.relativePath)
                                return try await operation(candidate)
                            }
                    }
                    emit(.completed(candidate.ordinal, .success(result)))
                } catch { emit(.completed(candidate.ordinal, .failure(error))) }
            }
            workers[candidate.ordinal] = worker
            cancellation.insert(worker, ordinal: candidate.ordinal)
        }
        await onProgress?(completed, total)
        var iterator = events.makeAsyncIterator()
        try await withTaskCancellationHandler {
            for _ in 0..<min(lanes, candidates.count) {
                try Task.checkCancellation()
                startChild()
            }
            while !workers.isEmpty || probing || abortCheckID != nil {
                try Task.checkCancellation()
                guard let event = await iterator.next() else { break }
                switch event {
                case .failedAttempt(let ordinal, let error, let time):
                    if SourceReadFailure.retryClass(error) == .cancelled { throw CancellationError() }
                    guard SourceReadFailure.mustPropagate(error) else { continue }
                    attempts[ordinal] = error
                    if firstFailure == nil { firstFailure = error }
                    if deadline == nil {
                        deadline = time.advanced(by: policy.failureCutoff)
                        if !interactiveUnlocks.isEmpty { pausedAt = max(time, promptBeganAt ?? time) }
                        armCutoffTimer()
                    }
                    if probeSource, !probed, SourceReadFailure.retryClass(error) == .network
                        || SourceReadFailure.cause(error) == .notFound {
                        probed = true
                        probing = true
                        auxiliaries.append(Task.detached(priority: priority) {
                            do {
                                emit(.probe(try await AssemblyRetry.sourceIsReachable(sourceURL, policy: policy)))
                            } catch {}
                        })
                    }
                case .retry(let ordinal, let attempt):
                    // 一度だけの短い資源不足では HUD を出さない(設計書 §7.4)。
                    if attempt == 3, let candidate = byOrdinal[ordinal] {
                        await onRetry?(candidate.relativePath)
                    }
                case .completed(let ordinal, let result):
                    workers.removeValue(forKey: ordinal)
                    cancellation.remove(ordinal)
                    attempts.removeValue(forKey: ordinal)
                    switch result {
                    case .success(let child):
                        results[ordinal] = child
                        await onComplete?(ordinal, child)
                    case .failure(let error):
                        if SourceReadFailure.retryClass(error) == .cancelled { throw CancellationError() }
                        if SourceReadFailure.mustPropagate(error) { failures[ordinal] = error }
                        else {
                            results[ordinal] = .excluded
                            await onComplete?(ordinal, .excluded)
                        }
                    }
                    completed += 1
                    await onProgress?(completed, total)
                case .interactiveUnlock(let ordinal, let active, let time):
                    if active {
                        if interactiveUnlocks.isEmpty {
                            promptBeganAt = time
                            if deadline != nil { pausedAt = time }
                            cancelCutoffTimer()
                        }
                        interactiveUnlocks.insert(ordinal)
                    } else {
                        interactiveUnlocks.remove(ordinal)
                        if interactiveUnlocks.isEmpty {
                            if let pausedAt, let limit = deadline {
                                deadline = limit.advanced(by: max(.zero, time - pausedAt))
                            }
                            pausedAt = nil
                            promptBeganAt = nil
                            armCutoffTimer()
                        }
                    }
                case .cutoff(let id):
                    if id == cutoffID, interactiveUnlocks.isEmpty,
                       !attempts.isEmpty || !failures.isEmpty { requestAbortCheck() }
                case .probe(let reachable):
                    probing = false
                    if !reachable { pendingVolumeUnavailable = true }
                case .abortCheck(let id):
                    guard id == abortCheckID else { continue }
                    abortCheckID = nil
                    if results.count != candidates.count, interactiveUnlocks.isEmpty,
                       !attempts.isEmpty || !failures.isEmpty {
                        if pendingVolumeUnavailable || deadline.map({ policy.now() >= $0 }) == true {
                            volumeUnavailable = pendingVolumeUnavailable
                            aborted = true
                        }
                    }
                }
                // 完了通知と期限通知が重なっても、回復済みの本を失敗に戻さない(設計書 §7.4)。
                if results.count == candidates.count { break }
                if attempts.isEmpty, failures.isEmpty {
                    deadline = nil
                    pausedAt = nil
                    pendingVolumeUnavailable = false
                    abortCheckID = nil
                    cancelCutoffTimer()
                } else if !aborted, interactiveUnlocks.isEmpty,
                          pendingVolumeUnavailable || deadline.map({ policy.now() >= $0 }) == true {
                    requestAbortCheck()
                }
                if aborted { break }
                if !probing, !pendingVolumeUnavailable, abortCheckID == nil {
                    let limit = budget.sawResourceShortage ? 1 : lanes
                    while workers.count < limit, next < candidates.count {
                        try Task.checkCancellation()
                        startChild()
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel(); sink.finish() }
        if aborted {
            // 再試行中の子には最後に観測した原因を付け、未応答の子だけを未確認にする(設計書 §7.4)。
            failures.merge(attempts) { old, _ in old }
        }
        let unchecked = aborted ? candidates.count - results.count - failures.count : 0
        if !failures.isEmpty || unchecked > 0 {
            let ordered = failures.sorted { $0.key < $1.key }
            let children = ordered.compactMap { ordinal, error -> ChildReadFailure? in
                guard let candidate = byOrdinal[ordinal] else { return nil }
                return ChildReadFailure(relativePath: candidate.relativePath, url: candidate.url, error: error)
            }
            throw AssemblyFailure(failures: children, total: total,
                unchecked: unchecked,
                volumeUnavailable: volumeUnavailable, sourceURL: sourceURL,
                underlyingError: ordered.first?.value ?? firstFailure)
        }
        return results
    }
}
