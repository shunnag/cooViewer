import CoreGraphics
import Foundation
import PDFKit
import XADMaster

/// 書庫(zip/rar/7z 等)を本として読む(仕様書 §2.4, §4.17)。
/// XADArchive はスレッド安全でないため actor で直列化する。
/// ファイル名エンコーディングは XADMaster + UniversalDetector が自動判定する。
///
/// ネットワークドライブや solid 書庫でも快適に読めるよう、開いた後に
/// バックグラウンドで全ページをローカル一時領域へ逐次展開する(スプール。
/// 設計書「キャッシュ・先読み設計」)。スプール済みページはローカル読みになる。
///
/// 書庫内の書庫/PDF は一時領域へ展開して**子ソース**(ArchiveSource/PDFSource)
/// を生成し、そのページを同じ本に取り込む(仕様書 §2.4 のネスト COImageLoader
/// 相当)。ページの相対パスは「書庫内パス/子の相対パス」になる。
/// EN: Reads an archive as a book via XADMaster, serialized by this actor.
/// EN: Pages are spooled to local temp storage in the background, and nested
/// EN: archives/PDFs are expanded into child sources joined into the same book.
actor ArchiveSource: BookSource {
    nonisolated let url: URL
    private let archive: XADArchive
    /// ネスト段数(0=最上位)。zip 爆弾対策で 3 段目以降は展開しない
    /// EN: Nesting level (0 = top); expansion stops after three levels.
    private let nestingDepth: Int

    /// 最上位書庫の画像エントリ(id=書庫エントリ番号。init で確定)
    /// EN: Image entries of this archive itself (id = archive entry index).
    private let outerImages: [PageEntry]
    /// ネスト候補(書庫/PDF エントリ。entries() で展開する)
    /// EN: Archive/PDF entries to expand lazily in entries().
    private let nestedCandidates: [(index: Int32, path: String)]

    /// ページの所在: 最上位書庫のエントリ番号、または子ソースのページ
    /// EN: Where a page lives: this archive, or a page of a child source.
    private enum PageLocation {
        case outer(entryIndex: Int32)
        case child(sourceIndex: Int, entry: PageEntry)
    }

    /// entries() の組み立て結果(actor 再入で二重構築しないよう Task で共有)
    /// EN: Memoized build task so reentrant callers share one assembly pass.
    private var buildTask: Task<[PageEntry], Never>?
    private var locations: [Int: PageLocation] = [:]
    private var children: [any BookSource] = []
    private var nestedRoot: URL?
    private var password: String?
    /// ネスト書庫/PDF のロック解除係(本の全ネスト階層で共有)
    /// EN: Shared unlocker for encrypted nested children (all nesting levels).
    private let unlocker: NestedUnlocker
    /// 置き場所の速度プロファイル(スプール方針に使う。既定=従来動作)
    /// EN: Volume-speed profile driving the spool policy.
    private var mediaProfile: MediaProfile = .unknown

    private var spoolDirectory: URL?
    private var spooledIDs: Set<Int> = []
    private var spoolTask: Task<Void, Never>?

    /// スプールする合計展開サイズの上限(これを超える書庫はオンデマンドのみ)
    /// EN: Total-size cap for spooling; larger archives stay on-demand only.
    static let defaultSpoolSizeLimit: Int64 = 4 << 30

    /// ネストページの id 基数(最上位のエントリ番号と衝突しない大きさ)
    /// EN: ID stride for nested pages, chosen to avoid outer-index collisions.
    private static let nestedIDStride = 1_000_000

    nonisolated var supportsDateSort: Bool { false }

    /// スプールの置き場所。<pid>-<uuid> のサブディレクトリを掘る
    /// (起動時掃除で生存プロセスのものを残すため。仕様書 §4.17 の残骸問題への対策)。
    /// EN: Spool root; pid-tagged subdirectories let startup cleanup keep
    /// EN: directories that belong to still-running processes.
    nonisolated static func spoolRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cooViewer-spool")
    }

    init(url: URL, nestingDepth: Int = 0, unlocker: NestedUnlocker? = nil) throws {
        self.url = url
        self.nestingDepth = nestingDepth
        self.unlocker = unlocker ?? NestedUnlocker()
        guard let archive = XADArchive(file: url.path) else {
            throw BookSourceError.unreadable(url)
        }
        self.archive = archive

        // 旧実装(XADWrapper)同様、ディレクトリとサイズ 0 のエントリを除外する。
        // 加えて画像以外のファイルと macOS メタデータ(__MACOSX/、._*)も除外する。
        // EN: Skip directories, zero-size entries, non-images and macOS metadata.
        var images: [PageEntry] = []
        var candidates: [(index: Int32, path: String)] = []
        for index in 0..<archive.numberOfEntries() {
            guard let name = archive.name(ofEntry: index) else { continue }
            guard !archive.entryIsDirectory(index), archive.size(ofEntry: index) != 0 else {
                continue
            }
            let lastComponent = (name as NSString).lastPathComponent
            guard !lastComponent.hasPrefix("."), !name.hasPrefix("__MACOSX") else {
                continue
            }
            // ネスト id 域(1M 刻み)との衝突を防ぐ。100 万エントリ超の書庫は
            // 病的ケースなので以降を切り捨てる
            // EN: Guard the nested-id ranges; archives with 1M+ entries are
            // EN: pathological and get truncated here.
            guard index < Int32(Self.nestedIDStride) else { break }
            if SupportedTypes.isImageFile(lastComponent) {
                images.append(PageEntry(
                    id: Int(index),
                    name: lastComponent,
                    pathInBook: name,
                    fileURL: nil,
                    creationDate: nil,
                    modificationDate: nil
                ))
            } else if nestingDepth < 2,
                      SupportedTypes.isBookFile(URL(fileURLWithPath: lastComponent)) {
                candidates.append((index: index, path: name))
            }
        }
        self.outerImages = images
        self.nestedCandidates = candidates
    }

    deinit {
        spoolTask?.cancel()
        let directories = [spoolDirectory, nestedRoot].compactMap(\.self)
        if !directories.isEmpty {
            Task.detached(priority: .utility) {
                for directory in directories {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
    }

    func entries() async throws -> [PageEntry] {
        await buildIfNeeded()
    }

    @discardableResult
    private func buildIfNeeded() async -> [PageEntry] {
        if let buildTask { return await buildTask.value }
        let task = Task { await build() }
        buildTask = task
        return await task.value
    }

    /// 最上位の画像とネスト展開したページを、書庫の列挙順で 1 つの本に組む
    /// EN: Assemble outer images and expanded nested pages in archive order.
    private func build() async -> [PageEntry] {
        var result: [PageEntry] = []
        var imageIterator = outerImages.makeIterator()
        var pendingImage = imageIterator.next()
        var candidateOrdinal = 0
        for index in 0..<archive.numberOfEntries() {
            if let image = pendingImage, image.id == Int(index) {
                locations[image.id] = .outer(entryIndex: index)
                result.append(image)
                pendingImage = imageIterator.next()
                continue
            }
            guard candidateOrdinal < nestedCandidates.count,
                  nestedCandidates[candidateOrdinal].index == index else { continue }
            let candidate = nestedCandidates[candidateOrdinal]
            candidateOrdinal += 1
            await appendNestedPages(of: candidate, ordinal: candidateOrdinal, into: &result)
        }
        return result
    }

    /// ネスト候補 1 つを一時領域へ展開し、子ソースのページを取り込む。
    /// 失敗(壊れた書庫等)はそのエントリを黙って飛ばす(§4.17 の方針)
    /// EN: Extract one nested book and merge its pages; failures are skipped
    /// EN: silently, matching the legacy error policy.
    private func appendNestedPages(of candidate: (index: Int32, path: String),
                                   ordinal: Int, into result: inout [PageEntry]) async {
        guard let fileURL = extractNestedFile(candidate) else { return }
        let child: any BookSource
        if SupportedTypes.isPDF(fileURL) {
            guard let pdf = try? PDFSource(url: fileURL) else { return }
            child = pdf
        } else {
            guard let nested = try? ArchiveSource(
                url: fileURL, nestingDepth: nestingDepth + 1,
                unlocker: unlocker) else { return }
            child = nested
        }
        // 暗号化された子は共有アンロッカーで解除する(既知パスワード→入力依頼)。
        // 解除できない/キャンセルされた子は本から外す(§4.17 の黙殺方針。
        // 恒久的な空セルとして残すより一覧が正直になる)
        // EN: Unlock encrypted children via the shared unlocker (known
        // EN: passwords, then prompt); still-locked children are skipped
        // EN: entirely rather than left as permanently blank pages.
        if await child.isEncrypted() {
            let name = (candidate.path as NSString).lastPathComponent
            guard await unlocker.unlock(child, name: name) else { return }
        }
        guard let childEntries = try? await child.entries(), !childEntries.isEmpty else {
            return
        }
        children.append(child)
        let sourceIndex = children.count - 1
        let idBase = ordinal * Self.nestedIDStride
        for (offset, childEntry) in childEntries.enumerated() {
            // 子のページ数が id 域(1M)を超えたら以降を切り捨てる。
            // 溢れると次のネスト候補の id と衝突し、locations の上書きで
            // 別ページの画像が表示されてしまう(外側の 1M ガードと同じ方針)
            // EN: Cap child pages at the id stride; overflow would collide with
            // EN: the next candidate's id range and swap page images.
            guard offset < Self.nestedIDStride else { break }
            let id = idBase + offset
            locations[id] = .child(sourceIndex: sourceIndex, entry: childEntry)
            result.append(PageEntry(
                id: id,
                name: childEntry.name,
                pathInBook: candidate.path + "/" + childEntry.pathInBook,
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil
            ))
        }
    }

    /// ネスト候補のファイルを一時領域へ書き出す(<pid>-<uuid>-nested/)
    /// EN: Write the nested archive/PDF out to local temp storage.
    private func extractNestedFile(_ candidate: (index: Int32, path: String)) -> URL? {
        if nestedRoot == nil {
            let directory = Self.spoolRoot().appendingPathComponent(
                "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)-nested")
            guard (try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)) != nil else { return nil }
            nestedRoot = directory
        }
        guard let root = nestedRoot,
              let data = archive.contents(ofEntry: candidate.index) else { return nil }
        let fileURL = root.appendingPathComponent(
            "\(candidate.index)-\((candidate.path as NSString).lastPathComponent)")
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return fileURL
    }

    func imageData(for entry: PageEntry) async -> Data? {
        switch locations[entry.id] {
        case .child(let sourceIndex, let childEntry):
            return await children[sourceIndex].imageData(for: childEntry)
        case .outer(let index):
            return spooledData(for: entry.id) ?? archive.contents(ofEntry: index)
        case nil:
            guard let index = Int32(exactly: entry.id) else { return nil }
            return spooledData(for: entry.id) ?? archive.contents(ofEntry: index)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        // EN: Abandoned requests bail out here before touching the archive.
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return try await children[sourceIndex].image(
                for: childEntry, maxPixelSize: maxPixelSize)
        }
        let data: Data
        if let spooled = spooledData(for: entry.id) {
            data = spooled
        } else if let index = Int32(exactly: entry.id),
                  let extracted = archive.contents(ofEntry: index) {
            data = extracted
        } else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize)
    }

    /// ルーペ用。ネストした PDF はベクトルから倍率連動で描き直せるよう子へ委譲する
    /// EN: Loupe path; delegates to children so nested PDFs re-rasterize sharply.
    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return try await children[sourceIndex].loupeImage(
                for: childEntry, pixelScale: pixelScale)
        }
        return try await image(for: entry, maxPixelSize: nil)
    }

    func isEncrypted() async -> Bool {
        archive.isEncrypted()
    }

    func hasSkippedLockedContent() async -> Bool {
        await unlocker.sawSkippedChild
    }

    func attachNestedPasswordProvider(_ provider: NestedPasswordProvider?) async {
        await unlocker.setProvider(provider)
    }

    func applyMediaProfile(_ profile: MediaProfile) async {
        mediaProfile = profile
    }

    /// パスワードを設定し、先頭エントリの展開を試して検証する(仕様書 §4.1.3)。
    /// 画像がなくネスト書庫だけの本でも検証できるよう候補もプローブに使う。
    /// EN: Set and verify the password by test-extracting the first entry;
    /// EN: nested-only books probe the first nested candidate instead.
    func checkAndSetPassword(_ password: String) async -> Bool {
        let probe = outerImages.first.map { Int32($0.id) } ?? nestedCandidates.first?.index
        // 画像も書庫/PDF もない書庫は検証しようがない(=本としては空)。
        // false を返すと正しいパスワードでも「試行超過」になってしまうため通す
        // EN: Nothing to verify (the book is empty anyway); rejecting here would
        // EN: mislabel a correct password as "too many failed attempts".
        guard let probe else { return true }
        archive.setPassword(password)
        guard archive.contents(ofEntry: probe) != nil else { return false }
        self.password = password
        // ネストした子の解除でも再利用できるよう記録する
        // EN: Remember it so nested children can be unlocked with it too.
        await unlocker.addKnown(password)
        return true
    }

    // MARK: - スプール

    /// 全ページのローカル展開を開始する(パスワード解除後に呼ぶこと)。
    /// 書庫順=エントリ順の逐次展開なので、ネットワーク越しでも solid 書庫でも
    /// 最速のアクセスパターンになる。展開中のページ要求は従来経路で応える。
    /// ネスト分は展開時点でローカルファイルになっているため対象外。
    /// EN: Start spooling all outer pages to local temp; sequential archive
    /// EN: order is the fastest pattern for network drives and solid archives.
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async {
        await buildIfNeeded()  // ネスト展開もこの時点で済ませる
        // EN: Nested expansion also happens here (already local afterwards).
        beginSpooling(sizeLimit: spoolSizeLimit)
    }

    func beginSpooling(sizeLimit: Int64) {
        // 高速ローカルボリュームではランダムアクセスが安い形式(zip 系)の
        // スプールを省き、二重書き込みを避ける(設計書 キャッシュ節)
        // EN: Fast local volumes skip spooling for cheap-random-access formats.
        guard mediaProfile.shouldSpoolArchive(fileExtension: url.pathExtension) else {
            return
        }
        guard spoolTask == nil, !outerImages.isEmpty else { return }
        var total: Int64 = 0
        for entry in outerImages {
            total += Int64(archive.size(ofEntry: Int32(entry.id)))
        }
        guard total <= sizeLimit else { return }

        let directory = Self.spoolRoot().appendingPathComponent(
            "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil else { return }
        spoolDirectory = directory

        let ids = outerImages.map(\.id)
        spoolTask = Task { [weak self] in
            for id in ids {
                if Task.isCancelled { return }
                await self?.spoolEntry(id)
                // 表示中のページ要求が割り込めるよう 1 エントリごとに譲る
                // EN: Yield after each entry so on-screen page loads can cut in.
                await Task.yield()
            }
        }
    }

    /// スプール完了を待つ(テスト・診断用)
    /// EN: Await spool completion (tests/diagnostics only).
    func waitForSpoolCompletion() async {
        await spoolTask?.value
    }

    var spooledEntryCount: Int { spooledIDs.count }

    private func spoolEntry(_ id: Int) {
        guard let directory = spoolDirectory, !spooledIDs.contains(id) else { return }
        guard let data = archive.contents(ofEntry: Int32(id)) else { return }
        let fileURL = directory.appendingPathComponent(String(id))
        if (try? data.write(to: fileURL, options: .atomic)) != nil {
            spooledIDs.insert(id)
        }
    }

    private func spooledData(for id: Int) -> Data? {
        guard spooledIDs.contains(id), let directory = spoolDirectory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(String(id)))
    }
}
