import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// サムネイルのメモリ+ディスクキャッシュ(設計書「キャッシュ・先読み設計」)。
/// ディスク側は Caches/jp.coo.cooViewer/Thumbnails/<bookKey>/<entryID>.png。
/// bookKey は本のパス+更新日時+サイズ由来のため、本が更新されればキーごと変わる
/// (旧キーのフォルダは起動時の trimDiskCache で回収する)。
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    static let maxPixelSize = 200

    private var memory: [String: CGImage] = [:]
    private var order: [String] = []
    /// 200px サムネイル(1 枚 ≈ 160KB)換算で 64MB 相当
    private let memoryCountLimit = 400

    private let diskRoot: URL

    init(diskRoot: URL? = nil) {
        self.diskRoot = diskRoot ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.coo.cooViewer/Thumbnails")
    }

    /// 生成中の共有タスクと待ち手数(重複要求は同じ生成を待つ)。
    /// キャンセル/完了の通知は「自分の世代のタスク」に一致する場合のみ作用させ、
    /// キー再利用後の新しい生成を旧世代の遅延通知が壊さないようにする。
    private struct InFlight {
        let task: Task<CGImage?, Never>
        var waiters: Int
    }

    private var inFlight: [String: InFlight] = [:]

    /// メモリ → ディスク → 生成の順で取得する。
    func thumbnail(for entry: PageEntry, in source: any BookSource,
                   bookKey: String) async -> CGImage? {
        let key = bookKey + "/" + String(entry.id)
        if let hit = memory[key] {
            touch(key)
            return hit
        }

        let task: Task<CGImage?, Never>
        if let running = inFlight[key], !running.task.isCancelled {
            // 進行中の生成に合流(キャンセル済みには合流せず作り直す)
            task = running.task
            inFlight[key]?.waiters += 1
        } else {
            let fileURL = diskRoot.appendingPathComponent(bookKey)
                .appendingPathComponent("\(entry.id).png")
            // detached: セル側(SwiftUI .task)のキャンセルにもこの actor の
            // 文脈にも縛られない独立タスクとして生成する
            let generation = Task.detached(priority: .userInitiated) {
                await Self.loadOrGenerate(entry: entry, source: source, fileURL: fileURL)
            }
            task = generation
            inFlight[key] = InFlight(task: generation, waiters: 1)
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.waiterCancelled(key: key, task: task) }
        }
        // キャンセルされた待ち手の分は waiterCancelled 側が処理済み
        if !Task.isCancelled {
            releaseWaiter(key: key, task: task)
        }
        if let image {
            store(image, for: key)
        }
        return image
    }

    /// 待ち手のキャンセル通知。同一世代のタスクで、かつ全員去っていたら
    /// 生成をキャンセルして登録を外す(実行前ならソース側の
    /// checkCancellation で脱落し、実行中なら完走してキャッシュに残る)。
    private func waiterCancelled(key: String, task: Task<CGImage?, Never>) {
        guard var entry = inFlight[key], entry.task == task else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = entry
        }
    }

    /// 通常完了した待ち手の登録解除(同一世代のタスクの場合のみ)
    private func releaseWaiter(key: String, task: Task<CGImage?, Never>) {
        guard var entry = inFlight[key], entry.task == task else { return }
        entry.waiters -= 1
        inFlight[key] = entry.waiters <= 0 ? nil : entry
    }

    /// 古い本のディスクキャッシュを回収する(起動時に呼ぶ)。
    func trimDiskCache(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: diskRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for child in children {
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    // MARK: - 内部

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
    }

    private func store(_ image: CGImage, for key: String) {
        if memory[key] == nil {
            order.append(key)
        } else {
            touch(key)
        }
        memory[key] = image
        while order.count > memoryCountLimit {
            memory.removeValue(forKey: order.removeFirst())
        }
    }

    /// ディスク読取 → ソース生成 → ディスク保存(actor 状態に触れない)
    private static func loadOrGenerate(entry: PageEntry, source: any BookSource,
                                       fileURL: URL) async -> CGImage? {
        // 実行に入る前にキャンセル済みなら何もしない(遠いページの早期破棄)。
        // ソース呼び出しが始まった後は完走させてキャッシュに残す
        guard !Task.isCancelled else { return nil }
        if let data = try? Data(contentsOf: fileURL),
           let image = try? ImageDecoding.decode(data) {
            return image
        }
        guard let image = try? await source.image(
            for: entry, maxPixelSize: maxPixelSize) else { return nil }
        writeToDisk(image, at: fileURL)
        return image
    }

    private static func writeToDisk(_ image: CGImage, at fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
