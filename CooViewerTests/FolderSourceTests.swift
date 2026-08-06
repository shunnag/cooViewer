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
