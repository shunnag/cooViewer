import SwiftUI

/// リフロー EPUB の検索結果。Washi の型を UI 状態へ持ち込まず、
/// 近似位置と表示用スニペットだけを保持する。
struct SearchHit: Equatable, Sendable {
    let spineIndex: Int
    let progression: Double
    let snippet: String
}

/// EPUB 本文検索の決定論的な計算を UI から分離する。
enum EPUBSearchLogic {
    static let hitLimit = 500

    /// 抽出テキスト上の文字位置を項目内進行率へ変換する。
    static func progression(characterOffset: Int, itemTextLength: Int) -> Double {
        let ratio = Double(characterOffset) / Double(max(1, itemTextLength))
        return min(1, max(0, ratio))
    }

    /// バックエンドの読み順を保ったまま表示上限へ切り詰める。
    static func limited<T>(_ values: [T], limit: Int = hitLimit)
        -> (values: [T], isTruncated: Bool) {
        let clampedLimit = max(0, limit)
        return (Array(values.prefix(clampedLimit)), values.count > clampedLimit)
    }

    /// 現在位置から次または前へ進み、端では反対側へ回り込む。
    static func selectionIndex(current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else {
            return forward ? 0 : count - 1
        }
        return forward ? (current + 1) % count : (current - 1 + count) % count
    }
}

/// 検索パネルの表示状態。検索処理とナビゲーションはコントローラが所有する。
@MainActor
final class EPUBSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var pageNumbers: [Int?] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isTruncated = false
    @Published private(set) var pendingQuery: String?
    @Published private(set) var completedQuery: String?
    @Published private(set) var selectedIndex: Int?

    func beginSearch(query: String) {
        hits = []
        pageNumbers = []
        isSearching = true
        isTruncated = false
        pendingQuery = query
        completedQuery = nil
        selectedIndex = nil
    }

    func finishSearch(query: String, hits: [SearchHit], pageNumbers: [Int?],
                      isTruncated: Bool) {
        self.hits = hits
        self.pageNumbers = pageNumbers
        self.isSearching = false
        self.isTruncated = isTruncated
        self.pendingQuery = nil
        self.completedQuery = query
        self.selectedIndex = nil
    }

    func updatePageNumbers(_ pageNumbers: [Int?]) {
        self.pageNumbers = pageNumbers
    }

    func select(_ index: Int?) {
        selectedIndex = index
    }

    func clearResults() {
        hits = []
        pageNumbers = []
        isSearching = false
        isTruncated = false
        pendingQuery = nil
        completedQuery = nil
        selectedIndex = nil
    }
}

/// リフロー EPUB のフローティング検索パネル。
struct EPUBSearchView: View {
    @ObservedObject var model: EPUBSearchModel
    let onQueryChange: @MainActor (String) -> Void
    let onSearchNow: @MainActor (String) -> Void
    let onSelect: @MainActor (Int) -> Void
    let onNext: @MainActor () -> Void
    let onPrevious: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            TextField(String(localized: "Search"), text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldFocused)
                .onChange(of: model.query) { _, query in
                    onQueryChange(query)
                }
                .onSubmit {
                    if model.completedQuery == model.query, !model.hits.isEmpty {
                        onNext()
                    } else {
                        onSearchNow(model.query)
                    }
                }

            HStack(spacing: 8) {
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(resultSummary)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onPrevious()
                } label: {
                    Label(String(localized: "Find Previous"),
                          systemImage: "chevron.up")
                }
                .disabled(model.hits.isEmpty)
                Button {
                    onNext()
                } label: {
                    Label(String(localized: "Find Next"),
                          systemImage: "chevron.down")
                }
                .disabled(model.hits.isEmpty)
            }

            List {
                ForEach(model.hits.indices, id: \.self) { index in
                    Button {
                        onSelect(index)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(pageText(at: index))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            Text(model.hits[index].snippet)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(
                            model.selectedIndex == index
                                ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minHeight: 280)
        }
        .padding(12)
        .frame(minWidth: 440, idealWidth: 480,
               minHeight: 360, idealHeight: 500)
        .onAppear { searchFieldFocused = true }
        .onExitCommand { onClose() }
    }

    private var resultSummary: String {
        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        if model.isSearching {
            return String(localized: "Searching…")
        }
        if model.hits.isEmpty {
            return String(localized: "No Results")
        }
        if model.isTruncated {
            return String(localized: "500+ results")
        }
        let format = String(localized: "%lld results")
        return String(format: format, locale: Locale.current, Int64(model.hits.count))
    }

    private func pageText(at index: Int) -> String {
        guard model.pageNumbers.indices.contains(index),
              let page = model.pageNumbers[index] else { return "—" }
        return String(page)
    }
}
