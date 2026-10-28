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

    // 相対パスの検証は OS の UTI 登録状態に依存しない拡張子を使う。
    private func makeRelativePathFixture() throws -> URL {
        let root = tempDir.appendingPathComponent("paths", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for (directory, name) in [(root, "a.avifs"), (sub, "c.avifs"),
                                  (root, "book.zip"), (root, "book.pdf")] {
            try Data().write(to: directory.appendingPathComponent(name, isDirectory: false))
        }
        return root
    }

    private func legacyRelativePath(fileURL: URL, folderURL: URL) -> String {
        let basePath = folderURL.standardizedFileURL.path
        let fullPath = fileURL.standardizedFileURL.path
        var relativePath = fullPath.hasPrefix(basePath)
            ? String(fullPath.dropFirst(basePath.count)) : fileURL.lastPathComponent
        if relativePath.hasPrefix("/") { relativePath.removeFirst() }
        return relativePath
    }

    private func assertLegacyPaths(at url: URL, recursive: Bool = false,
                                   expectedFast: Bool = true,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = try FolderSource(url: url, readSubFolders: recursive)
        let entries = try await source.entries()
        var urls: [URL]
        if recursive {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]))
            urls = enumerator.allObjects.compactMap { $0 as? URL }
        } else {
            urls = try FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        }
        urls.sort { $0.path < $1.path }
        urls = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                && (["png", "jpg", "avifs"].contains($0.pathExtension) || SupportedTypes.isBookFile($0))
        }
        let images = urls.filter { ["png", "jpg", "avifs"].contains($0.pathExtension) }
        let books = urls.filter { !["png", "jpg", "avifs"].contains($0.pathExtension) }
        XCTAssertEqual(entries.map { Array($0.pathInBook.utf8) },
                       images.map { Array(legacyRelativePath(fileURL: $0, folderURL: url).utf8) },
                       file: file, line: line)
        XCTAssertEqual(entries.map(\.fileURL), images.map { Optional($0) }, file: file, line: line)
        XCTAssertEqual(entries.map(\.id), Array(images.indices), file: file, line: line)
        XCTAssertEqual(source.nestedBookCandidates.map { Array($0.relativePath.utf8) },
                       books.map { Array(legacyRelativePath(fileURL: $0, folderURL: url).utf8) },
                       file: file, line: line)
        let base = url.standardizedFileURL.path
        let prefixes = FolderSource.fastPrefixes(for: url, standardizedBasePath: base)
        for child in urls {
            let result = FolderSource.relativePath(of: child, fastPrefixes: prefixes, standardizedBasePath: base)
            XCTAssertEqual(Array(result.path.utf8), Array(legacyRelativePath(fileURL: child, folderURL: url).utf8),
                           file: file, line: line)
            XCTAssertEqual(result.usedFastPath, expectedFast, child.path, file: file, line: line)
        }
    }

    func testRelativePathsMatchLegacyForVarSpelledTempURL() async throws {
        let root = try makeRelativePathFixture()
        let path = root.path.hasPrefix("/private/var/") ? String(root.path.dropFirst(8)) : root.path
        XCTAssertTrue(path.hasPrefix("/var/"))
        try await assertLegacyPaths(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    func testRelativePathsMatchLegacyForPrivatePrefixedURL() async throws {
        let root = try makeRelativePathFixture()
        let path = root.path.hasPrefix("/private/") ? root.path : "/private" + root.path
        try await assertLegacyPaths(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    func testRelativePathsMatchLegacyForDotDotURL() async throws {
        let root = try makeRelativePathFixture()
        try await assertLegacyPaths(at: URL(fileURLWithPath: root.path + "/sub/..", isDirectory: true))
    }

    func testRelativePathsMatchLegacyRecursively() async throws {
        let root = try makeRelativePathFixture()
        let deep = root.appendingPathComponent("sub/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for name in ["image.avifs", "book.zip", "book.pdf"] {
            try Data().write(to: deep.appendingPathComponent(name, isDirectory: false))
        }
        try await assertLegacyPaths(at: root, recursive: true)
    }

    func testRelativePathsMatchLegacyForDecomposedUnicodeNames() async throws {
        let folder = tempDir.appendingPathComponent("cafe\u{301}", isDirectory: true)
        let sub = folder.appendingPathComponent("e\u{301}tage", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["cafe\u{301}.avifs", "cafe\u{301}.zip"] {
            try Data().write(to: sub.appendingPathComponent(name, isDirectory: false))
        }
        try await assertLegacyPaths(at: folder, recursive: true)
        let encoded = try XCTUnwrap(folder.path.precomposedStringWithCanonicalMapping
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        let composed = try XCTUnwrap(URL(string: "file://" + encoded + "/"))
        try await assertLegacyPaths(at: composed, recursive: true, expectedFast: false)
    }

    func testCaseMismatchedFolderURLKeepsLegacyRelativePaths() async throws {
        let folder = tempDir.appendingPathComponent("MixedCase", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("a.avifs", isDirectory: false))
        let mismatched = tempDir.appendingPathComponent("mixedcase", isDirectory: true)
        guard FileManager.default.fileExists(atPath: mismatched.path) else {
            throw XCTSkip("大小文字を区別するファイルシステム")
        }
        try await assertLegacyPaths(at: mismatched, expectedFast: false)
    }

    func testSymlinkedLeafFileKeepsLegacyRelativePath() async throws {
        let root = try makeRelativePathFixture()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.avifs"),
                                                   withDestinationURL: root.appendingPathComponent("a.avifs"))
        try await assertLegacyPaths(at: root)
    }

    func testSymlinkedFolderURLBehavesAsBefore() throws {
        let link = tempDir.appendingPathComponent("linked", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tempDir.appendingPathComponent("sub"))
        XCTAssertThrowsError(try FileManager.default.contentsOfDirectory(at: link,
            includingPropertiesForKeys: [.isDirectoryKey]))
        XCTAssertThrowsError(try FolderSource(url: link, readSubFolders: false))
    }

    func testFastRelativePathHelperBranches() {
        let base = "/synthetic/base"
        let cases: [(String, Bool)] = [
            (base + "/sub/a.png", true), (base + "/a.png", true),
            (base, false), (base + "Extra/a.png", false),
            (base + "/sub/../a.png", false), (base + "/./a.png", false),
            ("/synthetic/cafe\u{301}/a.png", false),
        ]
        for (path, fast) in cases {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            let result = FolderSource.relativePath(of: url, fastPrefixes: [base], standardizedBasePath: base)
            XCTAssertEqual(result.usedFastPath, fast, path)
            XCTAssertEqual(Array(result.path.utf8), Array(legacyRelativePath(
                fileURL: url, folderURL: URL(fileURLWithPath: base, isDirectory: true)).utf8))
        }
        let unicode = FolderSource.relativePath(of: URL(fileURLWithPath: "/synthetic/cafe\u{301}/a.png"),
            fastPrefixes: ["/synthetic/café"], standardizedBasePath: "/synthetic/café")
        XCTAssertFalse(unicode.usedFastPath)
        let emptyComponent = FolderSource.relativePath(of: URL(string: "file://" + base + "//a.png")!,
            fastPrefixes: [base], standardizedBasePath: base)
        XCTAssertFalse(emptyComponent.usedFastPath)
        let fallback = FolderSource.relativePath(of: URL(fileURLWithPath: base + "/a.png"),
            fastPrefixes: [], standardizedBasePath: base)
        XCTAssertFalse(fallback.usedFastPath)
    }

    private func assertRARContinuations(_ names: [String], expected: Set<String>) throws {
        for name in names {
            let url = tempDir.appendingPathComponent(name, isDirectory: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: url)
        }
        let source = try FolderSource(url: tempDir, readSubFolders: true)
        XCTAssertEqual(Set(source.splitContinuationCandidateIndices.map {
            source.nestedBookCandidates[$0].relativePath
        }), expected)
        XCTAssertEqual(source.nestedBookCandidates.count, names.count)
    }

    func testRARPartContinuationsFlaggedWhenFirstPartPresent() throws {
        try assertRARContinuations(["x.part1.rar", "x.part2.rar", "x.part3.rar"],
                                   expected: ["x.part2.rar", "x.part3.rar"])
    }

    func testRARPartNumbersCanGrowBeyondFirstPartWidth() throws {
        try assertRARContinuations(["x.part1.rar", "x.part2.rar", "x.part10.rar", "x.part12.rar"],
                                   expected: ["x.part2.rar", "x.part10.rar", "x.part12.rar"])
    }

    func testZeroPaddedPartSetRequiresSameWidth() throws {
        try assertRARContinuations([
            "x.part01.rar", "x.part02.rar", "x.part2.rar", "x.part0003.rar", "x.part100.rar",
            "y.part1.rar", "y.part02.rar", "z.part001.rar", "z.part02.rar", "z.part010.rar",
        ], expected: ["x.part02.rar", "x.part100.rar", "z.part010.rar"])
    }

    func testLonePartContinuationIsNotFlagged() throws {
        try assertRARContinuations(["x.part2.rar"], expected: [])
    }

    func testPartSiblingMustBeInSameDirectory() throws {
        try assertRARContinuations(["one/x.part1.rar", "two/x.part2.rar"], expected: [])
    }

    func testPartPrefixCaseMismatchIsNotFlagged() throws {
        try assertRARContinuations(["X.part1.rar", "x.part2.rar"], expected: [])
    }

    func testPartMarkerAndExtensionSpellingMustMatch() throws {
        try assertRARContinuations([
            "marker.part1.rar", "marker.PART2.rar", "extension.part1.rar", "extension.part2.RAR",
            "X.PART01.RAR", "X.PART02.RAR",
        ], expected: ["X.PART02.RAR"])
    }

    func testUnrelatedPartNamesAreNotFlagged() throws {
        try assertRARContinuations([
            "x.part1.rar", "y.part2.rar", "x.part.rar", "x.partA.rar", "x.part0.rar",
            "x.part2.backup.rar", "x.part２.rar", "x.part2.cbr", "x.part1.part2.rar",
        ], expected: [])
    }

    func testPartNumbersAndPaddingAreNotLimitedByIntegerWidth() throws {
        let first = "x.part" + String(repeating: "0", count: 30) + "1.rar"
        let large = "18446744073709551616"
        let continuation = "x.part" + String(repeating: "0", count: 11) + large + ".rar"
        let unpadded = "y.part" + large + ".rar"
        try assertRARContinuations([first, "x.part" + large + ".rar", continuation, "y.part1.rar", unpadded],
                                   expected: [continuation, unpadded])
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
