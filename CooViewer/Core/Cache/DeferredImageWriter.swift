import CoreGraphics
import Darwin
import Foundation
import os

/// 表示は保存を待たず、保存中の同一キーは完成画像で応える(設計書 §5、§7.3)。
final class DeferredImageWriter: Sendable {
    static let shared = DeferredImageWriter()
    typealias Write = @Sendable (CGImage, URL) async throws -> Void

    private struct Pending {
        let id: UUID
        let generation: UUID
        let image: CGImage
        let task: Task<Void, Never>
    }
    private struct State {
        var generation = UUID()
        var stopped = false
        var pending: [URL: Pending] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var generation: UUID { state.withLock { $0.generation } }

    func image(at url: URL) -> CGImage? {
        state.withLock {
            guard let pending = $0.pending[url], pending.generation == $0.generation else { return nil }
            return pending.image
        }
    }

    func enqueue(_ image: CGImage, at url: URL, generation: UUID,
                 write: @escaping Write, didWrite: @escaping @Sendable () -> Void = {}) {
        guard !Task.isCancelled else { return }
        state.withLock { value in
            guard !value.stopped, value.generation == generation,
                  value.pending[url]?.generation != generation else { return }
            let id = UUID()
            let task = Task.detached(priority: .utility) { [self] in
                let manager = FileManager.default
                let temporary = url.deletingLastPathComponent()
                    .appendingPathComponent(".\(id.uuidString).tmp")
                defer {
                    try? manager.removeItem(at: temporary)
                    state.withLock {
                        if $0.pending[url]?.id == id { $0.pending[url] = nil }
                    }
                }
                do {
                    try Task.checkCancellation()
                    try manager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                    try await write(image, temporary)
                    try Task.checkCancellation()
                    // 取消と公開を同じロックで順序付け、旧世代の遅延保存を防ぐ(設計書 §7.3)。
                    let published = state.withLock {
                        guard !$0.stopped, $0.generation == generation,
                              $0.pending[url]?.id == id else { return false }
                        return rename(temporary.path, url.path) == 0
                    }
                    if published { didWrite() }
                } catch { }
            }
            value.pending[url] = Pending(id: id, generation: generation, image: image, task: task)
        }
    }

    /// 本を閉じると保存も失効する。終了時は新規受付も止める(設計書 §5 後始末)。
    func cancelAll(stopping: Bool = false) {
        state.withLock {
            $0.generation = UUID()
            $0.stopped = $0.stopped || stopping
            for pending in $0.pending.values { pending.task.cancel() }
        }
    }

    /// 保存を待つのは検証・後始末だけで、画像を返す経路では使わない(設計書 §7.6)。
    func waitForPendingWrites() async {
        let tasks = state.withLock { $0.pending.values.map(\.task) }
        for task in tasks { await task.value }
    }
}
