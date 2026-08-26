import Foundation

/// サムネイルオーバーレイの状態(仕様書 §4.8 の近代化版)。
/// 本のスナップショット・表示中画面・絞り込みトグル・先読みを所有し、
/// ビュー(ThumbnailOverlayView)は本モデルの描画に徹する。
/// 行×列は固定設定ではなく、グリッド領域の実寸とセルサイズ
/// (ThumbnailCellSize。ピンチ/設定スライダで可変)から自動算出する
/// (Photos 風。設計書 §2.4 — 旧 Thumbnail{row, column} §6.1 は凍結)。
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
        /// 提示世代(present ごとに増える)。セルの読み込みタスクの id に含め、
        /// 一覧を開き直したときに全セルが読み直すようにする — 再挑戦を使い切って
        /// プレースホルダのまま残ったセルが、開き直しで(その後の先読み成功分を
        /// 含めて)回復できるように。キャッシュ命中は即時なのでチラつかない
        var presentationEpoch = 0
    }

    @Published private(set) var snapshot = Snapshot()
    /// 表示中のサムネイル画面(0 始まり)
    @Published private(set) var screen = 0
    /// セル幅(pt)。ピンチと設定スライダで変わり、ThumbnailCellSize に保存
    @Published private(set) var cellSize: CGFloat
    /// グリッド領域の実寸(ビューが onGeometryChange で報告する)
    @Published private(set) var viewportSize: CGSize = .zero
    /// 画面先頭のセル組インデックス(ズーム/リサイズをまたぐ表示アンカー)。
    /// 明示的なページ送り・ジャンプだけが動かし、ズームやリサイズによる
    /// 行列の変化は screen をここから導出する。screen×旧セル数→新セル数の
    /// 逐次換算だと床関数の丸めが 60Hz のピンチで累積し、表示が先頭方向へ
    /// 這うため(アンカー固定でドリフトを断つ)
    private var anchorGroup = 0
    /// ピンチ開始時のセルサイズ(非 nil = ジェスチャ中)。ビューは描画方式の
    /// 切替(固定サイズ/余白吸収)に使い、defaults 同期はジェスチャ中を避ける
    @Published private(set) var pinchBaseCellSize: CGFloat?
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
            anchorGroup = 0
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
    /// pausePrefetch〜present の間 true(一覧が閉じている間の先読み再開防止)
    private var prefetchPaused = false
    /// 提示世代の通し番号(Snapshot.presentationEpoch の供給元)
    private var presentationCounter = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onlyBookmarks = defaults.bool(forKey: "ThumbnailOnlyBookmark")
        comicMode = defaults.bool(forKey: "ThumbnailComicMode")
        cellSize = ThumbnailZoomSetting.read(from: defaults)
    }

    /// 現在の状態から組んだグリッド構成。入力(エントリ数・しおり・トグル・
    /// ビューポート・セルサイズ)が変わると自動的に変わる
    var layout: ThumbnailGridLayout {
        // ジオメトリ到着前(初回表示の 1 レイアウトパスだけ)は旧既定の 3×4
        let grid = viewportSize == .zero
            ? (rows: 3, columns: 4)
            : ThumbnailGridLayout.dimensions(for: viewportSize, cellSize: cellSize)
        return ThumbnailGridLayout(
            entryCount: snapshot.entries.count,
            bookmarkedPages: snapshot.bookmarkedPages,
            onlyBookmarks: onlyBookmarks,
            comicMode: comicMode,
            rows: grid.rows,
            columns: grid.columns,
            knownLargePages: knownLargePages)
    }

    // MARK: - ズームとビューポート

    /// グリッド領域の実寸の報告(ビューの onGeometryChange から。
    /// ウインドウリサイズにも同経路で追従する)
    func updateViewport(_ size: CGSize) {
        guard size != viewportSize else { return }
        let hadViewport = viewportSize != .zero
        let oldCellsPerScreen = layout.cellsPerScreen
        viewportSize = size
        if !hadViewport {
            // 初回のジオメトリ到着: フォールバック 3×4 で組んだ画面は捨てて
            // 現在ページ基準で取り直す(アンカー換算だと現在ページが画面外に
            // 落ちることがある)
            showScreenContainingCurrentPage()
            prefetchAroundScreen()
        } else if layout.cellsPerScreen != oldCellsPerScreen {
            deriveScreenFromAnchor()
            prefetchAroundScreen()
        }
    }

    /// セルサイズの変更(ピンチ/設定スライダ)。commit=false(ジェスチャ中)は
    /// 保存も先読みもしない — 60Hz で走るため、保存はジェスチャ終了時のみ。
    /// 表示は anchorGroup 起点を保つ
    func setCellSize(_ size: CGFloat, commit: Bool) {
        let clamped = ThumbnailZoomSetting.clamp(size)
        if clamped != cellSize {
            cellSize = clamped
            deriveScreenFromAnchor()
        }
        if commit {
            ThumbnailZoomSetting.write(clamped, to: defaults)
            prefetchAroundScreen()
        }
    }

    /// ピンチの進行(ビューの MagnifyGesture から)。倍率は開始時サイズ起点
    func pinchChanged(magnification: CGFloat) {
        let base = pinchBaseCellSize ?? cellSize
        if pinchBaseCellSize == nil { pinchBaseCellSize = base }
        setCellSize(base * magnification, commit: false)
    }

    /// ピンチの確定(指を離した)。ここで初めて保存・先読みする
    func pinchEnded(magnification: CGFloat) {
        let base = pinchBaseCellSize ?? cellSize
        pinchBaseCellSize = nil
        setCellSize(base * magnification, commit: true)
    }

    /// defaults → モデルの同期(設定スライダの変更を開いている一覧へ反映する。
    /// ReaderWindowController.applySettings から呼ばれる)。自身の commit も
    /// defaults 変更通知を起こすため、同値なら何もしない。ピンチ中は未確定の
    /// 一時値と保存値が常に異なるため、無関係な defaults 書込(ウインドウ枠の
    /// autosave 等)で表示が保存値へスナップしないよう同期しない
    func syncCellSizeFromDefaults() {
        guard pinchBaseCellSize == nil else { return }
        let stored = ThumbnailZoomSetting.read(from: defaults)
        guard stored != cellSize else { return }
        setCellSize(stored, commit: false)
        prefetchAroundScreen()
    }

    /// ズーム/リサイズ後の画面番号をアンカーから導出する
    private func deriveScreenFromAnchor() {
        let layout = layout
        screen = layout.clamped(screen: anchorGroup / layout.cellsPerScreen)
    }

    // MARK: - 操作

    /// book の内容でオーバーレイを組み(直す)。本の切替時にも使う
    func present(book: Book, displayedIndices: [Int] = []) {
        present(snapshot: Snapshot(
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
            prefetchConcurrency: book.mediaProfile.thumbnailPrefetchConcurrency))
    }

    /// スナップショット直渡しの組み直し(EPUB リフローの画面単位一覧など、
    /// Book を持たない供給元用。設計書 §2.4 EPUB 対応)
    func present(snapshot newSnapshot: Snapshot) {
        presentationCounter &+= 1
        snapshot = newSnapshot
        snapshot.presentationEpoch = presentationCounter
        measuredAspects = [:]
        prefetchPaused = false
        pinchBaseCellSize = nil  // 閉じ方によっては onEnded が来ないため
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

    /// 現在ページ強調と画面追従だけを更新する(展開一覧など、エントリ列が
    /// book と一致しないスナップショットの追従用。follow の代替)
    func focus(currentIndex: Int, displayedIndices: [Int] = []) {
        focusCurrentIndex(currentIndex, displayedIndices: displayedIndices)
    }

    /// 先読みだけを止める(オーバーレイを閉じたときに呼ぶ)。低速媒体で
    /// 閉じた後もサムネイル読みがページ表示と帯域を奪い合うのを防ぐ。
    /// 次に開いたときは present が先読みを再開する。停止中は設定スライダの
    /// 同期・非表示中のリサイズ経由でも再開しない(prefetchPaused)
    func pausePrefetch() {
        prefetchPaused = true
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
        anchorGroup = 0
    }

    /// サムネイル画面のページ送り(ページ送りキー・フッターの矢印)
    func moveScreen(by delta: Int) {
        let layout = layout
        screen = layout.clamped(screen: screen + delta)
        anchorGroup = screen * layout.cellsPerScreen
        prefetchAroundScreen()
    }

    // MARK: - 先読み

    private static let prefetchScreenOffsets = [0, 1, -1, 2, -2, 3, -3]

    /// 現在±3 画面分のサムネイルを近い順に先読みする。
    /// キャッシュ経由なので生成済み分は即座に飛ばされ、画面が移れば
    /// 前回の先読みは打ち切られる(未着手分はキャッシュ側で脱落する)
    private func prefetchAroundScreen() {
        prefetchTask?.cancel()
        // ジオメトリ未到着の間は先読みしない: フォールバック 3×4 の画面割りで
        // 組んだ対象は実寸グリッド確定で即キャンセルされ、生成のやり直しと
        // チラつきの churn を生むだけのため(到着時に updateViewport が起動する)
        guard !prefetchPaused, viewportSize != .zero,
              let source = snapshot.source else { return }
        let layout = layout
        // 自動グリッドでは 1 画面のセル数が大きく(60 超もある)、±3 画面分を
        // 全部積むとメモリ LRU(ThumbnailCache は 400 枚)を 1 波で追い越して
        // 可視画面のぶんまで追い出してしまう。近い順に上限を掛けて LRU と
        // 生成行列の圧を抑える(可視セルはセル側の urgent 要求が別途保証する)。
        // 上限は「現在画面の 2 面ぶん」を下限 180 で確保する: 極小セルの巨大
        // グリッドでも現在画面全体の縦横比計測(ペア判定 §4.2.1)が欠けない
        // ようにしつつ、LRU(400)は超えない
        let budget = min(max(180, layout.cellsPerScreen * 2), 360)
        let targets: [(index: Int, entry: PageEntry)] = Array(
            Self.prefetchScreenOffsets.flatMap { offset in
                layout.groups(onScreen: screen + offset).flatMap(\.self).compactMap {
                    snapshot.entries.indices.contains($0)
                        ? (index: $0, entry: snapshot.entries[$0]) : nil
                }
            }.prefix(budget))
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
        let layout = layout
        screen = layout.screen(containing: snapshot.currentIndex) ?? 0
        anchorGroup = screen * layout.cellsPerScreen
    }
}
