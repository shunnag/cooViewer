import SwiftUI

/// しおり編集シート(仕様書 §4.7.2)。名前の変更・ページ変更・削除・
/// 並べ替え・追加ができる。**コピーを編集して OK で確定**するため
/// Cancel が正しく効く(旧実装の「Cancel しても取り消されない」は
/// §13.3 の方針どおり修正)。
struct BookmarkEditorView: View {
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var pageNumber: Int  // 1 始まり(表示・入力用。保存時に 0 始まりへ戻す)
        var original: PageBookmark?

        func bookmark(offset: Int, pageCount: Int, bookIsComplete: Bool = true,
                      pagePath: (Int) -> String?) -> PageBookmark {
            // 名前変更や並べ替えだけで錨を失わず、未変更の旧しおりも補完しない(設計書 §7.4)。
            let unchanged = original.map { pageNumber == $0.pageIndex + 1 } ?? false
            // 不完全な一覧の旧しおりだけは位置を推定できないため元の番号を守る(設計書 §7.4)。
            let preserveLegacyIndex = unchanged && original?.pagePath == nil && !bookIsComplete
            let index = preserveLegacyIndex ? original!.pageIndex
                : min(max(0, pageNumber - 1), max(0, pageCount - 1))
            return PageBookmark(name: name.isEmpty ? "bookmark\(offset + 1)" : name, pageIndex: index,
                                pagePath: unchanged ? original?.pagePath : pagePath(index))
        }
    }

    let pageCount: Int
    let bookIsComplete: Bool
    let pagePath: @MainActor (Int) -> String?
    let onSave: @MainActor ([PageBookmark]) -> Void
    let onClose: @MainActor () -> Void

    @State private var items: [Item]
    @State private var selection: Set<UUID> = []

    init(bookmarks: [PageBookmark], pageCount: Int, bookIsComplete: Bool = true,
         pagePath: @escaping @MainActor (Int) -> String? = { _ in nil },
         onSave: @escaping @MainActor ([PageBookmark]) -> Void,
         onClose: @escaping @MainActor () -> Void) {
        self.pageCount = pageCount
        self.bookIsComplete = bookIsComplete
        self.pagePath = pagePath
        self.onSave = onSave
        self.onClose = onClose
        _items = State(initialValue: bookmarks.map {
            Item(name: $0.name, pageNumber: $0.pageIndex + 1, original: $0)
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
                    // 旧しおりの不確かな位置を守りつつ、確定できる範囲外ページは補正する(設計書 §7.4)。
                    onSave(items.enumerated().map { offset, item in
                        item.bookmark(offset: offset, pageCount: pageCount,
                                      bookIsComplete: bookIsComplete, pagePath: pagePath)
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
