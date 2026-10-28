import CoreGraphics
import Darwin
import Foundation

/// フォルダを本として読む(仕様書 §4.1)。
/// 内容は初期化時に列挙して確定する。不変データのみ保持するため並列アクセス可能で、
/// 画像デコードもページごとに並行実行できる。
final class FolderSource: BookSource {
    let url: URL
    private let pageEntries: [PageEntry]
    /// フォルダ内の書庫/PDF(旧実装はネスト COImageLoader として本に統合した。
    /// 統合は NestedFolderSource が担い、本クラスは列挙のみ行う)
    let nestedBookCandidates: [(fileURL: URL, relativePath: String)]
    let splitContinuationCandidateIndices: Set<Int>

    /// 撮影用の不変スナップショットは実フォルダや利用者の履歴に触れない(設計書 §7.4)。
    init(snapshotURL: URL, images: [PageEntry], nestedPaths: [String]) {
        url = snapshotURL
        pageEntries = images
        nestedBookCandidates = nestedPaths.map { (snapshotURL.appendingPathComponent($0), $0) }
        splitContinuationCandidateIndices = []
    }

    var supportsDateSort: Bool { true }
    var supportsParallelPageLoads: Bool { true }

    /// 同時読み取りゲート(サムネイルのセル読みも含む全読者に適用)。
    /// HDD のシーク嵐防止と SSD の並列デコードの両立(設計書 キャッシュ節)
    private let readGate = SourceReadGate(limit: MediaProfile.unknown.sourceReadConcurrency)

    func applyMediaProfile(_ profile: MediaProfile) async {
        await readGate.setLimit(profile.sourceReadConcurrency)
    }

    /// フォルダ直下の ComicInfo.xml を read-only で読む(cooViewer-4fi.2)。
    /// 巨大ファイル対策で 16MiB を上限にする(標準のメタデータは数 KB)。
    /// macOS 既定 FS は大小無視なので綴りは標準の "ComicInfo.xml" を使う
    func metadata() async -> ComicInfo? {
        let candidate = url.appendingPathComponent("ComicInfo.xml")
        let size = (try? candidate.resourceValues(
            forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 16 << 20,
              let data = try? Data(contentsOf: candidate) else { return nil }
        return ComicInfo.parse(data)
    }

    /// サブフォルダのどこかに画像があるか(空フォルダ表示のヒント用)。
    /// 最初の 1 件で打ち切り、巨大ツリーでも走査を 2000 項目で止める
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
        // NAS への照会を子ごとに繰り返さず、親で一度だけ調べる。不明なら macOS の既定に合わせる。
        let caseSensitive = (try? url.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
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
        fileURLs.sort { $0.path < $1.path }

        let basePath = url.standardizedFileURL.path
        let fastPrefixes = Self.fastPrefixes(for: url, standardizedBasePath: basePath)
        var entries: [PageEntry] = []
        var candidates: [(fileURL: URL, relativePath: String)] = []
        for fileURL in fileURLs {
            let isImage = SupportedTypes.isImageFile(fileURL.lastPathComponent)
            // 分割書庫の続き巻(.002/.r00 等)は候補にしない(先頭巻から
            // KaitoKit が .z01…zip、.r00/.partN、.001 系の分割巻を処理する。設計書 §2.4)
            let isBook = SupportedTypes.isBookFile(fileURL)
                && !SupportedTypes.isSplitVolumeContinuation(
                    fileURL.pathExtension.lowercased())
            guard isImage || isBook else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }

            let relativePath = Self.relativePath(of: fileURL, fastPrefixes: fastPrefixes,
                                                 standardizedBasePath: basePath).path

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
        // KaitoKit は先頭巻の綴りと桁幅で続きを開くため、ボリュームの名前比較規則に従って照合する。
        // 偶然この命名の別々の単独書庫も続き巻とみなす残余リスクがある。
        // 候補は残し、後続ページの id を保つ(設計書 §2.4)。
        self.splitContinuationCandidateIndices = SupportedTypes.rarPartContinuationIndices(
            in: candidates.map(\.relativePath), caseSensitive: caseSensitive)
    }

    nonisolated static func fastPrefixes(for url: URL, standardizedBasePath: String) -> [String] {
        // NFC 綴りの入力を Foundation が NFD に変える場合、実パス候補だけが検査を通る。
        // この場合も従来経路に戻し、正規化形が異なる入力の永続キーを保つ(設計書 §7.4)。
        guard url.path.utf8.elementsEqual(url.path.decomposedStringWithCanonicalMapping.utf8) else { return [] }
        var paths = [url.path]
        if let resolved = realpath(url.path, nil) {
            paths.append(String(cString: resolved))
            free(resolved)
        }
        // 列挙 URL の実パス表記も受けるが、大小文字・正規化形の違いは従来経路へ戻す(設計書 §7.4)。
        return paths.filter {
            URL(fileURLWithPath: $0).standardizedFileURL.path.utf8.elementsEqual(standardizedBasePath.utf8)
        }
    }

    nonisolated static func relativePath(of fileURL: URL, fastPrefixes: [String],
                                         standardizedBasePath basePath: String)
        -> (path: String, usedFastPath: Bool) {
        let rawPath = fileURL.path
        for prefix in fastPrefixes {
            let directoryPrefix = prefix + "/"
            guard rawPath.utf8.starts(with: directoryPrefix.utf8) else { continue }
            let rest = String(decoding: rawPath.utf8.dropFirst(directoryPrefix.utf8.count), as: UTF8.self)
            guard rest.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { continue }
            return (rest, true)
        }
        // しおり・サムネイルの永続キーは、前提外の URL の従来の癖まで保つ(設計書 §7.4)。
        let fullPath = fileURL.standardizedFileURL.path
        var relativePath = fullPath.hasPrefix(basePath)
            ? String(fullPath.dropFirst(basePath.count)) : fileURL.lastPathComponent
        if relativePath.hasPrefix("/") { relativePath.removeFirst() }
        return (relativePath, false)
    }

    func entries() async throws -> [PageEntry] {
        pageEntries
    }

    func imageSize(for entry: PageEntry) async -> CGSize? {
        // ヘッダ読みは数十 KB の小さな I/O なのでゲートを通さない
        // (フルデコードの代替としては常に軽い)
        guard let fileURL = entry.fileURL else { return nil }
        return ImageDecoding.imageSize(at: fileURL)
    }

    func imageData(for entry: PageEntry) async -> Data? {
        guard let fileURL = entry.fileURL else { return nil }
        // アニメーション用の生データ読みも同じゲートを通す(全読者を制御)
        guard await readGate.acquire() else { return nil }
        let data = try? Data(contentsOf: fileURL)
        await readGate.release()
        return data
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        guard let fileURL = entry.fileURL else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        // ゲートはディスク I/O のみを絞る。デコード(CPU)はゲート外で行い、
        // 多コアの並列デコードを活かす(HDD でもゲート保持時間が短くなる)
        guard await readGate.acquire() else { throw CancellationError() }
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
