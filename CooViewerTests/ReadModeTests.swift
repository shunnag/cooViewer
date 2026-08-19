import XCTest
@testable import cooViewer

/// 読み方向の差し替え(ComicInfo の読み方向ヒント適用に使う。cooViewer-4fi.4)。
/// 見開き/単ページは保ち、左右方向だけを変える
final class ReadModeTests: XCTestCase {
    func testWithDirectionSetsDirectionKeepingSpreadness() {
        XCTAssertEqual(ReadMode.rightToLeftSpread.withDirection(readsRightToLeft: true),
                       .rightToLeftSpread)
        XCTAssertEqual(ReadMode.rightToLeftSpread.withDirection(readsRightToLeft: false),
                       .leftToRightSpread)
        XCTAssertEqual(ReadMode.leftToRightSpread.withDirection(readsRightToLeft: true),
                       .rightToLeftSpread)
        XCTAssertEqual(ReadMode.rightToLeftSingle.withDirection(readsRightToLeft: false),
                       .leftToRightSingle)
        XCTAssertEqual(ReadMode.leftToRightSingle.withDirection(readsRightToLeft: true),
                       .rightToLeftSingle)
    }

    func testWithDirectionPreservesSpreadAndAppliesDirectionForAllModes() {
        for mode in ReadMode.allCases {
            // 見開き/単ページ性は不変
            XCTAssertEqual(mode.withDirection(readsRightToLeft: true).isSpread, mode.isSpread)
            XCTAssertEqual(mode.withDirection(readsRightToLeft: false).isSpread, mode.isSpread)
            // 方向は指定どおり
            XCTAssertFalse(mode.withDirection(readsRightToLeft: true).readsFromLeft)
            XCTAssertTrue(mode.withDirection(readsRightToLeft: false).readsFromLeft)
        }
    }
}
