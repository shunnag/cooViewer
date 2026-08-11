import Foundation

/// サムネイルオーバーレイの状態(仕様書 §4.8 の近代化版)。
/// 本のスナップショット・表示中画面・絞り込みトグル・先読みを所有し、
/// ビュー(ThumbnailOverlayView)は本モデルの描画に徹する。
/// 行×列は旧設定 Thumbnail{row, column} を読む(§6.1)。
@MainActor
final class ThumbnailOverlayModel: ObservableObject {
    /// オーバーレイが必要とする本の状態の写し(Book 本体は保持しない)
    struct Snapshot {
        var entries: [PageEntry] = []
        var source: (any BookSource)?
        var bookKey = ""
        /// 本の現在ページ(スプレッド先頭)。開いたときの初期画面の決定に使う
        var currentIndex = 0
        /// いま表示中のスプレッドの全ページ(見開きなら 2 枚。強調表示に使う)
        var displayedIndices: Set<Int> = []
        var bookmarkedPages: Set<Int> = []
        var readsFromLeft = false
        /// 見開き判定用(旧 mangaMode の isSmallImage 規則。§4.2.1/§4.8)
        var marks = PageMarks()
        var singleSetting = PageLayout.defaultSingleSetting
        /// 表紙(先頭ページ)を単ページにする(Book.coverSingleFirst と同期)
        var coverSingle = false
        /// 先読み並列度(本の置き場所の速度プロファイル由来)
        var prefetchConcurrency = MediaProfile.unknown.thumbnailPrefetchConcurrency
    }

    @Published private(set) var snapshot = Snapshot()
    /// 表示中のサムネイル画面(0 始まり)
    @Published private(set) var screen = 0
    /// サムネイル生成で計測したページの縦横比(幅/高さ)。見開きモードの
    /// ペア判定に使い、レイアウトが漸進的に旧仕様へ収束する。marks は
    /// ここに混ぜず表示時に適用する(マーク変更に即追従するため)
    @Published private(set) var measuredAspects: [Int: CGFloat] = [:]

    /// 見開きモードでペアにしないページ(計測済みの横長+強制単ページ。
    /// 強制ペア指定は縦横比に優先する。旧 isSmallImage 規則 §4.2.1)
    var knownLargePages: Set<Int> {
        var large = Set(snapshot.marks.forcedSingleIndices)
        let paired = Set(snapshot.marks.forcedPairMemberIndices)
        // 表紙単ページ設定は先頭ページを単独セルにする(強制ペア指定が優先)
        if snapshot.coverSingle, !paired.contains(0) {
            large.insert(0)
        }
        let threshold = CGFloat(snapshot.singleSetting) / 1000
        for (index, ratio) in measuredAspects
            where ratio > threshold && !paired.contains(index) && !large.contains(index) {
            large.insert(index)
        }
        return large
    }

    /// しおり付きページのみ表示(旧 ThumbnailOnlyBookmark)
    @Published var onlyBookmarks: Bool {
        didSet {
            guard onlyBookmarks != oldValue else { return }
            defaults.set(onlyBookmarks, forKey: "ThumbnailOnlyBookmark")
            screen = 0  // 絞り込みの切替では先頭画面へ(旧挙動)
            prefetchAroundScreen()
        }
    }

    /// 見開き 2 ページを 1 セルに束ねる(旧 ThumbnailComicMode。§4.8 mangaMode)
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
    var layout: ThumbnailGridLayout {
        let grid = ThumbnailGridSetting.read(from: defaults)
        return ThumbnailGridLayout(
            entryCount: snapshot.entries.count,
            bookmarkedPages: snapshot.bookmarkedPages,
            onlyBookmarks: onlyBookmarks,
            comicMode: comicMode,
            rows: grid.rows,
            columns: grid.columns,
            knownLargePages: knownLargePages)
    }

    // MARK: - 操作

    /// book の内容でオーバーレイを組み(直す)。本の切替時にも使う
    func present(book: Book, displayedIndices: [Int] = []) {
        snapshot = Snapshot(
            entries: book.entries,
            source: book.source,
            bookKey: book.cacheKey,
            currentIndex: book.currentIndex,
            displayedIndices: displayedIndices.isEmpty
                ? [book.currentIndex] : Set(displayedIndices),
            bookmarkedPages: Set(book.bookmarks.map(\.pageIndex)),
            readsFromLeft: book.readMode.readsFromLeft,
            marks: book.marks,
            singleSetting: book.singleSetting,
            coverSingle: book.coverSingleFirst,
            prefetchConcurrency: book.mediaProfile.thumbnailPrefetchConcurrency)
        measuredAspects = [:]
        showScreenContainingCurrentPage()
        prefetchAroundScreen()
    }

    /// 表示中の本の更新に追従する(リーダーの表示更新ごとに呼ばれる)。
    /// ソート変更・シャッフル(仕様書 §4.4)等でエントリ列が変わっていたら
    /// スナップショットごと組み直す。古い並びのまま放置すると、一覧の表示も
    /// クリックでのジャンプ先も実際の本とずれる(別の画像に飛ぶ)ため。
    /// 並びが同じなら現在ページの強調と画面追従だけを更新する。
    func follow(book: Book, displayedIndices: [Int]) {
        if snapshot.entries != book.entries {
            present(book: book, displayedIndices: displayedIndices)
        } else {
            // しおり・マーク(見開き強制)・読み方向・見開きしきい値は本側で
            // 変わり得るので併せて追従する
            let bookmarked = Set(book.bookmarks.map(\.pageIndex))
            if snapshot.bookmarkedPages != bookmarked {
                snapshot.bookmarkedPages = bookmarked
            }
            if snapshot.marks != book.marks {
                snapshot.marks = book.marks
            }
            if snapshot.readsFromLeft != book.readMode.readsFromLeft {
                snapshot.readsFromLeft = book.readMode.readsFromLeft
            }
            if snapshot.singleSetting != book.singleSetting {
                snapshot.singleSetting = book.singleSetting
            }
            if snapshot.coverSingle != book.coverSingleFirst {
                snapshot.coverSingle = book.coverSingleFirst
            }
            focusCurrentIndex(book.currentIndex, displayedIndices: displayedIndices)
        }
    }

    /// 本のページ移動(0-9 の % ジャンプ・しおり移動等)に追従して、
    /// そのページを含む画面へ飛び、現在ページ強調も更新する
    private func focusCurrentIndex(_ index: Int, displayedIndices: [Int] = []) {
        let displayed = displayedIndices.isEmpty ? [index] : Set(displayedIndices)
        guard snapshot.currentIndex != index
            || snapshot.displayedIndices != displayed else { return }
        snapshot.currentIndex = index
        snapshot.displayedIndices = displayed
        showScreenContainingCurrentPage()
        prefetchAroundScreen()
    }

    /// 先読みだけを止める(オーバーレイを閉じたときに呼ぶ)。低速媒体で
    /// 閉じた後もサムネイル読みがページ表示と帯域を奪い合うのを防ぐ。
    /// 次に開いたときは present が先読みを再開する
    func pausePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// スナップショットを空にして本への参照を解く。オーバーレイ非表示のまま
    /// 本が切り替わったときに呼ぶ: 古い Snapshot.source(ArchiveSource)を
    /// 持ち続けると、その本のスプール/ネスト展開の一時ファイル(数 GB になり得る)が
    /// deinit で回収されないため。次回表示時は present が組み直す。
    func clear() {
        prefetchTask?.cancel()
        prefetchTask = nil
        snapshot = Snapshot()
        measuredAspects = [:]
        screen = 0
    }

    /// サムネイル画面のページ送り(ページ送りキー・フッターの矢印)
    func moveScreen(by delta: Int) {
        screen = layout.clamped(screen: screen + delta)
        prefetchAroundScreen()
    }

    // MARK: - 先読み

    private static let prefetchScreenOffsets = [0, 1, -1, 2, -2, 3, -3]

    /// 現在±3 画面分のサムネイルを近い順に先読みする。
    /// キャッシュ経由なので生成済み分は即座に飛ばされ、画面が移れば
    /// 前回の先読みは打ち切られる(未着手分はキャッシュ側で脱落する)
    private func prefetchAroundScreen() {
        prefetchTask?.cancel()
        guard let source = snapshot.source else { return }
        let layout = layout
        let targets: [(index: Int, entry: PageEntry)] =
            Self.prefetchScreenOffsets.flatMap { offset in
                layout.groups(onScreen: screen + offset).flatMap(\.self).compactMap {
                    snapshot.entries.indices.contains($0)
                        ? (index: $0, entry: snapshot.entries[$0]) : nil
                }
            }
        let bookKey = snapshot.bookKey
        // 並列度は本の置き場所の速度プロファイル由来(SSD=6 / HDD・NW=2)。
        // 書庫ソースは actor で直列化されるため過剰要求にはならない
        let concurrency = max(1, snapshot.prefetchConcurrency)
        prefetchTask = Task {
            // 常時 prefetchConcurrency 本を維持しつつ 1 件ずつ流し込む。
            // 生成結果の寸法は見開きモードのペア判定へ反映する(旧 isSmallImage)
            await withTaskGroup(of: Void.self) { group in
                var iterator = targets.makeIterator()
                let fetchOne: @Sendable ((index: Int, entry: PageEntry)) async -> Void = {
                    target in
                    guard let image = await ThumbnailCache.shared.thumbnail(
                        for: target.entry, in: source, bookKey: bookKey) else { return }
                    await self.noteThumbnailSize(
                        bookKey: bookKey, index: target.index, entryID: target.entry.id,
                        size: CGSize(width: image.width, height: image.height))
                }
                for _ in 0..<concurrency {
                    guard let target = iterator.next() else { break }
                    group.addTask { await fetchOne(target) }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled, let target = iterator.next() else { continue }
                    group.addTask { await fetchOne(target) }
                }
            }
        }
    }

    /// 生成済みサムネイルの寸法から縦横比を記録する(§4.2.1 の判定材料)。
    /// 縮小生成でも縦横比は保たれるため判定に使える。本の切替や並び替えを
    /// またいで届いた古い完了は bookKey とエントリ id の照合で捨てる
    private func noteThumbnailSize(bookKey: String, index: Int, entryID: Int,
                                   size: CGSize) {
        guard bookKey == snapshot.bookKey,
              snapshot.entries.indices.contains(index),
              snapshot.entries[index].id == entryID,
              size.height > 0,
              measuredAspects[index] == nil else { return }
        measuredAspects[index] = size.width / size.height
    }

    /// テスト・診断用: 先読みの完了を待つ
    func waitForPrefetch() async {
        await prefetchTask?.value
    }

    // MARK: - 内部

    /// 本の現在ページを含む画面から表示する(§4.8)。絞り込みで
    /// 現在ページが非表示の場合は先頭画面
    private func showScreenContainingCurrentPage() {
        screen = layout.screen(containing: snapshot.currentIndex) ?? 0
    }
}
