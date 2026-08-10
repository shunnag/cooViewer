import XCTest

@testable import cooViewer

/// ファイル情報パネルの行組み立て(PageFileInfo)のテスト
/// EN: Tests for the File Info row builder.
final class PageFileInfoTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    func testRowsForImageInsideArchive() throws {
        let data = TestFixtures.pngData(width: 40, height: 60)
        let archive = tempDir.appendingPathComponent("vol1.zip")
        try Data([0x50, 0x4B]).write(to: archive)

        let rows = PageFileInfo.rows(
            entryName: "p1.png", pathInBook: "vol1.zip/p1.png",
            containerURL: archive, pageNumber: 3, pageCount: 10,
            imageData: data, fallbackPixelSize: nil)
        let values = rows.map(\.value)

        XCTAssertEqual(rows.first?.value, "p1.png")
        XCTAssertTrue(values.contains("vol1.zip/p1.png"), "本の中のパス行")
        XCTAssertTrue(values.contains("3 / 10"), "ページ行")
        XCTAssertTrue(values.contains("40 × 60"), "ピクセル寸法行")
        XCTAssertTrue(values.contains(archive.path), "場所=書庫本体")
        XCTAssertTrue(values.contains { $0.contains("PNG") || $0.contains("png") },
                      "形式行")
        // 実体ファイル(書庫)の作成/更新日時が付くこと
        XCTAssertGreaterThanOrEqual(
            rows.count(where: { $0.value.contains(":") && $0.value.contains(",")
                || $0.value.contains("/") }), 2)
    }

    func testRowsOmitPathWhenSameAsName() {
        let rows = PageFileInfo.rows(
            entryName: "a.png", pathInBook: "a.png",
            containerURL: tempDir.appendingPathComponent("a.png"),
            pageNumber: 1, pageCount: 1,
            imageData: nil, fallbackPixelSize: CGSize(width: 100, height: 200))
        let values = rows.map(\.value)
        XCTAssertEqual(values.count(where: { $0 == "a.png" }), 1,
                       "名前とパスが同じなら 1 行だけ")
        XCTAssertTrue(values.contains("100 × 200"), "データ無しでも寸法フォールバック")
    }
}
