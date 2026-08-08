import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// サムネイルのメモリ+ディスクキャッシュ(設計書「キャッシュ・先読み設計」)。
/// ディスク側は Caches/jp.coo.cooViewer/Thumbnails-v2/<bookKey>/<entryID>.heic。
/// v2: PNG → HEIC(Apple Silicon のハードウェアエンコード)で 1 枚あたり
/// 約 1/5 のサイズになり、ディスク I/O と使用量を抑える。旧 Thumbnails/ は
/// 起動時に丸ごと削除して作り直す(キャッシュは使い捨て可能なため)。
/// bookKey は本のパス+更新日時+サイズ由来のため、本が更新されればキーごと変わる
/// (旧キーのフォルダは起動時の trimDiskCache で回収する)。
/// EN: Memory + disk thumbnail cache, v2: HEIC (hardware-encoded, ~5x smaller
/// EN: than PNG) under Thumbnails-v2; the legacy PNG cache is deleted at
/// EN: startup and rebuilt. bookKey derives from the book's identity.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    static let maxPixelSize = 200

    private var memory: [String: CGImage] = [:]
    private var order: [String] = []
    /// 200px サムネイル(1 枚 ≈ 160KB)換算で 64MB 相当
    /// EN: About 64 MB worth of 200 px thumbnails.
    private let memoryCountLimit = 400

    /// 生成に失敗したページ(壊れ画像・パスワード付きネスト書庫等)の記録。
    /// これがないと画面に入るたびに毎回展開し直してしまい、solid 書庫や
    /// ネットワークボリュームでは失敗ページ 1 つが延々と CPU/IO を食い続ける。
    /// メモリのみ(セッション内)。本が更新されれば bookKey ごと変わるので解ける。
    /// EN: Negative cache for failed generations (broken pages, locked nested
    /// EN: archives). Without it every screen visit re-extracts the doomed
    /// EN: entry — seconds of CPU per attempt on solid archives. Memory-only.
    private var failedKeys: Set<String> = []
    private var failedOrder: [String] = []
    private let failedCountLimit = 4096

    private let diskRoot: URL

    init(diskRoot: URL? = nil) {
        self.diskRoot = diskRoot ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.coo.cooViewer/Thumbnails-v2")
    }

    /// 生成中の共有タスクと待ち手数(重複要求は同じ生成を待つ)。
    /// キャンセル/完了の通知は「自分の世代のタスク」に一致する場合のみ作用させ、
    /// キー再利用後の新しい生成を旧世代の遅延通知が壊さないようにする。
    /// EN: One shared generation task per key plus a waiter count. Cancel and
    /// EN: release notifications only apply when they match the registered
    /// EN: task, so late notifications from an old generation are ignored.
    private struct InFlight {
        let task: Task<CGImage?, Never>
        var waiters: Int
    }

    private var inFlight: [String: InFlight] = [:]

    /// メモリ → ディスク → 生成の順で取得する。
    /// EN: Lookup order: memory cache, disk cache, then generate from source.
    func thumbnail(for entry: PageEntry, in source: any BookSource,
                   bookKey: String) async -> CGImage? {
        let key = bookKey + "/" + String(entry.id)
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        // 過去に生成失敗したページは再挑戦しない(プレースホルダ表示のまま)
        // EN: Known-failed pages are not retried; the cell keeps its placeholder.
        if failedKeys.contains(key) {
            return nil
        }

        let task: Task<CGImage?, Never>
        if let running = inFlight[key], !running.task.isCancelled {
            // 進行中の生成に合流(キャンセル済みには合流せず作り直す)
            // EN: Join the running generation; never join a cancelled one.
            task = running.task
            inFlight[key]?.waiters += 1
        } else {
            let fileURL = diskRoot.appendingPathComponent(bookKey)
                .appendingPathComponent("\(entry.id).heic")
            // detached: セル側(SwiftUI .task)のキャンセルにもこの actor の
            // 文脈にも縛られない独立タスクとして生成する。優先度は utility に
            // 落とし、ソースの読み取りゲートで表示中ページの読み込み
            // (userInitiated)に道を譲る(低速媒体でのページ表示停滞の防止)
            // EN: Detached so a cancelled SwiftUI cell cannot kill the shared
            // EN: work; utility priority yields the source read gate to
            // EN: interactive page loads on slow media.
            let generation = Task.detached(priority: .utility) {
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
        // EN: Cancelled waiters were already accounted for by waiterCancelled.
        if !Task.isCancelled {
            releaseWaiter(key: key, task: task)
        }
        if let image {
            store(image, for: key)
        } else if !task.isCancelled {
            // キャンセルではなく「実行して失敗」した場合のみ記録する
            // (キャンセルされた生成は次の要求で普通に作り直される)
            // EN: Record only real failures; cancelled generations may retry.
            markFailed(key)
        }
        return image
    }

    /// 待ち手のキャンセル通知。同一世代のタスクで、かつ全員去っていたら
    /// 生成をキャンセルして登録を外す(実行前ならソース側の
    /// checkCancellation で脱落し、実行中なら完走してキャッシュに残る)。
    /// EN: A waiter was cancelled; when the last one leaves, cancel the
    /// EN: generation (not-yet-started work drops, running work completes).
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
    /// EN: Unregister a normally-completed waiter (same-generation task only).
    private func releaseWaiter(key: String, task: Task<CGImage?, Never>) {
        guard var entry = inFlight[key], entry.task == task else { return }
        entry.waiters -= 1
        inFlight[key] = entry.waiters <= 0 ? nil : entry
    }

    /// 旧形式(PNG)のキャッシュディレクトリを丸ごと削除する(起動時に一度)。
    /// キャッシュは使い捨て可能なので変換はせず作り直す
    /// EN: Delete the legacy PNG cache directory outright; caches are
    /// EN: disposable, so we rebuild instead of converting.
    nonisolated static func removeLegacyCacheDirectory() {
        let legacy = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.coo.cooViewer/Thumbnails")
        try? FileManager.default.removeItem(at: legacy)
    }

    /// 古い本のディスクキャッシュを回収する(起動時に呼ぶ)。
    /// EN: Reclaim disk thumbnails of books not opened recently (at launch).
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

    private func markFailed(_ key: String) {
        guard !failedKeys.contains(key) else { return }
        failedKeys.insert(key)
        failedOrder.append(key)
        while failedOrder.count > failedCountLimit {
            failedKeys.remove(failedOrder.removeFirst())
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
    /// EN: Disk read, else generate from source and persist; touches no
    /// EN: actor state so it can run detached.
    private static func loadOrGenerate(entry: PageEntry, source: any BookSource,
                                       fileURL: URL) async -> CGImage? {
        // 実行に入る前にキャンセル済みなら何もしない(遠いページの早期破棄)。
        // ソース呼び出しが始まった後は完走させてキャッシュに残す
        // EN: Bail out only before starting; once source work begins, finish
        // EN: and cache the result.
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
        // HEIC(ハードウェアエンコード)。サムネイル画質は 0.75 で十分
        // EN: HEIC hardware encode; 0.75 quality is plenty for thumbnails.
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        CGImageDestinationFinalize(destination)
    }
}
