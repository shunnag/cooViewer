import CoreGraphics
import Foundation
import os
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

    nonisolated func prefetchVolumeKey(for entry: PageEntry) -> Int { entry.id / Self.nestedIDStride }

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

    func currentlySupportsParallelPageLoads(forEntryIDs ids: [Int]) async -> Bool {
        var seen: Set<Int> = []
        // await 中の再組み立てで children の添字が変わるため、先に子の参照を確保する(設計書 §7.4)。
        let sources: [any BookSource] = ids.compactMap { id in
            guard case .child(let index, _) = locations[id], seen.insert(index).inserted else { return nil }
            return children[index]
        }
        for child in sources {
            if await !child.currentlySupportsParallelPageLoads() { return false }
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
    private var spoolLimit: Int64?
    private var preparationStarted = false
    private var collectionSpoolBudget: Int64 = 0
    private var mediaProfileApplied = false
    private var windowTask: Task<Void, Never>?
    private var window: [ObjectIdentifier] = []
    private var windowChildren: [ArchiveSource] = []
    private var positionKnown = false
    private var readingPositionSequence: UInt64 = 0
    private var readingForward = true
    private var windowGeneration = UUID()
    private nonisolated let windowEpoch = OSAllocatedUnfairLock(initialState: UUID())
    private var activeWindowChild: ArchiveSource?
    private var spooledChildren: [ObjectIdentifier: ArchiveSource] = [:]
    private var spoolLRU: [ObjectIdentifier] = []

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
    @TaskLocal static var testingAssemblyLanes: Int?

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
    /// 子の本(書庫/PDF)のオープンと一覧取得は媒体に応じた幅で並列に行い、
    /// 大量の書庫を含むフォルダのオープン時間を線形から短縮する。
    /// 登録(id 割当・locations)は従来どおり候補順に直列で行う
    private func build(id: UUID) async throws -> [PageEntry] {
        let images = try await folder.entries()
        preparedImages = images
        let candidates = folder.nestedBookCandidates
        let unlocker = unlocker
        let profile = mediaProfile
        let spoolLimit = spoolLimit
        let profileApplied = mediaProfileApplied
        let lanes = Self.testingAssemblyLanes ?? profile.collectionAssemblyLanes
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
        skippedOrdinals.formUnion(folder.splitContinuationCandidateIndices)
        let pendingCandidates = candidates.indices.filter {
            preparedChildren[$0] == nil && !excludedOrdinals.contains($0) && !skippedOrdinals.contains($0)
        }.map { AssemblyCandidate(ordinal: $0, relativePath: candidates[$0].relativePath,
                                  url: candidates[$0].fileURL) }
        _ = try await AssemblyPreparation.run(
            candidates: pendingCandidates, total: candidates.count, sourceURL: url, lanes: lanes, policy: policy,
            excludePermanentChildFailures: true,
            onRetry: { path in await self.notifyAssemblyRetry(path, buildID: id) },
            onProgress: { done, total in await self.notifyAssemblyProgress(done, total: total, buildID: id) },
            onComplete: { ordinal, child in await self.keepPrepared(child, ordinal: ordinal, buildID: id) }) { candidate in
                try await Self.prepareChild(
                    candidate: (candidate.url, candidate.relativePath), unlocker: unlocker, profile: profile, spoolLimit: spoolLimit, profileApplied: profileApplied,
                    preferredEngine: preferredEngine, engineFactory: engineFactory, retryPolicy: policy)
            }
        guard buildTask?.id == id else { throw CancellationError() }

        lastAssemblyFailure = nil
        return assemble(images: images, failure: nil)
    }

    private func assemble(images: [PageEntry], failure: AssemblyFailure?) -> [PageEntry] {
        let candidates = folder.nestedBookCandidates
        let causes = Dictionary((failure?.failures ?? []).map { ($0.relativePath, $0.cause) },
                                uniquingKeysWith: { first, _ in first })
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
            } else if failure != nil, !excludedOrdinals.contains(position), !skippedOrdinals.contains(position) {
                let marker = UnreadableVolumeMarker(relativePath: candidate.relativePath,
                    cause: causes[candidate.relativePath])
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
    /// 破損・解除不能・恒久的な子の失敗を除外に数え、意図的な省略とは区別する(仕様書 §4.17、設計書 §7.4)。
    private static func prepareChild(
        candidate: (fileURL: URL, relativePath: String),
        unlocker: NestedUnlocker, profile: MediaProfile, spoolLimit: Int64?, profileApplied: Bool,
        preferredEngine: ArchiveEngineKind, engineFactory: ArchiveEngineFactory,
        retryPolicy: AssemblyRetryPolicy
    ) async throws -> AssemblyChildPreparation {
        do {
            return try await prepareReadableChild(candidate: candidate, unlocker: unlocker,
                profile: profile, spoolLimit: spoolLimit, profileApplied: profileApplied, preferredEngine: preferredEngine, engineFactory: engineFactory,
                retryPolicy: retryPolicy)
        } catch {
            if SourceReadFailure.mustPropagate(error) { throw error }
            return .excluded
        }
    }

    private static func prepareReadableChild(
        candidate: (fileURL: URL, relativePath: String),
        unlocker: NestedUnlocker, profile: MediaProfile, spoolLimit: Int64?, profileApplied: Bool,
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
        if let spoolLimit { await child.configureSpooling(sizeLimit: spoolLimit) }
        if profileApplied { await child.applyMediaProfile(profile) }
        let childEntries = try await AssemblyPreparation.entriesForOwnedChild(child)
        guard !childEntries.isEmpty else {
            return await child.excludedChildCount() > 0 ? .excluded : .skipped
        }
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
            let child = children[sourceIndex]
            await prepareDisplayChild(at: sourceIndex)
            // 合本の開始・登録を通さず子だけが表示スプールを始めることを防ぐ。
            return try await PageRequestIntent.$isDisplay.withValue(false) {
                try await child.image(for: childEntry, maxPixelSize: maxPixelSize)
            }
        case .folder(let folderEntry):
            return try await folder.image(for: folderEntry, maxPixelSize: maxPixelSize)
        case nil:
            throw BookSourceError.pageLoadFailed(entry.name)
        }
    }

    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            let child = children[sourceIndex]
            await prepareDisplayChild(at: sourceIndex)
            return try await PageRequestIntent.$isDisplay.withValue(false) {
                try await child.loupeImage(for: childEntry, pixelScale: pixelScale)
            }
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
            let child = children[sourceIndex]
            await prepareDisplayChild(at: sourceIndex)
            return await PageRequestIntent.$isDisplay.withValue(false) {
                await child.imageData(for: childEntry)
            }
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

    /// 等分せず、読んでいる子と隣の子へ全予算を順に回す(cooViewer-tg48、設計書 §5)。
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async {
        if !hasPageList { guard (try? await buildIfNeeded()) != nil else { return } }
        let wasPreparing = preparationStarted
        let changed = updateSpoolLimit(spoolSizeLimit)
        preparationStarted = true
        if !positionKnown {
            windowChildren = children.compactMap { $0 as? ArchiveSource }.prefix(1).map { $0 }
            window = windowChildren.map(ObjectIdentifier.init)
        }
        if changed, wasPreparing {
            await adjustRunningSpools()
            guard spoolLimit == spoolSizeLimit, !Task.isCancelled else { return }
        }
        if windowTask == nil || changed { scheduleWindow(interactive: positionKnown) }
    }

    func noteReadingPosition(current: PageEntry, next: PageEntry?, previous: PageEntry?, forward: Bool, sequence: UInt64) async {
        // 通知 Task の配送順が前後しても、新しい窓を古い位置で上書きしない。
        guard sequence > readingPositionSequence else { return }
        readingPositionSequence = sequence
        readingForward = forward
        let targets: [ArchiveSource]
        if let reading = childIndex(for: current) {
            targets = windowTargets(reading: reading, forward: forward)
        } else if let neighbor = childIndex(for: forward ? next : previous) {
            // 直下画像を読んでいる間は、隣の巻の先頭の子から数える。
            targets = nearestArchiveChild(from: neighbor, forward: forward).map { [$0] } ?? []
        } else {
            targets = []
        }
        if preparationStarted, mediaProfileApplied, let first = targets.first {
            _ = await startDisplaySpool(first, generation: windowGeneration)
        }
        guard sequence == readingPositionSequence else { return }
        moveWindow(to: targets)
    }

    private func moveWindow(to targets: [ArchiveSource]) {
        var seen: Set<ObjectIdentifier> = []
        let sources = targets.filter { seen.insert(ObjectIdentifier($0)).inserted }
        let ids = sources.map(ObjectIdentifier.init)
        let changed = window != ids || !positionKnown
        positionKnown = true
        guard changed else { return }
        window = ids
        windowChildren = sources
        for id in ids {
            if spooledChildren[id] != nil {
                spoolLRU.removeAll { $0 == id }
                spoolLRU.append(id)
            }
        }
        if preparationStarted, spoolLimit != nil { scheduleWindow(interactive: true) }
    }

    private func prepareDisplayChild(at index: Int) async {
        guard PageRequestIntent.isDisplay, mediaProfileApplied, spoolLimit != nil,
              let child = children[index] as? ArchiveSource else { return }
        let targets = windowTargets(reading: index, forward: readingForward)
        let generation = windowGeneration
        let wasPreparing = preparationStarted
        guard await startDisplaySpool(child, generation: generation), generation == windowGeneration else { return }
        preparationStarted = true
        if !windowChildren.contains(where: { $0 === child }) || !positionKnown { moveWindow(to: targets) }
        if !wasPreparing, windowTask == nil { scheduleWindow(interactive: true) }
    }

    private func startDisplaySpool(_ child: ArchiveSource, generation: UUID) async -> Bool {
        guard generation == windowGeneration, spoolLimit != nil, mediaProfileApplied else { return false }
        windowEpoch.withLock { $0 = generation }
        let others = spooledChildren.values.filter { $0 !== child }
        let releasing = Set(others.map(ObjectIdentifier.init))
        // 開始できた場合だけ旧窓を取り消す。取消し中の書き込みは予算に残す。
        let budget = availableSpoolBudget(for: child, releasing: releasing)
        let epoch = windowEpoch
        let started = await child.beginSpoolingForDisplay(sizeLimit: budget) {
            epoch.withLock {
                guard $0 == generation else { return false }
                for source in others { source.cancelSpoolingForWindow() }
                return true
            }
        }
        guard started || child.hasFinishedSpool else { return false }
        guard generation == windowGeneration else {
            registerSpool(child, active: false)
            if !windowChildren.contains(where: { $0 === child }) { child.cancelSpoolingForWindow() }
            return false
        }
        // 開始した子を同じ actor 区間で台帳と LRU に登録し、次の窓移動で必ず回収する。
        registerSpool(child, active: started)
        return true
    }

    private func registerSpool(_ child: ArchiveSource, active: Bool = true) {
        let id = ObjectIdentifier(child)
        if active { activeWindowChild = child }
        spooledChildren[id] = child
        spoolLRU.removeAll { $0 == id }
        spoolLRU.append(id)
    }

    /// 表示・窓の予約・追い出しで同じ台帳を使い、空き容量由来の総予算は設定時に固定する。
    private func availableSpoolBudget(for child: ArchiveSource, releasing: Set<ObjectIdentifier> = []) -> Int64 {
        var remaining = collectionSpoolBudget
        for (id, source) in spooledChildren where source !== child {
            let reserved = releasing.contains(id) ? source.usedSpoolBytes : source.reservedSpoolBytes
            remaining = max(0, remaining - reserved)
        }
        return remaining
    }

    func archiveChild(for entry: PageEntry?) -> ArchiveSource? {
        guard let index = childIndex(for: entry) else { return nil }
        return children[index] as? ArchiveSource
    }

    private func childIndex(for entry: PageEntry?) -> Int? {
        guard let entry, case .child(let index, _) = locations[entry.id] else { return nil }
        return index
    }

    /// 読書中の子(書庫なら)と、読む向きで最も近い書庫の子。ページではなく子の順で数え、
    /// PDF の子を読んでいる間も次の書庫のスプールを先に始める(CV4-1、cooViewer-kjw7)。
    private func windowTargets(reading index: Int, forward: Bool) -> [ArchiveSource] {
        let reading = children.indices.contains(index) ? children[index] as? ArchiveSource : nil
        let neighbor = nearestArchiveChild(from: index + (forward ? 1 : -1), forward: forward)
        return [reading, neighbor].compactMap { $0 }
    }

    /// 起点を含む 2 つの子だけを探し、PDF が続いても遠い子を窓へ引き込まない(CV4-1)。
    private func nearestArchiveChild(from start: Int, forward: Bool) -> ArchiveSource? {
        let step = forward ? 1 : -1
        for offset in 0..<2 {
            let index = start + offset * step
            guard children.indices.contains(index) else { return nil }
            if let archive = children[index] as? ArchiveSource { return archive }
        }
        return nil
    }

    private func scheduleWindow(interactive: Bool) {
        let previousTask = windowTask
        previousTask?.cancel()
        let targets = windowChildren
        let generation = UUID()
        windowEpoch.withLock { $0 = generation }
        windowGeneration = generation
        windowTask = Task { [weak self] in
            // 昇格と着地は開始成功時だけ旧巻を止め、別の子 actor の完了を表示に待たせない。
            if interactive, let child = targets.first,
               await self?.startDisplaySpool(child, generation: generation) == true {
                await self?.cancelOutOfWindowSpools(generation: generation)
            }
            await previousTask?.value
            for (index, child) in targets.enumerated() {
                guard !Task.isCancelled,
                      let budget = await self?.budgetForWindowChild(child, generation: generation) else { return }
                let started = await child.beginSpooling(sizeLimit: budget, interactive: interactive && index == 0)
                await self?.recordStartedSpool(child, started: started, generation: generation)
                await child.waitForSpoolCompletion()
                await self?.recordSpool(child, generation: generation)
            }
            await self?.finishedWindow(generation)
        }
    }

    private func cancelOutOfWindowSpools(generation: UUID) {
        guard generation == windowGeneration else { return }
        // 完了済みの巻への後退では onStart が呼ばれない。旧窓の終了待ちより先に
        // 窓外を取り消し、現在のエントリ境界で止める。開始不能な着地では呼ばない。
        for (id, source) in spooledChildren where !window.contains(id) {
            source.cancelSpoolingForWindow()
        }
    }

    private func recordStartedSpool(_ child: ArchiveSource, started: Bool, generation: UUID) {
        guard started, generation == windowGeneration else { return }
        registerSpool(child)
    }

    private func budgetForWindowChild(_ child: ArchiveSource, generation: UUID) async -> Int64? {
        guard generation == windowGeneration, spoolLimit != nil, !Task.isCancelled else { return nil }
        let permitted = await child.canBeginSpooling(sizeLimit: collectionSpoolBudget)
        guard generation == windowGeneration, !Task.isCancelled else { return nil }
        guard permitted else { return 0 }
        let ownBytes = child.usedSpoolBytes
        let need = await child.spoolDemandBytes() ?? collectionSpoolBudget
        guard generation == windowGeneration, !Task.isCancelled else { return nil }
        // 表示経路は他の子を待たず、追い出しだけを窓の準備係に任せる(設計書 §5)。
        for id in spoolLRU where !window.contains(id) {
            let budget = availableSpoolBudget(for: child)
            guard need > max(0, budget - ownBytes) else { break }
            if let source = spooledChildren[id], !source.hasRunningSpool {
                await source.discardSpool()
                guard generation == windowGeneration, !Task.isCancelled else { return nil }
                spooledChildren[id] = nil
            }
        }
        spoolLRU.removeAll { spooledChildren[$0] == nil }
        let budget = availableSpoolBudget(for: child)
        registerSpool(child, active: false)
        return budget
    }

    private func recordSpool(_ child: ArchiveSource, generation: UUID) async {
        let stats = await child.spoolStats()
        guard generation == windowGeneration else { return }
        // 完了待ちの後に表示が始めた走査はまだ 0 バイトでも台帳に残し、総予算から外さない(D3)。
        if stats.bytes == 0, !child.hasRunningSpool {
            let id = ObjectIdentifier(child)
            spooledChildren[id] = nil
            spoolLRU.removeAll { $0 == id }
        }
        if activeWindowChild === child { activeWindowChild = nil }
    }

    private func finishedWindow(_ generation: UUID) {
        if generation == windowGeneration { windowTask = nil }
    }

    deinit {
        windowTask?.cancel()
        if let child = activeWindowChild { Task { await child.pauseSpooling() } }
    }

    /// 合本の窓の完了を待つ診断口。表示経路からは呼ばない(設計書 §5、§7.4)。
    func waitForSpoolCompletion() async -> Int {
        let task = windowTask
        await task?.value
        var count = 0
        for archive in spooledChildren.values { count += await archive.spooledEntryCount }
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
        if let marker = entry.unreadableVolume {
            return url.appendingPathComponent(marker.relativePath, isDirectory: false)
        }
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

    @discardableResult
    private func updateSpoolLimit(_ sizeLimit: Int64) -> Bool {
        guard spoolLimit != sizeLimit else { return false }
        spoolLimit = sizeLimit
        collectionSpoolBudget = SpoolSpacePolicy.totalBudget(sizeLimit: sizeLimit)
        return true
    }

    /// 設定の総上限は合本の台帳にだけ入れ、子の予算は窓が配り直す(CV3-1、CV3-4)。
    func configureSpooling(sizeLimit: Int64) async {
        let changed = updateSpoolLimit(sizeLimit)
        for child in preparedChildren.values {
            guard spoolLimit == sizeLimit, !Task.isCancelled else { return }
            if let archive = child.source as? ArchiveSource {
                await archive.configureSpooling(sizeLimit: sizeLimit, adjustsRunningSpool: false)
            } else {
                await child.source.configureSpooling(sizeLimit: sizeLimit)
            }
        }
        // 直後の beginBackgroundPreparation は同じ上限で呼ばれ変更を検出できないため、ここで配り直す。
        guard changed, preparationStarted, spoolLimit == sizeLimit, !Task.isCancelled else { return }
        await adjustRunningSpools()
        guard spoolLimit == sizeLimit, !Task.isCancelled else { return }
        scheduleWindow(interactive: positionKnown)
    }

    /// 窓の再計画は旧窓の完了を待つため、稼働中の子の予算は先にその場で詰め直す。
    /// 解凍位置は巻き戻さず、超過分は現在のエントリ境界で止まる(CV3-4、設計書 §5)。
    private func adjustRunningSpools() async {
        let budget = collectionSpoolBudget
        for source in spooledChildren.values where source.hasRunningSpool {
            guard collectionSpoolBudget == budget, !Task.isCancelled else { return }
            await source.adjustRunningSpoolLimit(availableSpoolBudget(for: source))
        }
    }

    /// プロファイルはフォルダ(読み取りゲート)と、生成済み/今後生成される
    /// 子ソース(書庫のスプール方針)の両方へ配る
    func applyMediaProfile(_ profile: MediaProfile) async {
        mediaProfile = profile
        mediaProfileApplied = true
        await folder.applyMediaProfile(profile)
        for child in preparedChildren.values {
            guard mediaProfile == profile, !Task.isCancelled else { return }
            await child.source.applyMediaProfile(profile)
        }
    }
}

extension NestedFolderSource {
    static func syntheticFailure(failures: [ChildReadFailure]? = nil) async -> (NestedFolderSource, AssemblyFailure) {
        let url = URL(fileURLWithPath: "/synthetic/図面集")
        let paths = (1...5).map { String(format: "A-%03d.zip", $0) }
        let source = NestedFolderSource(folder: FolderSource(snapshotURL: url, images: [], nestedPaths: paths))
        let failure = await source.prepareSynthetic(paths: paths, failures: failures)
        return (source, failure)
    }

    private func prepareSynthetic(paths: [String], failures: [ChildReadFailure]?) -> AssemblyFailure {
        for ordinal in [0, 2, 4] {
            let child = SyntheticCollectionVolume(url: url.appendingPathComponent(paths[ordinal], isDirectory: false))
            preparedChildren[ordinal] = AssemblyPreparedChild(source: child,
                entries: child.pages, excludedCount: 0)
        }
        let failure = AssemblyFailure(failures: failures ?? [1, 3].map { ordinal in
            ChildReadFailure(relativePath: paths[ordinal], url: url.appendingPathComponent(paths[ordinal], isDirectory: false),
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
