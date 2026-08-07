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

    /// 生成中の共有タスク(重複要求は同じ生成を待つ)
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    /// キーごとの待ち手数。全員がキャンセルで去った生成は、まだ実行に
    /// 入っていなければキャンセルして遠いページの生成を早期に破棄する
    private var waiterCounts: [String: Int] = [:]

    /// メモリ → ディスク → 生成の順で取得する。
    func thumbnail(for entry: PageEntry, in source: any BookSource,
                   bookKey: String) async -> CGImage? {
        let key = bookKey + "/" + String(entry.id)
        if let hit = memory[key] {
            touch(key)
            return hit
        }

        let task: Task<CGImage?, Never>
        if let running = inFlight[key], !running.isCancelled {
            // 進行中の生成に合流(キャンセル済みタスクには合流しない:
            // 先読みの世代交代で待ち手ゼロ→キャンセル直後に新しい要求が
            // 来た場合は作り直す)
            task = running
        } else {
            let fileURL = diskRoot.appendingPathComponent(bookKey)
                .appendingPathComponent("\(entry.id).png")
            // detached: セル側(SwiftUI .task)のキャンセルにもこの actor の
            // 文脈にも縛られない独立タスクとして生成を完走させる
            task = Task.detached(priority: .userInitiated) {
                await Self.loadOrGenerate(entry: entry, source: source, fileURL: fileURL)
            }
            inFlight[key] = task
        }

        waiterCounts[key, default: 0] += 1
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.waiterCancelled(key: key) }
        }
        waiterCounts[key] = max(0, (waiterCounts[key] ?? 1) - 1)
        if waiterCounts[key] == 0 { waiterCounts.removeValue(forKey: key) }
        // 自分の待っていたタスクの登録だけを外す(遅れて終了した旧世代が
        // 新しい生成の登録を消さないように)
        if inFlight[key] == task {
            inFlight[key] = nil
        }
        if let image {
            store(image, for: key)
        }
        return image
    }

    /// 待ち手のキャンセル通知。全員去っていたら生成タスクをキャンセルする
    /// (実行前ならソース側の checkCancellation で脱落し、実行中なら完走する)。
    private func waiterCancelled(key: String) {
        waiterCounts[key] = max(0, (waiterCounts[key] ?? 1) - 1)
        if waiterCounts[key] == 0 {
            waiterCounts.removeValue(forKey: key)
            inFlight[key]?.cancel()
            inFlight.removeValue(forKey: key)  // 新しい要求は作り直す
        }
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
