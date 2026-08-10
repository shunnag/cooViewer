import SwiftUI

/// ファイル情報パネルの中身(ラベル+値の 2 列。値は選択コピー可)。
/// 行の組み立ては PageFileInfo(純ロジック)が担い、本ビューは描画のみ。
/// EN: Content of the File Info panel: a two-column grid of label/value rows
/// EN: built by PageFileInfo; values are selectable for copying.
struct FileInfoView: View {
    let rows: [PageFileInfo.Row]

    var body: some View {
        ScrollView {
            FileInfoGrid(rows: rows)
        }
        .frame(minWidth: 360, maxWidth: 560, minHeight: 200, maxHeight: 480)
    }
}

/// グリッド本体。スナップショット検証(ImageRenderer)は ScrollView を
/// 描画できないため、こちらを直接描画する
/// EN: The grid itself; headless snapshots render this directly because
/// EN: ImageRenderer cannot render ScrollView content.
struct FileInfoGrid: View {
    let rows: [PageFileInfo.Row]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 12))
        .padding(16)
    }
}
