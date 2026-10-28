import Foundation
import os

/// 単一飛行へ合流した表示は、元の先読みの待機だけを取り消して昇格する(設計書 §5)。
final class DecodePromotion: Sendable {
    private enum Intent { case prefetch, display, declined }
    private struct State {
        var intent = Intent.prefetch
        var waiters: [UUID: Task<Bool, Never>] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isPromoted: Bool { state.withLock { $0.intent == .display } }
    fileprivate var isDeclined: Bool { state.withLock { $0.intent == .declined } }

    func promote() {
        let waiters = state.withLock { state in
            state.intent = .display
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.cancel() }
    }

    /// 実行中のデコードは共有し続け、未開始の先読みだけを辞退させる(設計書 §5)。
    func declineQueuedPrefetch() {
        let waiters = state.withLock { state in
            guard state.intent != .display else { return [Task<Bool, Never>]() }
            state.intent = .declined
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.cancel() }
    }

    fileprivate func register(_ waiter: Task<Bool, Never>, id: UUID) {
        let shouldCancel = state.withLock { state in
            state.waiters[id] = waiter
            return state.intent != .prefetch
        }
        if shouldCancel { waiter.cancel() }
    }

    fileprivate func unregister(_ id: UUID) {
        state.withLock { $0.waiters[id] = nil }
    }
}

/// 共有デコーダーを先読みで占有しない。待機は取得だけの子タスクとし、処理本体は同期の葉に保つ(設計書 §5)。
enum PrefetchDecodeGate {
    static let concurrencyLimit = 2
    static let shared = SourceReadGate(limit: concurrencyLimit)
    struct Declined: Error {}

    static func run<T: Sendable>(isPrefetch: Bool = PageRequestIntent.isPrefetch,
                                gate: SourceReadGate = shared,
                                promotion: DecodePromotion? = PageRequestIntent.decodePromotion,
                                operation: @Sendable () throws -> T) async throws -> T {
        guard isPrefetch else { return try operation() }
        try Task.checkCancellation()
        let promotion = promotion ?? DecodePromotion()
        if promotion.isPromoted { return try operation() }
        if promotion.isDeclined { throw Declined() }
        let id = UUID()
        let waiter = Task { await gate.acquire(interactive: false) }
        promotion.register(waiter, id: id)
        let acquired = await withTaskCancellationHandler {
            await waiter.value
        } onCancel: {
            waiter.cancel()
        }
        promotion.unregister(id)
        // 昇格は FIFO を並べ替えるだけでなく、表示要求と同じく枠数制限を迂回する。
        guard acquired || promotion.isPromoted else {
            try Task.checkCancellation()
            throw Declined()
        }
        do {
            try Task.checkCancellation()
            let result = try operation()
            if acquired { await gate.release() }
            return result
        } catch {
            if acquired { await gate.release() }
            throw error
        }
    }
}
