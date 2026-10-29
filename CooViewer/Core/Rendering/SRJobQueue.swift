import Foundation
import os

enum SRJobPriority: Sendable {
    case prefetch, display
}

/// 合流した表示要求は、進行中の先読みを同じ計算のまま昇格させる(設計書 §5、§7.3)。
final class SRJobRequest: Sendable {
    let id = UUID()
    private let intent: OSAllocatedUnfairLock<SRJobPriority>

    init(priority: SRJobPriority = .display) {
        intent = OSAllocatedUnfairLock(initialState: priority)
    }

    var priority: SRJobPriority { intent.withLock { $0 } }

    func promote() { intent.withLock { $0 = .display } }

    func setPriority(_ priority: SRJobPriority) { intent.withLock { $0 = priority } }
}

/// タイル境界だけで実行権を渡し、表示の全タイルが終わるまで先読みを待たせる(設計書 §5)。
/// 待機中も呼び出し側の出力バッファとループ位置を保ち、完了済みタイルを再計算しない。
actor SRJobQueue {
    private struct Waiting {
        let job: SRJobRequest
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var active: SRJobRequest?
    private var waiting: [Waiting] = []

    /// 推論を止めたまま待機登録を確認し、時間に依存しない検証を可能にする(設計書 §7.6)。
    var queuedCount: Int { waiting.count }

    func nextTile(for job: SRJobRequest) async -> Bool {
        let permitted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                if active?.id == job.id {
                    if job.priority == .display
                        || !waiting.contains(where: { $0.job.priority == .display }) {
                        continuation.resume(returning: true)
                        return
                    }
                    active = nil
                    // 中断した先読みは他の先読みより先に再開する(設計書 §5)。
                    waiting.insert(Waiting(job: job, continuation: continuation), at: 0)
                } else {
                    waiting.append(Waiting(job: job, continuation: continuation))
                }
                startNext()
            }
        } onCancel: {
            Task { await self.cancelWaiting(job) }
        }
        return permitted && !Task.isCancelled
    }

    func finish(_ job: SRJobRequest) {
        if active?.id == job.id { active = nil }
        cancelWaiting(job)
        startNext()
    }

    private func cancelWaiting(_ job: SRJobRequest) {
        if let index = waiting.firstIndex(where: { $0.job.id == job.id }) {
            waiting.remove(at: index).continuation.resume(returning: false)
        }
        // 実行中の同期推論は割り込まず、次の境界と finish で解放する(設計書 §7.3)。
    }

    private func startNext() {
        guard active == nil, !waiting.isEmpty else { return }
        let index = waiting.firstIndex(where: { $0.job.priority == .display }) ?? 0
        let next = waiting.remove(at: index)
        active = next.job
        next.continuation.resume(returning: true)
    }
}
