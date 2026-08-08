import SwiftUI

/// サムネイルオーバーレイの描画(仕様書 §4.8)。
/// 別ウインドウではなくリーダーウインドウ内の半透明オーバーレイとして表示し、
/// 旧来どおり「行×列の固定グリッド+ページめくり」で閲覧する(§3.1, §4.8)。
/// 状態はすべて ThumbnailOverlayModel が持ち、本ビューは描画と操作の転送に徹する。
/// EN: In-window translucent overlay with a fixed rows×columns grid; all state
/// EN: lives in ThumbnailOverlayModel, this view just renders and forwards input.
struct ThumbnailOverlayView: View {
    @ObservedObject var model: ThumbnailOverlayModel

    /// フッターのファイル名をパス表示にするか(設定「ファイル名の表示」)
    @AppStorage("ShowRelativePaths") private var showRelativePaths = false

    var body: some View {
        let layout = model.layout
        ZStack {
            // 半透明の背景(クリックで閉じる)
            // EN: dimmed backdrop; clicking it closes the overlay.
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { model.onClose?() }

            VStack(spacing: 10) {
                header(layout)
                grid(layout)
                footer(layout)
            }
            .padding(16)
        }
        // 右綴じでは右上から左へ並べる(グリッドごと反転させる)
        // EN: right-to-left books mirror the whole grid via layoutDirection.
        .environment(\.layoutDirection,
                     model.snapshot.readsFromLeft ? .leftToRight : .rightToLeft)
    }

    private func header(_ layout: ThumbnailGridLayout) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: $model.onlyBookmarks) {
                Image(systemName: model.onlyBookmarks ? "bookmark.fill" : "bookmark")
            }
            .toggleStyle(.button)
            .help(String(localized: "Show bookmarked pages only"))

            Toggle(isOn: $model.comicMode) {
                Image(systemName: model.comicMode ? "book.fill" : "book")
            }
            .toggleStyle(.button)
            .help(String(localized: "Two-page thumbnails"))

            Spacer()
            Text(verbatim:
                "\(layout.clamped(screen: model.screen) + 1)/\(layout.screenCount)")
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
        // EN: the header strip itself always reads left-to-right.
        .environment(\.layoutDirection, .leftToRight)  // 帯は常に左→右
    }

    private func grid(_ layout: ThumbnailGridLayout) -> some View {
        let groups = layout.groups(onScreen: layout.clamped(screen: model.screen))
        return GeometryReader { geometry in
            let spacing: CGFloat = 8
            let cellWidth = (geometry.size.width
                - spacing * CGFloat(layout.columns - 1)) / CGFloat(layout.columns)
            let cellHeight = (geometry.size.height
                - spacing * CGFloat(layout.rows - 1)) / CGFloat(layout.rows)
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<layout.columns, id: \.self) { column in
                            let position = row * layout.columns + column
                            if position < groups.count {
                                ThumbnailCell(
                                    pageIndices: groups[position],
                                    snapshot: model.snapshot,
                                    onSelect: { model.onJump?(groups[position][0]) })
                                    .frame(width: cellWidth, height: cellHeight)
                            } else {
                                Color.clear
                                    .frame(width: cellWidth, height: cellHeight)
                            }
                        }
                    }
                }
            }
            // セル間の隙間クリックが背面の「クリックで閉じる」に抜けて、
            // ジャンプせずオーバーレイだけ閉じる誤動作を防ぐ(グリッド内は不感帯)
            // EN: Absorb clicks on the gaps between cells so a near-miss doesn't
            // EN: fall through to the backdrop and close the overlay instead of jumping.
            .contentShape(Rectangle())
            .onTapGesture {}
        }
    }

    private func footer(_ layout: ThumbnailGridLayout) -> some View {
        HStack {
            Button {
                model.moveScreen(by: -1)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .disabled(model.screen == 0)
            Spacer()
            // いま表示中のファイル名(見開きは 2 つ併記)
            // EN: names of the pages currently displayed (both pages of a spread).
            Text(verbatim: model.snapshot.displayedIndices.sorted().compactMap {
                let entries = model.snapshot.entries
                return entries.indices.contains($0)
                    ? entries[$0].displayTitle(relativePath: showRelativePaths) : nil
            }.joined(separator: "  "))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer()
            Button {
                model.moveScreen(by: 1)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .buttonStyle(.borderless)
            .disabled(model.screen >= layout.screenCount - 1)
        }
    }
}

/// 1 セル(単ページまたは見開き 2 ページ)。表示中のページを含むセルは
/// アクセント色の塗り+発光枠+太字番号で強調する
/// EN: One grid cell (single page or a two-page spread); cells containing the
/// EN: displayed pages get an accent fill, glowing border and bold number.
private struct ThumbnailCell: View {
    let pageIndices: [Int]  // 読み順
    let snapshot: ThumbnailOverlayModel.Snapshot
    let onSelect: @MainActor () -> Void

    private var isCurrent: Bool {
        !snapshot.displayedIndices.isDisjoint(with: pageIndices)
    }

    var body: some View {
        // 番号ラベルまで含めたセル全体を 1 つのボタンにする。番号や画像まわりの
        // 余白をクリックしても確実にジャンプさせる(当たり判定の穴を作らない)
        // EN: The whole cell — number label included — is one button, with an
        // EN: explicit content shape so there are no dead spots inside the cell.
        Button(action: onSelect) {
            VStack(spacing: 2) {
                HStack(spacing: 1) {
                    ForEach(pageIndices, id: \.self) { index in
                        if snapshot.entries.indices.contains(index) {
                            ThumbnailPageImage(
                                entry: snapshot.entries[index],
                                source: snapshot.source,
                                bookKey: snapshot.bookKey,
                                isBookmarked: snapshot.bookmarkedPages.contains(index))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.22))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isCurrent ? Color.accentColor : Color.clear,
                                lineWidth: 3)
                        .shadow(color: isCurrent ? Color.accentColor.opacity(0.9)
                                                 : .clear,
                                radius: 7)
                }
                Text(verbatim: pageIndices.map { String($0 + 1) }.joined(separator: "-"))
                    .font(isCurrent ? .caption.bold() : .caption)
                    .foregroundStyle(isCurrent ? Color.accentColor : .white.opacity(0.8))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 1 ページ分のサムネイル画像(表示されたときに非同期ロード。キャッシュ経由)。
/// ホバーでファイル名/相対パス(設定「ファイル名の表示」準拠)をツールチップ表示する。
/// EN: One page's thumbnail, loaded lazily through ThumbnailCache; hovering
/// EN: shows the file name or relative path as a tooltip.
private struct ThumbnailPageImage: View {
    let entry: PageEntry
    let source: (any BookSource)?
    let bookKey: String
    let isBookmarked: Bool

    @AppStorage("ShowRelativePaths") private var showRelativePaths = false

    /// 固定グリッドではセルのビュー実体がページめくり後も再利用され、
    /// オーバーレイ自体も閉じても破棄されない(非表示になるだけ)ため、
    /// 画像がどの本のどのエントリのものかを併せて保持し、表示時に必ず照合する。
    /// キーは本の識別子込みにする: entry.id はどの本でも 0,1,2,… の連番で、
    /// 本の切替後に同じマス目で衝突し、前の本のサムネイルが残ってしまうため
    /// (素早い往復でのキャンセル・遅延代入による空白/取り違えの防止も兼ねる)。
    /// EN: Cells are reused across screen flips AND across books (the overlay
    /// EN: is only hidden, never torn down), so the identity must include the
    /// EN: book key — bare entry ids are 0,1,2,… in every book and collide
    /// EN: after a book switch, leaving the previous book's thumbnails on screen.
    @State private var loaded: (key: String, image: CGImage)?

    /// 本の識別子込みのページ識別キー(ThumbnailCache のキーと同じ形)
    /// EN: Book-qualified page key (same shape as the ThumbnailCache key).
    private var pageKey: String { bookKey + "/" + String(entry.id) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.08))  // ロード中プレースホルダ
            if let loaded, loaded.key == pageKey {
                Image(decorative: loaded.image, scale: 1)
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
        .help(entry.displayTitle(relativePath: showRelativePaths))
        .task(id: pageKey) {
            guard let source else { return }
            // 常に読み直す(キャッシュ命中は即時)。キーを添えて保存するため、
            // 旧タスクの遅延代入が現エントリの表示を汚すことはない
            // EN: always reload (cache hits are instant); the stored key keeps a
            // EN: late assignment from a stale task off the current entry.
            let key = pageKey
            if let image = await ThumbnailCache.shared.thumbnail(
                for: entry, in: source, bookKey: bookKey) {
                loaded = (key, image)
            }
        }
    }
}
