import SwiftUI

/// しおり編集シート(仕様書 §4.7.2)。名前の変更・ページ変更・削除・
/// 並べ替え・追加ができる。**コピーを編集して OK で確定**するため
/// Cancel が正しく効く(旧実装の「Cancel しても取り消されない」は
/// §13.3 の方針どおり修正)。
/// EN: Bookmark editor sheet: rename, change page, delete, reorder, add.
/// EN: It edits a copy and commits on OK, so Cancel genuinely discards changes
/// EN: (the legacy app's broken Cancel is deliberately fixed here).
struct BookmarkEditorView: View {
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var pageNumber: Int  // 1 始まり(表示・入力用。保存時に 0 始まりへ戻す)
        // EN: 1-based for display/input; converted back to 0-based when saved.
    }

    let pageCount: Int
    let onSave: @MainActor ([BookHistoryStore.Bookmark]) -> Void
    let onClose: @MainActor () -> Void

    @State private var items: [Item]
    @State private var selection: Set<UUID> = []

    init(bookmarks: [BookHistoryStore.Bookmark], pageCount: Int,
         onSave: @escaping @MainActor ([BookHistoryStore.Bookmark]) -> Void,
         onClose: @escaping @MainActor () -> Void) {
        self.pageCount = pageCount
        self.onSave = onSave
        self.onClose = onClose
        _items = State(initialValue: bookmarks.map {
            Item(name: $0.name, pageNumber: $0.pageIndex + 1)
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(String(localized: "Edit Bookmarks"))
                .font(.headline)
            List(selection: $selection) {
                ForEach($items) { $item in
                    HStack(spacing: 8) {
                        TextField(String(localized: "Name"), text: $item.name)
                            .textFieldStyle(.roundedBorder)
                        Stepper(value: $item.pageNumber, in: 1...max(1, pageCount)) {
                            Text(verbatim: "p.\(item.pageNumber)")
                                .monospacedDigit()
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                    }
                    .tag(item.id)
                }
                // EN: drag to reorder / delete rows, mirroring the legacy sheet.
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }  // 並べ替え(§4.7.2)
                .onDelete { items.remove(atOffsets: $0) }
            }
            .frame(minHeight: 200)
            if items.isEmpty {
                Text(String(localized: "No bookmarks yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    // 名前は旧実装の自動命名に合わせ "bookmarkN"(§4.7.1)
                    // EN: auto-name "bookmarkN" to match the legacy app.
                    items.append(Item(name: "bookmark\(items.count + 1)", pageNumber: 1))
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    items.removeAll { selection.contains($0.id) }
                    selection.removeAll()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "OK")) {
                    // 空の名前と範囲外ページは保存時に補正する
                    // EN: Normalize empty names and clamp pages on commit.
                    onSave(items.enumerated().map { offset, item in
                        BookHistoryStore.Bookmark(
                            name: item.name.isEmpty
                                ? "bookmark\(offset + 1)" : item.name,
                            pageIndex: min(max(0, item.pageNumber - 1),
                                           max(0, pageCount - 1)))
                    })
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440, height: 360)
    }
}
