import Foundation
import os
import Washi
import XCTest
@testable import cooViewer

/// マップできないボリューム上の EPUB をローカルへステージングして開く経路
/// (設計書 §5 EPUB のステージング)。ボリューム判定・空き容量・コピーを
/// 注入し、実ファイルは一時ディレクトリに置く。
final class EPUBStagingAreaTests: XCTestCase {
    private var workDirectory: URL!
    private var stagingDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBStagingAreaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: true)
        stagingDirectory = workDirectory.appendingPathComponent("staging")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: - 補助

    /// コピー呼び出しの回数
    private final class Copies: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: 0)
        var count: Int { storage.withLock { $0 } }
        func increment() { storage.withLock { $0 += 1 } }
    }

    /// 最小のリフロー EPUB をファイルとして書き出す(題名 = name)
    private func writeEPUB(named name: String) throws -> URL {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/package.opf"
            media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">staging-\(name)</dc:identifier>
            <dc:title>\(name)</dc:title><dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-10-01T00:00:00Z</meta>
          </metadata>
          <manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>1</title></head>
        <body><p>本文</p></body></html>
        """
        let data = TestFixtures.storedZip(entries: [
            (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
            (Array("META-INF/container.xml".utf8), Data(container.utf8)),
            (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
            (Array("OEBPS/ch1.xhtml".utf8), Data(chapter.utf8)),
        ])
        let url = workDirectory.appendingPathComponent("\(name).epub")
        try data.write(to: url)
        return url
    }

    /// 既定はマップ不可のボリュームとして扱い、コピーは数えつつ実コピーする。
    /// コピーはオープン経路なので、メイン外かつ userInitiated で走ることも固定する
    private func makeArea(
        isSafe: Bool = false,
        availableCapacity: Int64? = .max,
        copies: Copies = Copies(),
        copy: (@Sendable (URL, URL) throws -> Void)? = nil
    ) -> EPUBStagingArea {
        let copy = copy ?? { try FileManager.default.copyItem(at: $0, to: $1) }
        return EPUBStagingArea(environment: .init(
            directory: stagingDirectory,
            probe: FileManagerProbe(),
            isSafeForMemoryMapping: { _ in isSafe },
            availableCapacity: { _ in availableCapacity },
            copy: { source, destination in
                copies.increment()
                XCTAssertFalse(Thread.isMainThread, "コピーはメインスレッドで走らない")
                XCTAssertEqual(qos_class_self(), QOS_CLASS_USER_INITIATED,
                               "コピーはオープン経路の優先度で走る")
                try copy(source, destination)
            }))
    }

    private func stagedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    /// 背面の unlink を待つ
    private func waitUntilStagingEmpty(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stagedFiles().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return stagedFiles().isEmpty
    }

    private func assertRegularFile(_ url: URL, file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertEqual(values.isRegularFile, true, "コピーはリンクではなく実体",
                       file: file, line: line)
        XCTAssertEqual(values.isSymbolicLink, false, file: file, line: line)
    }

    // MARK: - 方針

    func testSafeLocalVolumeOpensDirectlyWithoutStaging() async throws {
        let url = try writeEPUB(named: "local")
        let copies = Copies()
        let area = makeArea(isSafe: true, copies: copies)
        let publication = try await area.openPublication(at: url)
        XCTAssertEqual(publication.url, url)
        XCTAssertEqual(copies.count, 0, "安全なローカルボリュームはコピーしない")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path),
                       "ステージングディレクトリも作らない")
    }

    func testUnsafeVolumeOpensStagedCopyUnderOriginalURL() async throws {
        let url = try writeEPUB(named: "nas")
        let copies = Copies()
        let area = makeArea(copies: copies)
        let publication = try await area.openPublication(at: url)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(stagedFiles().count, 1, "ステージングファイルは 1 つ")
        // 同一性: 保存キーになる URL は元ファイル、ステージング先ではない
        XCTAssertEqual(publication.url, url)
        XCTAssertFalse(publication.url.path.hasPrefix(stagingDirectory.path))
        XCTAssertEqual(publication.metadata.mainTitle, "nas", "コピーから本文が読める")
        let staged = try XCTUnwrap(stagedFiles().first)
        try assertRegularFile(staged)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: staged.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testCopyFailureFallsBackToInMemoryCopy() async throws {
        struct CopyFailed: Error {}
        let url = try writeEPUB(named: "fails")
        let area = makeArea(copy: { _, destination in
            // 部分コピーを残して失敗する
            try Data([0x50, 0x4b]).write(to: destination)
            throw CopyFailed()
        })
        let publication = try await area.openPublication(at: url)
        XCTAssertEqual(publication.url, url)
        XCTAssertEqual(publication.metadata.mainTitle, "fails", "従来の alwaysCopy で開く")
        XCTAssertTrue(stagedFiles().isEmpty, "失敗した部分コピーは残さない")
    }

    func testInsufficientSpaceFallsBackWithoutCopying() async throws {
        let url = try writeEPUB(named: "full")
        let copies = Copies()
        let area = makeArea(availableCapacity: EPUBStagingArea.capacityHeadroom,
                            copies: copies)
        let publication = try await area.openPublication(at: url)
        XCTAssertEqual(publication.metadata.mainTitle, "full")
        XCTAssertEqual(copies.count, 0, "空き不足ではコピーを始めない")
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    func testSourceChangedDuringCopyFallsBack() async throws {
        let url = try writeEPUB(named: "changed")
        let area = makeArea(copy: { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
            // コピー中に元が差し替えられた(更新日時が進んだ)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 60)],
                ofItemAtPath: source.path)
        })
        let publication = try await area.openPublication(at: url)
        XCTAssertEqual(publication.metadata.mainTitle, "changed", "alwaysCopy へ戻る")
        let emptied = await waitUntilStagingEmpty()
        XCTAssertTrue(emptied, "同一性の変わったコピーは捨てる")
    }

    func testTruncatedCopyIsNeverOpened() async throws {
        let url = try writeEPUB(named: "truncated")
        let area = makeArea(copy: { _, destination in
            // 失敗を報告しないまま短いファイルが出来た
            try Data("partial".utf8).write(to: destination)
        })
        let publication = try await area.openPublication(at: url)
        XCTAssertEqual(publication.url, url)
        XCTAssertEqual(publication.metadata.mainTitle, "truncated", "元を alwaysCopy で読む")
        let emptied = await waitUntilStagingEmpty()
        XCTAssertTrue(emptied, "サイズの合わないコピーは捨てる")
    }

    func testStagedParseFailureFallsBackToInMemoryCopy() async throws {
        let url = try writeEPUB(named: "corrupt-copy")
        let area = makeArea(copy: { source, destination in
            // サイズと同一性は合うが中身が壊れたコピー
            try FileManager.default.copyItem(at: source, to: destination)
            let size = try FileManager.default.attributesOfItem(
                atPath: destination.path)[.size] as? Int ?? 0
            try Data(count: size).write(to: destination)
        })
        let publication = try await area.openPublication(at: url)
        XCTAssertEqual(publication.url, url)
        XCTAssertEqual(publication.metadata.mainTitle, "corrupt-copy",
                       "コピーの解析に失敗したら元を alwaysCopy で読む")
        let emptied = await waitUntilStagingEmpty()
        XCTAssertTrue(emptied, "解析できなかったコピーは利用者がいないので消える")
    }

    func testUnpackedDirectoryIsNotStaged() async throws {
        let directory = workDirectory.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copies = Copies()
        let area = makeArea(copies: copies)
        let copy = await area.stagedCopy(forResolvedPath: CanonicalPath.normalize(directory.path))
        XCTAssertNil(copy)
        XCTAssertEqual(copies.count, 0)
    }

    func testHasRoomRequiresHeadroomAndKnownCapacity() {
        let headroom = EPUBStagingArea.capacityHeadroom
        XCTAssertFalse(EPUBStagingArea.hasRoom(forFileOfSize: 1, availableCapacity: nil))
        XCTAssertFalse(EPUBStagingArea.hasRoom(forFileOfSize: 1, availableCapacity: headroom))
        XCTAssertTrue(EPUBStagingArea.hasRoom(forFileOfSize: 1, availableCapacity: headroom + 1))
        XCTAssertTrue(EPUBStagingArea.hasRoom(forFileOfSize: 0, availableCapacity: headroom))
    }

    // MARK: - 共有と寿命

    func testSameFileSharesOneStagedCopyAcrossOpens() async throws {
        let url = try writeEPUB(named: "shared")
        let copies = Copies()
        let area = makeArea(copies: copies)
        let first = try await area.openPublication(at: url)
        let second = try await area.openPublication(at: url)
        XCTAssertEqual(copies.count, 1, "同じ実体は 1 回しかコピーしない")
        XCTAssertEqual(stagedFiles().count, 1)
        XCTAssertFalse(first === second, "publication 自体は呼び出しごとに別")
        withExtendedLifetime((first, second)) {}
    }

    func testDifferentFilesAndChangedIdentitiesHaveDifferentCopies() async throws {
        let url = try writeEPUB(named: "a")
        let other = try writeEPUB(named: "b")
        let copies = Copies()
        let area = makeArea(copies: copies)
        let first = try await area.openPublication(at: url)
        let second = try await area.openPublication(at: other)
        XCTAssertEqual(copies.count, 2, "別のファイルは別のコピー")
        // 同じパスでも更新日時が変われば別の実体
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: url.path)
        let changed = try await area.openPublication(at: url)
        XCTAssertEqual(copies.count, 3, "差し替えられた本は改めてコピーする")
        XCTAssertEqual(stagedFiles().count, 3)
        withExtendedLifetime((first, second, changed)) {}
    }

    func testConcurrentOpensOfSameFileCopyOnce() async throws {
        let url = try writeEPUB(named: "concurrent")
        let copies = Copies()
        let area = makeArea(copies: copies, copy: { source, destination in
            Thread.sleep(forTimeInterval: 0.2)
            try FileManager.default.copyItem(at: source, to: destination)
        })
        async let a = area.openPublication(at: url)
        async let b = area.openPublication(at: url)
        let (first, second) = try await (a, b)
        XCTAssertEqual(copies.count, 1, "進行中のコピーに合流する")
        XCTAssertEqual(first.url, second.url)
    }

    func testStagedCopyIsRemovedWhenLastPublicationIsReleased() async throws {
        let url = try writeEPUB(named: "lifetime")
        let area = makeArea()
        var first: EPUBPublication? = try await area.openPublication(at: url)
        var second: EPUBPublication? = try await area.openPublication(at: url)
        XCTAssertEqual(stagedFiles().count, 1)
        first = nil
        XCTAssertEqual(stagedFiles().count, 1, "まだ使っている本がある間は残す")
        XCTAssertEqual(second?.metadata.mainTitle, "lifetime", "残った本は読める")
        second = nil
        let emptied = await waitUntilStagingEmpty()
        XCTAssertTrue(emptied, "最後の利用者が手放したらコピーを消す")
        // 消えた後に開き直せば改めてコピーする
        let reopened = try await area.openPublication(at: url)
        XCTAssertEqual(stagedFiles().count, 1)
        XCTAssertEqual(reopened.url, url)
    }

    func testTerminationRemovesDirectoryWhileMappedDataStaysReadable() async throws {
        let url = try writeEPUB(named: "terminating")
        let area = makeArea()
        let staged = await area.stagedCopy(forResolvedPath: CanonicalPath.normalize(url.path))
        let copy = try XCTUnwrap(staged)
        let data = try XCTUnwrap(copy.mappedData())
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDirectory.path))

        area.removeDirectoryAtTermination()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path),
                       "利用者が残っていてもディレクトリは同期に消える")
        // unlink 済みでもマッピングは有効で、中身は読める
        let publication = try EPUBPublication(data: data, displayURL: url)
        XCTAssertEqual(publication.metadata.mainTitle, "terminating")
        withExtendedLifetime(copy) {}
    }

    // MARK: - 同一性(保存キー)

    @MainActor
    func testPublicationUsesOriginalPathForStateRecentsAndCensus() async throws {
        let url = try writeEPUB(named: "history")
        let area = makeArea()
        let publication = try await area.openPublication(at: url)
        let staged = try XCTUnwrap(stagedFiles().first)
        let suite = "EPUBStagingAreaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = BookHistoryStore(
            defaults: defaults, directory: workDirectory.appendingPathComponent("history"))
        history.noteOpened(path: publication.url.path)
        history.noteClosedReflow(path: publication.url.path, spineIndex: 0, progression: 0.4)
        history.noteReflowCensus(path: publication.url.path, metricsKey: "metrics",
                                 counts: [3], releaseIdentifier: nil)
        XCTAssertEqual(history.recentPaths(), [CanonicalPath.normalize(url.path)])
        XCTAssertEqual(history.savedReflowPosition(forPath: url.path, inRecents: true)?.progression,
                       0.4)
        XCTAssertEqual(history.savedReflowCensus(forPath: url.path)?.counts, [3])
        XCTAssertNil(history.savedReflowPosition(forPath: staged.path, inRecents: true),
                     "ステージング先のパスには何も記録されない")
        XCTAssertNil(history.savedReflowCensus(forPath: staged.path))
    }

    // MARK: - シンボリックリンク

    func testSymlinkAndRealPathShareARegularLocalCopy() async throws {
        let source = try writeEPUB(named: "target")
        let link = workDirectory.appendingPathComponent("link.epub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let originalPermissions = try FileManager.default.attributesOfItem(
            atPath: source.path)[.posixPermissions] as? Int
        let copies = Copies()
        let area = makeArea(copies: copies)
        let viaSource = try await area.openPublication(at: source)
        let viaLink = try await area.openPublication(at: link)
        XCTAssertEqual(copies.count, 1, "リンクと実パスは同じ実体として 1 コピーを共有する")
        XCTAssertEqual(stagedFiles().count, 1)
        try assertRegularFile(try XCTUnwrap(stagedFiles().first))
        XCTAssertEqual(viaLink.url, link, "表示 URL はリンクのまま")
        XCTAssertEqual(viaSource.url, source)
        // 元ファイルの権限を変えてはならない(リンクのコピーへの chmod が実体に届く事故)
        XCTAssertEqual(try FileManager.default.attributesOfItem(
            atPath: source.path)[.posixPermissions] as? Int, originalPermissions)
        // 元(切断される媒体)が消えてもコピーから読める
        try FileManager.default.removeItem(at: source)
        XCTAssertFalse(try viaLink.resource(at: "OEBPS/ch1.xhtml").data.isEmpty)
    }

    func testRetargetedSymlinkDuringCopyStagesTheResolvedTarget() async throws {
        let source = try writeEPUB(named: "target")
        let other = try writeEPUB(named: "other")
        let link = workDirectory.appendingPathComponent("link.epub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let area = makeArea(copy: { from, destination in
            try FileManager.default.copyItem(at: from, to: destination)
            // コピー中にリンクが別の本へ向け直された
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        })
        let publication = try await area.openPublication(at: link)
        XCTAssertEqual(publication.url, link)
        // リンクは開く前に実体へ解決しているので、コピーは解決時の実体の忠実な
        // 複製(通常ファイル)になる。リンクのコピーや部分コピーを開くことはない
        XCTAssertEqual(publication.metadata.mainTitle, "target")
        XCTAssertEqual(stagedFiles().count, 1)
        try assertRegularFile(try XCTUnwrap(stagedFiles().first))
    }

    // MARK: - 起動時掃除

    func testStartupCleanupRemovesStagingOfDeadProcesses() throws {
        let root = workDirectory.appendingPathComponent("spool")
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let dead = root.appendingPathComponent("1-\(UUID().uuidString)-epub")
        let live = root.appendingPathComponent("\(ownPid)-\(UUID().uuidString)-epub")
        let unrelated = root.appendingPathComponent("notes.txt")
        for directory in [dead, live] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appendingPathComponent("a.epub"))
        }
        try Data("x".utf8).write(to: unrelated)

        ArchiveSource.removeStaleSpoolDirectories(in: root, livePids: [ownPid])

        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path),
                       "生存しない pid のステージングは消える")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path),
                      "生きている cooViewer の分は残す")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.path),
                       "pid で始まらない残骸も消える")
    }
}
