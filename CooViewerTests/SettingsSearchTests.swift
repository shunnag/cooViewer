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

    /// 「省電力」の行の索引語(英語の原文キー)。SettingsView.searchTerms(for: .advanced) と
    /// 同じ鍵で、Localizable.xcstrings の日本語訳を lproj から直接読む
    private static let powerSavingKeys = [
        "Power saving:",
        "Reduce in Low Power Mode or under thermal pressure (default)",
        "Reduce only in Low Power Mode",
        "Always full speed",
        "Battery, thermal, CPU",
    ]

    /// 「省電力」の行が実際の「高度」ペインの索引に載っている(設計書 §5)
    @MainActor
    func testRealAdvancedIndexContainsPowerSavingRow() {
        let terms = SettingsView.searchTerms(for: .advanced)
        for key in Self.powerSavingKeys {
            XCTAssertTrue(terms.contains(String(localized: String.LocalizationValue(key))), key)
        }
    }

    /// 自明な語(省電力・電力・温度・バッテリー / power・thermal・battery・CPU)で見つかる。
    /// 実行機の言語に依存しないよう、日英の訳を lproj から解決して索引を組む
    func testPowerSavingRowIsFoundByObviousTermsInJapaneseAndEnglish() throws {
        let app = Bundle(for: SettingsStore.self)
        let queries = [
            "ja": ["省電力", "電力", "温度", "バッテリー", "CPU"],
            "en": ["power", "thermal", "battery", "CPU"],
        ]
        for (language, words) in queries {
            let bundle = app.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
            if language == "ja" { XCTAssertNotNil(bundle, "ja.lproj がアプリに無い") }
            let terms = Self.powerSavingKeys.map {
                bundle?.localizedString(forKey: $0, value: $0, table: nil) ?? $0
            }
            if language == "ja" {
                XCTAssertNotEqual(terms, Self.powerSavingKeys, "日本語訳が解決されていない")
            }
            let entry = SettingsSearch.Entry(id: SettingsPane.advanced.rawValue, title: "", terms: terms)
            for word in words {
                let matches = SettingsSearch.filter(query: word, entries: [entry])
                XCTAssertEqual(matches.map(\.id), [SettingsPane.advanced.rawValue], "\(language): \(word)")
                XCTAssertFalse(matches.first?.matchedTerms.isEmpty ?? true, "\(language): \(word)")
            }
        }
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
