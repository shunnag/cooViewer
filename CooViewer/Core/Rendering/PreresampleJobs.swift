import Foundation

/// 計画タスクの取消しとページ処理の寿命を分け、再計画で完成済みタイルを捨てない(設計書 §5、§7.3)。
@MainActor
final class PreresampleJobs {
    private struct Job {
        let id: UUID
        let entryID: Int
        let configuration: String
        let task: Task<Void, Never>
    }

    private var planned: Set<String> = []
    private var jobs: [String: Job] = [:]
    private var selected: String?

    var currentEntryID: Int? { selected.flatMap { jobs[$0]?.entryID } }
    var activeCount: Int { jobs.count }

    /// 新計画を確定してから計画外だけを停止する。各キーにつき保持する計算は一つ(設計書 §5)。
    func replacePlan(_ keys: Set<String>) {
        planned = keys
        for key in Array(jobs.keys) where !keys.contains(key) {
            jobs.removeValue(forKey: key)?.task.cancel()
        }
        if let selected, jobs[selected] == nil { self.selected = nil }
    }

    func cancelAll() { replacePlan([]) }

    func run(key: String, entryID: Int, configuration: String,
             operation: @escaping @Sendable () async -> Void) async {
        guard !Task.isCancelled, planned.contains(key) else { return }
        let job: Job
        if let running = jobs[key], running.configuration == configuration {
            job = running
        } else {
            jobs[key]?.task.cancel()
            job = Job(id: UUID(), entryID: entryID, configuration: configuration,
                      task: Task { await operation() })
            jobs[key] = job
        }
        selected = key
        // 待ち手である旧計画が取り消されても、ページ処理は次の計画へ引き継ぐ(設計書 §5)。
        await job.task.value
        if jobs[key]?.id == job.id {
            jobs[key] = nil
            if selected == key { selected = nil }
        }
    }
}
