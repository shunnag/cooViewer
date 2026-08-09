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

    /// 同時読み取りゲート(サムネイルのセル読みも含む全読者に適用)。
    /// HDD のシーク嵐防止と SSD の並列デコードの両立(設計書 キャッシュ節)
    /// EN: Concurrency gate applied to every reader (thumbnail cells included).
    private let readGate = SourceReadGate(limit: MediaProfile.unknown.sourceReadConcurrency)

    func applyMediaProfile(_ profile: MediaProfile) async {
        await readGate.setLimit(profile.sourceReadConcurrency)
    }

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

    func imageSize(for entry: PageEntry) async -> CGSize? {
        // ヘッダ読みは数十 KB の小さな I/O なのでゲートを通さない
        // (フルデコードの代替としては常に軽い)
        // EN: Header reads are tiny; they bypass the gate.
        guard let fileURL = entry.fileURL else { return nil }
        return ImageDecoding.imageSize(at: fileURL)
    }

    func imageData(for entry: PageEntry) async -> Data? {
        guard let fileURL = entry.fileURL else { return nil }
        // アニメーション用の生データ読みも同じゲートを通す(全読者を制御)
        // EN: Animation raw reads honor the same gate (every reader is capped).
        await readGate.acquire()
        let data = try? Data(contentsOf: fileURL)
        await readGate.release()
        return data
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        // EN: Abandoned requests bail out here before doing any I/O.
        guard let fileURL = entry.fileURL else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        // ゲートはディスク I/O のみを絞る。デコード(CPU)はゲート外で行い、
        // 多コアの並列デコードを活かす(HDD でもゲート保持時間が短くなる)
        // EN: The gate caps disk I/O only; decode runs outside so many-core
        // EN: CPUs decode in parallel and the gate is held briefly.
        await readGate.acquire()
        let data: Data
        do {
            try Task.checkCancellation()
            data = try Data(contentsOf: fileURL)
        } catch {
            await readGate.release()
            throw error
        }
        await readGate.release()
        return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize)
    }
}
