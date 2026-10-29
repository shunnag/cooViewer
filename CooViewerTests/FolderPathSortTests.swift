import Foundation
import XCTest
@testable import cooViewer

final class FolderPathSortTests: XCTestCase {
    func testShuffledMixedNamesKeepLegacyPathOrderAndEquivalentNameTies() {
        // 設計書 §5・§7.6: 正規等価な NFC/NFD も別々の URL として残し、
        // String の等値判定で差が隠れないよう UTF-8 の列そのものを照合する。
        let names = [
            "a2.png", "a10.png", "A.png", "z.png", "0.png", "a b.png", "a%20b.png",
            "第2話/ページ10.png", "第10話/ページ2.png", "日本語.png",
            "é.png", "e\u{301}.png", "が.png", "か\u{3099}.png",
            "😀.png", "sub/a.png", "sub2/a.png",
        ]
        let urls = names.map { URL(fileURLWithPath: "/mixed/" + $0, isDirectory: false) }
        var state: UInt64 = 0xC001
        for _ in 0..<64 {
            var shuffled = urls
            for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
                state = state &* 6364136223846793005 &+ 1
                shuffled.swapAt(index, Int(state % UInt64(index + 1)))
            }
            let old = shuffled.sorted { $0.path < $1.path }
            let new = FolderSource.sortedByPath(shuffled)
            XCTAssertEqual(new.map { Array($0.path.utf8) }, old.map { Array($0.path.utf8) })
            XCTAssertEqual(new.map(\.absoluteString), old.map(\.absoluteString))
        }
    }

    func testEmptyAndSingleURLKeepTheirSequence() {
        XCTAssertTrue(FolderSource.sortedByPath([]).isEmpty)
        let url = URL(fileURLWithPath: "/日本語/e\u{301}.png", isDirectory: false)
        XCTAssertEqual(FolderSource.sortedByPath([url]).map(\.absoluteString), [url.absoluteString])
    }
}
