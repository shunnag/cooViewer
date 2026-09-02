import SwiftUI
import Washi

/// リフロー EPUB のしおり編集シート(仕様書 §4.7.2、設計書 §2.4)。
/// census 完了時はページ番号もコピー編集し、未完時は従来どおり
/// 位置を読み取り専用で表示する。OK でのみ確定する(§13.3)
struct EPUBBookmarkEditorView: View {
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        let locator: EPUBLocator
        let position: String
        var pageNumber: Int?
        let originalPageNumber: Int?
    }

    let pageRange: ClosedRange<Int>?
    let onSave: @MainActor ([
        (name: String, locator: EPUBLocator, pageNumber: Int?)
    ]) -> Void
    let onClose: @MainActor () -> Void

    @State private var items: [Item]
    @State private var selection: Set<UUID> = []

    init(bookmarks: [(name: String, locator: EPUBLocator)], positions: [String],
         pageNumbers: [Int?], pageRange: ClosedRange<Int>?,
         onSave: @escaping @MainActor (
             [(name: String, locator: EPUBLocator, pageNumber: Int?)]) -> Void,
         onClose: @escaping @MainActor () -> Void) {
        self.pageRange = pageRange
        self.onSave = onSave
        self.onClose = onClose
        _items = State(initialValue: bookmarks.enumerated().map { index, bookmark in
            let pageNumber = pageNumbers.indices.contains(index)
                ? pageNumbers[index] : nil
            return Item(
                name: bookmark.name, locator: bookmark.locator,
                position: positions.indices.contains(index) ? positions[index] : "—",
                pageNumber: pageNumber, originalPageNumber: pageNumber)
        })
    }

    /// 空名を従来同様に補正し、仕様書 §4.7.2 の「ページ番号を
    /// 触っていないしおりは元 locator を保持」するため、変更値だけを返す。
    static func saveItems(_ items: [Item]) -> [
        (name: String, locator: EPUBLocator, pageNumber: Int?)
    ] {
        items.enumerated().map { offset, item in
            (item.name.isEmpty ? "bookmark\(offset + 1)" : item.name,
             item.locator,
             item.pageNumber != item.originalPageNumber ? item.pageNumber : nil)
        }
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
                        if let pageRange, item.pageNumber != nil {
                            Stepper(value: Binding(
                                get: { item.pageNumber ?? pageRange.lowerBound },
                                set: { item.pageNumber = $0 }
                            ), in: pageRange) {
                                Text(verbatim: "p.\(item.pageNumber ?? pageRange.lowerBound)")
                                    .monospacedDigit()
                                    .frame(minWidth: 48, alignment: .trailing)
                            }
                        } else {
                            Text(verbatim: item.position)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 150, alignment: .trailing)
                        }
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
                    onSave(Self.saveItems(items))
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500, height: 360)
    }
}
