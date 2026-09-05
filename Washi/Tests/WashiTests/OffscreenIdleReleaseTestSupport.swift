import Foundation
@testable import Washi

/// cooViewer-oxr.68: 実時間を進めず、期限切れとキャンセル済み callback の
/// 競合を MainActor 上で決定的に再現するテスト用 scheduler。
@MainActor
final class ManualOffscreenIdleScheduler {
    @MainActor
    final class Entry {
        let delay: Duration
        let action: @MainActor @Sendable () -> Void
        var isCancelled = false
        var isFired = false

        init(delay: Duration,
             action: @escaping @MainActor @Sendable () -> Void) {
            self.delay = delay
            self.action = action
        }
    }

    private(set) var entries: [Entry] = []
    var firesNextEntrySynchronously = false

    var scheduler: EPUBOffscreenIdleReleaseTimer.Scheduler {
        { [weak self] delay, action in
            guard let self else { return {} }
            let entry = Entry(delay: delay, action: action)
            entries.append(entry)
            if firesNextEntrySynchronously {
                firesNextEntrySynchronously = false
                entry.isFired = true
                entry.action()
            }
            return { entry.isCancelled = true }
        }
    }

    var lastActiveEntry: Entry? {
        entries.last { !$0.isCancelled && !$0.isFired }
    }

    func fire(_ entry: Entry, includingCancelled: Bool = false) {
        guard !entry.isFired,
              includingCancelled || !entry.isCancelled else { return }
        entry.isFired = true
        entry.action()
    }
}
