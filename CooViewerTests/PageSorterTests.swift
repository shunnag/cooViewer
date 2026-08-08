import XCTest
@testable import cooViewer

final class PageSorterTests: XCTestCase {
    private func entry(_ path: String, id: Int = 0,
                       created: Date? = nil, modified: Date? = nil) -> PageEntry {
        PageEntry(id: id, name: (path as NSString).lastPathComponent, pathInBook: path,
                  fileURL: nil, creationDate: created, modificationDate: modified)
    }

    func testNameSortIsFinderLikeNaturalOrder() {
        // 数字は数値比較、大文字小文字非区別(仕様書 §4.4.3)
        let entries = ["page10.png", "page2.png", "Page1.png"].map { entry($0) }
        let sorted = PageSorter.sorted(entries, mode: .name)
        XCTAssertEqual(sorted.map(\.pathInBook), ["Page1.png", "page2.png", "page10.png"])
    }

    func testNameSortUsesFullPathInBook() {
        let entries = ["b/1.png", "a/2.png", "a/10.png"].map { entry($0) }
        let sorted = PageSorter.sorted(entries, mode: .name)
        XCTAssertEqual(sorted.map(\.pathInBook), ["a/2.png", "a/10.png", "b/1.png"])
    }

    func testNumericAwareNameSortOrdersByNumericValue() {
        // ゼロ埋めが混在しても数値の大小で並ぶ
        let names = ["hoge-006.png", "hoge-0.png", "hoge-03.png",
                     "hoge-1.png", "hoge-5.png", "hoge-2.png", "hoge-4.png"]
        let sorted = PageSorter.sorted(names.map { entry($0) }, mode: .name)
        XCTAssertEqual(sorted.map(\.pathInBook),
                       ["hoge-0.png", "hoge-1.png", "hoge-2.png", "hoge-03.png",
                        "hoge-4.png", "hoge-5.png", "hoge-006.png"])
    }

    func testLiteralNameSortIsPlainCharacterOrder() {
        // 単純な文字コード順: 数値としては解釈しない
        let names = ["hoge-006.png", "hoge-0.png", "hoge-03.png",
                     "hoge-1.png", "hoge-5.png", "hoge-2.png", "hoge-4.png"]
        let sorted = PageSorter.sorted(names.map { entry($0) }, mode: .literalName)
        XCTAssertEqual(sorted.map(\.pathInBook),
                       ["hoge-0.png", "hoge-006.png", "hoge-03.png", "hoge-1.png",
                        "hoge-2.png", "hoge-4.png", "hoge-5.png"])
    }

    func testShuffleIsReproducibleWithSameSeed() {
        let entries = (0..<20).map { entry("page\($0).png", id: $0) }
        var rng1 = SplitMix64(seed: 42)
        var rng2 = SplitMix64(seed: 42)
        let shuffled1 = PageSorter.sorted(entries, mode: .shuffle, using: &rng1)
        let shuffled2 = PageSorter.sorted(entries, mode: .shuffle, using: &rng2)
        XCTAssertEqual(shuffled1.map(\.id), shuffled2.map(\.id))
        XCTAssertEqual(Set(shuffled1.map(\.id)), Set(entries.map(\.id)))
    }

    func testDateSortPutsUndatedEntriesLastInNameOrder() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let entries = [
            entry("c.png", id: 0, modified: new),
            entry("b.png", id: 1),
            entry("a.png", id: 2, modified: old),
            entry("d.png", id: 3),
        ]
        let sorted = PageSorter.sorted(entries, mode: .modificationDate)
        XCTAssertEqual(sorted.map(\.pathInBook), ["a.png", "c.png", "b.png", "d.png"])
    }

    func testDateSortIsStableForEqualDates() {
        let date = Date(timeIntervalSince1970: 100)
        let entries = ["b.png", "a.png", "c.png"].enumerated().map {
            entry($0.element, id: $0.offset, created: date)
        }
        let sorted = PageSorter.sorted(entries, mode: .creationDate)
        // 同一日付なら名前順(正規化順)を維持
        XCTAssertEqual(sorted.map(\.pathInBook), ["a.png", "b.png", "c.png"])
    }
}
