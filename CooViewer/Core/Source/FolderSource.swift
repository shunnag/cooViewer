import CoreGraphics
import Foundation

/// フォルダを本として読む(仕様書 §4.1)。
/// 内容は初期化時に列挙して確定する。不変データのみ保持するため並列アクセス可能で、
/// 画像デコードもページごとに並行実行できる。
/// EN: Reads a folder as a book. The listing is fixed at init and immutable,
/// EN: so pages can be decoded in parallel without locking.
final class FolderSource: BookSource {
    let url: URL
    private let pageEntries: [PageEntry]
    /// フォルダ内の書庫/PDF(旧実装はネスト COImageLoader として本に統合した。
    /// 統合は NestedFolderSource が担い、本クラスは列挙のみ行う)
    /// EN: Archives/PDFs inside the folder; NestedFolderSource merges their
    /// EN: pages into the book (legacy nested-loader behavior).
    let nestedBookCandidates: [(fileURL: URL, relativePath: String)]

    var supportsDateSort: Bool { true }
    var supportsParallelPageLoads: Bool { true }

    /// サブフォルダのどこかに画像があるか(空フォルダ表示のヒント用)。
    /// 最初の 1 件で打ち切り、巨大ツリーでも走査を 2000 項目で止める
    /// EN: Used by the empty-book hint; stops at the first image or 2000 items.
    static func subfoldersContainImages(at url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > 2000 { return false }
            let isDirectory = (try? fileURL.resourceValues(
                forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDirectory, SupportedTypes.isImageFile(fileURL.lastPathComponent) {
                return true
            }
        }
        return false
    }

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

        // 列挙順は FS 依存(特にネットワークボリューム)。id はディスクの
        // サムネイルキャッシュのキーになるため、パス順に固定して安定させる
        // EN: Enumeration order is filesystem-dependent; sort by path so entry
        // EN: ids (which key the disk thumbnail cache) are stable across opens.
        fileURLs.sort { $0.path < $1.path }

        let basePath = url.standardizedFileURL.path
        var entries: [PageEntry] = []
        var candidates: [(fileURL: URL, relativePath: String)] = []
        for fileURL in fileURLs {
            let isImage = SupportedTypes.isImageFile(fileURL.lastPathComponent)
            // 分割書庫の続き巻(.002/.r00 等)は候補にしない(先頭巻から
            // XADMaster がスパンする。続き巻を別の本として数えない)
            // EN: Skip continuation split volumes; the first volume spans them.
            let isBook = SupportedTypes.isBookFile(fileURL)
                && !SupportedTypes.isSplitVolumeContinuation(
                    fileURL.pathExtension.lowercased())
            guard isImage || isBook else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }

            let fullPath = fileURL.standardizedFileURL.path
            var relativePath = fullPath.hasPrefix(basePath)
                ? String(fullPath.dropFirst(basePath.count)) : fileURL.lastPathComponent
            if relativePath.hasPrefix("/") { relativePath.removeFirst() }

            if isImage {
                entries.append(PageEntry(
                    id: entries.count,
                    name: fileURL.lastPathComponent,
                    pathInBook: relativePath,
                    fileURL: fileURL,
                    creationDate: values?.creationDate,
                    modificationDate: values?.contentModificationDate
                ))
            } else {
                candidates.append((fileURL: fileURL, relativePath: relativePath))
            }
        }
        self.pageEntries = entries
        self.nestedBookCandidates = candidates
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
        // EN: Abandoned requests bail out here before doing any I/O.
        guard let fileURL = entry.fileURL else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        let data = try Data(contentsOf: fileURL)
        return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize)
    }
}
