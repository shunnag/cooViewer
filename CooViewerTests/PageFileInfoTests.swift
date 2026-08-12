import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import cooViewer

/// ファイル情報パネルの内容組み立て(PageFileInfo)のテスト
final class PageFileInfoTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func allValues(_ details: PageFileInfo.Details) -> [String] {
        details.sections.flatMap(\.rows).map(\.value)
    }

    func testDetailsForImageInsideArchive() throws {
        let data = TestFixtures.pngData(width: 40, height: 60)
        let archive = tempDir.appendingPathComponent("vol1.zip")
        try Data([0x50, 0x4B]).write(to: archive)

        let details = PageFileInfo.details(
            entryName: "p1.png", pathInBook: "vol1.zip/p1.png",
            containerURL: archive, pageNumber: 3, pageCount: 10,
            imageData: data, fallbackPixelSize: nil)
        let values = allValues(details)

        XCTAssertEqual(details.sections.first?.rows.first?.value, "p1.png")
        XCTAssertTrue(values.contains("vol1.zip/p1.png"), "本の中のパス行")
        XCTAssertTrue(values.contains("3 / 10"), "ページ行")
        XCTAssertTrue(values.contains("40 × 60"), "ピクセル寸法行")
        XCTAssertTrue(values.contains(archive.path), "場所=書庫本体")
        XCTAssertNil(details.latitude, "GPS の無い画像は座標なし")
        // EXIF の無い画像に EXIF セクションを作らない
        XCTAssertFalse(details.sections.contains { $0.title == "EXIF" })
    }

    func testDetailsOmitPathWhenSameAsName() {
        let details = PageFileInfo.details(
            entryName: "a.png", pathInBook: "a.png",
            containerURL: tempDir.appendingPathComponent("a.png"),
            pageNumber: 1, pageCount: 1,
            imageData: nil, fallbackPixelSize: CGSize(width: 100, height: 200))
        let values = allValues(details)
        XCTAssertEqual(values.count(where: { $0 == "a.png" }), 1,
                       "名前とパスが同じなら 1 行だけ")
        XCTAssertTrue(values.contains("100 × 200"), "データ無しでも寸法フォールバック")
    }

    /// EXIF・GPS 付き JPEG からカメラ情報・撮影日時・座標が取れること
    func testDetailsExtractExifAndGPS() throws {
        let base = TestFixtures.pngData(width: 8, height: 8)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(base as CFData, nil))
        let cgImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [100],
                kCGImagePropertyExifFocalLength: 24.0,
                kCGImagePropertyExifLensModel: "RF24-70mm F2.8",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "Canon EOS R5",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.681236,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 139.767125,
                kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 3.5,
            ],
        ]
        CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let details = PageFileInfo.details(
            entryName: "photo.jpg", pathInBook: "photo.jpg",
            containerURL: tempDir.appendingPathComponent("photo.jpg"),
            pageNumber: 1, pageCount: 1,
            imageData: jpeg as Data, fallbackPixelSize: nil)

        let exif = try XCTUnwrap(
            details.sections.first { $0.title == "EXIF" }, "EXIF セクション")
        let values = exif.rows.map(\.value)
        XCTAssertTrue(values.contains("Canon EOS R5"),
                      "メーカー名は機種名と重複させない")
        XCTAssertTrue(values.contains("1/250 s"), "露出時間の分数表記")
        XCTAssertTrue(values.contains("f/2.8"), "絞り")
        XCTAssertTrue(values.contains("100"), "ISO")
        XCTAssertTrue(values.contains { $0.hasPrefix("24 mm") }, "焦点距離")
        XCTAssertTrue(values.contains("RF24-70mm F2.8"), "レンズ")

        XCTAssertEqual(details.latitude ?? 0, 35.681236, accuracy: 0.0001)
        XCTAssertEqual(details.longitude ?? 0, 139.767125, accuracy: 0.0001)
        // セクション名・数値の丸め(GPS は度分秒で保存される)に依存せず、
        // 高度行の存在で GPS セクションを確認する
        XCTAssertTrue(details.sections.contains {
            $0.rows.contains { $0.value == "3.5 m" }
        }, "高度行を含む GPS セクション")
    }

    /// 見開きの左右並び: 右→左読みでは読み順先頭が右ページになる
    func testPhysicalOrderForSpreads() {
        // 右→左読み(既定): 読み順 [4,5] → 画面は左=5, 右=4。既定選択は右(位置1)
        let rightToLeft = PageFileInfo.physicalOrder(
            readingOrderIndices: [4, 5], readsFromLeft: false)
        XCTAssertEqual(rightToLeft.ordered, [5, 4])
        XCTAssertEqual(rightToLeft.initialPosition, 1, "読み順先頭(4)は右=位置1")

        // 左→右読み: 並びそのまま。既定選択は左(位置0)
        let leftToRight = PageFileInfo.physicalOrder(
            readingOrderIndices: [4, 5], readsFromLeft: true)
        XCTAssertEqual(leftToRight.ordered, [4, 5])
        XCTAssertEqual(leftToRight.initialPosition, 0)

        // 単ページはそのまま
        let single = PageFileInfo.physicalOrder(
            readingOrderIndices: [7], readsFromLeft: false)
        XCTAssertEqual(single.ordered, [7])
        XCTAssertEqual(single.initialPosition, 0)
    }

    /// 南緯・西経は負の座標になること
    func testGPSSouthWestAreNegative() throws {
        let base = TestFixtures.pngData(width: 8, height: 8)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(base as CFData, nil))
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.87,
                kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.21,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ]
        CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let details = PageFileInfo.details(
            entryName: "p.jpg", pathInBook: "p.jpg",
            containerURL: tempDir.appendingPathComponent("p.jpg"),
            pageNumber: 1, pageCount: 1,
            imageData: jpeg as Data, fallbackPixelSize: nil)
        XCTAssertEqual(details.latitude ?? 0, -33.87, accuracy: 0.0001)
        XCTAssertEqual(details.longitude ?? 0, -151.21, accuracy: 0.0001)
    }
}
