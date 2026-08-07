import XCTest
@testable import cooViewer

final class ArchiveSourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func writeZip(named name: String,
                          entries: [(nameBytes: [UInt8], data: Data)]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try TestFixtures.storedZip(entries: entries).write(to: url)
        return url
    }

    func testListsImagesAndSkipsJunkEntries() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let url = try writeZip(named: "book.zip", entries: [
            (Array("cover.png".utf8), png),
            (Array("sub/page1.png".utf8), png),
            (Array("__MACOSX/._cover.png".utf8), Data([0, 1, 2])),
            (Array("notes.txt".utf8), Data("x".utf8)),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()
        XCTAssertEqual(Set(entries.map(\.pathInBook)), ["cover.png", "sub/page1.png"])
        let sub = try XCTUnwrap(entries.first { $0.pathInBook == "sub/page1.png" })
        XCTAssertEqual(sub.containerPath, "sub")
        XCTAssertNil(sub.fileURL)
    }

    func testImageExtractsAndDecodes() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let url = try writeZip(named: "book.zip", entries: [(Array("a.png".utf8), png)])
        let source = try ArchiveSource(url: url)
        let entry = try await source.entries()[0]
        let image = try await source.image(for: entry, maxPixelSize: nil)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 6)
    }

    func testShiftJISEntryNamesAreAutoDetected() async throws {
        // UTF-8 フラグなしの DOS ホスト ZIP に Shift-JIS 名を入れると、
        // XADMaster + UniversalDetector が自動判定する(仕様書 §4.17)
        let png = TestFixtures.pngData(width: 2, height: 2)
        let sjis = { (s: String) in [UInt8](s.data(using: .shiftJIS)!) }
        let url = try writeZip(named: "sjis.zip", entries: [
            (sjis("画像1.png"), png),
            (sjis("画像2.png"), png),
            (sjis("漫画テスト絵巻.png"), png),
        ])
        let source = try ArchiveSource(url: url)
        let names = try await source.entries().map(\.name)
        XCTAssertEqual(Set(names), ["画像1.png", "画像2.png", "漫画テスト絵巻.png"])
    }

    func testEncryptedZipPasswordFlow() async throws {
        // ZipCrypto 暗号化 ZIP を zip CLI で生成
        let plain = tempDir.appendingPathComponent("secret.png")
        try TestFixtures.pngData(width: 3, height: 3).write(to: plain)
        let zipURL = tempDir.appendingPathComponent("locked.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-j", "-P", "hunter2", zipURL.path, plain.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let source = try ArchiveSource(url: zipURL)
        let encrypted = await source.isEncrypted()
        XCTAssertTrue(encrypted)
        let wrong = await source.checkAndSetPassword("wrong")
        XCTAssertFalse(wrong)
        let right = await source.checkAndSetPassword("hunter2")
        XCTAssertTrue(right)
        let entry = try await source.entries()[0]
        let image = try await source.image(for: entry, maxPixelSize: nil)
        XCTAssertEqual(image.width, 3)
    }

    func testSpoolingServesPagesFromLocalFiles() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let url = try writeZip(named: "book.zip", entries: [
            (Array("a.png".utf8), png),
            (Array("b.png".utf8), png),
            (Array("c.png".utf8), png),
        ])
        let source = try ArchiveSource(url: url)
        await source.beginSpooling(sizeLimit: 1 << 30)
        await source.waitForSpoolCompletion()
        let spooled = await source.spooledEntryCount
        XCTAssertEqual(spooled, 3)
        // スプール後もページは正しくデコードできる
        let entry = try await source.entries()[1]
        let image = try await source.image(for: entry, maxPixelSize: nil)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 6)
    }

    func testSpoolingSkippedWhenOverSizeLimit() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let url = try writeZip(named: "book.zip", entries: [(Array("a.png".utf8), png)])
        let source = try ArchiveSource(url: url)
        await source.beginSpooling(sizeLimit: 1)  // 上限超過 → スプールしない
        await source.waitForSpoolCompletion()
        let spooled = await source.spooledEntryCount
        XCTAssertEqual(spooled, 0)
        // オンデマンド経路は従来どおり動く
        let entry = try await source.entries()[0]
        let image = try await source.image(for: entry, maxPixelSize: nil)
        XCTAssertEqual(image.width, 4)
    }

    func testGarbageArchiveDoesNotCrash() async throws {
        let url = tempDir.appendingPathComponent("garbage.zip")
        try Data((0..<256).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        // 旧実装は壊れた書庫を「空の本」として扱う(仕様書 §4.17)。
        // 生成に失敗するか、成功してもエントリ 0 件であること。
        if let source = try? ArchiveSource(url: url) {
            let entries = try await source.entries()
            XCTAssertEqual(entries.count, 0)
        }
    }
}
