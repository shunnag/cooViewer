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

    /// メモリ → ディスク → 生成の順で取得する。
    func thumbnail(for entry: PageEntry, in source: any BookSource,
                   bookKey: String) async -> CGImage? {
        let key = bookKey + "/" + String(entry.id)
        if let hit = memory[key] {
            touch(key)
            return hit
        }

        let fileURL = diskRoot.appendingPathComponent(bookKey)
            .appendingPathComponent("\(entry.id).png")
        if let data = try? Data(contentsOf: fileURL),
           let image = try? ImageDecoding.decode(data) {
            store(image, for: key)
            return image
        }

        guard let image = try? await source.image(
            for: entry, maxPixelSize: Self.maxPixelSize) else { return nil }
        writeToDisk(image, at: fileURL)
        store(image, for: key)
        return image
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

    private func writeToDisk(_ image: CGImage, at fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
