import AppKit
import SwiftUI

/// サムネイル一覧パネル(仕様書 §4.8 の近代化版)。
/// 旧 ThumbnailController の performSelector 連鎖による疑似非同期充填は、
/// SwiftUI LazyVGrid + 表示セル単位の非同期ロードに置き換える(設計書 §1.1 補助 UI)。
/// 旧パネルの意匠に合わせ、透明背景+ツールバー帯(しおりのみ表示/見開き
/// サムネイル)を持ち、列数は旧設定 Thumbnail{column} に従う(§3.1, §6.1)。
@MainActor
final class ThumbnailWindowController: NSWindowController {
    private var hasAppeared = false

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = String(localized: "Thumbnails")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 240)
        // キーボードは本体ウインドウに残す(t キーでのトグルを効かせるため)
        panel.becomesKeyOnlyIfNeeded = true
        self.init(window: panel)
    }

    /// 現在の本の内容でグリッドを組み直して表示する。
    /// パネル表示中の本の状態変化(ページ移動・しおり追加)には追随しない簡略化
    /// (選択で閉じ、次回表示時に組み直すため。旧実装は表示のたび再充填 §4.8)。
    func present(book: Book, onJump: @escaping @MainActor (Int) -> Void) {
        let grid = ThumbnailGridView(
            entries: book.entries,
            source: book.source,
            bookKey: book.cacheKey,
            currentIndex: book.currentIndex,
            bookmarkedPages: Set(book.bookmarks.map(\.pageIndex)),
            readsFromLeft: book.readMode.readsFromLeft,
            onSelect: { [weak self] index in
                self?.close()
                onJump(index)
            })
        let hosting = NSHostingController(rootView: grid)
        hosting.sizingOptions = []

        // contentViewController の差し替えでウインドウサイズが変わらないよう、
        // 2 回目以降は直前のフレームを維持する
        let savedFrame = hasAppeared ? window?.frame : nil
        window?.contentViewController = hosting
        if let savedFrame {
            window?.setFrame(savedFrame, display: true)
        } else {
            window?.setContentSize(NSSize(width: 520, height: 640))
            window?.center()
            hasAppeared = true
        }
        window?.orderFront(nil)
    }
}

// MARK: - グリッド

/// ページサムネイルの格子。列数は旧設定 Thumbnail{column}(既定 4、2-8 に制限)。
private struct ThumbnailGridView: View {
    let entries: [PageEntry]
    let source: any BookSource
    let bookKey: String
    let currentIndex: Int
    let bookmarkedPages: Set<Int>
    let readsFromLeft: Bool
    let onSelect: @MainActor (Int) -> Void

    /// 旧キーそのまま(仕様書 §6.1): しおりのみ表示 / 見開きサムネイル
    @AppStorage("ThumbnailOnlyBookmark") private var onlyBookmarks = false
    @AppStorage("ThumbnailComicMode") private var comicMode = false

    private var columnCount: Int {
        let stored = (UserDefaults.standard.dictionary(forKey: "Thumbnail")?["column"]
            as? Int) ?? 4
        return min(8, max(2, stored))
    }

    /// フィルタ適用後のページ index 列
    private var visibleIndices: [Int] {
        onlyBookmarks
            ? entries.indices.filter { bookmarkedPages.contains($0) }
            : Array(entries.indices)
    }

    /// セル単位のページ組(見開きモードでは 2 ページずつ。仕様書 §4.8 mangaMode)
    private var cellGroups: [[Int]] {
        guard comicMode else { return visibleIndices.map { [$0] } }
        var groups: [[Int]] = []
        var iterator = visibleIndices.makeIterator()
        var pending: Int?
        while let index = iterator.next() {
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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: comicMode ? max(1, columnCount / 2) : columnCount),
                              spacing: 12) {
                        ForEach(cellGroups, id: \.first) { group in
                            ThumbnailCell(
                                pageIndices: group,
                                entries: entries,
                                source: source,
                                bookKey: bookKey,
                                currentIndex: currentIndex,
                                bookmarkedPages: bookmarkedPages,
                                onSelect: { onSelect(group[0]) })
                                .id(group.first ?? 0)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    // 旧実装の「現在ページを含む画面から開始」(§4.8)に相当
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
        // 右→左読みでは行内を右端の列から充填する(仕様書 §4.8)。
        // LazyVGrid に行単位の反転はないため layoutDirection で簡易再現する。
        .environment(\.layoutDirection, readsFromLeft ? .leftToRight : .rightToLeft)
    }

    /// 旧パネルのツールバー帯に相当(仕様書 §3.1)
    private var toolbar: some View {
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
            Text(verbatim: "\(visibleIndices.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .environment(\.layoutDirection, .leftToRight)  // ツールバーは常に左→右
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

/// 1 セル(単ページまたは見開き 2 ページ)。
private struct ThumbnailCell: View {
    let pageIndices: [Int]  // 読み順
    let entries: [PageEntry]
    let source: any BookSource
    let bookKey: String
    let currentIndex: Int
    let bookmarkedPages: Set<Int>
    let onSelect: @MainActor () -> Void

    private var isCurrent: Bool { pageIndices.contains(currentIndex) }

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 1) {
                    ForEach(pageIndices, id: \.self) { index in
                        ThumbnailPageImage(
                            entry: entries[index],
                            source: source,
                            bookKey: bookKey,
                            isBookmarked: bookmarkedPages.contains(index))
                    }
                }
                .frame(height: 140)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3)
                }
            }
            .buttonStyle(.plain)
            Text(verbatim: pageIndices.map { String($0 + 1) }.joined(separator: "-"))
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
    }
}

/// 1 ページ分のサムネイル画像(表示されたときに非同期ロード。キャッシュ経由)。
private struct ThumbnailPageImage: View {
    let entry: PageEntry
    let source: any BookSource
    let bookKey: String
    let isBookmarked: Bool

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)  // ロード中プレースホルダ
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
            guard image == nil else { return }
            // メモリ+ディスクキャッシュ経由(2 回目以降は再展開しない)
            image = await ThumbnailCache.shared.thumbnail(
                for: entry, in: source, bookKey: bookKey)
        }
    }
}

// MARK: - ReaderWindowController 配線

extension ReaderWindowController {
    /// サムネイル一覧の表示/トグル(仕様書 §4.8)。本が無ければ何もしない。
    func showThumbnail() {
        guard let book else { return }
        if let controller = thumbnailWindowController,
           controller.window?.isVisible == true {
            controller.close()
            return
        }
        let controller = thumbnailWindowController ?? ThumbnailWindowController()
        thumbnailWindowController = controller
        controller.present(book: book) { [weak self] index in
            book.goTo(index: index)
            self?.refreshAfterJump()
        }
    }

    @objc func showThumbnailsMenu(_ sender: Any?) {
        showThumbnail()
    }
}
