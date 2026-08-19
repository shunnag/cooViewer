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
}
