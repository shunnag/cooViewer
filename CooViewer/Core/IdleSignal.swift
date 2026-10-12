import Foundation
import os

/// 「作業中 → 完了」を待つ側へ、ポーリングなしで知らせる信号(設計書 §5)。
/// 作業中でなければ待たずに戻り、完了の合図で待機者を一斉に起こす。
/// 待機中にタスクがキャンセルされれば、次の合図を待たずにその場で抜ける。
@MainActor
final class IdleSignal {
    private(set) var isBusy = false
    private var waiters: [Waiter] = []

    func setBusy(_ busy: Bool) {
        isBusy = busy
        guard !busy else { return }
        let woken = waiters
        waiters = []
        for waiter in woken { waiter.resume() }
    }

    func waitUntilIdle() async {
        guard isBusy else { return }
        let waiter = Waiter()
        waiters.append(waiter)
        defer { waiters.removeAll { $0 === waiter } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter.arm($0) }
        } onCancel: {
            // キャンセルは任意スレッドから届くため、MainActor を経由せずロックで解く
            waiter.resume()
        }
    }

    /// 完了・キャンセルのどちらが先でも一度だけ再開する。先にキャンセルが届いた
    /// (arm より前に resume された)場合は arm の時点で即座に再開する
    private final class Waiter: Sendable {
        private enum State {
            case idle
            case armed(CheckedContinuation<Void, Never>)
            case resumed
        }

        private let state = OSAllocatedUnfairLock<State>(initialState: .idle)

        func arm(_ continuation: CheckedContinuation<Void, Never>) {
            let resumeNow = state.withLock { current -> Bool in
                switch current {
                case .idle:
                    current = .armed(continuation)
                    return false
                case .resumed:
                    return true
                case .armed:
                    preconditionFailure("IdleSignal.Waiter は一度しか待てない")
                }
            }
            if resumeNow { continuation.resume() }
        }

        func resume() {
            let continuation = state.withLock { current -> CheckedContinuation<Void, Never>? in
                defer { current = .resumed }
                if case .armed(let continuation) = current { return continuation }
                return nil
            }
            continuation?.resume()
        }
    }
}
