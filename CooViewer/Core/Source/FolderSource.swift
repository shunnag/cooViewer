import CoreGraphics
import Foundation

/// フォルダを本として読む(仕様書 §4.1)。
/// 内容は初期化時に列挙して確定する。不変データのみ保持するため並列アクセス可能で、
/// 画像デコードもページごとに並行実行できる。
final class FolderSource: BookSource {
    let url: URL
    private let pageEntries: [PageEntry]

    var supportsDateSort: Bool { true }
    var supportsParallelPageLoads: Bool { true }

    init(url: URL, readSubFolders: Bool) throws {
        self.url = url
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .creationDateKey, .contentModificationDateKey,
        ]

        var fileURLs: [URL] = []
        if readSubFolders {
            guard let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw BookSourceError.unreadable(url)
            }
            for case let fileURL as URL in enumerator {
                fileURLs.append(fileURL)
            }
        } else {
            fileURLs = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        }

        let basePath = url.standardizedFileURL.path
        var entries: [PageEntry] = []
        for fileURL in fileURLs {
            guard SupportedTypes.isImageFile(fileURL.lastPathComponent) else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }

            let fullPath = fileURL.standardizedFileURL.path
            var relativePath = fullPath.hasPrefix(basePath)
                ? String(fullPath.dropFirst(basePath.count)) : fileURL.lastPathComponent
            if relativePath.hasPrefix("/") { relativePath.removeFirst() }

            entries.append(PageEntry(
                id: entries.count,
                name: fileURL.lastPathComponent,
                pathInBook: relativePath,
                fileURL: fileURL,
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate
            ))
        }
        self.pageEntries = entries
    }

    func entries() async throws -> [PageEntry] {
        pageEntries
    }

    func imageData(for entry: PageEntry) async -> Data? {
        guard let fileURL = entry.fileURL else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        guard let fileURL = entry.fileURL else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        let data = try Data(contentsOf: fileURL)
        return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize)
    }
}
