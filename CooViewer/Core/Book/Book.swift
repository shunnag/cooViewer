import CoreGraphics
import Foundation

/// 開いている 1 冊の本。ページ列(ソート適用済み)・現在位置・見開き判定・
/// キャッシュ・先読みを束ねる。UI から使うため MainActor に置く。
///
/// 旧実装の「nowPage の二重意味」(仕様書 §1.4)は持ち込まず、
/// `currentIndex` は常に「表示中スプレッドの先頭ページ(読み順)」を指す。
@MainActor
final class Book {
    let source: any BookSource
    private(set) var entries: [PageEntry]
    private(set) var currentIndex = 0
    private(set) var sortMode: SortMode
    var readMode: ReadMode = .rightToLeftSpread
    var marks = PageMarks()
    var singleSetting = PageLayout.defaultSingleSetting
    var bookmarks: [BookHistoryStore.Bookmark] = []

    private let cache: PageCache
    private var prefetchTask: Task<Void, Never>?
    private var lastDisplayCount = 1
    private var lastMoveForward = true

    /// 表示すべきページの組。images の nil は「読めないページ」
    /// (呼び出し側が壊れ画像プレースホルダを当てる。仕様書 §4.17)。
    struct Spread {
        let indices: [Int]
        let images: [CGImage?]
    }

    enum MoveResult {
        case moved
        case hitStart  // 巻頭超え(loopCheck 処理は呼び出し側)
        case hitEnd    // 巻末超え(同上)
    }

    init(source: any BookSource, entries: [PageEntry],
         sortMode: SortMode = .name, cacheCapacity: Int = 8) {
        self.source = source
        self.sortMode = sortMode
        self.entries = PageSorter.sorted(entries, mode: sortMode)
        self.cache = PageCache(capacity: cacheCapacity)
    }

    static func open(source: any BookSource, sortMode: SortMode = .name) async throws -> Book {
        let entries = try await source.entries()
        return Book(source: source, entries: entries, sortMode: sortMode)
    }

    var pageCount: Int { entries.count }
    var displayName: String { source.displayName }

    // MARK: - 画像ロード

    func image(at index: Int) async -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        let key = entries[index].id
        if let hit = await cache.image(for: key) { return hit }
        guard let image = try? await source.image(for: entries[index], maxPixelSize: nil) else {
            return nil
        }
        await cache.insert(image, for: key)
        return image
    }

    private func isSmall(_ image: CGImage?, at index: Int) -> Bool {
        guard let image else { return false }
        return PageLayout.isSmall(
            size: CGSize(width: image.width, height: image.height),
            index: index, marks: marks, singleSetting: singleSetting
        )
    }

    /// 現在位置のスプレッドを確定する(仕様書 §4.2.4 の見開き判定を再現)。
    func currentSpread() async -> Spread {
        guard !entries.isEmpty else { return Spread(indices: [], images: []) }
        currentIndex = min(max(0, currentIndex), entries.count - 1)

        let first = await image(at: currentIndex)
        var indices = [currentIndex]
        var images: [CGImage?] = [first]

        if readMode.isSpread, currentIndex + 1 < entries.count, isSmall(first, at: currentIndex) {
            let second = await image(at: currentIndex + 1)
            if isSmall(second, at: currentIndex + 1) {
                indices.append(currentIndex + 1)
                images.append(second)
            }
        }
        lastDisplayCount = indices.count
        schedulePrefetch()
        return Spread(indices: indices, images: images)
    }

    // MARK: - ナビゲーション(仕様書 §4.3)

    func moveNext() -> MoveResult {
        guard !entries.isEmpty else { return .hitEnd }
        guard currentIndex + lastDisplayCount < entries.count else { return .hitEnd }
        currentIndex += lastDisplayCount
        lastMoveForward = true
        return .moved
    }

    func movePrevious() async -> MoveResult {
        guard !entries.isEmpty, currentIndex > 0 else { return .hitStart }
        lastMoveForward = false
        if readMode.isSpread, currentIndex >= 2 {
            let first = await image(at: currentIndex - 2)
            let second = await image(at: currentIndex - 1)
            if isSmall(first, at: currentIndex - 2), isSmall(second, at: currentIndex - 1) {
                currentIndex -= 2
                return .moved
            }
        }
        currentIndex -= 1
        return .moved
    }

    /// 見開きから 1 ページだけ進む/戻る(仕様書 §5.5 action 2/3)
    func moveHalfNext() -> MoveResult {
        guard currentIndex + 1 < entries.count else { return .hitEnd }
        currentIndex += 1
        lastMoveForward = true
        return .moved
    }

    func moveHalfPrevious() -> MoveResult {
        guard currentIndex > 0 else { return .hitStart }
        currentIndex -= 1
        lastMoveForward = false
        return .moved
    }

    func goTo(index: Int) {
        guard !entries.isEmpty else { return }
        currentIndex = min(max(0, index), entries.count - 1)
    }

    func goToFirst() {
        currentIndex = 0
        lastMoveForward = true
    }

    /// 末尾へ。見開きなら最終 2 枚がペアになる場合 count-2 に着地(仕様書 §4.3.3)。
    func goToLast() async {
        guard !entries.isEmpty else { return }
        lastMoveForward = true
        if readMode.isSpread, entries.count >= 2 {
            let first = await image(at: entries.count - 2)
            let second = await image(at: entries.count - 1)
            if isSmall(first, at: entries.count - 2), isSmall(second, at: entries.count - 1) {
                currentIndex = entries.count - 2
                return
            }
        }
        currentIndex = entries.count - 1
    }

    /// パーセントジャンプ(旧 goToPar)。上限クランプなしの旧仕様を維持し、
    /// 100% 以上は hitEnd を返す(仕様書 §13.3)。
    func goToPercent(_ percent: Double) -> MoveResult {
        guard !entries.isEmpty else { return .hitEnd }
        let target = Int(Double(entries.count) * percent)
        guard target < entries.count else { return .hitEnd }
        goTo(index: max(0, target))
        return .moved
    }

    /// スキップ(仕様書 §4.3.6 相当。value ページ分移動)
    func skip(by value: Int) {
        goTo(index: currentIndex + value)
    }

    /// ソート変更。旧仕様通り先頭ページへ戻る(仕様書 §13.3 で「維持」判断)。
    func setSortMode(_ mode: SortMode) {
        sortMode = mode
        entries = PageSorter.sorted(entries, mode: mode)
        currentIndex = 0
    }

    // MARK: - サブフォルダ移動(仕様書 §4.3.5: containerPath 単位で巡回)

    func nextSubFolderIndex() -> Int? {
        guard !entries.isEmpty else { return nil }
        let current = entries[currentIndex].containerPath
        for offset in 1...entries.count {
            let index = (currentIndex + offset) % entries.count
            if entries[index].containerPath != current { return index }
        }
        return nil
    }

    func previousSubFolderIndex() -> Int? {
        guard !entries.isEmpty else { return nil }
        let current = entries[currentIndex].containerPath
        var index = currentIndex
        for _ in 1...entries.count {
            index = (index - 1 + entries.count) % entries.count
            if entries[index].containerPath != current {
                // 前グループの先頭へ(仕様書 §4.3.5)
                let target = entries[index].containerPath
                var first = index
                while first > 0, entries[first - 1].containerPath == target { first -= 1 }
                return first
            }
        }
        return nil
    }

    // MARK: - しおり移動

    func nextBookmarkIndex() -> Int? {
        bookmarks.map(\.pageIndex).filter { $0 > currentIndex }.min()
    }

    func previousBookmarkIndex() -> Int? {
        bookmarks.map(\.pageIndex).filter { $0 < currentIndex }.max()
    }

    // MARK: - 先読み(仕様書 §4.5 の置換。設計書 §3.1)

    private func schedulePrefetch() {
        prefetchTask?.cancel()
        let forward = lastMoveForward
        let index = currentIndex
        let count = lastDisplayCount
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            let targets = forward
                ? [index + count, index + count + 1, index - 1]
                : [index - 1, index - 2, index + count]
            for target in targets {
                if Task.isCancelled { return }
                _ = await self.image(at: target)
            }
        }
    }
}
