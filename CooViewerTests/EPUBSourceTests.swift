import Washi
import XCTest

@testable import cooViewer

/// EPUBSource の綴じ方向 → ComicInfo ヒント写像(入力系監査 2026-08-20)。
/// 明示 rtl/ltr は対称に写し、属性省略(default)はヒント化しない
final class EPUBSourceTests: XCTestCase {
    func testMangaHintMapsExplicitDirectionsSymmetrically() {
        XCTAssertEqual(EPUBSource.mangaHint(for: .rtl), .yesAndRightToLeft)
        XCTAssertEqual(EPUBSource.mangaHint(for: .ltr), .no)
        XCTAssertNil(EPUBSource.mangaHint(for: .byDefault))
    }
}
