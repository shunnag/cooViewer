import MapKit
import SwiftUI

/// ファイル情報パネルの 1 ページ分(タイトル・セグメント表示名・内容)
/// EN: One page's worth of File Info panel content.
struct FileInfoPage {
    /// パネルのウインドウタイトル(ページのファイル名)
    let title: String
    /// セグメントの表示名(見開き時のみ使用: 「左ページ」「右ページ」)
    let sideLabel: String
    let details: PageFileInfo.Details
}

/// ファイル情報パネルの中身。見開き時は上部のセグメントで左右のページを
/// 切り替える。各ページはセクション見出し付きの 2 列グリッドで、GPS 座標が
/// あれば撮影地点の地図を末尾に表示する(ピン付き・操作可)。
/// 内容の組み立ては PageFileInfo(純ロジック)が担い、本ビューは描画のみ。
/// EN: File Info panel content: a left/right segmented switcher for spreads,
/// EN: then a sectioned label/value grid plus an interactive map pinned at
/// EN: the EXIF GPS location when present.
struct FileInfoView: View {
    /// パネルの固定幅(高さは内容に合わせて呼び出し側が決める)
    /// EN: Fixed content width; the caller sizes the panel height to fit.
    static let contentWidth: CGFloat = 520
    /// セグメント行の高さぶん(パネルの高さ計算用)
    /// EN: Extra height the segmented switcher adds.
    static let segmentHeight: CGFloat = 46

    let pages: [FileInfoPage]
    /// 開いた時点で選択するページ(読み順の先頭)
    /// EN: Initially selected page (reading-order first).
    let initialIndex: Int
    /// 切替時にパネルのタイトルを差し替えるためのコールバック
    /// EN: Lets the panel retitle itself when the selection changes.
    var onPageChange: ((FileInfoPage) -> Void)?

    @State private var selected: Int

    init(pages: [FileInfoPage], initialIndex: Int,
         onPageChange: ((FileInfoPage) -> Void)? = nil) {
        self.pages = pages
        self.initialIndex = initialIndex
        self.onPageChange = onPageChange
        _selected = State(initialValue: initialIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            if pages.count > 1 {
                Picker("", selection: $selected) {
                    ForEach(pages.indices, id: \.self) { index in
                        Text(pages[index].sideLabel).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .onChange(of: selected) { _, newValue in
                    onPageChange?(pages[newValue])
                }
            }
            // 内容が画面に収まる高さならスクロールは実質無効(パネル側が
            // 内容の自然サイズに合わせる)。巨大なときだけスクロールが生きる
            // EN: The panel is sized to the content, so scrolling only matters
            // EN: when the content outgrows the screen.
            ScrollView {
                FileInfoContent(details: pages[selected].details)
                    .frame(width: Self.contentWidth)
            }
        }
    }
}

/// グリッド本体。スナップショット検証(ImageRenderer)は ScrollView を
/// 描画できないため、こちらを直接描画する
/// EN: The content itself; headless snapshots render this directly because
/// EN: ImageRenderer cannot render ScrollView content.
struct FileInfoContent: View {
    let details: PageFileInfo.Details

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(details.sections.enumerated()), id: \.offset) {
                _, section in
                if let title = section.title {
                    Divider()
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                sectionGrid(section)
            }
            if let latitude = details.latitude, let longitude = details.longitude {
                locationMap(latitude: latitude, longitude: longitude)
            }
        }
        .padding(18)
    }

    private func sectionGrid(_ section: PageFileInfo.Section) -> some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .frame(minWidth: 110, alignment: .trailing)
                    Text(row.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 12))
    }

    /// 撮影地点の地図(ピン付き。ドラッグ/ズーム操作可)
    /// EN: Map of the capture location with a marker.
    private func locationMap(latitude: Double, longitude: Double) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude,
                                                longitude: longitude)
        return Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))) {
            Marker("", coordinate: coordinate)
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // initialPosition は「初期値」なので、左右切替(別ページの座標)では
        // カメラが動かない。座標を id にして地図ごと作り直す
        // EN: initialPosition only seeds the camera; keying the view identity
        // EN: on the coordinate recreates the map when the page switches.
        .id("map:\(latitude),\(longitude)")
    }
}
