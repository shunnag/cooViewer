import XCTest
@testable import cooViewer

/// 設定検索の絞り込み(SettingsSearch.filter)のテスト
final class SettingsSearchTests: XCTestCase {
    private let entries: [SettingsSearch.Entry] = [
        .init(id: 0, title: "一般", terms: ["起動時に前回の本を開く", "履歴に残す冊数"]),
        .init(id: 1, title: "表示", terms: ["読む方向:", "補間:", "背景色:"]),
        .init(id: 8, title: "デコーダ", terms: ["MAG", "MAKI", "PBM"]),
    ]

    func testEmptyQueryReturnsEveryPane() {
        let matches = SettingsSearch.filter(query: "", entries: entries)
        XCTAssertEqual(matches.map(\.id), [0, 1, 8])
        XCTAssertTrue(matches.allSatisfy { $0.matchedTerms.isEmpty })

        // 空白のみも同じ扱い
        XCTAssertEqual(
            SettingsSearch.filter(query: "  ", entries: entries).map(\.id), [0, 1, 8])
    }

    func testTermMatchNarrowsAndReportsMatchedTerms() {
        let matches = SettingsSearch.filter(query: "補間", entries: entries)
        XCTAssertEqual(matches.map(\.id), [1])
        XCTAssertEqual(matches.first?.matchedTerms, ["補間:"])
    }

    func testTitleMatchReportsNoTerms() {
        // タイトル一致は注釈不要なので matchedTerms は空
        let matches = SettingsSearch.filter(query: "デコーダ", entries: entries)
        XCTAssertEqual(matches.map(\.id), [8])
        XCTAssertEqual(matches.first?.matchedTerms, [])
    }

    func testCaseAndWidthInsensitive() {
        // 小文字・全角英字でも MAG/MAKI に一致する
        XCTAssertEqual(
            SettingsSearch.filter(query: "ma", entries: entries).map(\.id), [8])
        XCTAssertEqual(
            SettingsSearch.filter(query: "MAG", entries: entries).map(\.id), [8])
    }

    func testNoHitReturnsEmpty() {
        XCTAssertTrue(SettingsSearch.filter(query: "存在しない語", entries: entries).isEmpty)
    }

    /// 実際の索引が全ペインを網羅していること(新ペイン追加時の追従漏れ検出)
    @MainActor
    func testRealIndexCoversEveryPane() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(SettingsView.searchTerms(for: pane).isEmpty,
                           "searchTerms が空: \(pane)")
        }
        XCTAssertEqual(Set(SettingsPane.sidebarOrder), Set(SettingsPane.allCases),
                       "sidebarOrder に全ペインが並んでいない")
    }
}
