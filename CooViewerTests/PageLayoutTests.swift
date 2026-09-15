import CoreGraphics
import XCTest
@testable import cooViewer

/// 見開き判定 isSmall の優先度(marks(ユーザー)> ComicInfo > coverSingle > 縦横比。
/// cooViewer-bt1)
final class PageLayoutTests: XCTestCase {
    private let portrait = CGSize(width: 70, height: 100)  // 通常は見開き候補(small=true)

    func testComicSingleIndicesForcesSingle() {
        XCTAssertTrue(PageLayout.isSmall(size: portrait, index: 3, marks: PageMarks()))
        XCTAssertFalse(PageLayout.isSmall(size: portrait, index: 3, marks: PageMarks(),
                                          comicSingleIndices: [3]))
    }

    func testUserMarksOverrideComicInfo() {
        // ユーザーが「見開きにする」(4-5)と指定したページは ComicInfo より優先
        let marks = PageMarks(legacyArray: ["4-5"])  // 1 始まり → 0 始まり 3,4 を pair 強制
        XCTAssertTrue(PageLayout.isSmall(size: portrait, index: 3, marks: marks,
                                         comicSingleIndices: [3]))
    }

    func testComicInfoAppliesToNonCoverPages() {
        // coverSingle は先頭のみ単ページ。ComicInfo は任意ページを単ページにできる
        XCTAssertFalse(PageLayout.isSmall(size: portrait, index: 0, marks: PageMarks(),
                                          coverSingle: true))
        XCTAssertFalse(PageLayout.isSmall(size: portrait, index: 5, marks: PageMarks(),
                                          comicSingleIndices: [5]))
    }

    func testInvalidPersistedMarksDoNotAffectLayout() {
        let raw: Set<String> = [String(Int.min), "0", "-1-2", "0-1", "2-5", "3-2",
                               "1--2", "1-2-3", "+4", "01", "04-05", "", "999999999999999999999"]
        let marks = PageMarks(raw: raw)
        XCTAssertTrue(marks.forcedSingleIndices.isEmpty)
        XCTAssertTrue(marks.forcedPairMemberIndices.isEmpty)
        XCTAssertEqual(marks.raw, raw, "解釈できない保存値を勝手に削除しない")
        XCTAssertEqual(PageMarks(legacyArray: marks.legacyArray), marks)
    }

    func testCanonicalMarksUseOneBasedAdjacentPages() {
        let marks = PageMarks(legacyArray: ["3", "8-9", String(Int.max),
                                            "\(Int.max - 1)-\(Int.max)"])
        XCTAssertEqual(Set(marks.forcedSingleIndices), [2, Int.max - 1])
        XCTAssertEqual(Set(marks.forcedPairMemberIndices), [7, 8, Int.max - 2, Int.max - 1])
        XCTAssertTrue(PageLayout.isSmall(size: CGSize(width: 200, height: 100),
                                        index: 7, marks: marks))
        XCTAssertFalse(PageLayout.isSmall(size: portrait, index: 2, marks: marks))
    }

    func testMarkMutationsIgnoreUnrepresentablePageNumbers() {
        var marks = PageMarks(legacyArray: ["3", "8-9"])
        let original = marks
        for index in [Int.min, -1, Int.max] {
            marks.setForcedSingle(index)
            marks.setForcedPair(firstIndex: index)
            marks.removeMark(containing: index)
        }
        marks.setForcedPair(firstIndex: Int.max - 1)
        XCTAssertEqual(marks, original)
    }

    func testLastRepresentablePageCanBeMarkedAndUnmarked() {
        var marks = PageMarks()
        marks.setForcedSingle(Int.max - 1)
        marks.setForcedPair(firstIndex: Int.max - 2)
        XCTAssertTrue(marks.forcesSingle(Int.max - 1))
        XCTAssertTrue(marks.forcesPairContaining(Int.max - 2))
        marks.removeMark(containing: Int.max - 1)
        XCTAssertTrue(marks.raw.isEmpty)
    }
}
