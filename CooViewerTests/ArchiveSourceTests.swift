import AppKit
import PDFKit
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

    func testMetadataParsesRootComicInfo() async throws {
        // ルートの ComicInfo.xml を metadata() が解析し、画像一覧には混ざらないこと(4fi.2)
        let xml = Data("<ComicInfo><Series>統合テスト</Series><Number>2</Number><Manga>YesAndRightToLeft</Manga><Pages><Page Image=\"0\" Bookmark=\"序章\"/></Pages></ComicInfo>".utf8)
        let url = try writeZip(named: "meta.cbz", entries: [
            (Array("ComicInfo.xml".utf8), xml),
            (Array("p1.png".utf8), TestFixtures.pngData(width: 4, height: 6)),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["p1.png"], "ComicInfo.xml はページに混ざらない")
        let fetched = await source.metadata()
        let info = try XCTUnwrap(fetched)
        XCTAssertEqual(info.series, "統合テスト")
        XCTAssertEqual(info.number, "2")
        XCTAssertEqual(info.manga, .yesAndRightToLeft)
        XCTAssertEqual(info.chapters.map(\.name), ["序章"])
    }

    func testMetadataNilWithoutComicInfo() async throws {
        let url = try writeZip(named: "plain.cbz", entries: [
            (Array("p1.png".utf8), TestFixtures.pngData(width: 4, height: 6)),
        ])
        let source = try ArchiveSource(url: url)
        let info = await source.metadata()
        XCTAssertNil(info)
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

    func testParallelZipLoadsDecodeCorrectlyThroughPool() async throws {
        // エントリ独立圧縮(zip)は展開プールで並列展開しても、全ページが
        // 正しい内容で届くこと(ページ幅にエントリ番号を埋めて照合する)
        var entries: [(nameBytes: [UInt8], data: Data)] = []
        for page in 0..<12 {
            entries.append((Array(String(format: "p%02d.png", page).utf8),
                            TestFixtures.pngData(width: 4 + page, height: 6)))
        }
        let url = try writeZip(named: "pool.zip", entries: entries)
        let source = try ArchiveSource(url: url)
        let pages = try await source.entries()
        XCTAssertEqual(pages.count, 12)
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for (offset, entry) in pages.enumerated() {
                group.addTask {
                    let image = try await source.image(for: entry, maxPixelSize: nil)
                    return (offset, image.width)
                }
            }
            for try await (offset, width) in group {
                XCTAssertEqual(width, 4 + offset)
            }
        }
        // プールは成長してもコア数連動の上限まで
        let extractorCount = await source.extractorCount
        XCTAssertGreaterThanOrEqual(extractorCount, 1)
        XCTAssertLessThanOrEqual(extractorCount, ArchiveSource.extractorPoolSize)
    }

    func testSerialZipReadsKeepPoolMinimal() async throws {
        // 直列読みでは展開係が 1 つより増えないこと(余計に書庫を開かない)
        let png = TestFixtures.pngData(width: 4, height: 6)
        let url = try writeZip(named: "serial.zip", entries: [
            (Array("a.png".utf8), png), (Array("b.png".utf8), png)])
        let source = try ArchiveSource(url: url)
        for entry in try await source.entries() {
            _ = try await source.image(for: entry, maxPixelSize: nil)
        }
        let count = await source.extractorCount
        XCTAssertLessThanOrEqual(count, 1)
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

    func testUnflaggedUTF8Names() async throws {
        // UTF-8 フラグ(汎用ビット 11)を立てずに UTF-8 バイトの CJK 名を格納した ZIP。
        // universalchardet は短い CJK 名を統計推定で外しやすいが、XADMaster フォークの
        // 「確信 UTF-8」fast path(3 バイト以上の列を含む厳密妥当 UTF-8 は UTF-8 と確定。
        // XADString.m IsDataConfidentlyUTF8)が正しく復号する。1 文字名・日中韓・4 バイトの
        // 絵文字(サロゲート)まで含めて検証する
        let png = TestFixtures.pngData(width: 2, height: 2)
        let u8 = { (s: String) in [UInt8](s.utf8) }
        let url = try writeZip(named: "utf8noflag.zip", entries: [
            (u8("図.png"), png),        // 1 文字(推定器が最も外しやすい)
            (u8("目次.png"), png),      // 日本語
            (u8("封面.png"), png),      // 中国語
            (u8("표지.png"), png),      // 韓国語
            (u8("絵🎉.png"), png),      // 3 バイト + 4 バイト(絵文字)
        ])
        let source = try ArchiveSource(url: url)
        let names = try await source.entries().map(\.name)
        XCTAssertEqual(Set(names), ["図.png", "目次.png", "封面.png", "표지.png", "絵🎉.png"])
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

    /// 画像も書庫/PDF もない暗号化書庫: 検証プローブがないので通す
    /// (拒否すると正しいパスワードでも「試行超過」と誤表示されるため)
    func testEncryptedZipWithNothingToVerifyAcceptsPassword() async throws {
        let text = tempDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let zipURL = tempDir.appendingPathComponent("textonly.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-j", "-P", "hunter2", zipURL.path, text.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let source = try ArchiveSource(url: zipURL)
        let accepted = await source.checkAndSetPassword("anything")
        XCTAssertTrue(accepted)
        let entries = try await source.entries()
        XCTAssertTrue(entries.isEmpty, "本としては空(表示できる画像なし)")
    }

    /// 高速ローカル判定では zip のスプールを省き(直読みで十分)、
    /// 低速判定では従来どおり全ページをローカル展開すること
    func testMediaProfileControlsZipSpooling() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let entries: [(nameBytes: [UInt8], data: Data)] = [
            (Array("a.png".utf8), png), (Array("b.png".utf8), png),
        ]

        let fastURL = try writeZip(named: "fast.zip", entries: entries)
        let fast = try ArchiveSource(url: fastURL)
        await fast.applyMediaProfile(MediaProfile(mediaClass: .fastLocal))
        await fast.beginBackgroundPreparation(spoolSizeLimit: 1 << 30)
        await fast.waitForSpoolCompletion()
        let fastSpooled = await fast.spooledEntryCount
        XCTAssertEqual(fastSpooled, 0, "高速ローカルの zip はスプールしない")

        let slowURL = try writeZip(named: "slow.zip", entries: entries)
        let slow = try ArchiveSource(url: slowURL)
        await slow.applyMediaProfile(MediaProfile(mediaClass: .slowLocal))
        await slow.beginBackgroundPreparation(spoolSizeLimit: 1 << 30)
        await slow.waitForSpoolCompletion()
        let slowSpooled = await slow.spooledEntryCount
        XCTAssertEqual(slowSpooled, 2, "低速媒体は従来どおり全ページ展開する")
    }

    /// 高度設定のスプール方針(明示)は自動判定より優先されること
    func testSpoolOverrideBeatsProfileClass() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let entries: [(nameBytes: [UInt8], data: Data)] = [
            (Array("a.png".utf8), png),
        ]

        // 「行わない」: 低速媒体でも展開しない
        let neverURL = try writeZip(named: "never.zip", entries: entries)
        let never = try ArchiveSource(url: neverURL)
        await never.applyMediaProfile(
            MediaProfile(mediaClass: .slowLocal, spoolOverride: false))
        await never.beginBackgroundPreparation(spoolSizeLimit: 1 << 30)
        await never.waitForSpoolCompletion()
        let neverSpooled = await never.spooledEntryCount
        XCTAssertEqual(neverSpooled, 0)

        // 「常に行う」: 高速ローカルの zip でも展開する
        let alwaysURL = try writeZip(named: "always.zip", entries: entries)
        let always = try ArchiveSource(url: alwaysURL)
        await always.applyMediaProfile(
            MediaProfile(mediaClass: .fastLocal, spoolOverride: true))
        await always.beginBackgroundPreparation(spoolSizeLimit: 1 << 30)
        await always.waitForSpoolCompletion()
        let alwaysSpooled = await always.spooledEntryCount
        XCTAssertEqual(alwaysSpooled, 1)
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

/// 書庫内書庫・書庫内 PDF のネスト展開(仕様書 §2.4)
final class NestedArchiveTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func writeZip(_ data: Data, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testNestedArchivePagesJoinTheBook() async throws {
        let png = TestFixtures.pngData(width: 10, height: 10)
        let inner = TestFixtures.storedZip(entries: [
            (Array("a.png".utf8), png),
            (Array("b.png".utf8), png),
        ])
        let outer = TestFixtures.storedZip(entries: [
            (Array("cover.png".utf8), png),
            (Array("inner.zip".utf8), inner),
        ])
        let source = try ArchiveSource(url: writeZip(outer, name: "outer.zip"))
        let entries = try await source.entries()

        XCTAssertEqual(entries.map(\.pathInBook),
                       ["cover.png", "inner.zip/a.png", "inner.zip/b.png"])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "id は一意")
        // ネストしたページも展開・デコードできる
        let image = try await source.image(for: entries[2], maxPixelSize: nil)
        XCTAssertEqual(image.width, 10)
    }

    func testDoublyNestedArchiveIsExpanded() async throws {
        let png = TestFixtures.pngData(width: 10, height: 10)
        let innermost = TestFixtures.storedZip(entries: [(Array("deep.png".utf8), png)])
        let middle = TestFixtures.storedZip(entries: [(Array("mid.zip".utf8), innermost)])
        let outer = TestFixtures.storedZip(entries: [(Array("outer.zip".utf8), middle)])
        let source = try ArchiveSource(url: writeZip(outer, name: "nested3.zip"))
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["outer.zip/mid.zip/deep.png"])
        let image = try await source.image(for: entries[0], maxPixelSize: nil)
        XCTAssertEqual(image.width, 10)
    }

    @MainActor
    func testNestedPDFPagesJoinTheBook() async throws {
        let png = TestFixtures.pngData(width: 40, height: 60)
        guard let nsImage = NSImage(data: png),
              let page = PDFPage(image: nsImage) else {
            return XCTFail("PDF フィクスチャを生成できない")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard let pdfData = document.dataRepresentation() else {
            return XCTFail("PDF データ化に失敗")
        }
        let outer = TestFixtures.storedZip(entries: [
            (Array("cover.png".utf8), TestFixtures.pngData(width: 10, height: 10)),
            (Array("doc.pdf".utf8), pdfData),
        ])
        let source = try ArchiveSource(url: writeZip(outer, name: "withpdf.zip"))
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].pathInBook, "doc.pdf/000000")
        let image = try await source.image(for: entries[1], maxPixelSize: nil)
        XCTAssertGreaterThan(image.width, 0)
    }

    func testSpoolCoversOnlyOuterImages() async throws {
        let png = TestFixtures.pngData(width: 10, height: 10)
        let inner = TestFixtures.storedZip(entries: [(Array("a.png".utf8), png)])
        let outer = TestFixtures.storedZip(entries: [
            (Array("cover.png".utf8), png),
            (Array("inner.zip".utf8), inner),
        ])
        let source = try ArchiveSource(url: writeZip(outer, name: "spool.zip"))
        await source.beginBackgroundPreparation(spoolSizeLimit: 1 << 30)
        await source.waitForSpoolCompletion()
        let spooled = await source.spooledEntryCount
        XCTAssertEqual(spooled, 1, "ネスト分は展開済みなのでスプール対象は外側の画像のみ")
        // スプール後もネストページは読める
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)
        let image = try await source.image(for: entries[1], maxPixelSize: nil)
        XCTAssertEqual(image.width, 10)
    }

    // MARK: - mmap 経由の open(cooViewer-01h)

    func testMemoryMapGateAllowsSingleFileFormatsOnLocalVolume() throws {
        // temp はローカル固定ボリューム: 単一ファイル形式のみ許可される
        for name in ["a.zip", "a.cbz", "a.7z", "a.cb7"] {
            let url = tempDir.appendingPathComponent(name)
            try Data([0]).write(to: url)
            XCTAssertTrue(ArchiveSource.shouldMemoryMap(url: url), name)
        }
        // rar 系は分割書庫の兄弟探索(ファイル名ベース)が data: 経路で働かないため除外
        for name in ["a.rar", "a.cbr", "a.lzh", "a.part1.rar"] {
            let url = tempDir.appendingPathComponent(name)
            try Data([0]).write(to: url)
            XCTAssertFalse(ArchiveSource.shouldMemoryMap(url: url), name)
        }
    }

    func testMemoryMapGateRejectsSpannedZip() throws {
        // .z01 兄弟がいる spanned zip はボリューム探索が要るため file 経路に残す
        let url = tempDir.appendingPathComponent("span.zip")
        try Data([0]).write(to: url)
        XCTAssertTrue(ArchiveSource.shouldMemoryMap(url: url))
        try Data([0]).write(to: tempDir.appendingPathComponent("span.z01"))
        XCTAssertFalse(ArchiveSource.shouldMemoryMap(url: url))
    }

    func testMemoryMappedZipExtractsAndSharesPool() async throws {
        // ローカル temp の zip は mmap で開き、展開結果は従来と同一。
        // 展開プールも同じマップ済みデータから育つ(disk 再オープンなし)
        let png = TestFixtures.pngData(width: 4, height: 6)
        let zip = TestFixtures.storedZip(entries: [
            (Array("p1.png".utf8), png),
            (Array("p2.png".utf8), png),
        ])
        let source = try ArchiveSource(url: writeZip(zip, name: "mapped.cbz"))
        let mapped = await source.isMemoryMapped
        XCTAssertTrue(mapped, "ローカルボリュームの cbz は mmap 経由で開く")
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            let image = try await source.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, 4)
        }
    }

    // MARK: - 7z の並列粒度(cooViewer-7ni)

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: ArchiveSourceTests.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: "7z"),
                             "テストリソース \(name).7z がバンドルにない")
    }

    func testSevenZipParallelModeFollowsStructure() async throws {
        // 非 solid → perEntry(zip 同様の自由並列)、完全 solid → serial(従来)、
        // ブロック分割 solid → byGroup(グループ内直列・グループ間並列)
        let nonsolid = try ArchiveSource(url: fixture("nonsolid"))
        let nonsolidMode = await nonsolid.parallelGranularityForTesting
        XCTAssertEqual(nonsolidMode, "perEntry")
        let solid = try ArchiveSource(url: fixture("solid"))
        let solidMode = await solid.parallelGranularityForTesting
        XCTAssertEqual(solidMode, "serial")
        let blocks = try ArchiveSource(url: fixture("blocks"))
        let blocksMode = await blocks.parallelGranularityForTesting
        XCTAssertEqual(blocksMode, "byGroup")
        let parallelOK = await blocks.currentlySupportsParallelPageLoads()
        XCTAssertTrue(parallelOK)
        let solidParallel = await solid.currentlySupportsParallelPageLoads()
        XCTAssertFalse(solidParallel, "完全 solid は未スプールの間は直列のまま")
    }

    func testBlockSolidSevenZipExtractsCorrectlyInParallel() async throws {
        // byGroup 並列で全ページが正しい内容で届くこと(IEND 後のパディングは
        // ImageIO が無視するので幅 4 の PNG がそのまま出る)
        let source = try ArchiveSource(url: fixture("blocks"))
        let pages = try await source.entries()
        XCTAssertEqual(pages.count, 4)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for entry in pages {
                group.addTask {
                    let image = try await source.image(for: entry, maxPixelSize: nil)
                    return image.width
                }
            }
            for try await width in group {
                XCTAssertEqual(width, 4)
            }
        }
        let count = await source.extractorCount
        XCTAssertLessThanOrEqual(count, ArchiveSource.extractorPoolSize)
    }

    func testFastLocalSkipsSpoolForIndependentSevenZip() async throws {
        // 非 solid 7z は fastLocal ではスプールしない(zip 同様の扱い)、
        // 完全 solid は従来どおりスプールする(cooViewer-7ni)
        let fast = MediaProfile(mediaClass: .fastLocal)
        let nonsolid = try ArchiveSource(url: fixture("nonsolid"))
        await nonsolid.applyMediaProfile(fast)
        await nonsolid.beginBackgroundPreparation(spoolSizeLimit: 1 << 30)
        await nonsolid.waitForSpoolCompletion()
        let nonsolidSpooled = await nonsolid.spooledEntryCount
        XCTAssertEqual(nonsolidSpooled, 0)

        let solid = try ArchiveSource(url: fixture("solid"))
        await solid.applyMediaProfile(fast)
        await solid.beginBackgroundPreparation(spoolSizeLimit: 1 << 30)
        await solid.waitForSpoolCompletion()
        let solidSpooled = await solid.spooledEntryCount
        XCTAssertEqual(solidSpooled, 4)
    }

    func testRarStaysOnFilePath() async throws {
        // ゲート対象外の拡張子は従来どおり file 経路(sourceData なし)
        let png = TestFixtures.pngData(width: 4, height: 6)
        let zip = TestFixtures.storedZip(entries: [
            (Array("p1.png".utf8), png),
        ])
        // 中身は zip だが拡張子 cbr → ゲートは拡張子で判定するため file 経路
        let source = try ArchiveSource(url: writeZip(zip, name: "notzip.cbr"))
        let mapped = await source.isMemoryMapped
        XCTAssertFalse(mapped)
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 1)
    }
}
