import CryptoKit
import Foundation
import os
import XCTest
@testable import cooViewer

/// 旧実装の観測値をゴールデンに固定し、KaitoKit の
/// 書庫エンジン契約を同じ基準で検証する(設計書 §2.4)。
final class ArchiveEngineTests: XCTestCase {
    private enum StubOpenError: Error {
        case rejected
    }

    private struct Fixture {
        let name: String
        let url: URL
    }

    /// 列挙開始時に不正な件数を返し、KaitoKit 側の列挙失敗を再現する。
    private final class EnumerationFailureEngine: ArchiveEngine {
        init?(file path: String) {}
        init?(data: Data) {}

        func numberOfEntries() -> Int32 { -1 }
        func name(ofEntry index: Int32) -> String? { nil }
        func contents(ofEntry index: Int32) -> Data? { nil }
        func uncompressedSize(ofEntry index: Int32) -> Int64 { Int64.max }
        func entryHasSize(_ index: Int32) -> Bool { false }
        func entryIsDirectory(_ index: Int32) -> Bool { false }
        func entryIsEncrypted(_ index: Int32) -> Bool { false }
        func isEncrypted() -> Bool { false }
        func setPassword(_ password: String) {}
        func solidGroup(ofEntry index: Int32) -> Int32 { -1 }
        func extractEntry(_ index: Int32, to directory: String) -> Bool { false }

        static var defaultZipLazyLocalHeaders: Bool { true }
        static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {}
    }

    /// 契約上の名前欠落を再現し、後続の正規ページまで列挙する。
    private final class MissingNameEngine: ArchiveEngine {
        init() {}
        init?(file path: String) {}
        init?(data: Data) {}
        func numberOfEntries() -> Int32 { 3 }
        func name(ofEntry index: Int32) -> String? { index == 1 ? nil : "page-\(index).avifs" }
        func contents(ofEntry index: Int32) -> Data? { TestFixtures.pngData(width: 2, height: 3) }
        func uncompressedSize(ofEntry index: Int32) -> Int64 { 1 }
        func entryHasSize(_ index: Int32) -> Bool { true }
        func entryIsDirectory(_ index: Int32) -> Bool { false }
        func entryIsEncrypted(_ index: Int32) -> Bool { false }
        func isEncrypted() -> Bool { false }
        func setPassword(_ password: String) {}
        func solidGroup(ofEntry index: Int32) -> Int32 { -1 }
        func extractEntry(_ index: Int32, to directory: String) -> Bool { false }
        static var defaultZipLazyLocalHeaders: Bool { true }
        static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {}
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
        ArchiveEngineDiagnostics.resetForTesting()
    }

    override func tearDownWithError() throws {
        ArchiveEngineDiagnostics.resetForTesting()
        try FileManager.default.removeItem(at: tempDir)
    }

    /// 7 形式・構造の file/data 両入口を保存済みの観測値と比較し、
    /// 並列判定を含めた契約を XADMaster 撤去後も維持する(設計書 §2.4)。
    func testKaitoKitMatchesEngineGoldenAcrossArchiveFixtures() throws {
        try assertEngineMatchesGolden(.kaitokit)
    }

    /// 暗号化フラグ・誤パスワード・復号 SHA をゴールデンに照合する
    /// (仕様書 §4.1.3、設計書 §2.4)。
    func testKaitoKitZipCryptoPasswordBehavior() throws {
        let expected = try EngineGolden.load().zipCrypto
        let archiveURL = try makeEncryptedZIP(payload: encryptedZIPPayload())
        let data = try Data(contentsOf: archiveURL)
        let kind = ArchiveEngineKind.kaitokit
        let engines = [
            ("file", try open(kind, file: archiveURL, context: "zipcrypto")),
            ("data", try open(kind, data: data, context: "zipcrypto")),
        ]
        for (entrypoint, engine) in engines {
            let context = "zipcrypto:\(kind.rawValue):\(entrypoint)"
            let index = try XCTUnwrap(firstFileIndex(in: engine), context)
            XCTAssertEqual(engine.isEncrypted(), expected.archive.isEncrypted,
                           "\(context):archive encryption before password")
            let expectedEntry = try XCTUnwrap(
                expected.archive.entries.first { !$0.isDirectory }, context)
            XCTAssertEqual(engine.entryIsEncrypted(index), expectedEntry.isEncrypted,
                           "\(context):entry encryption before password")
            engine.setPassword("wrong")
            XCTAssertEqual(
                engine.contents(ofEntry: index)?.isEmpty ?? true,
                expected.wrongPasswordReturnsEmptyOrNil,
                "\(context): 誤パスワードで空または nil")
            engine.setPassword("archive-engine-test")
            let contents = try XCTUnwrap(engine.contents(ofEntry: index), context)
            let digest = Self.sha256(contents)
            XCTAssertEqual(digest, expected.payloadSHA256, "\(context):payload SHA-256")
            XCTAssertEqual(digest == expected.payloadSHA256,
                           expected.correctPasswordMatchesPayload,
                           "\(context): 正パスワードで本文一致")
            try assertMatchesGolden(
                engine, expected: expected.archive,
                allowsDirectorySeparatorDifference: kind == .kaitokit,
                context: context)
        }
    }

    /// 本体の既定引数で KaitoKit が選ばれる(設計書 §2.4)。
    func testArchiveSourceDefaultsToKaitoKit() throws {
        let url = try makeCBZFixture()
        let source = try ArchiveSource(url: url, persistenceKey: .file(path: url.path))
        XCTAssertEqual(source.archiveEngineKind, .kaitokit)
        XCTAssertEqual(ArchiveEngineKind.allCases, [.kaitokit])
        XCTAssertEqual(ArchiveEngineKind(rawValue: "kaitokit"), .kaitokit)
        XCTAssertEqual(ArchiveEngineDiagnostics.snapshot().mmapRetryCount, 0)
    }

    func testNilOpenIsUnreadableWithoutRetry() throws {
        try assertOpenFailureIsUnreadable(throwsOnOpen: false)
    }

    func testThrownOpenIsUnreadableWithoutRetry() throws {
        try assertOpenFailureIsUnreadable(throwsOnOpen: true)
    }

    /// data の生成に成功した後の列挙失敗では file を試さない(設計書 §2.4)。
    func testEnumerationFailureIsUnreadableWithoutRetry() throws {
        let fixture = try makeCBZFixture()
        try XCTSkipUnless(ArchiveSource.shouldMemoryMap(url: fixture), "mmap 対象のローカルボリュームが必要")
        let routes = OSAllocatedUnfairLock(initialState: [String]())
        let factory = ArchiveEngineFactory(
            openFile: { _, path in
                routes.withLock { $0.append("file") }
                return EnumerationFailureEngine(file: path)
            },
            openData: { _, data in
                routes.withLock { $0.append("data") }
                return EnumerationFailureEngine(data: data)
            })
        XCTAssertThrowsError(try ArchiveSource(url: fixture, engineFactory: factory)) { error in
            self.assertUnreadable(error, url: fixture)
        }
        XCTAssertEqual(routes.withLock { $0 }, ["data"])
        let fileURL = tempDir.appendingPathComponent("unmapped.rar")
        XCTAssertThrowsError(try ArchiveSource(url: fileURL, engineFactory: factory)) { error in
            self.assertUnreadable(error, url: fileURL)
        }
        XCTAssertThrowsError(try ArchiveSource(
            data: Data(), name: fixture.path, nestingDepth: 0, unlocker: NestedUnlocker(),
            persistenceKey: .file(path: fixture.path), engineFactory: factory)) { error in
            self.assertUnreadable(error, url: fixture)
        }
        XCTAssertEqual(routes.withLock { $0 }, ["data", "file", "data"])
        XCTAssertEqual(ArchiveEngineDiagnostics.snapshot().mmapRetryCount, 0)
        XCTAssertNotNil(ArchiveEngineDiagnostics.snapshot().lastError)
    }

    /// 名前 nil は書庫全体の失敗にせず、そのエントリだけを除く(設計書 §2.4)。
    func testMissingEntryNameKeepsRemainingPages() async throws {
        let fixture = try makeCBZFixture()
        let factory = ArchiveEngineFactory(
            openFile: { _, _ in MissingNameEngine() },
            openData: { _, _ in MissingNameEngine() })
        let sources = [
            try ArchiveSource(url: fixture, engineFactory: factory),
            try ArchiveSource(
                data: Data(), name: fixture.path, nestingDepth: 0, unlocker: NestedUnlocker(),
                persistenceKey: .file(path: fixture.path), engineFactory: factory),
        ]
        for source in sources {
            let entries = try await source.entries()
            XCTAssertEqual(entries.map(\.id), [0, 2])
            XCTAssertEqual(entries.map(\.name), ["page-0.avifs", "page-2.avifs"])
            let image = try await source.image(for: XCTUnwrap(entries.last), maxPixelSize: nil)
            XCTAssertEqual(image.width, 2)
            XCTAssertEqual(source.archiveEngineKind, .kaitokit)
        }
        XCTAssertEqual(ArchiveEngineDiagnostics.snapshot().mmapRetryCount, 0)
        XCTAssertNil(ArchiveEngineDiagnostics.snapshot().lastError)
    }

    private func assertOpenFailureIsUnreadable(throwsOnOpen: Bool) throws {
        // 非 mmap の URL とメモリ専用の入口では、それぞれ一回だけ open する。
        let fixture = tempDir.appendingPathComponent("failed.rar")
        let routes = OSAllocatedUnfairLock(initialState: [String]())
        let factory = ArchiveEngineFactory(
            openFile: { _, _ in
                routes.withLock { $0.append("file") }
                if throwsOnOpen { throw StubOpenError.rejected }
                return nil
            },
            openData: { _, _ in
                routes.withLock { $0.append("data") }
                if throwsOnOpen { throw StubOpenError.rejected }
                return nil
            })
        XCTAssertThrowsError(try ArchiveSource(url: fixture, engineFactory: factory)) { error in
            self.assertUnreadable(error, url: fixture)
        }
        XCTAssertThrowsError(try ArchiveSource(
            data: Data(), name: fixture.path, nestingDepth: 0, unlocker: NestedUnlocker(),
            persistenceKey: .file(path: fixture.path), engineFactory: factory)) { error in
            self.assertUnreadable(error, url: fixture)
        }
        XCTAssertEqual(routes.withLock { $0 }, ["file", "data"])
        XCTAssertEqual(ArchiveEngineDiagnostics.snapshot().mmapRetryCount, 0)
        XCTAssertNotNil(ArchiveEngineDiagnostics.snapshot().lastError)
    }

    private func assertUnreadable(_ error: Error, url: URL,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case BookSourceError.unreadable(let actualURL) = error else {
            return XCTFail("unreadable が必要: \(error)", file: file, line: line)
        }
        XCTAssertEqual(actualURL, url, file: file, line: line)
    }

    /// mmap 解析不能なら、同じエンジンの file 入口で一度だけ救済する(設計書 §2.4)。
    func testMappedDataNilOpenRetriesFileOnce() async throws {
        try await assertMappedOpenRetriesFile(throwsOnData: false)
    }

    func testMappedDataThrownOpenRetriesFileOnce() async throws {
        try await assertMappedOpenRetriesFile(throwsOnData: true)
    }

    /// 両入口が失敗した書庫は、既存の黒画面経路へ渡す。
    func testMappedDataAndFileOpenFailuresAreUnreadable() throws {
        let fixture = try makeCBZFixture()
        try XCTSkipUnless(ArchiveSource.shouldMemoryMap(url: fixture), "mmap 対象のローカルボリュームが必要")
        for throwsOnOpen in [false, true] {
            ArchiveEngineDiagnostics.resetForTesting()
            let routes = OSAllocatedUnfairLock(initialState: [String]())
            let factory = ArchiveEngineFactory(
                openFile: { _, _ in
                    routes.withLock { $0.append("file") }
                    if throwsOnOpen { throw StubOpenError.rejected }
                    return nil
                },
                openData: { _, _ in
                    routes.withLock { $0.append("data") }
                    if throwsOnOpen { throw StubOpenError.rejected }
                    return nil
                })
            XCTAssertThrowsError(try ArchiveSource(
                url: fixture, preferredEngine: .kaitokit, engineFactory: factory)) { error in
                guard case BookSourceError.unreadable(let url) = error else {
                    return XCTFail("unreadable が必要: \(error)")
                }
                XCTAssertEqual(url, fixture)
            }
            XCTAssertEqual(routes.withLock { $0 }, ["data", "file"])
            XCTAssertEqual(ArchiveEngineDiagnostics.snapshot().mmapRetryCount, 1)
        }
    }

    private func assertMappedOpenRetriesFile(throwsOnData: Bool) async throws {
        // 入口の再試行を単独で検証するため、型データベース不要の画像拡張子を使う。
        // 内容は PNG のままで、デコーダはマジックから形式を判別する。
        let fixture = try makeCBZFixture(imageExtension: "avifs")
        try XCTSkipUnless(ArchiveSource.shouldMemoryMap(url: fixture), "mmap 対象のローカルボリュームが必要")
        for kind in ArchiveEngineKind.allCases {
            ArchiveEngineDiagnostics.resetForTesting()
            let routes = OSAllocatedUnfairLock(initialState: [String]())
            let factory = ArchiveEngineFactory(
                openFile: { actualKind, path in
                    XCTAssertEqual(actualKind, kind)
                    routes.withLock { $0.append("file") }
                    return try ArchiveEngineFactory.live.openFile(actualKind, path)
                },
                openData: { actualKind, _ in
                    XCTAssertEqual(actualKind, kind)
                    routes.withLock { $0.append("data") }
                    if throwsOnData { throw StubOpenError.rejected }
                    return nil
                })
            let source = try ArchiveSource(
                url: fixture, preferredEngine: kind, engineFactory: factory)
            XCTAssertEqual(source.archiveEngineKind, kind)
            let entries = try await source.entries()
            XCTAssertEqual(entries.count, 2)
            let isMemoryMapped = await source.isMemoryMapped
            XCTAssertFalse(isMemoryMapped, "file 再試行後は sourceData を保持しない")
            XCTAssertEqual(routes.withLock { $0 }, ["data", "file"])
            let diagnostics = ArchiveEngineDiagnostics.snapshot()
            XCTAssertEqual(diagnostics.mmapRetryCount, 1)
            XCTAssertTrue(diagnostics.lastError?.contains(kind.displayName) == true)

            // 再試行後の展開係も file 入口を使い、失敗した data 入口へ戻らない。
            let image = try await source.image(for: XCTUnwrap(entries.first), maxPixelSize: nil)
            XCTAssertEqual(image.width, 3)
            XCTAssertEqual(routes.withLock { $0 }, ["data", "file", "file"])
        }
    }

    /// KaitoKit が報告する 7z folder の solidGroup を ArchiveSource の純粋な
    /// 並列粒度判定へ通し、独立・単一 solid・分割 solid を識別する(cooViewer-7ni)。
    func testKaitoKitSolidGroupsDriveParallelMode() async throws {
        let cases = [
            (name: "nonsolid", expected: "perEntry"),
            (name: "solid", expected: "serial"),
            (name: "blocks", expected: "byGroup"),
        ]

        for item in cases {
            let url = try bundledFixture(item.name, "7z")
            let source = try ArchiveSource(url: url, preferredEngine: .kaitokit)
            XCTAssertEqual(source.archiveEngineKind, .kaitokit, item.name)
            let granularity = await source.parallelGranularityForTesting
            XCTAssertEqual(granularity, item.expected, item.name)
        }
    }

    private func fixtures() throws -> [Fixture] {
        let zipURL = tempDir.appendingPathComponent("contract.zip")
        let zipData = TestFixtures.storedZip(entries: [
            (Array("folder/".utf8), Data()),
            (Array("folder/page.bin".utf8), Data("zip payload".utf8)),
            (Array("root.bin".utf8), Data([0, 1, 2, 3, 4])),
        ])
        try zipData.write(to: zipURL)

        let cbzURL = try makeCBZFixture()
        let rarURL = tempDir.appendingPathComponent("solid-rar4.rar")
        let rarData = try XCTUnwrap(
            Data(base64Encoded: Self.rar4FixtureBase64,
                 options: .ignoreUnknownCharacters),
            "RAR4 フィクスチャを復号できない"
        )
        XCTAssertEqual(
            Self.sha256(rarData),
            "a2771b950416d3df441de579b76646d203fe75eb176536c2b8fb8e67a235a0ed",
            "RAR4 フィクスチャの固定値"
        )
        try rarData.write(to: rarURL)

        return [
            Fixture(name: "zip", url: zipURL),
            Fixture(name: "cbz", url: cbzURL),
            Fixture(name: "7z-nonsolid", url: try bundledFixture("nonsolid", "7z")),
            Fixture(name: "7z-solid", url: try bundledFixture("solid", "7z")),
            Fixture(name: "7z-blocks", url: try bundledFixture("blocks", "7z")),
            Fixture(name: "rar4-solid", url: rarURL),
            Fixture(name: "lzh", url: try bundledFixture("book", "lzh")),
        ]
    }

    private func makeCBZFixture(imageExtension: String = "png") throws -> URL {
        let url = tempDir.appendingPathComponent("contract.cbz")
        let data = TestFixtures.storedZip(entries: [
            (Array("cover.\(imageExtension)".utf8), TestFixtures.pngData(width: 3, height: 5)),
            (Array("pages/002.\(imageExtension)".utf8), TestFixtures.pngData(
                width: 4, height: 6, red: 0.2, green: 0.4, blue: 0.8)),
        ])
        try data.write(to: url)
        return url
    }

    private func encryptedZIPPayload() -> Data {
        // 旧実装のゴールデンと同じ本文を維持する。決定的な疑似乱数を
        // 64 文字へ写像し、deflate 後も約 24 KiB にする。
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var state: UInt32 = 0x1234_5678
        return Data((0..<32_768).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return alphabet[Int(state >> 26)]
        })
    }

    private func makeEncryptedZIP(payload: Data) throws -> URL {
        let zipPath = "/usr/bin/zip"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: zipPath),
            "/usr/bin/zip が無いため ZipCrypto 互換テストをスキップします")
        // 旧実装で採取したゴールデンと同じファイル名を維持する。
        let inputURL = tempDir.appendingPathComponent("secret.txt")
        try payload.write(to: inputURL)
        let archiveURL = tempDir.appendingPathComponent("encrypted.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zipPath)
        process.currentDirectoryURL = tempDir
        process.arguments = [
            "-P", "archive-engine-test", "-q",
            archiveURL.lastPathComponent, inputURL.lastPathComponent,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "暗号化 ZIP の生成に失敗")
        return archiveURL
    }

    private func bundledFixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: ArchiveEngineTests.self).url(
                forResource: name, withExtension: ext),
            "テストリソース \(name).\(ext) がバンドルにない"
        )
    }

    private func open(_ kind: ArchiveEngineKind, file url: URL,
                      context: String) throws -> any ArchiveEngine {
        let engine: (any ArchiveEngine)? = switch kind {
        case .kaitokit: KaitoKitEngine(file: url.path)
        }
        return try XCTUnwrap(engine, "\(context):\(kind.rawValue) file open")
    }

    private func open(_ kind: ArchiveEngineKind, data: Data,
                      context: String) throws -> any ArchiveEngine {
        let engine: (any ArchiveEngine)? = switch kind {
        case .kaitokit: KaitoKitEngine(data: data)
        }
        return try XCTUnwrap(engine, "\(context):\(kind.rawValue) data open")
    }

    private func assertEngineMatchesGolden(_ kind: ArchiveEngineKind) throws {
        let golden = try EngineGolden.load()
        let fixtures = try fixtures()
        XCTAssertEqual(fixtures.map(\.name), golden.fixtures.map(\.name), "fixture 一覧と順序")
        for fixture in fixtures {
            let expected = try XCTUnwrap(
                golden.fixtures.first { $0.name == fixture.name }, fixture.name)
            let fileEngine = try open(kind, file: fixture.url, context: fixture.name)
            try assertMatchesGolden(
                fileEngine, expected: expected,
                allowsDirectorySeparatorDifference: kind == .kaitokit,
                context: "\(fixture.name):\(kind.rawValue):file")
            let dataEngine = try open(
                kind, data: Data(contentsOf: fixture.url), context: fixture.name)
            try assertMatchesGolden(
                dataEngine, expected: expected,
                allowsDirectorySeparatorDifference: kind == .kaitokit,
                context: "\(fixture.name):\(kind.rawValue):data")
        }
    }

    private func assertMatchesGolden(_ engine: any ArchiveEngine,
                                     expected: EngineGolden.Fixture,
                                     allowsDirectorySeparatorDifference: Bool,
                                     context: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let actual = try observation(of: engine, name: expected.name, file: file, line: line)
        XCTAssertEqual(actual.entries.count, expected.entries.count,
                       "\(context):entry count", file: file, line: line)
        XCTAssertEqual(actual.isEncrypted, expected.isEncrypted,
                       "\(context):archive encryption", file: file, line: line)
        for (index, pair) in zip(expected.entries, actual.entries).enumerated() {
            let (expectedEntry, actualEntry) = pair
            // cooViewer-vwey.8 の互換層修正待ちにつき、KaitoKit だけ
            // ディレクトリ名の末尾区切り差を許す。それ以外は保存値と完全一致。
            if allowsDirectorySeparatorDifference {
                if actualEntry.name != expectedEntry.name {
                    print("\(context):\(index):名前の保存形の差 "
                          + "golden=\(String(reflecting: expectedEntry.name)) "
                          + "KaitoKit=\(String(reflecting: actualEntry.name))")
                }
                XCTAssertEqual(
                    comparableName(actualEntry.name, isDirectory: actualEntry.isDirectory),
                    comparableName(expectedEntry.name, isDirectory: expectedEntry.isDirectory),
                    "\(context):\(index):name", file: file, line: line)
            } else {
                XCTAssertEqual(actualEntry.name, expectedEntry.name,
                               "\(context):\(index):name", file: file, line: line)
            }
            XCTAssertEqual(actualEntry.hasSize, expectedEntry.hasSize,
                           "\(context):\(index):hasSize", file: file, line: line)
            XCTAssertEqual(actualEntry.size, expectedEntry.size,
                           "\(context):\(index):size", file: file, line: line)
            XCTAssertEqual(actualEntry.isDirectory, expectedEntry.isDirectory,
                           "\(context):\(index):directory", file: file, line: line)
            XCTAssertEqual(actualEntry.isEncrypted, expectedEntry.isEncrypted,
                           "\(context):\(index):encryption", file: file, line: line)
            XCTAssertEqual(actualEntry.sha256, expectedEntry.sha256,
                           "\(context):\(index):SHA-256", file: file, line: line)
            XCTAssertEqual(actualEntry.solidGroup, expectedEntry.solidGroup,
                           "\(context):\(index):solidGroup", file: file, line: line)
        }
    }

    private func observation(of engine: any ArchiveEngine,
                             name: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> EngineGolden.Fixture {
        let count = engine.numberOfEntries()
        _ = try XCTUnwrap(count > 0 ? count : nil,
                          "\(name):empty archive", file: file, line: line)
        let isEncrypted = engine.isEncrypted()
        let solidGroups = normalizedSolidGroups(in: engine)
        let entries = try (0..<count).map { index in
            let isDirectory = engine.entryIsDirectory(index)
            let contents: Data?
            if isDirectory {
                contents = nil
            } else {
                contents = try XCTUnwrap(engine.contents(ofEntry: index),
                                         "\(name):\(index):contents", file: file, line: line)
            }
            return EngineGolden.Entry(
                name: engine.name(ofEntry: index),
                hasSize: engine.entryHasSize(index),
                size: engine.uncompressedSize(ofEntry: index),
                isDirectory: isDirectory,
                isEncrypted: engine.entryIsEncrypted(index),
                sha256: contents.map(Self.sha256),
                solidGroup: solidGroups[Int(index)])
        }
        return EngineGolden.Fixture(name: name, isEncrypted: isEncrypted, entries: entries)
    }

    private func firstFileIndex(in engine: any ArchiveEngine) -> Int32? {
        let count = engine.numberOfEntries()
        guard count > 0 else { return nil }
        return (0..<count).first { !engine.entryIsDirectory($0) }
    }

    /// 互換層の修正前後を許容する比較形。通常ファイル名は一切変更せず、
    /// ディレクトリと判定されたエントリの末尾区切りだけを除く。
    private func comparableName(_ name: String?, isDirectory: Bool) -> String? {
        guard isDirectory, var comparable = name else { return name }
        while comparable.last == "/" || comparable.last == "\\" {
            comparable.removeLast()
        }
        return comparable
    }

    private func normalizedSolidGroups(in engine: any ArchiveEngine) -> [Int32] {
        let count = engine.numberOfEntries()
        guard count > 0 else { return [] }
        // グループ番号自体は旧実装が先頭エントリ番号、KaitoKit が 7z folder
        // 番号を使い得る。単独グループは独立(-1)へ、複数グループは最初に現れた
        // 順へ正規化し、ArchiveSource が使う依存関係だけを比較する。
        let rawGroups = (0..<count).map { engine.solidGroup(ofEntry: $0) }
        let memberCounts = rawGroups.reduce(into: [Int32: Int]()) { counts, group in
            if group >= 0 { counts[group, default: 0] += 1 }
        }
        var ordinals: [Int32: Int32] = [:]
        var nextOrdinal: Int32 = 0
        return rawGroups.map { rawGroup in
            guard rawGroup >= 0, memberCounts[rawGroup, default: 0] > 1 else {
                return -1
            }
            if let existing = ordinals[rawGroup] { return existing }
            defer { nextOrdinal += 1 }
            ordinals[rawGroup] = nextOrdinal
            return nextOrdinal
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// RAR 3.00 の solid LZ で生成した 2 エントリの最小フィクスチャ。
    /// KaitoKit 側の同一コーパスを文字列で保持し、外部コマンドへの依存を避ける。
    private static let rar4FixtureBase64 = """
        UmFyIRoHADvQcwgADQAAAAAAAABuGXSAgCkALQAAAB4AAAACXlM4pdM2m1wdMwkAIAAAAGhlbGxv
        LnR4dAlBSL6Q+9hX8Ah42BPO7ODTBAgglE75YPYZ72uXVmeoQ0FikZ1O+Qo68NgqeD9ldJCAKAAD
        AAAACQAAAAKRWHvS0zabXB0zCAAgAAAAdGlueS50eHQ/qeTEPXsAQAcA
        """
}
