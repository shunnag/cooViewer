import AppKit
import PDFKit
import XCTest

@testable import cooViewer

/// 書庫内書庫(ネスト書庫。仕様書 §2.4)のテスト。
/// ページ列の組み立て順・id 空間・開き直しでの安定性・深さ上限・壊れ書庫の
/// スキップと、サムネイルキャッシュのキー衝突がないことを確認する。
/// EN: Nested-archive coverage: assembly order, id space, reopen stability,
/// EN: depth cap, corrupt-child skipping, and thumbnail-cache key isolation.
final class NestedArchiveSourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    /// 幅をページの「内容マーカー」に使う(width が一致すれば正しい画像)
    /// EN: Page width doubles as a content marker for identity assertions.
    private func png(width: Int) -> Data {
        TestFixtures.pngData(width: width, height: 60)
    }

    private func zipData(_ entries: [(String, Data)]) -> Data {
        TestFixtures.storedZip(entries: entries.map { (Array($0.0.utf8), $0.1) })
    }

    private func writeZip(named name: String, _ entries: [(String, Data)]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try zipData(entries).write(to: url)
        return url
    }

    /// 外側画像とネスト書庫のページが書庫の列挙順で 1 冊に組まれ、
    /// id が「外側=エントリ番号 / ネスト=序数×1M+連番」で衝突しないこと
    func testNestedPagesInterleaveInArchiveOrder() async throws {
        let url = try writeZip(named: "nested.zip", [
            ("00.png", png(width: 40)),
            ("innerA.zip", zipData([("a1.png", png(width: 41)), ("a2.png", png(width: 42))])),
            ("10.png", png(width: 43)),
            ("innerB.zip", zipData([("b1.png", png(width: 51)), ("b2.png", png(width: 52))])),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()

        XCTAssertEqual(entries.map(\.pathInBook), [
            "00.png",
            "innerA.zip/a1.png", "innerA.zip/a2.png",
            "10.png",
            "innerB.zip/b1.png", "innerB.zip/b2.png",
        ])
        XCTAssertEqual(entries.map(\.id), [0, 1_000_000, 1_000_001, 2, 2_000_000, 2_000_001])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "id が一意であること")

        // 各エントリが正しい画像に対応している(幅マーカーで検証)
        for (entry, width) in zip(entries, [40, 41, 42, 43, 51, 52]) {
            let image = try await source.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, width, "\(entry.pathInBook) の画像内容")
        }
    }

    /// 同じ書庫を開き直しても id と並びが変わらない(ディスクの
    /// サムネイルキャッシュ <bookKey>/<id>.png の同一性の前提)こと
    func testEntriesAndCacheKeyStableAcrossReopen() async throws {
        let url = try writeZip(named: "stable.zip", [
            ("cover.png", png(width: 30)),
            ("inner.zip", zipData([("p1.png", png(width: 31)), ("p2.png", png(width: 32))])),
        ])
        let first = try ArchiveSource(url: url)
        let second = try ArchiveSource(url: url)
        let firstEntries = try await first.entries()
        let secondEntries = try await second.entries()
        XCTAssertEqual(firstEntries.map(\.id), secondEntries.map(\.id))
        XCTAssertEqual(firstEntries.map(\.pathInBook), secondEntries.map(\.pathInBook))

        let firstBook = await MainActor.run { Book(source: first, entries: firstEntries) }
        let secondBook = await MainActor.run { Book(source: second, entries: secondEntries) }
        await MainActor.run {
            XCTAssertEqual(firstBook.cacheKey, secondBook.cacheKey,
                           "開き直しで bookKey が変わらないこと")
        }
    }

    /// ネスト展開は 3 段まで(zip 爆弾対策)。4 段目は取り込まれないこと
    func testDepthCapStopsAtThirdLevel() async throws {
        let level4 = zipData([("L4.png", png(width: 24))])
        let level3 = zipData([("L3.png", png(width: 23)), ("level4.zip", level4)])
        let level2 = zipData([("L2.png", png(width: 22)), ("level3.zip", level3)])
        let url = try writeZip(named: "deep.zip", [
            ("L1.png", png(width: 21)),
            ("level2.zip", level2),
        ])
        let source = try ArchiveSource(url: url)
        let paths = try await source.entries().map(\.pathInBook)
        XCTAssertEqual(paths, [
            "L1.png",
            "level2.zip/L2.png",
            "level2.zip/level3.zip/L3.png",
        ])
        XCTAssertFalse(paths.contains { $0.contains("L4") }, "4 段目は展開しない")
    }

    /// 壊れたネスト書庫は黙って飛ばし、他のページは無傷なこと(仕様書 §4.17)
    func testCorruptNestedArchiveIsSkippedSilently() async throws {
        let url = try writeZip(named: "corrupt.zip", [
            ("00.png", png(width: 40)),
            ("broken.zip", Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFF, 0x00])),
            ("10.png", png(width: 43)),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["00.png", "10.png"])
        for (entry, width) in zip(entries, [40, 43]) {
            let image = try await source.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, width)
        }
    }

    /// ネストした PDF のページも同じ本に取り込まれ、描画できること
    func testNestedPDFPagesJoinBook() async throws {
        let pdfDocument = PDFDocument()
        for index in 0..<2 {
            let image = NSImage(size: NSSize(width: 40, height: 60))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 40, height: 60).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            pdfDocument.insert(page, at: index)
        }
        let pdfData = try XCTUnwrap(pdfDocument.dataRepresentation())
        let url = try writeZip(named: "withpdf.zip", [
            ("cover.png", png(width: 30)),
            ("inner.pdf", pdfData),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].pathInBook, "cover.png")
        XCTAssertTrue(entries[1].pathInBook.hasPrefix("inner.pdf/"))
        XCTAssertEqual(entries[1].id, 1_000_000)
        let pdfPage = try await source.image(for: entries[1], maxPixelSize: nil)
        XCTAssertGreaterThan(pdfPage.width, 0)
    }

    // MARK: - 暗号化されたネスト書庫/PDF(パスワード問い合わせ)

    /// 入力回数を数えるパスワード提供者
    private actor PromptCounter {
        private(set) var count = 0
        private let answer: String?
        init(answer: String?) { self.answer = answer }
        func provide() -> String? {
            count += 1
            return answer
        }
    }

    /// zip CLI で暗号化 ZIP を作る(幅マーカー付き画像入り)
    private func encryptedZipData(widths: [Int], password: String,
                                  label: String) throws -> Data {
        let stage = tempDir.appendingPathComponent("enc-\(label)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var arguments = ["-j", "-P", password,
                         stage.appendingPathComponent("out.zip").path]
        for (index, width) in widths.enumerated() {
            let file = stage.appendingPathComponent("p\(index + 1).png")
            try png(width: width).write(to: file)
            arguments.append(file.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: stage.appendingPathComponent("out.zip"))
    }

    /// 暗号化されたネスト書庫は provider に問い合わせて解除し、本に取り込むこと
    func testEncryptedNestedChildUnlockedViaProvider() async throws {
        let inner = try encryptedZipData(widths: [41, 42], password: "sesame", label: "a")
        let url = try writeZip(named: "outer.zip", [
            ("00.png", png(width: 40)),
            ("locked.zip", inner),
        ])
        let prompts = PromptCounter(answer: "sesame")
        let unlocker = NestedUnlocker(provider: { _, _ in await prompts.provide() })
        let source = try ArchiveSource(url: url, unlocker: unlocker)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook),
                       ["00.png", "locked.zip/p1.png", "locked.zip/p2.png"])
        let image = try await source.image(for: entries[1], maxPixelSize: nil)
        XCTAssertEqual(image.width, 41)
        let count = await prompts.count
        XCTAssertEqual(count, 1)
    }

    /// キャンセル(nil)なら子を本から外し、以降は尋ねないこと
    func testEncryptedNestedChildSkippedOnCancel() async throws {
        let innerA = try encryptedZipData(widths: [41], password: "one", label: "a")
        let innerB = try encryptedZipData(widths: [51], password: "two", label: "b")
        let url = try writeZip(named: "outer.zip", [
            ("00.png", png(width: 40)),
            ("lockedA.zip", innerA),
            ("lockedB.zip", innerB),
        ])
        let prompts = PromptCounter(answer: nil)
        let unlocker = NestedUnlocker(provider: { _, _ in await prompts.provide() })
        let source = try ArchiveSource(url: url, unlocker: unlocker)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["00.png"])
        let count = await prompts.count
        XCTAssertEqual(count, 1, "キャンセル後は 2 つ目の子で尋ねないこと")
    }

    /// 一度入力されたパスワードは兄弟のネスト書庫へ再利用して尋ね直さないこと
    func testEnteredPasswordReusedForSiblingChildren() async throws {
        let innerA = try encryptedZipData(widths: [41], password: "sesame", label: "a")
        let innerB = try encryptedZipData(widths: [51], password: "sesame", label: "b")
        let url = try writeZip(named: "outer.zip", [
            ("lockedA.zip", innerA),
            ("lockedB.zip", innerB),
        ])
        let prompts = PromptCounter(answer: "sesame")
        let unlocker = NestedUnlocker(provider: { _, _ in await prompts.provide() })
        let source = try ArchiveSource(url: url, unlocker: unlocker)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook),
                       ["lockedA.zip/p1.png", "lockedB.zip/p1.png"])
        let count = await prompts.count
        XCTAssertEqual(count, 1, "同じパスワードの 2 冊目は既知パスワードで解けること")
    }

    /// 暗号化されたネスト PDF も provider 経由で解除されること
    func testEncryptedNestedPDFUnlockedViaProvider() async throws {
        let pdfDocument = PDFDocument()
        let image = NSImage(size: NSSize(width: 40, height: 60))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 60).fill()
        image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))
        pdfDocument.insert(page, at: 0)
        let pdfData = try XCTUnwrap(pdfDocument.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "sesame",
            PDFDocumentWriteOption.ownerPasswordOption: "sesame",
        ]))
        let url = try writeZip(named: "withlockedpdf.zip", [
            ("cover.png", png(width: 30)),
            ("locked.pdf", pdfData),
        ])
        let prompts = PromptCounter(answer: "sesame")
        let unlocker = NestedUnlocker(provider: { _, _ in await prompts.provide() })
        let source = try ArchiveSource(url: url, unlocker: unlocker)
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[1].pathInBook.hasPrefix("locked.pdf/"))
        let rendered = try await source.image(for: entries[1], maxPixelSize: nil)
        XCTAssertGreaterThan(rendered.width, 0)
    }

    /// provider なし(既知パスワードもなし)なら従来どおり黙って外すこと
    func testEncryptedNestedChildSkippedWithoutProvider() async throws {
        let inner = try encryptedZipData(widths: [41], password: "sesame", label: "a")
        let url = try writeZip(named: "outer.zip", [
            ("00.png", png(width: 40)),
            ("locked.zip", inner),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["00.png"])
        // スキップの記録(準備済みソースの使い回し判定に使う)
        let skipped = await source.hasSkippedLockedContent()
        XCTAssertTrue(skipped)
    }

    /// 解除に成功した本はスキップ記録なし(準備済みソースを使い回してよい)
    func testUnlockedBookReportsNoSkippedContent() async throws {
        let inner = try encryptedZipData(widths: [41], password: "sesame", label: "a")
        let url = try writeZip(named: "outer.zip", [("locked.zip", inner)])
        let prompts = PromptCounter(answer: "sesame")
        let unlocker = NestedUnlocker(provider: { _, _ in await prompts.provide() })
        let source = try ArchiveSource(url: url, unlocker: unlocker)
        _ = try await source.entries()
        let skipped = await source.hasSkippedLockedContent()
        XCTAssertFalse(skipped)
    }

    /// サムネイルキャッシュがネスト id でも衝突せず、正しい画像を保存すること
    func testThumbnailCacheKeysNestedIDsSeparately() async throws {
        let url = try writeZip(named: "cache.zip", [
            ("outer.png", png(width: 40)),
            ("inner.zip", zipData([("in.png", png(width: 41))])),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()
        let cacheRoot = tempDir.appendingPathComponent("thumbs")
        let cache = ThumbnailCache(diskRoot: cacheRoot)

        let outerResult = await cache.thumbnail(for: entries[0], in: source, bookKey: "K")
        let nestedResult = await cache.thumbnail(for: entries[1], in: source, bookKey: "K")
        let outer = try XCTUnwrap(outerResult)
        let nested = try XCTUnwrap(nestedResult)
        XCTAssertEqual(outer.width, 40)
        XCTAssertEqual(nested.width, 41)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(
            atPath: cacheRoot.appendingPathComponent("K/0.png").path))
        XCTAssertTrue(fm.fileExists(
            atPath: cacheRoot.appendingPathComponent("K/1000000.png").path))
    }
}
