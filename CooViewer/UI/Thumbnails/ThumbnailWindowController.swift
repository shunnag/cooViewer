import AppKit
import SwiftUI

/// サムネイル一覧パネル(仕様書 §4.8 の近代化版)。
/// 旧 ThumbnailController の performSelector 連鎖による疑似非同期充填は、
/// SwiftUI LazyVGrid + 表示セル単位の非同期ロードに置き換える(設計書 §1.1 補助 UI)。
/// mangaMode 合成・ソートポップアップ・キーボードジャンプ等の旧パネル内機能は
/// 近代化版では持たない(ページ選択と現在位置/しおりの可視化に絞る)。
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
        self.init(window: panel)
    }

    /// 現在の本の内容でグリッドを組み直して表示する。
    /// パネル表示中の本の状態変化(ページ移動・しおり追加)には追随しない簡略化
    /// (選択で閉じ、次回表示時に組み直すため。旧実装は表示のたび再充填 §4.8)。
    func present(book: Book, onJump: @escaping @MainActor (Int) -> Void) {
        let grid = ThumbnailGridView(
            entries: book.entries,
            source: book.source,
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
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - グリッド

/// ページサムネイルの格子。列数は 4 固定(将来設定化)。
private struct ThumbnailGridView: View {
    let entries: [PageEntry]
    let source: any BookSource
    let currentIndex: Int
    let bookmarkedPages: Set<Int>
    let readsFromLeft: Bool
    let onSelect: @MainActor (Int) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries.indices, id: \.self) { index in
                        ThumbnailCell(
                            entry: entries[index],
                            pageNumber: index + 1,
                            source: source,
                            isCurrent: index == currentIndex,
                            isBookmarked: bookmarkedPages.contains(index),
                            onSelect: { onSelect(index) })
                            .id(index)
                    }
                }
                .padding(12)
            }
            .onAppear {
                // 旧実装の「現在ページを含む画面から開始」(§4.8)に相当
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        }
        // 右→左読みでは行内を右端の列から充填する(仕様書 §4.8)。
        // LazyVGrid に行単位の反転はないため layoutDirection で簡易再現する。
        .environment(\.layoutDirection, readsFromLeft ? .leftToRight : .rightToLeft)
    }
}

/// 1 ページ分のセル。表示されたときに縮小画像を非同期ロードする
/// (LazyVGrid の遅延生成に相乗り。ロード中はプレースホルダ)。
private struct ThumbnailCell: View {
    let entry: PageEntry
    let pageNumber: Int  // 1 始まり
    let source: any BookSource
    let isCurrent: Bool
    let isBookmarked: Bool
    let onSelect: @MainActor () -> Void

    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onSelect) {
                thumbnail
            }
            .buttonStyle(.plain)
            Text(verbatim: "\(pageNumber)")
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
        .task(id: entry.id) {
            guard image == nil else { return }
            image = try? await source.image(for: entry, maxPixelSize: 200)
        }
    }

    private var thumbnail: some View {
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
        .frame(height: 140)
        .overlay {
            // 現在ページの枠(旧実装の開始位置強調に相当 §4.8)
            if isCurrent {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            // しおり付きページの記号(旧 bookmark_a.tiff 相当 §4.8)
            if isBookmarked {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.orange)
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - ReaderWindowController 配線(仕様書 §5.5 action 18/メニュー)

extension ReaderWindowController {
    /// サムネイル一覧の表示/非表示トグル。本が無ければ何もしない。
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
            guard let self, let book = self.book else { return }
            book.goTo(index: index)
            self.refreshAfterJump()
        }
    }

    @objc func showThumbnailsMenu(_ sender: Any?) { showThumbnail() }
}
