import CryptoKit
import Foundation
import XCTest
@testable import cooViewer

/// XADMaster の観測値をゴールデンに固定し、撤去後も KaitoKit の
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

    /// 採取元の file/data 両入口も完全一致させる一時的な検証。
    /// PR 1 では XADMaster とともにこのテストと採取テストを削除する。
    func testXADMasterMatchesEngineGolden() throws {
        try assertEngineMatchesGolden(.xadmaster)
    }

    /// 明示した出力先がある場合だけ XADMaster の file 入口で採取する。
    /// 通常のテスト実行では既存ゴールデンを書き換えない(設計書 §2.4)。
    func testCaptureEngineGolden() throws {
        let outputPath = ProcessInfo.processInfo.environment["COOVIEWER_CAPTURE_ENGINE_GOLDEN"]
        guard let outputPath, !outputPath.isEmpty else {
            throw XCTSkip("COOVIEWER_CAPTURE_ENGINE_GOLDEN が未指定のため採取しない")
        }
        let provenance = try EngineGolden.captureProvenance()
        let captured = try fixtures().map { fixture in
            let engine = try open(.xadmaster, file: fixture.url, context: fixture.name)
            return try observation(of: engine, name: fixture.name)
        }
        let payload = encryptedZIPPayload()
        let archiveURL = try makeEncryptedZIP(payload: payload)
        let engine = try open(.xadmaster, file: archiveURL, context: "zipcrypto")
        let index = try XCTUnwrap(firstFileIndex(in: engine), "暗号化 ZIP が空")
        engine.setPassword("wrong")
        let wrongReturnsEmptyOrNil = engine.contents(ofEntry: index)?.isEmpty ?? true
        engine.setPassword("archive-engine-test")
        let contents = try XCTUnwrap(engine.contents(ofEntry: index), "暗号化 ZIP を復号できない")
        let matchesPayload = Self.sha256(contents) == Self.sha256(payload)
        // 壊れた採取を新しい期待値として保存せず、その場で失敗させる。
        _ = try XCTUnwrap(
            wrongReturnsEmptyOrNil && matchesPayload ? true : nil,
            "XADMaster のパスワード挙動が採取条件を満たさない")
        let golden = EngineGolden(
            provenance: provenance,
            fixtures: captured,
            zipCrypto: EngineGolden.ZipCrypto(
                archive: try observation(of: engine, name: "zipcrypto"),
                payloadSHA256: Self.sha256(contents),
                wrongPasswordReturnsEmptyOrNil: wrongReturnsEmptyOrNil,
                correctPasswordMatchesPayload: matchesPayload))
        let json = try golden.encodedJSON()
        let outputURL = URL(fileURLWithPath: outputPath)
        try json.write(to: outputURL, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: outputURL), json, "採取 JSON の書き込み確認")
        XCTAssertEqual(try JSONDecoder().decode(EngineGolden.self, from: json), golden)
    }

    /// 暗号化フラグ・誤パスワード・復号 SHA をゴールデンに照合する
    /// (仕様書 §4.1.3、設計書 §2.4)。
    func testBothEnginesShareZipCryptoPasswordBehavior() throws {
        let expected = try EngineGolden.load().zipCrypto
        let archiveURL = try makeEncryptedZIP(payload: encryptedZIPPayload())
        let data = try Data(contentsOf: archiveURL)
        for kind in ArchiveEngineKind.allCases {
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
    }

    /// 注入指定のない従来呼び出しは XADMaster のままにする(設計書 §2.4)。
    func testArchiveSourceDefaultsToXADMaster() throws {
        let source = try ArchiveSource(url: makeCBZFixture())
        XCTAssertEqual(source.archiveEngineKind, .xadmaster)
    }

    /// 失敗可能な初期化が返す nil も一度だけ XADMaster へ退避する。
    func testKaitoKitNilOpenFallsBackOnce() async throws {
        let fixture = try makeCBZFixture()
        let factory = ArchiveEngineFactory(
            openFile: { kind, path in
                switch kind {
                case .xadmaster: XADMasterEngine(file: path)
                case .kaitokit: nil
                }
            },
            openData: { kind, data in
                switch kind {
                case .xadmaster: XADMasterEngine(data: data)
                case .kaitokit: nil
                }
            }
        )

        try await assertFallbackWorks(for: fixture, factory: factory)
    }

    /// 互換層より詳細な将来の生成処理がエラーを返しても同じ退避規則を使う。
    func testKaitoKitThrownOpenFallsBackOnce() async throws {
        let cbz = try makeCBZFixture()
        let fixture = tempDir.appendingPathComponent("thrown-open.cbr")
        try Data(contentsOf: cbz).write(to: fixture)
        let factory = ArchiveEngineFactory(
            openFile: { kind, path in
                switch kind {
                case .xadmaster: return XADMasterEngine(file: path)
                case .kaitokit: throw StubOpenError.rejected
                }
            },
            openData: { kind, data in
                switch kind {
                case .xadmaster: return XADMasterEngine(data: data)
                case .kaitokit: throw StubOpenError.rejected
                }
            }
        )

        try await assertFallbackWorks(for: fixture, factory: factory)
    }

    /// KaitoKit が書庫生成後の列挙で失敗しても XADMaster を一度だけ開き直し、
    /// 実際の使用エンジンと診断累積値を同じ退避として記録する(設計書 §2.4)。
    func testKaitoKitEnumerationFailureFallsBackOnce() async throws {
        let fixture = try makeCBZFixture()
        let factory = ArchiveEngineFactory(
            openFile: { kind, path in
                switch kind {
                case .xadmaster: XADMasterEngine(file: path)
                case .kaitokit: EnumerationFailureEngine(file: path)
                }
            },
            openData: { kind, data in
                switch kind {
                case .xadmaster: XADMasterEngine(data: data)
                case .kaitokit: EnumerationFailureEngine(data: data)
                }
            }
        )

        try await assertFallbackWorks(for: fixture, factory: factory)
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

    private func makeCBZFixture() throws -> URL {
        let url = tempDir.appendingPathComponent("contract.cbz")
        let data = TestFixtures.storedZip(entries: [
            (Array("cover.png".utf8), TestFixtures.pngData(width: 3, height: 5)),
            (Array("pages/002.png".utf8), TestFixtures.pngData(
                width: 4, height: 6, red: 0.2, green: 0.4, blue: 0.8)),
        ])
        try data.write(to: url)
        return url
    }

    private func encryptedZIPPayload() -> Data {
        // XADMaster は stored や圧縮後が数十バイトだけの暗号化 ZIP を開けない
        // (実測)。決定的な疑似乱数を 64 文字へ写像し、deflate 後も約 24 KiB にする。
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
        // 拡張子 .bin は XADMaster が MacBinary として中身を探るため、暗号化されていると
        // 開けなくなる(実測)。プレーンな拡張子にする
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

    private func assertFallbackWorks(for fixture: URL,
                                     factory: ArchiveEngineFactory) async throws {
        let source = try ArchiveSource(
            url: fixture, preferredEngine: .kaitokit, engineFactory: factory)
        XCTAssertEqual(source.archiveEngineKind, .xadmaster)
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 2)

        let diagnostics = ArchiveEngineDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.fallbackCount, 1)
        XCTAssertNotNil(diagnostics.lastError)
        XCTAssertTrue(diagnostics.lastError?.contains("KaitoKit") == true)
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
        case .xadmaster: XADMasterEngine(file: url.path)
        case .kaitokit: KaitoKitEngine(file: url.path)
        }
        return try XCTUnwrap(engine, "\(context):\(kind.rawValue) file open")
    }

    private func open(_ kind: ArchiveEngineKind, data: Data,
                      context: String) throws -> any ArchiveEngine {
        let engine: (any ArchiveEngine)? = switch kind {
        case .xadmaster: XADMasterEngine(data: data)
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
        // グループ番号自体は XADMaster が先頭エントリ番号、KaitoKit が 7z folder
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
