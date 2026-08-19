import XCTest
@testable import cooViewer

final class FolderSourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
        let files: [(String, Data)] = [
            ("a.png", TestFixtures.pngData(width: 4, height: 4)),
            ("b.jpg", TestFixtures.pngData(width: 4, height: 4)),  // 中身は PNG だが拡張子判定
            (".hidden.png", TestFixtures.pngData(width: 4, height: 4)),
            ("note.txt", Data("text".utf8)),
        ]
        for (name, data) in files {
            try data.write(to: tempDir.appendingPathComponent(name))
        }
        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try TestFixtures.pngData(width: 8, height: 2)
            .write(to: subDir.appendingPathComponent("c.png"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    func testMetadataReadsComicInfoFile() async throws {
        // フォルダ直下の ComicInfo.xml を metadata() が読むこと(4fi.2)
        let xml = Data("<ComicInfo><Series>フォルダ本</Series><Manga>No</Manga></ComicInfo>".utf8)
        try xml.write(to: tempDir.appendingPathComponent("ComicInfo.xml"))
        let source = try FolderSource(url: tempDir, readSubFolders: false)
        let fetched = await source.metadata()
        let info = try XCTUnwrap(fetched)
        XCTAssertEqual(info.series, "フォルダ本")
        XCTAssertEqual(info.manga, .no)
        XCTAssertEqual(info.manga.readsRightToLeft, false)
    }

    func testMetadataNilWhenNoComicInfoFile() async throws {
        let source = try FolderSource(url: tempDir, readSubFolders: false)
        let info = await source.metadata()
        XCTAssertNil(info)
    }

    func testNonRecursiveListsTopLevelImagesOnly() async throws {
        let source = try FolderSource(url: tempDir, readSubFolders: false)
        let entries = try await source.entries()
        XCTAssertEqual(Set(entries.map(\.name)), ["a.png", "b.jpg"])
        XCTAssertTrue(entries.allSatisfy { $0.fileURL != nil })
        XCTAssertTrue(entries.allSatisfy { $0.modificationDate != nil })
    }

    func testRecursiveIncludesSubfolderWithRelativePath() async throws {
        let source = try FolderSource(url: tempDir, readSubFolders: true)
        let entries = try await source.entries()
        XCTAssertEqual(Set(entries.map(\.name)), ["a.png", "b.jpg", "c.png"])
        let sub = try XCTUnwrap(entries.first { $0.name == "c.png" })
        XCTAssertEqual(sub.pathInBook, "sub/c.png")
        XCTAssertEqual(sub.containerPath, "sub")
    }

    func testImageLoadsAndDecodes() async throws {
        let source = try FolderSource(url: tempDir, readSubFolders: true)
        let entries = try await source.entries()
        let entry = try XCTUnwrap(entries.first { $0.name == "c.png" })
        let image = try await source.image(for: entry, maxPixelSize: nil)
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 2)
    }

    func testDateSortSupported() {
        XCTAssertTrue((try! FolderSource(url: tempDir, readSubFolders: false)).supportsDateSort)
    }
}

/// レビュー修正の回帰: フォルダの id は列挙順ではなくパス順で安定させる
/// (id はディスクのサムネイルキャッシュのキーになるため)
final class FolderEntryIDStabilityTests: XCTestCase {
    func testEntryIDsFollowPathOrder() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["c.png", "a.png", "b.png"] {
            try TestFixtures.pngData(width: 8, height: 8)
                .write(to: root.appendingPathComponent(name))
        }
        let source = try FolderSource(url: root, readSubFolders: false)
        let entries = try await source.entries()
        // パス昇順に 0,1,2 が振られる(列挙順に依存しない)
        XCTAssertEqual(entries.map(\.name), ["a.png", "b.png", "c.png"])
        XCTAssertEqual(entries.map(\.id), [0, 1, 2])
    }
}
