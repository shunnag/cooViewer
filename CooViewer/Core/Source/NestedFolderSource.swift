import CoreGraphics
import Foundation

/// フォルダ内の書庫/PDF を子ソースとして同じ本に統合するフォルダの本
/// (仕様書 §2.4 の旧ネスト COImageLoader 相当。フォルダ版)。
/// 画像だけのフォルダは従来どおり FolderSource が担い(並列ロード維持)、
/// 書庫/PDF を含むフォルダのみ本 actor が包む(BookSourceFactory が振り分け)。
/// 旧仕様どおり、ネスト書庫を含む本は日付ソート不可(canSortByDate 規則)。
/// EN: Folder book that merges archives/PDFs inside the folder as child
/// EN: sources (the legacy nested-loader behavior). Plain image folders keep
/// EN: using FolderSource; the factory wraps only folders that contain books.
/// EN: Date sort is disabled, matching the legacy canSortByDate rule.
actor NestedFolderSource: BookSource {
    nonisolated let url: URL
    private let folder: FolderSource
    private let unlocker: NestedUnlocker

    nonisolated var supportsDateSort: Bool { false }
    /// フォルダ画像はゲート制御下で並列。子(書庫/PDF)が全員「いまの状態で
    /// 並列可」のときのみ本全体を並列にする(solid 書庫の巻き戻し防止)
    /// EN: Parallel only while every child currently supports it.
    func currentlySupportsParallelPageLoads() async -> Bool {
        for child in children {
            if await !child.currentlySupportsParallelPageLoads() {
                return false
            }
        }
        return true
    }

    /// ページの所在: フォルダ直下の画像、または子ソースのページ
    /// EN: Where a page lives: the folder itself, or a child source.
    private enum PageLocation {
        case folder(PageEntry)
        case child(sourceIndex: Int, entry: PageEntry)
    }

    private var buildTask: Task<[PageEntry], Never>?
    private var locations: [Int: PageLocation] = [:]
    private var children: [any BookSource] = []
    /// 組み立て進捗(完了した子の数, 子の総数)の通知先。対話的なオープンのみ
    /// 設定される(次の本のバックグラウンド準備では nil のまま)。build は
    /// actor 上で走るため、組み立て途中に後付けされても以降の子から反映される
    /// EN: Assembly-progress callback; only the interactive open sets it, and
    /// EN: build() reads it per child so a mid-build attach takes effect.
    private var assemblyProgress: (@Sendable (Int, Int) -> Void)?
    /// 置き場所の速度プロファイル(フォルダと全子ソースへ配る)
    /// EN: Volume-speed profile propagated to the folder and every child.
    private var mediaProfile: MediaProfile = .unknown

    /// ネストページの id 基数(ArchiveSource と同じ 1M 刻み)
    /// EN: Same 1M id stride as ArchiveSource.
    private static let nestedIDStride = 1_000_000

    init(folder: FolderSource, unlocker: NestedUnlocker? = nil) {
        self.url = folder.url
        self.folder = folder
        self.unlocker = unlocker ?? NestedUnlocker()
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

    /// フォルダの画像と子の本のページを、パス単純順(FolderSource の列挙順)で
    /// 1 冊に組む。ArchiveSource.build と同じ方針。
    /// 子の本(書庫/PDF)のオープンと一覧取得は**並列**(幅 4)で行い、
    /// 大量の書庫を含むフォルダのオープン時間を線形から短縮する。
    /// 登録(id 割当・locations)は従来どおり候補順に直列で行う
    /// EN: Child books open and list in parallel (width 4); registration
    /// EN: stays sequential in candidate order, so ids are unchanged.
    private func build() async -> [PageEntry] {
        let images = (try? await folder.entries()) ?? []
        let candidates = folder.nestedBookCandidates
        let unlocker = unlocker
        let profile = mediaProfile
        var prepared: [Int: (any BookSource, [PageEntry])] = [:]
        if !candidates.isEmpty {
            assemblyProgress?(0, candidates.count)
        }
        await withTaskGroup(of: (Int, (any BookSource, [PageEntry])?).self) { group in
            var next = 0
            func addTask() {
                guard next < candidates.count else { return }
                let ordinal = next
                let candidate = candidates[ordinal]
                next += 1
                group.addTask {
                    (ordinal, await Self.prepareChild(
                        candidate: candidate, unlocker: unlocker, profile: profile))
                }
            }
            for _ in 0..<4 { addTask() }
            while let (ordinal, result) = await group.next() {
                prepared[ordinal] = result
                assemblyProgress?(prepared.count, candidates.count)
                addTask()
            }
        }

        var result: [PageEntry] = []
        var imageIterator = images.makeIterator()
        var pending = imageIterator.next()
        for (position, candidate) in candidates.enumerated() {
            while let image = pending, image.pathInBook < candidate.relativePath {
                appendFolderImage(image, into: &result)
                pending = imageIterator.next()
            }
            if let (child, childEntries) = prepared[position] {
                register(child: child, childEntries: childEntries,
                         candidate: candidate, ordinal: position + 1, into: &result)
            }
        }
        while let image = pending {
            appendFolderImage(image, into: &result)
            pending = imageIterator.next()
        }
        return result
    }

    /// 子の本 1 つを開いて一覧まで取得する(actor 外で並列実行される部分)。
    /// 壊れた子・解除できない子は nil(従来どおり黙って飛ばす)
    /// EN: Open one child and fetch its entries (runs off-actor, in parallel).
    private static func prepareChild(
        candidate: (fileURL: URL, relativePath: String),
        unlocker: NestedUnlocker, profile: MediaProfile
    ) async -> (any BookSource, [PageEntry])? {
        let child: any BookSource
        if SupportedTypes.isPDF(candidate.fileURL) {
            guard let pdf = try? PDFSource(url: candidate.fileURL) else { return nil }
            child = pdf
        } else {
            guard let nested = try? ArchiveSource(
                url: candidate.fileURL, nestingDepth: 1, unlocker: unlocker) else {
                return nil
            }
            child = nested
        }
        if await child.isEncrypted() {
            let name = (candidate.relativePath as NSString).lastPathComponent
            guard await unlocker.unlock(child, name: name) else { return nil }
        }
        guard let childEntries = try? await child.entries(),
              !childEntries.isEmpty else { return nil }
        await child.applyMediaProfile(profile)
        return (child, childEntries)
    }

    private func appendFolderImage(_ image: PageEntry, into result: inout [PageEntry]) {
        // ネスト id 域(1M 刻み)との衝突を防ぐ(ArchiveSource と同じ切り捨て)
        // EN: Same 1M truncation guard as ArchiveSource.
        guard image.id < Self.nestedIDStride else { return }
        locations[image.id] = .folder(image)
        result.append(image)
    }

    /// 準備済みの子を候補順に登録する(id 割当は従来と同一)
    /// EN: Register a prepared child in candidate order (ids unchanged).
    private func register(child: any BookSource, childEntries: [PageEntry],
                          candidate: (fileURL: URL, relativePath: String),
                          ordinal: Int, into result: inout [PageEntry]) {
        children.append(child)
        let sourceIndex = children.count - 1
        let idBase = ordinal * Self.nestedIDStride
        for (offset, childEntry) in childEntries.enumerated() {
            guard offset < Self.nestedIDStride else { break }
            let id = idBase + offset
            locations[id] = .child(sourceIndex: sourceIndex, entry: childEntry)
            result.append(PageEntry(
                id: id,
                name: childEntry.name,
                pathInBook: candidate.relativePath + "/" + childEntry.pathInBook,
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil
            ))
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()
        switch locations[entry.id] {
        case .child(let sourceIndex, let childEntry):
            return try await children[sourceIndex].image(
                for: childEntry, maxPixelSize: maxPixelSize)
        case .folder(let folderEntry):
            return try await folder.image(for: folderEntry, maxPixelSize: maxPixelSize)
        case nil:
            throw BookSourceError.pageLoadFailed(entry.name)
        }
    }

    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return try await children[sourceIndex].loupeImage(
                for: childEntry, pixelScale: pixelScale)
        }
        return try await image(for: entry, maxPixelSize: nil)
    }

    func imageSize(for entry: PageEntry) async -> CGSize? {
        switch locations[entry.id] {
        case .child(let sourceIndex, let childEntry):
            return await children[sourceIndex].imageSize(for: childEntry)
        case .folder(let folderEntry):
            return await folder.imageSize(for: folderEntry)
        case nil:
            return nil
        }
    }

    func imageData(for entry: PageEntry) async -> Data? {
        switch locations[entry.id] {
        case .child(let sourceIndex, let childEntry):
            return await children[sourceIndex].imageData(for: childEntry)
        case .folder(let folderEntry):
            return await folder.imageData(for: folderEntry)
        case nil:
            return nil
        }
    }

    /// 子の書庫のスプールを開始する(ネットワークボリューム上のフォルダ対策)。
    /// 上限はスプールし得る子(書庫)の数で等分し、フォルダ全体で
    /// spoolSizeLimit を超えないようにする。PDF 等はスプールしないため数えない
    /// EN: Start child spooling with the budget split across ARCHIVE children
    /// EN: only (PDFs never spool and must not dilute the budget).
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async {
        await buildIfNeeded()
        let archiveChildren = children.compactMap { $0 as? ArchiveSource }
        guard !archiveChildren.isEmpty else { return }
        let perChild = spoolSizeLimit / Int64(archiveChildren.count)
        for child in archiveChildren {
            await child.beginBackgroundPreparation(spoolSizeLimit: perChild)
        }
    }

    func hasSkippedLockedContent() async -> Bool {
        await unlocker.sawSkippedChild
    }

    func attachNestedPasswordProvider(_ provider: NestedPasswordProvider?) async {
        await unlocker.setProvider(provider)
    }

    func setAssemblyProgressHandler(
        _ handler: (@Sendable (Int, Int) -> Void)?) {
        assemblyProgress = handler
    }

    /// ページの実体ファイル: フォルダ直下の画像はその画像、子の本のページは
    /// その書庫/PDF ファイル(Finder 表示・ファイル情報用)
    /// EN: Folder pages map to their image file, child pages to the child
    /// EN: archive/PDF file (used by Show in Finder / File Info).
    func containerFileURL(for entry: PageEntry) async -> URL {
        await buildIfNeeded()
        switch locations[entry.id] {
        case .child(let sourceIndex, _):
            return children[sourceIndex].url
        case .folder(let folderEntry):
            return folderEntry.fileURL ?? url
        case nil:
            return url
        }
    }

    /// プロファイルはフォルダ(読み取りゲート)と、生成済み/今後生成される
    /// 子ソース(書庫のスプール方針)の両方へ配る
    /// EN: Forward the profile to the folder gate and to all children,
    /// EN: existing and future.
    func applyMediaProfile(_ profile: MediaProfile) async {
        mediaProfile = profile
        await folder.applyMediaProfile(profile)
        for child in children {
            await child.applyMediaProfile(profile)
        }
    }
}
