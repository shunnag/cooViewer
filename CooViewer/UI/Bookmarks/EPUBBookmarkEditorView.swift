import SwiftUI
import Washi

/// リフロー EPUB のしおり編集シート(仕様書 §4.7.2、設計書 §2.4)。
/// 固定ページ番号から位置を作れないため、位置表示は読み取り専用とし、
/// リネーム・削除・並べ替えだけをコピー編集して OK で確定する(§13.3)
struct EPUBBookmarkEditorView: View {
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        let locator: EPUBLocator
        let position: String
    }

    let onSave: @MainActor ([(name: String, locator: EPUBLocator)]) -> Void
    let onClose: @MainActor () -> Void

    @State private var items: [Item]
    @State private var selection: Set<UUID> = []

    init(bookmarks: [(name: String, locator: EPUBLocator)], positions: [String],
         onSave: @escaping @MainActor (
             [(name: String, locator: EPUBLocator)]) -> Void,
         onClose: @escaping @MainActor () -> Void) {
        self.onSave = onSave
        self.onClose = onClose
        _items = State(initialValue: bookmarks.enumerated().map { index, bookmark in
            Item(name: bookmark.name, locator: bookmark.locator,
                 position: positions.indices.contains(index) ? positions[index] : "—")
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
                        Text(verbatim: item.position)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 150, alignment: .trailing)
                    }
                    .tag(item.id)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
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
                    onSave(items.enumerated().map { offset, item in
                        (item.name.isEmpty ? "bookmark\(offset + 1)" : item.name,
                         item.locator)
                    })
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500, height: 360)
    }
}
