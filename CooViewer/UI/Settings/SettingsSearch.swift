import Foundation

/// 設定検索の絞り込みロジック(設計書 §2.4 設定ウインドウ)。
/// サイドバーの各ペインに「タイトル+ペイン内の設定項目ラベル」を索引として
/// 持たせ、検索語でペインを絞り込む。UI から独立した純関数(テスト対象)。
/// EN: Pure filtering logic behind the settings search field. Each pane carries
/// EN: an index of its title plus the labels of the settings it contains; a
/// EN: query narrows the sidebar down to panes with a hit.
enum SettingsSearch {
    /// 索引の 1 ペイン分: 識別子・タイトル・設定項目ラベル
    /// EN: One pane's index entry: id, title, and contained setting labels.
    struct Entry {
        let id: Int
        let title: String
        let terms: [String]

        init(id: Int, title: String, terms: [String]) {
            self.id = id
            self.title = title
            self.terms = terms
        }
    }

    /// 絞り込み結果。matchedTerms はタイトル一致のときは空
    /// (行の下に注釈を出す必要がないため)
    /// EN: A hit. matchedTerms is empty on a title match (no caption needed).
    struct Match: Equatable {
        let id: Int
        let matchedTerms: [String]
    }

    /// 検索語で索引を絞り込む。空(空白のみ)の検索語は全ペインを返す。
    /// 大文字小文字・全角半角・濁点等の揺れは無視して比較する。
    /// EN: Filter the index. An empty/whitespace query returns every pane.
    /// EN: Comparison ignores case, width (full/half), and diacritics.
    static func filter(query: String, entries: [Entry]) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return entries.map { Match(id: $0.id, matchedTerms: []) }
        }
        return entries.compactMap { entry in
            if contains(entry.title, trimmed) {
                return Match(id: entry.id, matchedTerms: [])
            }
            let hits = entry.terms.filter { contains($0, trimmed) }
            guard !hits.isEmpty else { return nil }
            return Match(id: entry.id, matchedTerms: hits)
        }
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
        ]) != nil
    }
}
