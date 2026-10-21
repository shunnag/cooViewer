import CryptoKit
import Foundation
import os

/// 表示 actor を長い solid 展開で塞がない専用の所有者(設計書 §5、cooViewer-tg48・r1t2)。
actor ArchiveSpoolWorker {
    private let archive: any ArchiveEngine

    init(archive: sending any ArchiveEngine) { self.archive = archive }

    func extract(_ index: Int32, key: SymmetricKey?, to fileURL: URL,
                 byteLimit: Int64 = .max) -> SpoolOutcome {
        guard !Task.isCancelled else { return .failed }
        guard let plain = archive.contents(ofEntry: index) else { return .skipped }
        return Self.store(plain, key: key, to: fileURL, byteLimit: byteLimit)
    }

    nonisolated static func store(_ plain: Data, key: SymmetricKey?, to fileURL: URL,
                                 byteLimit: Int64) -> SpoolOutcome {
        guard !Task.isCancelled else { return .failed }
        let data: Data
        if let key {
            // 封印失敗時に平文へ戻さない。鍵と平文はメモリだけに置く(設計書 §5)。
            guard let sealed = SuperResCacheCrypto.seal(plain, using: key) else { return .failed }
            data = sealed
        } else { data = plain }
        guard Int64(data.count) <= byteLimit else { return .failed }
        do {
            try Task.checkCancellation()
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return .stored(plain: plain, bytesOnDisk: Int64(data.count))
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return .failed
        }
    }
}

enum SpoolOutcome: Sendable {
    case stored(plain: Data, bytesOnDisk: Int64)
    case skipped
    case failed
}

/// 取消しと完了の競争は、同じ票を取り除けた側だけが再開する(設計書 §5)。
/// 継続の所有を独立させ、ソース破棄時にも全票を排出できるようにする。
final class ArchiveSpoolWaiters: Sendable {
    private struct Waiter {
        let entryID: Int
        let continuation: CheckedContinuation<Data?, any Error>
    }
    private let pending = OSAllocatedUnfairLock(initialState: [UUID: Waiter]())

    var count: Int { pending.withLock { $0.count } }

    func wait(for id: Int, isolation: isolated (any Actor)? = #isolation) async throws -> Data? {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { $0[token] = Waiter(entryID: id, continuation: continuation) }
                }
            }
        } onCancel: {
            let waiter = self.pending.withLock { $0.removeValue(forKey: token) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func resume(_ id: Int? = nil, data: Data? = nil) {
        let waiters = pending.withLock { state in
            let tokens = state.keys.filter { id == nil || state[$0]?.entryID == id }
            return tokens.compactMap { state.removeValue(forKey: $0) }
        }
        for waiter in waiters { waiter.continuation.resume(returning: data) }
    }

    deinit { resume() }
}

/// ステージングと同じ空き容量方針を、スプール先のボリュームで評価する(設計書 §5)。
enum SpoolSpacePolicy {
    static func totalBudget(sizeLimit: Int64) -> Int64 {
        let root = ArchiveSource.spoolRoot()
        let path = FileManager.default.fileExists(atPath: root.path) ? root.path : root.deletingLastPathComponent().path
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let capacity = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else { return 0 }
        let policy = EPUBStagingArea.SpacePolicy.standard
        return max(0, min(sizeLimit, policy.totalBudget(availableCapacity: capacity), capacity - policy.headroom))
    }
}
