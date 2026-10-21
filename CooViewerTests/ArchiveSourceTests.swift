import AppKit
import Darwin
import KaitoKit
import PDFKit
import XCTest
import os
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

    private func writeZip(_ data: Data, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
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
        XCTAssertLessThanOrEqual(extractorCount, ArchiveSource.extractorPoolSize(conserveEnergy: false))
    }

    func testFactoryReceivesPrimaryAndExtractorRolesForFileAndData() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let data = TestFixtures.storedZip(entries: [(Array("page.avifs".utf8), png)])
        let url = try writeZip(data, name: "roles.cbr")
        // 低電力・温度圧迫のどちらでも、両方でも、展開係のプール幅は同じ省エネ判定に従う(設計書 §5)
        let powerStates = [
            FixedPowerState(),
            FixedPowerState(isLowPowerModeEnabled: true),
            FixedPowerState(isThermalPressureActive: true),
            FixedPowerState(isLowPowerModeEnabled: true, isThermalPressureActive: true),
        ]
        for power in powerStates {
            let roles = OSAllocatedUnfairLock(initialState: [ArchiveReaderRole]())
            let factory = ArchiveEngineFactory(
                openFile: { kind, path, role in
                    roles.withLock { $0.append(role) }
                    return try ArchiveEngineFactory.live.openFile(kind, path, role)
                },
                openData: { kind, data, role in
                    roles.withLock { $0.append(role) }
                    return try ArchiveEngineFactory.live.openData(kind, data, role)
                })
            let sources = [
                try ArchiveSource(url: url, engineFactory: factory, powerState: power),
                try ArchiveSource(data: data, name: "roles.cbz", nestingDepth: 0, unlocker: NestedUnlocker(),
                                  persistenceKey: .file(path: url.path),
                                  engineFactory: factory, powerState: power)
            ]
            let poolSize = ArchiveSource.extractorPoolSize(conserveEnergy: power.shouldConserveEnergy)
            for source in sources {
                let entry = try await source.entries()[0]
                let image = try await source.image(for: entry, maxPixelSize: nil)
                XCTAssertEqual(image.width, 4)
                XCTAssertEqual(image.height, 6)
            }
            XCTAssertEqual(roles.withLock { $0 }, [.primary, .primary,
                .extractor(poolSize: poolSize), .extractor(poolSize: poolSize)])
        }
    }

    func testPowerChangeRestrictsExistingExtractorPoolWithoutReopening() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 3,
                      "協調スレッドを2本塞いでもテストを進行できるよう、3 CPU以上で実行する")
        // CIの3 CPUでも協調スレッドを1本残す。本番の数値ではなく縮小の仕組みを検証する。
        let normalCount = 2
        let reducedCount = 1
        let png = TestFixtures.pngData(width: 4, height: 6)
        let url = try writeZip(named: "power-pool.zip", entries: (0..<normalCount).map {
            (Array("page-\($0).avifs".utf8), png)
        })
        let state = OSAllocatedUnfairLock(initialState: (low: false, used: Set<Int>()))
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let center = NotificationCenter()
        let power = PowerStateMonitor(center: center, readState: {
            PowerConditions(isLowPowerModeEnabled: state.withLock { $0.low }, isThermalPressureActive: false)
        })
        let warmed = expectation(description: "通常時の全係を同時使用")
        warmed.expectedFulfillmentCount = normalCount
        let reduced = expectation(description: "低電力時の枠内の係を同時使用")
        reduced.expectedFulfillmentCount = reducedCount
        let release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<normalCount { release.signal() } }
        let factory = ArchiveEngineFactory(
            openFile: ArchiveEngineFactory.live.openFile,
            openData: { kind, data, role in
                guard let engine = try ArchiveEngineFactory.live.openData(kind, data, role) else { return nil }
                guard case .extractor = role else { return engine }
                let id = opens.withLock { $0 += 1; return $0 }
                return PoolTestArchiveEngine(engine: engine, pauseOnce: false) {
                    let (low, firstUse) = state.withLock {
                        ($0.low, $0.used.insert(id).inserted)
                    }
                    if firstUse { (low ? reduced : warmed).fulfill() }
                    XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
                }
            })
        let source = try ArchiveSource(
            url: url, persistenceKey: .file(path: url.path), engineFactory: factory, powerState: power,
            extractorPoolSizing: { $0 ? reducedCount : normalCount })
        let pages = try await source.entries()
        let warmTasks = pages.map { entry in
            Task { try await source.image(for: entry, maxPixelSize: nil) }
        }
        await fulfillment(of: [warmed], timeout: 3)
        for _ in 0..<normalCount { release.signal() }
        for task in warmTasks { _ = try await task.value }
        state.withLock { $0 = (low: true, used: []) }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        let lowTasks = pages.map { entry in
            Task { try await source.image(for: entry, maxPixelSize: nil) }
        }
        await fulfillment(of: [reduced], timeout: 3)
        XCTAssertEqual(state.withLock { $0.used }, Set(1...reducedCount))
        for _ in 0..<normalCount { release.signal() }
        for task in lowTasks { _ = try await task.value }
        XCTAssertEqual(state.withLock { $0.used }, Set(1...reducedCount))
        XCTAssertEqual(opens.withLock { $0 }, normalCount)
        let retainedCount = await source.extractorCount
        XCTAssertEqual(retainedCount, normalCount)
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

    func testCancelledOpenDoesNotRecordFailureOrRetry() async throws {
        defer { ArchiveEngineDiagnostics.resetForTesting() }
        let zip = TestFixtures.storedZip(entries: [
            (Array("a.png".utf8), TestFixtures.pngData(width: 4, height: 6)),
            (Array("b.png".utf8), TestFixtures.pngData(width: 5, height: 6)),
        ])
        let mappedURL = try writeZip(zip, name: "cancelled.zip")
        // 拡張子だけ変えて file 入口も通す。内容は同じ ZIP のまま。
        let fileURL = try writeZip(zip, name: "cancelled.cbr")
        XCTAssertTrue(ArchiveSource.shouldMemoryMap(url: mappedURL))
        XCTAssertFalse(ArchiveSource.shouldMemoryMap(url: fileURL))
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let factory = ArchiveEngineFactory(
            openFile: { kind, path, role in
                calls.withLock { $0.append("file") }
                return try ArchiveEngineFactory.live.openFile(kind, path, role)
            },
            openData: { kind, data, role in
                calls.withLock { $0.append("data") }
                return try ArchiveEngineFactory.live.openData(kind, data, role)
            })
        for route in 0..<3 {
            ArchiveEngineDiagnostics.resetForTesting()
            calls.withLock { $0.removeAll() }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    if route == 2 {
                        _ = try ArchiveSource(
                            data: zip, name: "nested.zip", nestingDepth: 1,
                            unlocker: NestedUnlocker(),
                            persistenceKey: .file(path: mappedURL.path).nested(entryPath: "nested.zip"),
                            engineFactory: factory)
                    } else {
                        _ = try ArchiveSource(url: route == 0 ? mappedURL : fileURL,
                                              engineFactory: factory)
                    }
                    XCTFail("キャンセル済みのオープンが成功した: \(route)")
                } catch {
                    XCTAssertTrue(error is CancellationError, "\(route): \(error)")
                }
            }
            await task.value
            XCTAssertEqual(ArchiveEngineDiagnostics.snapshot(),
                           .init(mmapRetryCount: 0, lastError: nil), "入口 \(route)")
            XCTAssertEqual(calls.withLock { $0 }, route == 1 ? ["file"] : ["data"])
        }
    }

    func testUncancelledPoolOpenFailureStillDisablesGrowth() async throws {
        let url = try writeZip(named: "failed-pool.zip", entries: (0..<3).map {
            (Array("p\($0).avifs".utf8), TestFixtures.pngData(width: 4 + $0, height: 6))
        })
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let factory = ArchiveEngineFactory(
            openFile: ArchiveEngineFactory.live.openFile,
            openData: { kind, data, role in
                let ordinal = opens.withLock { $0 += 1; return $0 }
                guard ordinal == 1 else { return nil }
                return try ArchiveEngineFactory.live.openData(kind, data, role)
            })
        let source = try ArchiveSource(url: url, engineFactory: factory)
        for (offset, entry) in try await source.entries().enumerated() {
            let image = try await source.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, 4 + offset)
        }
        XCTAssertEqual(opens.withLock { $0 }, 2, "通常の失敗では従来どおり増設を停止する")
        let count = await source.extractorCount
        XCTAssertEqual(count, 0)
    }

    func testCancelledPoolGrowthCanBeRetried() async throws {
        // OS の型情報サービスに依存しない拡張子を使い、PNG の実デコードは通す。
        let url = try writeZip(named: "cancelled-pool.zip", entries: (0..<4).map {
            (Array("p\($0).avifs".utf8), TestFixtures.pngData(width: 4 + $0, height: 6))
        })
        try await assertCancelledPoolGrowthCanBeRetried(
            url: url, cancelledPage: 1, expectedWidths: [4, 5, 6, 7])
    }

    func testCancelledSolidGroupAssignmentCanBeRetried() async throws {
        // 別の solid グループへ一時的に相乗りしても、その割当を固定しない。
        try await assertCancelledPoolGrowthCanBeRetried(
            url: fixture("blocks"), cancelledPage: 2, expectedWidths: [4, 4, 4, 4])
    }

    func testResourceFailureDuringPoolGrowthCanBeRetried() async throws {
        let url = try writeZip(named: "resource-pool.zip", entries: (0..<4).map {
            (Array("p\($0).avifs".utf8), TestFixtures.pngData(width: 4 + $0, height: 6))
        })
        try await assertCancelledPoolGrowthCanBeRetried(
            url: url, cancelledPage: 1, expectedWidths: [4, 5, 6, 7], resourceFailure: true)
    }

    func testResourceFailureCreatingFirstExtractorDoesNotDisableFutureGrowth() async throws {
        let url = try writeZip(named: "resource-first.zip", entries: [
            (Array("page.avifs".utf8), TestFixtures.pngData(width: 4, height: 6)),
        ])
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let factory = ArchiveEngineFactory(openFile: ArchiveEngineFactory.live.openFile,
            openData: { kind, data, role in
                let ordinal = opens.withLock { $0 += 1; return $0 }
                if ordinal == 2 { throw KaitoError.io(EMFILE) }
                return try ArchiveEngineFactory.live.openData(kind, data, role)
            })
        let source = try ArchiveSource(url: url, engineFactory: factory)
        let pages = try await source.entries()
        _ = try await source.image(for: pages[0], maxPixelSize: nil)
        let before = await source.extractorCount
        XCTAssertEqual(before, 0)
        _ = try await source.image(for: pages[0], maxPixelSize: nil)
        let after = await source.extractorCount
        XCTAssertEqual(after, 1)
    }

    func testCancelledFirstExtractorFailureIsTransient() async throws {
        let url = try writeZip(named: "first-cancel.zip", entries: [
            (Array("page.avifs".utf8), TestFixtures.pngData(width: 4, height: 6)),
        ])
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let factory = ArchiveEngineFactory(
            openFile: ArchiveEngineFactory.live.openFile,
            openData: { kind, data, role in
                let ordinal = opens.withLock { $0 += 1; return $0 }
                if ordinal == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                guard let engine = try ArchiveEngineFactory.live.openData(kind, data, role) else { return nil }
                return PoolTestArchiveEngine(engine: engine)
            })
        let source = try ArchiveSource(url: url, engineFactory: factory)
        let entries = try await source.entries()
        let entry = try XCTUnwrap(entries.first)
        let cancelled = Task { try await source.image(for: entry, maxPixelSize: nil) }
        do {
            _ = try await cancelled.value
            XCTFail("メイン書庫への退避も失敗したキャンセルは伝播する")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let image = try await source.image(for: entry, maxPixelSize: nil)
        XCTAssertEqual(image.width, 4)
        let count = await source.extractorCount
        XCTAssertEqual(count, 1, "最初の展開係の生成失敗も一時的に扱う")
    }

    private func assertCancelledPoolGrowthCanBeRetried(
        url: URL, cancelledPage: Int, expectedWidths: [Int], resourceFailure: Bool = false
    ) async throws {
        let busy = expectation(description: "最初の展開係を使用中にする")
        let cancelledOpen = expectation(description: "増設オープンをキャンセル済み Task で実行")
        let regrown = expectation(description: "後続の要求で増設を再試行")
        regrown.assertForOverFulfill = false
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let factory = ArchiveEngineFactory(
            openFile: ArchiveEngineFactory.live.openFile,
            openData: { kind, data, role in
                let ordinal = opens.withLock { $0 += 1; return $0 }
                if ordinal == 3, resourceFailure {
                    cancelledOpen.fulfill()
                    throw KaitoError.io(EMFILE)
                }
                // image() 入口の検査を通過後、KaitoKit を開く直前にキャンセルする。
                // actor 待機中にキャンセルされる競合を、時間待ちなしで再現する。
                if ordinal == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                let engine: (any ArchiveEngine)?
                do {
                    engine = try ArchiveEngineFactory.live.openData(kind, data, role)
                } catch {
                    if ordinal == 3 {
                        XCTAssertTrue(Task.isCancelled)
                        XCTAssertTrue(error is CancellationError, "キャンセルの理由を factory が保持する")
                        cancelledOpen.fulfill()
                    }
                    throw error
                }
                if ordinal == 3 {
                    XCTAssertTrue(Task.isCancelled)
                    XCTAssertNil(engine, "KaitoKit の実際のキャンセル契約を通す")
                    cancelledOpen.fulfill()
                }
                if ordinal >= 4 { regrown.fulfill() }
                guard let engine else { return nil }
                if ordinal == 2 {
                    return PoolTestArchiveEngine(engine: engine) {
                        busy.fulfill()
                        XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
                    }
                }
                return PoolTestArchiveEngine(engine: engine)
            })
        let source = try ArchiveSource(url: url, engineFactory: factory)
        let pages = try await source.entries()
        XCTAssertEqual(pages.count, expectedWidths.count)
        guard pages.count == expectedWidths.count else { return }
        let first = Task { try await source.image(for: pages[0], maxPixelSize: nil) }
        await fulfillment(of: [busy], timeout: 3)
        let cancelled = Task {
            do {
                let image = try await source.image(for: pages[cancelledPage], maxPixelSize: nil)
                if resourceFailure {
                    XCTAssertEqual(image.width, expectedWidths[cancelledPage])
                } else { XCTFail("キャンセルされた展開の nil を成功扱いしない") }
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
        await fulfillment(of: [cancelledOpen], timeout: 3)
        let countAfterCancellation = await source.extractorCount
        XCTAssertEqual(countAfterCancellation, 1)

        // 最初の係を保持したまま再要求するので、正常なら必ず 2 個以上へ成長する。
        let later = pages[2...].map { entry in
            Task { try await source.image(for: entry, maxPixelSize: nil) }
        }
        await fulfillment(of: [regrown], timeout: 3)
        let count = await source.extractorCount
        XCTAssertGreaterThan(count, 1, "キャンセル 1 回で増設を恒久停止しない")
        release.signal()
        let firstImage = try await first.value
        XCTAssertEqual(firstImage.width, expectedWidths[0])
        await cancelled.value
        for (offset, task) in later.enumerated() {
            let image = try await task.value
            XCTAssertEqual(image.width, expectedWidths[2 + offset])
        }
    }

    func testCancelledWaiterDoesNotDropNestedPages() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let nested = TestFixtures.storedZip(entries: [(Array("page.avifs".utf8), png)])
        let url = try writeZip(named: "nested-cancel.zip", entries: [
            (Array("cover.avifs".utf8), png), (Array("nested.zip".utf8), nested),
        ])
        let source = try ArchiveSource(url: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.entries()
        }
        // 一覧構築はキャンセルを継承しない共有 Task。途中結果を恒久保存しない。
        let cancelledEntries = try await task.value
        let laterEntries = try await source.entries()
        XCTAssertEqual(cancelledEntries.map(\.pathInBook), ["cover.avifs", "nested.zip/page.avifs"])
        XCTAssertEqual(laterEntries.map(\.pathInBook), cancelledEntries.map(\.pathInBook))
    }

    func testShiftJISEntryNamesAreAutoDetected() async throws {
        // UTF-8 フラグなしの DOS ホスト ZIP に Shift-JIS 名を入れると、
        // KaitoKit が文字コードを自動判定する(仕様書 §4.17、設計書 §2.4)
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
        // KaitoKit の文字コード自動判定で、短い CJK 名も正しく復号することを確認する。
        // 1 文字名・日中韓・4 バイトの絵文字まで含める(設計書 §2.4)。
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
        XCTAssertEqual(wrong, .rejected)
        let right = await source.checkAndSetPassword("hunter2")
        XCTAssertEqual(right, .accepted)
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
        XCTAssertEqual(accepted, .accepted)
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

    func testSpoolStatusFinishesAndRepeatedStartDoesNotRestart() async throws {
        let png = TestFixtures.pngData(width: 4, height: 6)
        let url = try writeZip(named: "status.zip", entries: [
            (Array("a.png".utf8), png), (Array("b.png".utf8), png),
        ])
        let source = try ArchiveSource(url: url)
        let initial = await source.spoolStats()
        XCTAssertFalse(initial.active)
        let started = await source.startSpoolingAndReadStats()
        XCTAssertTrue(started.active)
        await source.waitForSpoolCompletion()
        let finished = await source.spoolStats()
        XCTAssertFalse(finished.active, "完了後は実行中と報告しない")
        XCTAssertEqual(finished.spooled, 2)
        XCTAssertEqual(finished.bytes, Int64(png.count * 2))
        let repeated = await source.startSpoolingAndReadStats()
        XCTAssertFalse(repeated.active, "完了済みの準備を再実行しない")
        XCTAssertEqual(repeated, finished)
    }

    func testSerialSpoolAndDisplayUseIndependentEngines() async throws {
        let started = expectation(description: "専用復号器で先頭ページを展開中")
        let displayRequested = expectation(description: "表示要求を投入")
        displayRequested.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let probe = SpoolEngineProbe(beforeSpoolRead: { index in
            if index == 0 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            }
        })
        let source = try Self.spoolSource(groups: Array(repeating: 0, count: 64), probe: probe)
        let pages = try await source.entries()
        await source.beginSpooling(sizeLimit: 1 << 30)
        await fulfillment(of: [started], timeout: 3)
        let display = Task(priority: .userInitiated) {
            displayRequested.fulfill()
            return try await source.image(for: pages[62], maxPixelSize: nil)
        }
        let imageData = Task(priority: .userInitiated) {
            displayRequested.fulfill()
            return await source.imageData(for: pages[63])
        }
        await fulfillment(of: [displayRequested], timeout: 3)
        release.signal()
        let image = try await display.value
        let data = await imageData.value
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(data, probe.data)
        await source.waitForSpoolCompletion()
        let state = probe.state.withLock { $0 }
        XCTAssertEqual(state.reopenCalls, 1)
        XCTAssertEqual(state.primaryReads.sorted(), [62, 63], "表示と画像データ取得は主書庫を使う")
        XCTAssertEqual(state.spoolReads, Array(Int32(0)..<64), "スプールは専用復号器で単調増加する")
        XCTAssertTrue(state.primaryReadSpoolCounts.allSatisfy { $0 > 0 && $0 < 64 },
                      "両経路ともスプール途中の未展開ページを読む")
        XCTAssertEqual(state.liveSpoolEngines, 0, "ソースを保持していても完了で専用復号器を解放する")
        XCTAssertEqual(state.primaryDiscards, 1, "完了時の主書庫の復号状態解放を維持する")
        let stats = await source.spoolStats()
        XCTAssertEqual(stats.spooled, 64)
        XCTAssertFalse(stats.active)
    }

    func testSerialSpoolFallsBackWhenReopeningFails() async throws {
        let probe = SpoolEngineProbe(canReopen: false)
        let source = try Self.spoolSource(groups: [0, 0, 0, 0], probe: probe)
        let pages = try await source.entries()
        await source.beginSpooling(sizeLimit: 1 << 30)
        await source.waitForSpoolCompletion()
        let state = probe.state.withLock { $0 }
        XCTAssertEqual(state.reopenCalls, 1)
        XCTAssertEqual(state.primaryReads, [0, 1, 2, 3])
        XCTAssertEqual(state.spoolReads, [])
        XCTAssertEqual(state.liveSpoolEngines, 0)
        let stats = await source.spoolStats()
        XCTAssertEqual(stats.spooled, 4)
        XCTAssertFalse(stats.active)
        let data = await source.imageData(for: pages[3])
        XCTAssertEqual(data, probe.data)
        XCTAssertEqual(probe.state.withLock { $0.primaryReads }, [0, 1, 2, 3],
                       "完了後はスプール済みのファイルを読む")
    }

    func testParallelSpoolModesDoNotReopenEngine() async throws {
        for groups: [Int32] in [[-1, -1, -1, -1], [0, 0, 1, 1]] {
            let probe = SpoolEngineProbe()
            let source = try Self.spoolSource(groups: groups, probe: probe)
            let mode = await source.parallelGranularityForTesting
            XCTAssertEqual(mode, groups[0] == -1 ? "perEntry" : "byGroup")
            await source.beginSpooling(sizeLimit: 1 << 30)
            await source.waitForSpoolCompletion()
            let state = probe.state.withLock { $0 }
            XCTAssertEqual(state.reopenCalls, 0)
            XCTAssertEqual(state.primaryReads, [0, 1, 2, 3])
            XCTAssertEqual(state.spoolReads, [])
            let count = await source.spooledEntryCount
            XCTAssertEqual(count, 4)
        }
    }

    func testAbandoningAssemblyCancelsSpoolAndReleasesEngine() async throws {
        let started = expectation(description: "取消し前のスプールを開始")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let probe = SpoolEngineProbe(beforeSpoolRead: { index in
            if index == 0 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            }
        })
        let source = try Self.spoolSource(groups: [0, 0, 0, 0], probe: probe)
        await source.beginSpooling(sizeLimit: 1 << 30)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(probe.state.withLock { $0.liveSpoolEngines }, 1)
        source.abandonAssembly()
        release.signal()
        await source.waitForSpoolCompletion()
        let state = probe.state.withLock { $0 }
        XCTAssertEqual(state.spoolReads, [0], "放棄後は次のエントリへ進まない")
        XCTAssertEqual(state.primaryReads, [])
        XCTAssertEqual(state.liveSpoolEngines, 0)
        let stats = await source.spoolStats()
        XCTAssertFalse(stats.active)
        await source.beginSpooling(sizeLimit: 1 << 30)
        XCTAssertEqual(probe.state.withLock { $0.reopenCalls }, 1, "放棄したソースは再開しない")
    }

    func testSourceDeinitReleasesSpoolEngine() async throws {
        let started = expectation(description: "解放前のスプールを開始")
        let released = expectation(description: "ソースとともに専用復号器を解放")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let probe = SpoolEngineProbe(onRelease: { released.fulfill() }) { index in
            if index == 0 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            }
        }
        var source: ArchiveSource? = try Self.spoolSource(groups: [0, 0, 0, 0], probe: probe)
        await source?.beginSpooling(sizeLimit: 1 << 30)
        await fulfillment(of: [started], timeout: 3)
        weak let weakSource = source
        source = nil
        release.signal()
        await fulfillment(of: [released], timeout: 3)
        XCTAssertNil(weakSource)
        XCTAssertEqual(probe.state.withLock { $0.liveSpoolEngines }, 0)
    }

    private static func spoolSource(groups: [Int32], probe: SpoolEngineProbe) throws -> ArchiveSource {
        let factory = ArchiveEngineFactory(
            openFile: { _, _, _ in SpoolTestArchiveEngine(groups: groups, probe: probe) },
            openData: { _, _, _ in SpoolTestArchiveEngine(groups: groups, probe: probe) })
        return try ArchiveSource(data: Data([0]), name: "spool.7z", nestingDepth: 0,
                                 unlocker: NestedUnlocker(), persistenceKey: .file(path: "/spool.7z"),
                                 sensitive: false, engineFactory: factory)
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

    func testMemoryMapGateRejectsSpannedCBZ() throws {
        // ローカル判定を通る cbz でも .z01 兄弟があれば mmap しない
        let url = tempDir.appendingPathComponent("span.cbz")
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
        try fixture7z(name, ext: "7z")
    }

    private func fixture7z(_ name: String, ext: String) throws -> URL {
        let bundle = Bundle(for: ArchiveSourceTests.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: ext),
                             "テストリソース \(name).\(ext) がバンドルにない")
    }

    func testComicBookSevenZipExtractsAndSpoolsLikeSevenZip() async throws {
        // cb7 へ改名しても画像を展開でき、7z と同じ構造別のスプール方針になること(設計書 §2.4)
        for (name, expectedSpooled) in [("nonsolid", 0), ("solid", 4)] {
            let url = tempDir.appendingPathComponent("\(name).cb7")
            try FileManager.default.copyItem(at: fixture(name), to: url)
            let source = try ArchiveSource(url: url)
            let pages = try await source.entries()
            XCTAssertEqual(pages.count, 4)
            for entry in pages {
                let image = try await source.image(for: entry, maxPixelSize: nil)
                XCTAssertEqual(image.width, 4)
                XCTAssertEqual(image.height, 6)
            }

            await source.applyMediaProfile(MediaProfile(mediaClass: .fastLocal))
            await source.beginBackgroundPreparation(spoolSizeLimit: 1 << 30)
            await source.waitForSpoolCompletion()
            let spooled = await source.spooledEntryCount
            XCTAssertEqual(spooled, expectedSpooled, name)
        }
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
        XCTAssertLessThanOrEqual(count, ArchiveSource.extractorPoolSize(conserveEnergy: false))
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

    // MARK: - LHA lh5 展開(cooViewer-7ni: FastLZSS 移植のデコード正当性)

    func testLZH5ArchiveExtractsCorrectly() async throws {
        // XADLZHStaticHandle を per-byte から FastLZSS へ移植したので、lh5 の
        // 全ページが正しい寸法・内容でデコードされることをフィクスチャで固定する。
        // fixtures/book.lzh は 4x6 PNG(+パディング)×4 を lha -o5 で固めたもの。
        let source = try ArchiveSource(url: fixture7z("book", ext: "lzh"))
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 4)
        for entry in entries {
            let image = try await source.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, 4)
            XCTAssertEqual(image.height, 6)
        }
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
}

/// 復号器そのものを保持せずに、使用先と寿命を actor の外から観測する(設計書 §5、cooViewer-r1t2)。
private final class SpoolEngineProbe: Sendable {
    struct State: Sendable {
        var reopenCalls = 0
        var primaryReads: [Int32] = []
        var primaryReadSpoolCounts: [Int] = []
        var spoolReads: [Int32] = []
        var liveSpoolEngines = 0
        var primaryDiscards = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let data = TestFixtures.pngData(width: 4, height: 6)
    let canReopen: Bool
    let beforeSpoolRead: (@Sendable (Int32) -> Void)?
    let onRelease: (@Sendable () -> Void)?

    init(canReopen: Bool = true, onRelease: (@Sendable () -> Void)? = nil,
         beforeSpoolRead: (@Sendable (Int32) -> Void)? = nil) {
        self.canReopen = canReopen
        self.onRelease = onRelease
        self.beforeSpoolRead = beforeSpoolRead
    }
}

/// solid グループを固定し、インスタンスごとに展開要求を記録する偽エンジン。
private final class SpoolTestArchiveEngine: ArchiveEngine {
    private let groups: [Int32]
    private let probe: SpoolEngineProbe
    private let isSpool: Bool

    init(groups: [Int32], probe: SpoolEngineProbe, isSpool: Bool = false) {
        self.groups = groups
        self.probe = probe
        self.isSpool = isSpool
        if isSpool { probe.state.withLock { $0.liveSpoolEngines += 1 } }
    }
    init?(file path: String, role: ArchiveReaderRole) { return nil }
    init?(data: Data, role: ArchiveReaderRole) { return nil }

    deinit {
        if isSpool {
            probe.state.withLock { $0.liveSpoolEngines -= 1 }
            probe.onRelease?()
        }
    }

    func reopened() -> (any ArchiveEngine)? {
        probe.state.withLock { $0.reopenCalls += 1 }
        guard probe.canReopen else { return nil }
        return SpoolTestArchiveEngine(groups: groups, probe: probe, isSpool: true)
    }
    func contents(ofEntry index: Int32) -> Data? {
        let isSpool = self.isSpool
        probe.state.withLock {
            if isSpool { $0.spoolReads.append(index) }
            else {
                $0.primaryReads.append(index)
                $0.primaryReadSpoolCounts.append($0.spoolReads.count)
            }
        }
        if isSpool { probe.beforeSpoolRead?(index) }
        return probe.data
    }
    func discardDecodedState() {
        if !isSpool { probe.state.withLock { $0.primaryDiscards += 1 } }
    }
    func numberOfEntries() -> Int32 { Int32(groups.count) }
    func name(ofEntry index: Int32) -> String? { "page-\(index).avifs" }
    func uncompressedSize(ofEntry index: Int32) -> Int64 { Int64(probe.data.count) }
    func entryHasSize(_ index: Int32) -> Bool { true }
    func entryIsDirectory(_ index: Int32) -> Bool { false }
    func entryIsEncrypted(_ index: Int32) -> Bool { false }
    func isEncrypted() -> Bool { false }
    func setPassword(_ password: String) {}
    func solidGroup(ofEntry index: Int32) -> Int32 { groups[Int(index)] }
    static var defaultZipLazyLocalHeaders: Bool { true }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {}
}

private extension ArchiveSource {
    /// 開始直後の観測を同じ actor 呼出し内で行い、短い ZIP の完了競合を避ける。
    func startSpoolingAndReadStats() -> SpoolStats {
        beginSpooling(sizeLimit: 1 << 30)
        return spoolStats()
    }
}

/// 実エンジンの展開開始を同期し、キャンセル後の展開失敗(nil)も再現する。
private final class PoolTestArchiveEngine: ArchiveEngine {
    private let engine: any ArchiveEngine
    private var pause: (() -> Void)?
    private let pauseOnce: Bool

    init(engine: any ArchiveEngine, pauseOnce: Bool = true, pause: (() -> Void)? = nil) {
        self.engine = engine
        self.pauseOnce = pauseOnce
        self.pause = pause
    }

    init?(file path: String, role: ArchiveReaderRole) { return nil }
    init?(data: Data, role: ArchiveReaderRole) { return nil }

    func contents(ofEntry index: Int32) -> Data? {
        guard !Task.isCancelled else { return nil }
        let once = pause
        if pauseOnce { pause = nil }
        once?()
        return engine.contents(ofEntry: index)
    }

    func numberOfEntries() -> Int32 { engine.numberOfEntries() }
    func name(ofEntry index: Int32) -> String? {
        // 既存 7z の PNG も型情報サービスに依存せず列挙する。内容と solid 情報は実物を使う。
        engine.name(ofEntry: index)?.replacingOccurrences(of: ".png", with: ".avifs")
    }
    func uncompressedSize(ofEntry index: Int32) -> Int64 { engine.uncompressedSize(ofEntry: index) }
    func entryHasSize(_ index: Int32) -> Bool { engine.entryHasSize(index) }
    func entryIsDirectory(_ index: Int32) -> Bool { engine.entryIsDirectory(index) }
    func entryIsEncrypted(_ index: Int32) -> Bool { engine.entryIsEncrypted(index) }
    func isEncrypted() -> Bool { engine.isEncrypted() }
    func setPassword(_ password: String) { engine.setPassword(password) }
    func solidGroup(ofEntry index: Int32) -> Int32 { engine.solidGroup(ofEntry: index) }
    static var defaultZipLazyLocalHeaders: Bool { KaitoKitEngine.defaultZipLazyLocalHeaders }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {
        KaitoKitEngine.setDefaultZipLazyLocalHeaders(enabled)
    }
}
