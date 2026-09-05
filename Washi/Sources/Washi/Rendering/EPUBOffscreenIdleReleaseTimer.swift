import Foundation

/// オフスクリーン WebKit のアイドル解放を一箇所で管理する。
/// cooViewer-oxr.68: scheduler を差し替え可能にし、実時間を待たずに
/// 解放・再構築と競合防止を検証できるようにする。
@MainActor
final class EPUBOffscreenIdleReleaseTimer {
    typealias Cancellation = @MainActor @Sendable () -> Void
    typealias Scheduler = @MainActor @Sendable (
        _ delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> Cancellation

    /// cooViewer-oxr.68: 最後の要求が完了してから WebKit を保持する時間。
    nonisolated static let defaultInterval: Duration = .seconds(20)

    nonisolated static let continuousScheduler: Scheduler = { delay, action in
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    private let interval: Duration
    private let scheduler: Scheduler
    private var cancelScheduledAction: Cancellation?
    private var generation: UInt = 0

    init(
        interval: Duration = EPUBOffscreenIdleReleaseTimer.defaultInterval,
        scheduler: @escaping Scheduler = EPUBOffscreenIdleReleaseTimer.continuousScheduler
    ) {
        self.interval = interval
        self.scheduler = scheduler
    }

    func cancel() {
        generation &+= 1
        cancelScheduledAction?()
        cancelScheduledAction = nil
    }

    func restart(_ action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        let scheduledGeneration = generation
        let cancellation = scheduler(interval) { [weak self] in
            guard let self, generation == scheduledGeneration else { return }
            // scheduler が schedule 呼び出し中に同期発火しても、その戻り値の
            // stale cancellation が action 内で設定した次の期限を上書きしない。
            generation &+= 1
            cancelScheduledAction = nil
            action()
        }
        guard generation == scheduledGeneration else {
            cancellation()
            return
        }
        cancelScheduledAction = cancellation
    }
}
