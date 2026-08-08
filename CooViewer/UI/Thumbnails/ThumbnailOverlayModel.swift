import Foundation

/// サムネイルオーバーレイの状態(仕様書 §4.8 の近代化版)。
/// 本のスナップショット・表示中画面・絞り込みトグル・先読みを所有し、
/// ビュー(ThumbnailOverlayView)は本モデルの描画に徹する。
/// 行×列は旧設定 Thumbnail{row, column} を読む(§6.1)。
/// EN: Owns all thumbnail-overlay state (book snapshot, current screen, filter
/// EN: toggles, prefetch); the SwiftUI view only renders this model.
@MainActor
final class ThumbnailOverlayModel: ObservableObject {
    /// オーバーレイが必要とする本の状態の写し(Book 本体は保持しない)
    /// EN: Copy of the book state the overlay needs; never references Book itself.
    struct Snapshot {
        var entries: [PageEntry] = []
        var source: (any BookSource)?
        var bookKey = ""
        /// 本の現在ページ(スプレッド先頭)。開いたときの初期画面の決定に使う
        /// EN: Current book page (first page of the spread); picks the initial screen.
        var currentIndex = 0
        /// いま表示中のスプレッドの全ページ(見開きなら 2 枚。強調表示に使う)
        /// EN: Every page of the spread currently on screen; drives the highlight.
        var displayedIndices: Set<Int> = []
        var bookmarkedPages: Set<Int> = []
        var readsFromLeft = false
    }

    @Published private(set) var snapshot = Snapshot()
    /// 表示中のサムネイル画面(0 始まり)
    /// EN: Thumbnail screen currently shown (0-based).
    @Published private(set) var screen = 0

    /// しおり付きページのみ表示(旧 ThumbnailOnlyBookmark)
    /// EN: Show bookmarked pages only (legacy ThumbnailOnlyBookmark key).
    @Published var onlyBookmarks: Bool {
        didSet {
            guard onlyBookmarks != oldValue else { return }
            defaults.set(onlyBookmarks, forKey: "ThumbnailOnlyBookmark")
            screen = 0  // 絞り込みの切替では先頭画面へ(旧挙動)
            // EN: toggling the filter jumps back to the first screen (legacy behavior).
            prefetchAroundScreen()
        }
    }

    /// 見開き 2 ページを 1 セルに束ねる(旧 ThumbnailComicMode。§4.8 mangaMode)
    /// EN: Pair two pages into one cell (legacy ThumbnailComicMode).
    @Published var comicMode: Bool {
        didSet {
            guard comicMode != oldValue else { return }
            defaults.set(comicMode, forKey: "ThumbnailComicMode")
            showScreenContainingCurrentPage()
            prefetchAroundScreen()
        }
    }

    var onJump: (@MainActor (Int) -> Void)?
    var onClose: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private var prefetchTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onlyBookmarks = defaults.bool(forKey: "ThumbnailOnlyBookmark")
        comicMode = defaults.bool(forKey: "ThumbnailComicMode")
    }

    /// 現在の設定とスナップショットから組んだグリッド構成。
    /// 入力(エントリ数・しおり・トグル・行×列)が変わると自動的に変わる
    /// EN: Grid layout derived from settings + snapshot; recomputed on access.
    var layout: ThumbnailGridLayout {
        let grid = ThumbnailGridSetting.read(from: defaults)
        return ThumbnailGridLayout(
            entryCount: snapshot.entries.count,
            bookmarkedPages: snapshot.bookmarkedPages,
            onlyBookmarks: onlyBookmarks,
            comicMode: comicMode,
            rows: grid.rows,
            columns: grid.columns)
    }

    // MARK: - 操作

    /// book の内容でオーバーレイを組み(直す)。本の切替時にも使う
    /// EN: (Re)build the overlay from the book; also called when the book switches.
    func present(book: Book, displayedIndices: [Int] = []) {
        snapshot = Snapshot(
            entries: book.entries,
            source: book.source,
            bookKey: book.cacheKey,
            currentIndex: book.currentIndex,
            displayedIndices: displayedIndices.isEmpty
                ? [book.currentIndex] : Set(displayedIndices),
            bookmarkedPages: Set(book.bookmarks.map(\.pageIndex)),
            readsFromLeft: book.readMode.readsFromLeft)
        showScreenContainingCurrentPage()
        prefetchAroundScreen()
    }

    /// 本のページ移動(0-9 の % ジャンプ・しおり移動等)に追従して、
    /// そのページを含む画面へ飛び、現在ページ強調も更新する
    /// EN: Follow a book-page jump: show the containing screen, update highlight.
    func focusCurrentIndex(_ index: Int, displayedIndices: [Int] = []) {
        let displayed = displayedIndices.isEmpty ? [index] : Set(displayedIndices)
        guard snapshot.currentIndex != index
            || snapshot.displayedIndices != displayed else { return }
        snapshot.currentIndex = index
        snapshot.displayedIndices = displayed
        showScreenContainingCurrentPage()
        prefetchAroundScreen()
    }

    /// サムネイル画面のページ送り(ページ送りキー・フッターの矢印)
    /// EN: Flip thumbnail screens (page-turn keys and footer arrows).
    func moveScreen(by delta: Int) {
        screen = layout.clamped(screen: screen + delta)
        prefetchAroundScreen()
    }

    // MARK: - 先読み

    private static let prefetchScreenOffsets = [0, 1, -1, 2, -2, 3, -3]
    /// 書庫ソースは actor で直列化されるため、過剰な同時要求は避ける
    /// EN: Archive sources are actor-serialized, so keep concurrency modest.
    private static let prefetchConcurrency = 3

    /// 現在±3 画面分のサムネイルを近い順に先読みする。
    /// キャッシュ経由なので生成済み分は即座に飛ばされ、画面が移れば
    /// 前回の先読みは打ち切られる(未着手分はキャッシュ側で脱落する)
    /// EN: Prefetch ±3 screens nearest-first; a newer call cancels the older run,
    /// EN: and not-yet-started generations are dropped inside the cache.
    private func prefetchAroundScreen() {
        prefetchTask?.cancel()
        guard let source = snapshot.source else { return }
        let layout = layout
        let targets: [PageEntry] = Self.prefetchScreenOffsets.flatMap { offset in
            layout.groups(onScreen: screen + offset).flatMap(\.self).compactMap {
                snapshot.entries.indices.contains($0) ? snapshot.entries[$0] : nil
            }
        }
        let bookKey = snapshot.bookKey
        prefetchTask = Task {
            // 常時 prefetchConcurrency 本を維持しつつ 1 件ずつ流し込む
            // EN: keep N requests in flight, feeding one new entry per completion.
            await withTaskGroup(of: Void.self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<Self.prefetchConcurrency {
                    guard let entry = iterator.next() else { break }
                    group.addTask {
                        _ = await ThumbnailCache.shared.thumbnail(
                            for: entry, in: source, bookKey: bookKey)
                    }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled, let entry = iterator.next() else { continue }
                    group.addTask {
                        _ = await ThumbnailCache.shared.thumbnail(
                            for: entry, in: source, bookKey: bookKey)
                    }
                }
            }
        }
    }

    /// テスト・診断用: 先読みの完了を待つ
    /// EN: Test/diagnostics helper: await prefetch completion.
    func waitForPrefetch() async {
        await prefetchTask?.value
    }

    // MARK: - 内部

    /// 本の現在ページを含む画面から表示する(§4.8)。絞り込みで
    /// 現在ページが非表示の場合は先頭画面
    /// EN: Show the screen containing the current page, or the first when filtered out.
    private func showScreenContainingCurrentPage() {
        screen = layout.screen(containing: snapshot.currentIndex) ?? 0
    }
}
