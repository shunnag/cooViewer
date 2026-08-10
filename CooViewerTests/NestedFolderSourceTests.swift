import PDFKit
import os
import XCTest

@testable import cooViewer

/// フォルダ内の書庫/PDF の統合(旧ネスト COImageLoader のフォルダ版)のテスト。
/// EN: Folder books that merge archives/PDFs inside the folder.
final class NestedFolderSourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func png(width: Int) -> Data {
        TestFixtures.pngData(width: width, height: 60)
    }

    private func zipData(_ entries: [(String, Data)]) -> Data {
        TestFixtures.storedZip(entries: entries.map { (Array($0.0.utf8), $0.1) })
    }

    private func makePDFData(pageCount: Int) throws -> Data {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 40, height: 60))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 40, height: 60).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: index)
        }
        return try XCTUnwrap(document.dataRepresentation())
    }

    /// 画像だけのフォルダは従来どおり FolderSource(並列・日付ソート可)のまま
    func testPlainImageFolderStaysFolderSource() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("a.png"))
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        XCTAssertTrue(source is FolderSource)
        XCTAssertTrue(source.supportsDateSort)
    }

    /// 書庫/PDF を含むフォルダは統合ソースになり、パス単純順で 1 冊に組まれること
    func testFolderWithBooksMergesTheirPages() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("00.png"))
        try zipData([("p1.png", png(width: 41)), ("p2.png", png(width: 42))])
            .write(to: tempDir.appendingPathComponent("10_inner.zip"))
        try png(width: 43).write(to: tempDir.appendingPathComponent("20.png"))
        try makePDFData(pageCount: 2)
            .write(to: tempDir.appendingPathComponent("30_vol.pdf"))

        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        XCTAssertTrue(source is NestedFolderSource)
        XCTAssertFalse(source.supportsDateSort,
                       "ネスト書庫を含む本は日付ソート不可(旧 canSortByDate 規則)")

        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), [
            "00.png",
            "10_inner.zip/p1.png", "10_inner.zip/p2.png",
            "20.png",
            "30_vol.pdf/000000", "30_vol.pdf/000001",
        ])
        // 外側画像は元 id、ネストは 1M 刻みの序数域
        XCTAssertEqual(entries.map(\.id),
                       [0, 1_000_000, 1_000_001, 1, 2_000_000, 2_000_001])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)

        // 各エントリの画像内容(幅マーカー。PDF はレンダリングできること)
        for (entry, width) in [(entries[0], 40), (entries[1], 41),
                               (entries[2], 42), (entries[3], 43)] {
            let image = try await source.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, width, entry.pathInBook)
        }
        let pdfPage = try await source.image(for: entries[4], maxPixelSize: nil)
        XCTAssertGreaterThan(pdfPage.width, 0)

        // 外側画像は実ファイル URL を保持(ゴミ箱/Finder 機能用)。ネストは nil
        XCTAssertNotNil(entries[0].fileURL)
        XCTAssertNil(entries[1].fileURL)
    }

    /// 壊れた書庫は黙って飛ばし、残りは無傷なこと(仕様書 §4.17)
    func testCorruptArchiveInFolderIsSkipped() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("00.png"))
        try Data([0x50, 0x4B, 0xFF]).write(to: tempDir.appendingPathComponent("broken.zip"))
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["00.png"])
    }

    /// 並列の子構築でも解錠は直列化され、同じパスワードの 2 冊目は
    /// 入力を再利用してダイアログが 1 回で済むこと(多重プロンプト防止)
    func testParallelChildBuildSerializesUnlockPrompts() async throws {
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        for name in ["lockedA.zip", "lockedB.zip"] {
            let plain = tempDir.appendingPathComponent("p-\(name).png")
            try png(width: 41).write(to: plain)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-j", "-P", "sesame",
                                 tempDir.appendingPathComponent(name).path, plain.path]
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(at: plain)
        }
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false,
            nestedPasswordProvider: { _, _ in
                prompts.withLock { $0 += 1 }
                return "sesame"
            })
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(prompts.withLock { $0 }, 1,
                       "並列構築でもプロンプトは 1 回(直列化+既知パスワード再利用)")
    }

    /// 分割書庫の続き巻(.002 等)は候補にしない(画像だけなら FolderSource のまま)
    func testSplitVolumeContinuationDoesNotTriggerMerging() async throws {
        try png(width: 40).write(to: tempDir.appendingPathComponent("a.png"))
        try Data([0x00]).write(to: tempDir.appendingPathComponent("video.002"))
        try Data([0x00]).write(to: tempDir.appendingPathComponent("part.r00"))
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        XCTAssertTrue(source is FolderSource,
                      "続き巻だけならフォルダは従来どおり(並列・日付ソート維持)")
    }

    /// 暗号化された書庫は provider へ問い合わせて解除されること
    func testEncryptedArchiveInFolderUnlockedViaProvider() async throws {
        // zip CLI で暗号化 ZIP を作る
        let plain = tempDir.appendingPathComponent("p1.png")
        try png(width: 41).write(to: plain)
        let lockedURL = tempDir.appendingPathComponent("locked.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", "-P", "sesame", lockedURL.path, plain.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.removeItem(at: plain)  // 平文は消して zip だけ残す

        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false,
            nestedPasswordProvider: { _, _ in "sesame" })
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["locked.zip/p1.png"])
        let image = try await source.image(for: entries[0], maxPixelSize: nil)
        XCTAssertEqual(image.width, 41)
    }

    /// 組み立て進捗が (0,総数)→…→(総数,総数) で単調に通知されること
    /// (オープン進捗 HUD の情報源)
    func testAssemblyProgressReportsMonotonicCounts() async throws {
        for name in ["a.zip", "b.zip", "c.zip"] {
            try zipData([("p1.png", png(width: 40))])
                .write(to: tempDir.appendingPathComponent(name))
        }
        let source = try await BookSourceFactory.make(
            for: tempDir, readSubFolders: false)
        let collector = ProgressCollector()
        await source.setAssemblyProgressHandler { done, total in
            collector.append(done: done, total: total)
        }
        _ = try await source.entries()

        let events = collector.events
        XCTAssertEqual(events.first?.done, 0, "開始時に 0/総数 を通知")
        XCTAssertEqual(events.last?.done, 3)
        XCTAssertTrue(events.allSatisfy { $0.total == 3 })
        XCTAssertEqual(events.map(\.done), events.map(\.done).sorted(),
                       "完了数は単調増加")
    }
}

/// 進捗コールバックの記録(actor 外から呼ばれるためロックで保護)
/// EN: Thread-safe collector for progress callback events.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(done: Int, total: Int)] = []

    func append(done: Int, total: Int) {
        lock.lock()
        stored.append((done, total))
        lock.unlock()
    }

    var events: [(done: Int, total: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
