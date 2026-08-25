import XCTest
@testable import cooViewer

/// containerPath 単位の構成巻(サブフォルダ)移動の純関数版(Book.*SubFolderIndex
/// (in:from:))の検証。合本内の EPUB 巻からも同じ規則で移動できるよう切り出した
/// (監査 #7)。画像巻・EPUB 巻の双方が同じロジックを共有する
@MainActor
final class SubFolderNavigationTests: XCTestCase {
    /// containerPath が A,A,B,B,C になるエントリ列(pathInBook の親フォルダで決まる)
    private func entries() -> [PageEntry] {
        let paths = ["A/p1.png", "A/p2.png", "B/p1.png", "B/p2.png", "C/p1.png"]
        return paths.enumerated().map { index, path in
            PageEntry(id: index, name: (path as NSString).lastPathComponent,
                      pathInBook: path, fileURL: nil,
                      creationDate: nil, modificationDate: nil)
        }
    }

    func testNextGoesToStartOfNextGroup() {
        let e = entries()
        XCTAssertEqual(Book.nextSubFolderIndex(in: e, from: 0), 2)  // A → B 先頭
        XCTAssertEqual(Book.nextSubFolderIndex(in: e, from: 1), 2)  // A(2枚目)→ B 先頭
        XCTAssertEqual(Book.nextSubFolderIndex(in: e, from: 2), 4)  // B → C 先頭
    }

    func testNextWrapsAroundToFirstGroup() {
        let e = entries()
        XCTAssertEqual(Book.nextSubFolderIndex(in: e, from: 4), 0)  // C → 巡回して A 先頭
    }

    func testPreviousGoesToStartOfPreviousGroup() {
        let e = entries()
        XCTAssertEqual(Book.previousSubFolderIndex(in: e, from: 4), 2)  // C → B 先頭
        XCTAssertEqual(Book.previousSubFolderIndex(in: e, from: 3), 0)  // B(2枚目)→ A 先頭
        XCTAssertEqual(Book.previousSubFolderIndex(in: e, from: 2), 0)  // B → A 先頭
    }

    func testPreviousWrapsAroundToLastGroupStart() {
        let e = entries()
        XCTAssertEqual(Book.previousSubFolderIndex(in: e, from: 0), 4)  // A → 巡回して C 先頭
    }

    func testSingleGroupHasNoMove() {
        let e = ["X/1.png", "X/2.png"].enumerated().map { index, path in
            PageEntry(id: index, name: (path as NSString).lastPathComponent,
                      pathInBook: path, fileURL: nil,
                      creationDate: nil, modificationDate: nil)
        }
        XCTAssertNil(Book.nextSubFolderIndex(in: e, from: 0))
        XCTAssertNil(Book.previousSubFolderIndex(in: e, from: 1))
    }

    func testEmptyAndOutOfRangeAreNil() {
        XCTAssertNil(Book.nextSubFolderIndex(in: [], from: 0))
        XCTAssertNil(Book.previousSubFolderIndex(in: [], from: 0))
        let e = entries()
        XCTAssertNil(Book.nextSubFolderIndex(in: e, from: 99))
        XCTAssertNil(Book.previousSubFolderIndex(in: e, from: -1))
    }
}
