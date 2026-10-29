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
    private var pageTasks: [UUID: Task<Void, Never>] = [:]
    private var planTasks: [UUID: Task<Void, Never>] = [:]
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

    /// 差し替え済みの計画も完了まで追跡し、アンロードで旧本を残さない(設計書 §5、§7.3)。
    func startPlan(operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task(priority: .utility) {
            defer { self.planTasks[id] = nil }
            await operation()
        }
        planTasks[id] = task
        return task
    }

    /// 取消し済みで計画から外れた仕事も待つ。新しい本の計画は待機対象へ混ぜない(設計書 §5)。
    func cancelAllAndDrain() -> Task<Void, Never> {
        cancelAll()
        let tasks = Array(planTasks.values) + Array(pageTasks.values)
        for task in tasks { task.cancel() }
        return Task(priority: .utility) {
            for task in tasks { await task.value }
        }
    }

    func run(key: String, entryID: Int, configuration: String,
             operation: @escaping @Sendable () async -> Void) async {
        guard !Task.isCancelled, planned.contains(key) else { return }
        let job: Job
        if let running = jobs[key], running.configuration == configuration {
            job = running
        } else {
            jobs[key]?.task.cancel()
            job = Job(id: UUID(), entryID: entryID, configuration: configuration,
                      task: Task(priority: .utility) { await operation() })
            jobs[key] = job
            pageTasks[job.id] = job.task
        }
        selected = key
        // 待ち手である旧計画が取り消されても、ページ処理は次の計画へ引き継ぐ(設計書 §5)。
        await job.task.value
        pageTasks[job.id] = nil
        if jobs[key]?.id == job.id {
            jobs[key] = nil
            if selected == key { selected = nil }
        }
    }
}
