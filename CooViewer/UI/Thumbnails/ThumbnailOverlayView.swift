import SwiftUI

/// サムネイルオーバーレイの描画(仕様書 §4.8)。
/// 別ウインドウではなくリーダーウインドウ内の半透明オーバーレイとして表示し、
/// 旧来どおり「グリッド+ページめくり」で閲覧する(§3.1, §4.8)。行列は
/// ウインドウサイズとセルサイズから自動算出(Photos 風、設計書 §2.4)。
/// 状態はすべて ThumbnailOverlayModel が持ち、本ビューは描画と操作の転送に徹する。
struct ThumbnailOverlayView: View {
    @ObservedObject var model: ThumbnailOverlayModel

    /// フッターのファイル名をパス表示にするか(設定「ファイル名の表示」)
    @AppStorage("ShowRelativePaths") private var showRelativePaths = false

    var body: some View {
        let layout = model.layout
        ZStack {
            // 半透明の背景(クリックで閉じる)
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
        // オーバーレイ上のピンチはセルサイズの連続変更(Photos 風)。最前面の
        // ホスティングビューが捕捉するので背面 ReaderView のページズームへは届かない
        .simultaneousGesture(magnifyGesture)
        // 右綴じでは右上から左へ並べる(グリッドごと反転させる)
        .environment(\.layoutDirection,
                     model.snapshot.readsFromLeft ? .leftToRight : .rightToLeft)
    }

    /// ピンチでセルサイズを連続変更する。ジェスチャ中は保存・先読みなし
    /// (60Hz で走るため)。指を離した時点の値を確定・保存し、固定サイズ描画から
    /// 余白吸収の整列描画へ短いアニメーションで沈める(状態はモデル側が持つ —
    /// 閉じ方によって onEnded が来なくても present がリセットできるように)
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                model.pinchChanged(magnification: value.magnification)
            }
            .onEnded { value in
                withAnimation(.snappy(duration: 0.2)) {
                    model.pinchEnded(magnification: value.magnification)
                }
            }
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
        .environment(\.layoutDirection, .leftToRight)  // 帯は常に左→右
    }

    private func grid(_ layout: ThumbnailGridLayout) -> some View {
        let groups = layout.groups(onScreen: layout.clamped(screen: model.screen))
        // ピンチ中は指に追従する固定サイズ、静止時は余白を均等吸収して
        // ビューポートを埋める(Photos 風: ジェスチャ中だけ生のサイズで滑らかに
        // 動き、離すと整列へ沈む)。行列はセルサイズ基準の自動算出なので原則
        // 収まるが、極小ウインドウでは行列が 1 に下駄止めされてセルが領域を
        // 超えるため clipped で抑える(ジェスチャ中のみの一過性)
        let zooming = model.pinchBaseCellSize != nil
        return GeometryReader { geometry in
            let spacing = ThumbnailGridLayout.spacing
            // ジオメトリ未到着(viewportSize == .zero)の間は描かない:
            // フォールバック 3×4 で一度組んでから実寸グリッドへ組み替えると、
            // 全セルの担当ページが変わって「一旦表示 → チラついて再描画」になる
            // (GeometryReader 自体は残して onGeometryChange の報告は続ける)
            if model.viewportSize != .zero {
            let cellWidth = zooming
                ? model.cellSize * (model.comicMode ? 2 : 1)
                : (geometry.size.width
                    - spacing * CGFloat(layout.columns - 1)) / CGFloat(layout.columns)
            let cellHeight = zooming
                ? model.cellSize * ThumbnailZoomSetting.cellHeightFactor
                : (geometry.size.height
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
            // ピンチ中は中央基準で拡縮させる(グリッド全体がビューポートより
            // 小さくなり得るため)。静止時はセルが埋めるので見た目は不変
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // セル間の隙間クリックが背面の「クリックで閉じる」に抜けて、
            // ジャンプせずオーバーレイだけ閉じる誤動作を防ぐ(グリッド内は不感帯)
            .contentShape(Rectangle())
            .onTapGesture {}
            // 行列の組み替え(ズーム中のしきい値越え・ウインドウリサイズ)は
            // 短い整列アニメーションで滑らかに見せる
            .animation(.snappy(duration: 0.18), value: layout.columns)
            .animation(.snappy(duration: 0.18), value: layout.rows)
            .clipped()
            }
        }
        // グリッド領域の実寸をモデルへ報告(初回表示とウインドウリサイズ)。
        // ここから行列が自動算出される
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            model.updateViewport(size)
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
private struct ThumbnailCell: View {
    let pageIndices: [Int]  // 読み順
    let snapshot: ThumbnailOverlayModel.Snapshot
    let onSelect: @MainActor () -> Void

    private var isCurrent: Bool {
        !snapshot.displayedIndices.isDisjoint(with: pageIndices)
    }

    var body: some View {
        // 番号ラベルまで含めたセル全体を 1 つの当たり判定にする(穴を作らない)。
        // Button ではなく「押した瞬間に確定」のジェスチャを使う: サムネイル
        // 読み込み中は見開きペアの判明でセル組みが流動し(§4.8 mangaMode の
        // 漸進収束)、Button だと押下〜リリース間の組み替えで押下が取り消され、
        // 未生成プレースホルダのクリックが無反応(キャンセル扱い)になるため。
        // 押下時点でそのマスに表示されているページへ飛ぶ
        cellContent
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                // 最初のイベント(押下)のみ発火。移動が始まったら何もしない
                guard abs(value.translation.width) < 1,
                      abs(value.translation.height) < 1 else { return }
                onSelect()
            })
            // ジェスチャは支援技術に公開されないため、AXPress 相当を明示提供
            // (VoiceOver の VO+Space / フルキーボードアクセスでの起動)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(verbatim:
                pageIndices.map { String($0 + 1) }.joined(separator: "-")))
            .accessibilityAction { onSelect() }
    }

    private var cellContent: some View {
        VStack(spacing: 2) {
            HStack(spacing: 1) {
                ForEach(pageIndices, id: \.self) { index in
                    if snapshot.entries.indices.contains(index) {
                        ThumbnailPageImage(
                            entry: snapshot.entries[index],
                            source: snapshot.source,
                            bookKey: snapshot.bookKey,
                            isBookmarked: snapshot.bookmarkedPages.contains(index),
                            presentationEpoch: snapshot.presentationEpoch)
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
    }
}

/// 1 ページ分のサムネイル画像(表示されたときに非同期ロード。キャッシュ経由)。
/// ホバーでファイル名/相対パス(設定「ファイル名の表示」準拠)をツールチップ表示する。
private struct ThumbnailPageImage: View {
    let entry: PageEntry
    let source: (any BookSource)?
    let bookKey: String
    let isBookmarked: Bool
    let presentationEpoch: Int

    @AppStorage("ShowRelativePaths") private var showRelativePaths = false

    /// 固定グリッドではセルのビュー実体がページめくり後も再利用され、
    /// オーバーレイ自体も閉じても破棄されない(非表示になるだけ)ため、
    /// 画像がどの本のどのエントリのものかを併せて保持し、表示時に必ず照合する。
    /// キーは本の識別子込みにする: entry.id はどの本でも 0,1,2,… の連番で、
    /// 本の切替後に同じマス目で衝突し、前の本のサムネイルが残ってしまうため
    /// (素早い往復でのキャンセル・遅延代入による空白/取り違えの防止も兼ねる)。
    @State private var loaded: (key: String, image: CGImage)?

    /// 本の識別子込みのページ識別キー(ThumbnailCache のキーと同じ形)
    private var pageKey: String { bookKey + "/" + String(entry.id) }

    /// 読み込みタスクの再実行キー: ページ識別+提示世代。開き直し(present)で
    /// 世代が変わると**未取得セルだけ**が読み直す(loaded 済みセルは世代を
    /// 含めない = t 連打のたびに全セルが再要求・キャンセルされる嵐を防ぐ。
    /// 再挑戦を使い切って残ったプレースホルダは開き直しで回復できる)。
    /// 取得成功の瞬間は id が「#世代付き → 素の pageKey」へ一度だけ変わるため
    /// .task も一度だけ再実行される(メモリヒットで即返り、以後は不変)
    private var loadTaskID: String {
        loaded?.key == pageKey ? pageKey : pageKey + "#\(presentationEpoch)"
    }

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
        .task(id: loadTaskID) {
            guard let source else { return }
            // 常に読み直す(キャッシュ命中は即時)。キーを添えて保存するため、
            // 旧タスクの遅延代入が現エントリの表示を汚すことはない。
            // 失敗(nil)は一度だけ間を置いて再挑戦する: 多数の PDF を同時に
            // 開いた直後の一時失敗で恒久プレースホルダにしないため(キャッシュの
            // 恒久記録は 2 回完走失敗からなので、再挑戦は新しい生成になる)
            let key = pageKey
            for attempt in 0..<2 {
                guard !Task.isCancelled else { return }
                if let image = await ThumbnailCache.shared.thumbnail(
                    for: entry, in: source, bookKey: bookKey, urgent: true) {
                    loaded = (key, image)
                    return
                }
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(800))
                }
            }
        }
    }
}
