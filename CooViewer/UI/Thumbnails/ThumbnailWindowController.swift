import AppKit
import SwiftUI

/// サムネイル一覧(仕様書 §4.8 の近代化版)。
/// 別ウインドウではなくリーダーウインドウ内の半透明オーバーレイとして表示し、
/// 旧来どおり「行×列の固定グリッド+ページめくり」で閲覧する(§3.1, §4.8)。
/// 行×列は旧設定 Thumbnail{row, column} を読み書きする(§6.1)。
@MainActor
final class ThumbnailOverlayModel: ObservableObject {
    @Published var page = 0
    @Published var generation = 0  // 本の切替時に初期ページを再計算するための世代

    private(set) var entries: [PageEntry] = []
    private(set) var source: (any BookSource)?
    private(set) var bookKey = ""
    private(set) var currentIndex = 0
    private(set) var bookmarkedPages: Set<Int> = []
    private(set) var readsFromLeft = false
    var onJump: (@MainActor (Int) -> Void)?
    var onClose: (@MainActor () -> Void)?
    /// ビュー側から同期される実ページ数(キー転用時のクランプに使う)
    var knownPageCount = 1

    static var gridRows: Int {
        let stored = (UserDefaults.standard.dictionary(forKey: "Thumbnail")?["row"]
            as? Int) ?? 3
        return min(8, max(1, stored))
    }

    static var gridColumns: Int {
        let stored = (UserDefaults.standard.dictionary(forKey: "Thumbnail")?["column"]
            as? Int) ?? 4
        return min(8, max(1, stored))
    }

    func present(book: Book) {
        entries = book.entries
        source = book.source
        bookKey = book.cacheKey
        currentIndex = book.currentIndex
        bookmarkedPages = Set(book.bookmarks.map(\.pageIndex))
        readsFromLeft = book.readMode.readsFromLeft
        generation += 1
    }

    func movePage(by delta: Int, pageCount: Int) {
        guard pageCount > 0 else { return }
        page = min(max(0, page + delta), pageCount - 1)
    }
}

/// オーバーレイ本体。背景は半透明で、その下のページ表示がうっすら透ける。
struct ThumbnailOverlayView: View {
    @ObservedObject var model: ThumbnailOverlayModel

    @AppStorage("ThumbnailOnlyBookmark") private var onlyBookmarks = false
    @AppStorage("ThumbnailComicMode") private var comicMode = false

    private var visibleIndices: [Int] {
        onlyBookmarks
            ? model.entries.indices.filter { model.bookmarkedPages.contains($0) }
            : Array(model.entries.indices)
    }

    /// セル単位のページ組(見開きモードは 2 ページずつ。仕様書 §4.8 mangaMode)
    private var cellGroups: [[Int]] {
        guard comicMode else { return visibleIndices.map { [$0] } }
        var groups: [[Int]] = []
        var pending: Int?
        for index in visibleIndices {
            if let first = pending {
                groups.append([first, index])
                pending = nil
            } else {
                pending = index
            }
        }
        if let last = pending { groups.append([last]) }
        return groups
    }

    private var rows: Int { ThumbnailOverlayModel.gridRows }
    private var columns: Int {
        comicMode ? max(1, ThumbnailOverlayModel.gridColumns / 2)
                  : ThumbnailOverlayModel.gridColumns
    }
    private var perPage: Int { rows * columns }
    private var pageCount: Int {
        max(1, (cellGroups.count + perPage - 1) / perPage)
    }

    private var currentGroups: [[Int]] {
        let start = min(model.page, pageCount - 1) * perPage
        guard start < cellGroups.count else { return [] }
        return Array(cellGroups[start..<min(start + perPage, cellGroups.count)])
    }

    var body: some View {
        ZStack {
            // 半透明の背景(クリックで閉じる)
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { model.onClose?() }

            VStack(spacing: 10) {
                header
                grid
                footer
            }
            .padding(16)
        }
        .environment(\.layoutDirection,
                     model.readsFromLeft ? .leftToRight : .rightToLeft)
        .onAppear {
            showCurrentPage()
            model.knownPageCount = pageCount
        }
        .onChange(of: pageCount) { model.knownPageCount = pageCount }
        .onChange(of: model.generation) { showCurrentPage() }
        .onChange(of: onlyBookmarks) { model.page = 0 }
        .onChange(of: comicMode) { showCurrentPage() }
    }

    /// 実ページ位置を含むサムネイルページから開始する(§4.8)
    private func showCurrentPage() {
        if let position = cellGroups.firstIndex(where: {
            $0.contains(model.currentIndex)
        }) {
            model.page = position / perPage
        } else {
            model.page = 0
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $onlyBookmarks) {
                Image(systemName: onlyBookmarks ? "bookmark.fill" : "bookmark")
            }
            .toggleStyle(.button)
            .help(String(localized: "Show bookmarked pages only"))

            Toggle(isOn: $comicMode) {
                Image(systemName: comicMode ? "book.fill" : "book")
            }
            .toggleStyle(.button)
            .help(String(localized: "Two-page thumbnails"))

            Spacer()
            Text(verbatim: "\(min(model.page, pageCount - 1) + 1)/\(pageCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white)
            Spacer()
            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
        .environment(\.layoutDirection, .leftToRight)  // 帯は常に左→右
    }

    private var grid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 8
            let cellWidth = (geometry.size.width
                - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (geometry.size.height
                - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            let position = row * columns + column
                            if position < currentGroups.count {
                                ThumbnailCell(
                                    pageIndices: currentGroups[position],
                                    entries: model.entries,
                                    source: model.source,
                                    bookKey: model.bookKey,
                                    currentIndex: model.currentIndex,
                                    bookmarkedPages: model.bookmarkedPages,
                                    onSelect: {
                                        model.onJump?(currentGroups[position][0])
                                    })
                                    .frame(width: cellWidth, height: cellHeight)
                            } else {
                                Color.clear
                                    .frame(width: cellWidth, height: cellHeight)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.movePage(by: -1, pageCount: pageCount)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .disabled(model.page == 0)
            Spacer()
            Text(String(localized: "Turn pages with the usual page keys"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button {
                model.movePage(by: 1, pageCount: pageCount)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .buttonStyle(.borderless)
            .disabled(model.page >= pageCount - 1)
        }
    }
}

/// 1 セル(単ページまたは見開き 2 ページ)。
private struct ThumbnailCell: View {
    let pageIndices: [Int]  // 読み順
    let entries: [PageEntry]
    let source: (any BookSource)?
    let bookKey: String
    let currentIndex: Int
    let bookmarkedPages: Set<Int>
    let onSelect: @MainActor () -> Void

    private var isCurrent: Bool { pageIndices.contains(currentIndex) }

    var body: some View {
        VStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 1) {
                    ForEach(pageIndices, id: \.self) { index in
                        if entries.indices.contains(index) {
                            ThumbnailPageImage(
                                entry: entries[index],
                                source: source,
                                bookKey: bookKey,
                                isBookmarked: bookmarkedPages.contains(index))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3)
                }
            }
            .buttonStyle(.plain)
            Text(verbatim: pageIndices.map { String($0 + 1) }.joined(separator: "-"))
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : .white.opacity(0.8))
        }
    }
}

/// 1 ページ分のサムネイル画像(表示されたときに非同期ロード。キャッシュ経由)。
private struct ThumbnailPageImage: View {
    let entry: PageEntry
    let source: (any BookSource)?
    let bookKey: String
    let isBookmarked: Bool

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.08))  // ロード中プレースホルダ
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isBookmarked {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.orange)
                    .padding(4)
            }
        }
        .task(id: entry.id) {
            guard image == nil, let source else { return }
            // メモリ+ディスクキャッシュ経由(2 回目以降は再展開しない)
            image = await ThumbnailCache.shared.thumbnail(
                for: entry, in: source, bookKey: bookKey)
        }
    }
}

// MARK: - ReaderWindowController 配線

extension ReaderWindowController {
    /// サムネイルオーバーレイの表示/トグル(仕様書 §4.8)。本が無ければ何もしない。
    func showThumbnail() {
        guard let book else { return }
        if isThumbnailOverlayVisible {
            hideThumbnailOverlay()
            return
        }
        thumbnailOverlayModel.onJump = { [weak self] index in
            self?.hideThumbnailOverlay()
            book.goTo(index: index)
            self?.refreshAfterJump()
        }
        thumbnailOverlayModel.onClose = { [weak self] in
            self?.hideThumbnailOverlay()
        }
        thumbnailOverlayModel.present(book: book)
        thumbnailHostingView?.isHidden = false
    }

    func hideThumbnailOverlay() {
        thumbnailHostingView?.isHidden = true
    }

    var isThumbnailOverlayVisible: Bool {
        thumbnailHostingView?.isHidden == false
    }

    /// オーバーレイ表示中のページ送りキーはサムネイルのページめくりに転用する。
    /// ページ数の上限はビュー側の状態に依存するため movePage 側のクランプに任せる
    /// (超過分はビューの表示で丸められる)。
    func thumbnailOverlayTurnPage(forward: Bool) {
        thumbnailOverlayModel.movePage(by: forward ? 1 : -1,
                                       pageCount: thumbnailOverlayModel.knownPageCount)
    }

    @objc func showThumbnailsMenu(_ sender: Any?) {
        showThumbnail()
    }
}
