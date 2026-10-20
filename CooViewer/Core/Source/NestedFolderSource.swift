import CoreGraphics
import Foundation
import Washi

/// フォルダ内の書庫/PDF を子ソースとして同じ本に統合するフォルダの本
/// (仕様書 §2.4 の旧ネスト COImageLoader 相当。フォルダ版)。
/// 画像だけのフォルダは従来どおり FolderSource が担い(並列ロード維持)、
/// 書庫/PDF を含むフォルダのみ本 actor が包む(BookSourceFactory が振り分け)。
/// 旧仕様どおり、ネスト書庫を含む本は日付ソート不可(canSortByDate 規則)。
actor NestedFolderSource: BookSource {
    nonisolated let url: URL
    private let folder: FolderSource
    nonisolated let unlocker: NestedUnlocker
    /// コレクション内の各書庫も本を開いた時点の選択で揃える(設計書 §2.4)。
    private let preferredEngine: ArchiveEngineKind
    private let engineFactory: ArchiveEngineFactory
    private let retryPolicy: AssemblyRetryPolicy

    nonisolated var supportsDateSort: Bool { false }
    /// フォルダ画像はゲート制御下で並列。子(書庫/PDF)が全員「いまの状態で
    /// 並列可」のときのみ本全体を並列にする(solid 書庫の巻き戻し防止)
    func currentlySupportsParallelPageLoads() async -> Bool {
        for child in children {
            if await !child.currentlySupportsParallelPageLoads() {
                return false
            }
        }
        return true
    }

    /// ページの所在: フォルダ直下の画像、または子ソースのページ
    private enum PageLocation {
        case folder(PageEntry)
        case child(sourceIndex: Int, entry: PageEntry)
    }

    private var buildTask: (task: Task<[PageEntry], any Error>, id: UUID)?
    private var locations: [Int: PageLocation] = [:]
    private var children: [any BookSource] = []
    private typealias PreparedChild = AssemblyPreparedChild
    private struct CandidateIdentity: Equatable {
        let url: URL
        let path: String
    }
    // 失敗した再構築でも、同じ候補列の成功子は読み直さない(設計書 §2.4、§7.4)。
    private var preparedCandidateIdentity: [CandidateIdentity] = []
    private var preparedChildren: [Int: PreparedChild] = [:]
    private var excludedOrdinals: Set<Int> = []
    private var skippedOrdinals: Set<Int> = []
    private var preparedImages: [PageEntry] = []
    private var lastAssemblyFailure: AssemblyFailure?
    private var hasPageList = false
    private(set) var cardChildren: [UnreadableVolumeMarker] = []

    var canOpenPartial: Bool {
        lastAssemblyFailure?.volumeUnavailable == false
            && (!preparedImages.isEmpty || preparedChildren.values.contains { !$0.entries.isEmpty })
    }
    private var assemblyRetry: (@Sendable (String) -> Void)?
    /// 組み立て進捗(完了した子の数, 子の総数)の通知先。対話的なオープンのみ
    /// 設定される(次の本のバックグラウンド準備では nil のまま)。build は
    /// actor 上で走るため、組み立て途中に後付けされても以降の子から反映される
    private var assemblyProgress: (@Sendable (Int, Int) -> Void)?
    /// 置き場所の速度プロファイル(フォルダと全子ソースへ配る)
    private var mediaProfile: MediaProfile = .unknown

    /// ネストページの id 基数(ArchiveSource と同じ 1M 刻み)
    static let nestedIDStride = 1_000_000

    static func acceptsPageOffset(_ offset: Int) -> Bool { offset >= 0 && offset < nestedIDStride - 1 }

    static func realPageID(ordinal: Int, offset: Int) -> Int? {
        guard acceptsPageOffset(offset) else { return nil }
        return ordinal * nestedIDStride + offset
    }

    init(folder: FolderSource, unlocker: NestedUnlocker? = nil,
         preferredEngine: ArchiveEngineKind = .kaitokit,
         engineFactory: ArchiveEngineFactory = .live,
         retryPolicy: AssemblyRetryPolicy = .default) {
        self.url = folder.url
        self.folder = folder
        self.unlocker = unlocker ?? NestedUnlocker()
        self.preferredEngine = preferredEngine
        self.engineFactory = engineFactory
        self.retryPolicy = retryPolicy
    }

    func entries() async throws -> [PageEntry] {
        try await buildIfNeeded()
    }

    /// 同意した今回だけ保持済み結果を使う。完全版のキャッシュへは載せない(設計書 §7.4、§2.4)。
    func partialEntries() async throws -> [PageEntry] {
        guard buildTask == nil, canOpenPartial, let failure = lastAssemblyFailure else {
            throw BookSourceError.unreadable(url)
        }
        return assemble(images: preparedImages, failure: failure)
    }

    /// コレクションフォルダ直下の ComicInfo.xml を FolderSource へ委譲して読む
    /// (cooViewer-oo6)。子ごとの集約はしない(フォルダ単位のメタデータのみ)
    func metadata() async -> ComicInfo? {
        await folder.metadata()
    }

    @discardableResult
    private func buildIfNeeded() async throws -> [PageEntry] {
        let running: (task: Task<[PageEntry], any Error>, id: UUID)
        if let buildTask { running = buildTask }
        else {
            let id = UUID()
            running = (Task { try await build(id: id) }, id)
            buildTask = running
        }
        do { return try await running.task.value }
        catch {
            // 合流した古い失敗の後始末が、既に始まった新しい構築を壊さない。
            if buildTask?.id == running.id {
                buildTask = nil
                lastAssemblyFailure = SourceReadFailure.assemblyFailure(in: error)
            }
            throw error
        }
    }

    /// フォルダの画像と子の本のページを、パス単純順(FolderSource の列挙順)で
    /// 1 冊に組む。ArchiveSource.build と同じ方針。
    /// 子の本(書庫/PDF)のオープンと一覧取得は**並列**(幅 4)で行い、
    /// 大量の書庫を含むフォルダのオープン時間を線形から短縮する。
    /// 登録(id 割当・locations)は従来どおり候補順に直列で行う
    private func build(id: UUID) async throws -> [PageEntry] {
        let images = try await folder.entries()
        preparedImages = images
        let candidates = folder.nestedBookCandidates
        let unlocker = unlocker
        let profile = mediaProfile
        let preferredEngine = preferredEngine
        let engineFactory = engineFactory
        let policy = retryPolicy
        let identity = candidates.map { CandidateIdentity(url: $0.fileURL, path: $0.relativePath) }
        if identity != preparedCandidateIdentity {
            preparedChildren.removeAll()
            excludedOrdinals.removeAll()
            skippedOrdinals.removeAll()
            preparedCandidateIdentity = identity
        }
        let pendingCandidates = candidates.indices.filter {
            preparedChildren[$0] == nil && !excludedOrdinals.contains($0) && !skippedOrdinals.contains($0)
        }.map { AssemblyCandidate(ordinal: $0, relativePath: candidates[$0].relativePath,
                                  url: candidates[$0].fileURL) }
        _ = try await AssemblyPreparation.run(
            candidates: pendingCandidates, total: candidates.count, sourceURL: url, lanes: 4, policy: policy,
            onRetry: { path in await self.notifyAssemblyRetry(path, buildID: id) },
            onProgress: { done, total in await self.notifyAssemblyProgress(done, total: total, buildID: id) },
            onComplete: { ordinal, child in await self.keepPrepared(child, ordinal: ordinal, buildID: id) }) { candidate in
                try await Self.prepareChild(
                    candidate: (candidate.url, candidate.relativePath), unlocker: unlocker, profile: profile,
                    preferredEngine: preferredEngine, engineFactory: engineFactory, retryPolicy: policy)
            }
        guard buildTask?.id == id else { throw CancellationError() }

        lastAssemblyFailure = nil
        return assemble(images: images, failure: nil)
    }

    private func assemble(images: [PageEntry], failure: AssemblyFailure?) -> [PageEntry] {
        let candidates = folder.nestedBookCandidates
        locations.removeAll()
        children.removeAll()
        cardChildren.removeAll()
        hasPageList = true
        var result: [PageEntry] = []
        var imageIterator = images.makeIterator()
        var pending = imageIterator.next()
        for (position, candidate) in candidates.enumerated() {
            while let image = pending, image.pathInBook < candidate.relativePath {
                appendFolderImage(image, into: &result)
                pending = imageIterator.next()
            }
            if let prepared = preparedChildren[position] {
                register(child: prepared.source, childEntries: prepared.entries,
                         candidate: candidate, ordinal: position + 1, into: &result)
            } else if let failure, !excludedOrdinals.contains(position), !skippedOrdinals.contains(position) {
                let marker = UnreadableVolumeMarker(relativePath: candidate.relativePath,
                    cause: failure.failures.first { $0.relativePath == candidate.relativePath }?.cause)
                cardChildren.append(marker)
                result.append(PageEntry(id: (position + 1) * Self.nestedIDStride + (Self.nestedIDStride - 1),
                    name: candidate.fileURL.lastPathComponent, pathInBook: candidate.relativePath,
                    fileURL: nil, creationDate: nil,
                    modificationDate: nil, unreadableVolume: marker))
            }
        }
        while let image = pending {
            appendFolderImage(image, into: &result)
            pending = imageIterator.next()
        }
        return result
    }

    /// 子の本 1 つを開いて一覧まで取得する(actor 外で並列実行される部分)。
    /// 破損・解除不能だけを除外に数え、意図的な省略とは区別する(仕様書 §4.17、設計書 §7.4)。
    private static func prepareChild(
        candidate: (fileURL: URL, relativePath: String),
        unlocker: NestedUnlocker, profile: MediaProfile,
        preferredEngine: ArchiveEngineKind, engineFactory: ArchiveEngineFactory,
        retryPolicy: AssemblyRetryPolicy
    ) async throws -> AssemblyChildPreparation {
        do {
            return try await prepareReadableChild(candidate: candidate, unlocker: unlocker,
                profile: profile, preferredEngine: preferredEngine, engineFactory: engineFactory,
                retryPolicy: retryPolicy)
        } catch {
            if SourceReadFailure.mustPropagate(error) { throw error }
            return .excluded
        }
    }

    private static func prepareReadableChild(
        candidate: (fileURL: URL, relativePath: String),
        unlocker: NestedUnlocker, profile: MediaProfile,
        preferredEngine: ArchiveEngineKind, engineFactory: ArchiveEngineFactory,
        retryPolicy: AssemblyRetryPolicy
    ) async throws -> AssemblyChildPreparation {
        // コレクション内の子はディスク上の実ファイルなので、保存キーは
        // 正規化した実パス — 単体で同じ zip を開いたときと同一キーになり、
        // 保存パスワードが両経路で共有される(設計書 §2.4)
        let childKey = PasswordVault.Key.file(path: candidate.fileURL.path)
        let child: any BookSource
        if SupportedTypes.isPDF(candidate.fileURL) {
            child = try PDFSource(url: candidate.fileURL)
        } else if SupportedTypes.isEPUB(candidate.fileURL) {
            // コレクションの子 EPUB は一度だけ解析し、その Publication と画像のみ
            // 判定結果を子ソースへ渡す(cooViewer-oxr.42/44、設計書 §2.4)。
            let publication = try await EPUBStagingArea.shared.openPublication(at: candidate.fileURL)
            guard !publication.isDRMProtected else { return .skipped }
            if publication.isFixedLayout {
                let epub = try EPUBSource(
                    publication: publication, url: candidate.fileURL,
                    precomputedImageOnlyPageInfos: nil)
                child = epub
            } else if let infos = EPUBImageOnlyHeuristic.imageOnlyPageInfos(publication) {
                let epub = try EPUBSource(
                    publication: publication, url: candidate.fileURL,
                    precomputedImageOnlyPageInfos: infos)
                child = epub
            } else {
                // 通常のリフローは表紙 1 ページの代理エントリで組み込む。
                child = ReflowEPUBPlaceholderSource(
                    validatedReflowPublication: publication,
                    url: candidate.fileURL)
            }
        } else {
            let nested = try ArchiveSource(
                url: candidate.fileURL, nestingDepth: 1, unlocker: unlocker,
                persistenceKey: childKey, preferredEngine: preferredEngine,
                engineFactory: engineFactory, retryPolicy: retryPolicy)
            child = nested
        }
        let encrypted = await child.isEncrypted()
        try Task.checkCancellation()
        if encrypted {
            let name = (candidate.relativePath as NSString).lastPathComponent
            try Task.checkCancellation()
            guard try await unlocker.unlockForAssembly(child, name: name,
                                        persistenceKey: childKey) else { return .excluded }
        }
        let childEntries = try await AssemblyPreparation.entriesForOwnedChild(child)
        guard !childEntries.isEmpty else {
            return await child.excludedChildCount() > 0 ? .excluded : .skipped
        }
        await child.applyMediaProfile(profile)
        return .ready(AssemblyPreparedChild(source: child, entries: childEntries,
                                            excludedCount: await child.excludedChildCount()))
    }

    private func appendFolderImage(_ image: PageEntry, into result: inout [PageEntry]) {
        // ネスト id 域(1M 刻み)との衝突を防ぐ(ArchiveSource と同じ切り捨て)
        guard image.id < Self.nestedIDStride else { return }
        locations[image.id] = .folder(image)
        result.append(image)
    }

    /// 準備済みの子を候補順に登録する(id 割当は従来と同一)
    private func register(child: any BookSource, childEntries: [PageEntry],
                          candidate: (fileURL: URL, relativePath: String),
                          ordinal: Int, into result: inout [PageEntry]) {
        children.append(child)
        let sourceIndex = children.count - 1
        for (offset, childEntry) in childEntries.enumerated() {
            // 末尾 ID は欠落カード専用に予約し、画像キャッシュとの衝突を防ぐ(設計書 §7.4)。
            guard let id = Self.realPageID(ordinal: ordinal, offset: offset) else { break }
            locations[id] = .child(sourceIndex: sourceIndex, entry: childEntry)
            result.append(PageEntry(
                id: id,
                name: childEntry.name,
                pathInBook: candidate.relativePath + "/" + childEntry.pathInBook,
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil,
                reflowEPUBURL: childEntry.reflowEPUBURL  // 代理ページ印を保つ
            ))
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()
        if let marker = entry.unreadableVolume {
            guard let image = await PlaceholderImage.make(text: marker.message, fittingLines: true) else {
                throw BookSourceError.pageLoadFailed(entry.name)
            }
            return image
        }
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
        if entry.unreadableVolume != nil { return CGSize(width: 700, height: 1000) }
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

    /// 代理エントリを持つ子へだけ問い合わせ、コレクション入場時の再解析を
    /// 避ける。子側が更新日時とサイズを再検証する(cooViewer-oxr.42、設計書 §2.4)。
    func preparsedReflowPublication(for candidateURL: URL) async
        -> EPUBPublication? {
        if !hasPageList { guard (try? await buildIfNeeded()) != nil else { return nil } }
        let target = CanonicalPath.normalize(candidateURL.path)
        for location in locations.values {
            guard case .child(let sourceIndex, let childEntry) = location,
                  let childURL = childEntry.reflowEPUBURL,
                  CanonicalPath.normalize(childURL.path) == target else { continue }
            return await children[sourceIndex].preparsedReflowPublication(
                for: candidateURL)
        }
        return nil
    }

    /// フォルダ合本では現在ページの子だけへ問い合わせ、直下画像には実装名を付けない。
    func archiveEngineKind(for entry: PageEntry) async -> ArchiveEngineKind? {
        if !hasPageList { guard (try? await buildIfNeeded()) != nil else { return nil } }
        guard case .child(let sourceIndex, let childEntry) = locations[entry.id] else {
            return nil
        }
        return await children[sourceIndex].archiveEngineKind(for: childEntry)
    }

    /// 子の書庫のスプールを開始する(ネットワークボリューム上のフォルダ対策)。
    /// 上限はスプールし得る子(書庫)の数で等分し、フォルダ全体で
    /// spoolSizeLimit を超えないようにする。PDF 等はスプールしないため数えない
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async {
        if !hasPageList { guard (try? await buildIfNeeded()) != nil else { return } }
        let archiveChildren = children.compactMap { $0 as? ArchiveSource }
        guard !archiveChildren.isEmpty else { return }
        // カードの書庫分だけ枠を予約し、スプールしない除外・省略巻で完全版の配分を減らさない(設計書 §7.4、§2.4、仕様書 §4.17)。
        let archiveCardCount = cardChildren.filter {
            SupportedTypes.isArchive(url.appendingPathComponent($0.relativePath))
        }.count
        let perChild = spoolSizeLimit / Int64(archiveChildren.count + archiveCardCount)
        for child in archiveChildren {
            await child.beginBackgroundPreparation(spoolSizeLimit: perChild)
        }
    }

    /// 合本内の準備完了を実時間の待機なしで観測する診断口(設計書 §2.4、§7.4)。
    func waitForSpoolCompletion() async -> Int {
        let archives = children.compactMap { $0 as? ArchiveSource }
        var count = 0
        for archive in archives {
            await archive.waitForSpoolCompletion()
            count += await archive.spooledEntryCount
        }
        return count
    }

    func hasSkippedLockedContent() async -> Bool {
        await unlocker.sawSkippedChild
    }

    func excludedChildCount() async -> Int {
        var count = excludedOrdinals.count
        for child in preparedChildren.values { count += child.excludedCount }
        return count
    }

    private func keepPrepared(_ child: AssemblyChildPreparation, ordinal: Int, buildID: UUID) {
        // 打ち切った世代の遅い結果で新しい構築を汚さない(設計書 §7.4)。
        guard buildTask?.id == buildID else { return }
        switch child {
        case .ready(let prepared): preparedChildren[ordinal] = prepared
        case .excluded: excludedOrdinals.insert(ordinal)
        case .skipped: skippedOrdinals.insert(ordinal)
        }
    }

    private func notifyAssemblyProgress(_ done: Int, total: Int, buildID: UUID) {
        guard buildTask?.id == buildID else { return }
        assemblyProgress?(done, total)
    }

    private func notifyAssemblyRetry(_ path: String, buildID: UUID) {
        guard buildTask?.id == buildID else { return }
        assemblyRetry?(path)
    }

    func setAssemblyRetryHandler(_ handler: (@Sendable (String) -> Void)?) async {
        assemblyRetry = handler
    }

    /// フォルダ自体は暗号化されないが、組み立て時に暗号化された子(書庫/PDF)を
    /// 解除して束ねていれば、復号済み保護コンテンツを含む本になる(CWE-312)。
    /// 判定は子の解除が終わる build 後に確定する
    func containsProtectedContent() async -> Bool {
        if !hasPageList { guard (try? await buildIfNeeded()) != nil else { return true } }
        return await unlocker.sawUnlockedChild
    }

    func attachNestedPasswordProvider(_ provider: NestedPasswordProvider?) async {
        await unlocker.setProvider(provider)
    }

    func notePasswordSaveConsent(_ password: String) async {
        await unlocker.noteSaveConsent(password)
    }

    func setAssemblyProgressHandler(
        _ handler: (@Sendable (Int, Int) -> Void)?) async {
        assemblyProgress = handler
    }

    /// ページの実体ファイル: フォルダ直下の画像はその画像、子の本のページは
    /// その書庫/PDF ファイル(Finder 表示・ファイル情報用)
    func containerFileURL(for entry: PageEntry) async -> URL {
        if let marker = entry.unreadableVolume { return url.appendingPathComponent(marker.relativePath) }
        if !hasPageList { guard (try? await buildIfNeeded()) != nil else { return url } }
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
    func applyMediaProfile(_ profile: MediaProfile) async {
        mediaProfile = profile
        await folder.applyMediaProfile(profile)
        for child in preparedChildren.values {
            await child.source.applyMediaProfile(profile)
        }
    }
}

extension NestedFolderSource {
    static func syntheticFailure() async -> (NestedFolderSource, AssemblyFailure) {
        let url = URL(fileURLWithPath: "/synthetic/図面集")
        let paths = (1...5).map { String(format: "A-%03d.zip", $0) }
        let source = NestedFolderSource(folder: FolderSource(snapshotURL: url, images: [], nestedPaths: paths))
        let failure = await source.prepareSynthetic(paths: paths)
        return (source, failure)
    }

    private func prepareSynthetic(paths: [String]) -> AssemblyFailure {
        for ordinal in [0, 2, 4] {
            let child = SyntheticCollectionVolume(url: url.appendingPathComponent(paths[ordinal]))
            preparedChildren[ordinal] = AssemblyPreparedChild(source: child,
                entries: child.pages, excludedCount: 0)
        }
        let failure = AssemblyFailure(failures: [1, 3].map { ordinal in
            ChildReadFailure(relativePath: paths[ordinal], url: url.appendingPathComponent(paths[ordinal]),
                cause: ordinal == 1 ? .accessDenied : .connectionLost, retryClass: .persistent)
        }, total: 5, sourceURL: url)
        lastAssemblyFailure = failure
        return failure
    }
}

private struct SyntheticCollectionVolume: BookSource {
    let url: URL
    let supportsDateSort = false
    var pages: [PageEntry] {
        [PageEntry(id: 0, name: "001.png", pathInBook: "001.png", fileURL: nil,
                   creationDate: nil, modificationDate: nil)]
    }
    func entries() async throws -> [PageEntry] { pages }
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        guard let image = await PlaceholderImage.make(text: url.lastPathComponent) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return image
    }
}
