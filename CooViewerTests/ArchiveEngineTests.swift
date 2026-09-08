import CryptoKit
import Foundation
import XCTest
@testable import cooViewer

/// XADMaster と KaitoKit の境界が、実際に閲覧する書庫形式で同じ観測結果を返すことを
/// 固定する。試験移行中も既定エンジンの挙動を比較基準として保つ(設計書 §2.4)。
final class ArchiveEngineTests: XCTestCase {
    private enum StubOpenError: Error {
        case rejected
    }

    private struct Fixture {
        let name: String
        let url: URL
        let expectedNames: [String]
        let expectedDirectories: [Bool]
        let expectedSolidGroups: [Int32]
    }

    private struct EntryObservation: Equatable {
        let name: String?
        let hasSize: Bool
        let size: Int64
        let isDirectory: Bool
        let isEncrypted: Bool
        let digest: String?
        let solidGroupOrdinal: Int32
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

    /// 7 形式・構造を file/data の両入口から開き、列挙面と内容 SHA-256 を比較する。
    /// solidGroup は値が負なら独立、0 以上なら同じ依存ストリームという契約まで
    /// 一致させ、ArchiveSource の並列判定をエンジン非依存に保つ(設計書 §2.4)。
    func testBothEnginesMatchAcrossArchiveFixtures() throws {
        for fixture in try fixtures() {
            let fileXAD = try open(.xadmaster, file: fixture.url, context: fixture.name)
            let fileKaito = try open(.kaitokit, file: fixture.url, context: fixture.name)
            XCTAssertEqual(names(in: fileXAD), fixture.expectedNames, fixture.name)
            // KaitoKit 互換層はディレクトリ名を保存形(末尾区切り付き)で
            // 返す修正待ち。XADMaster 形式の期待値は保ち、その差だけを吸収する。
            XCTAssertEqual(
                comparableNames(in: fileKaito),
                comparableNames(
                    fixture.expectedNames,
                    directoryFlags: fixture.expectedDirectories),
                fixture.name)
            XCTAssertEqual(directoryFlags(in: fileXAD), fixture.expectedDirectories,
                           fixture.name)
            XCTAssertEqual(directoryFlags(in: fileKaito), fixture.expectedDirectories,
                           fixture.name)
            XCTAssertEqual(normalizedSolidGroups(in: fileXAD), fixture.expectedSolidGroups,
                           fixture.name)
            XCTAssertEqual(normalizedSolidGroups(in: fileKaito), fixture.expectedSolidGroups,
                           fixture.name)
            assertEquivalent(fileXAD, fileKaito, context: "\(fixture.name):file")

            let data = try Data(contentsOf: fixture.url)
            let dataXAD = try open(.xadmaster, data: data, context: fixture.name)
            let dataKaito = try open(.kaitokit, data: data, context: fixture.name)
            assertEquivalent(dataXAD, dataKaito, context: "\(fixture.name):data")
            assertEquivalent(fileXAD, dataXAD, context: "\(fixture.name):xad-entrypoint")
            assertEquivalent(fileKaito, dataKaito,
                             context: "\(fixture.name):kaito-entrypoint")
        }
    }

    /// 暗号化フラグ・パスワード設定・復号結果も XADMaster 固有の前提にせず比較する
    /// (仕様書 §4.1.3、設計書 §2.4)。
    func testBothEnginesShareZipCryptoPasswordBehavior() throws {
        // XADMaster は stored の暗号化エントリや圧縮後が数十バイトのエントリしかない
        // ZIP を開けない(実測)。zip が deflate を選び、かつ圧縮後も十分大きい本文にする:
        // 決定的な疑似乱数を base64 風の 64 文字へ写像した 32 KiB(圧縮後 ~24 KiB)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var state: UInt32 = 0x1234_5678
        let payload = Data((0..<32_768).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return alphabet[Int(state >> 26)]
        })
        let archiveURL = try makeEncryptedZIP(payload: payload)
        var decryptedContents: [Data] = []

        for kind in ArchiveEngineKind.allCases {
            let engine = try open(kind, file: archiveURL, context: kind.rawValue)
            XCTAssertTrue(engine.isEncrypted(), kind.rawValue)
            let index = try XCTUnwrap(firstFileIndex(in: engine), kind.rawValue)
            XCTAssertTrue(engine.entryIsEncrypted(index), kind.rawValue)

            engine.setPassword("wrong")
            let wrongContents = engine.contents(ofEntry: index)
            XCTAssertTrue(
                wrongContents?.isEmpty ?? true,
                "\(kind.rawValue): 誤ったパスワードで展開結果を返さない")
            engine.setPassword("archive-engine-test")
            let contents = try XCTUnwrap(
                engine.contents(ofEntry: index),
                "\(kind.rawValue): 正しいパスワードで展開できない")
            XCTAssertEqual(contents, payload, kind.rawValue)
            decryptedContents.append(contents)
        }
        XCTAssertEqual(decryptedContents.count, ArchiveEngineKind.allCases.count)
        XCTAssertEqual(decryptedContents.first, decryptedContents.last,
                       "両エンジンの復号バイトが一致しない")
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
            Fixture(
                name: "zip", url: zipURL,
                // XADMaster はディレクトリエントリ名の末尾区切りを落として返す
                // (実測)。KaitoKit 互換層も同じ形へ揃える(cooViewer-vwey.8)
                expectedNames: ["folder", "folder/page.bin", "root.bin"],
                expectedDirectories: [true, false, false],
                expectedSolidGroups: [-1, -1, -1]),
            Fixture(
                name: "cbz", url: cbzURL,
                expectedNames: ["cover.png", "pages/002.png"],
                expectedDirectories: [false, false],
                expectedSolidGroups: [-1, -1]),
            Fixture(
                name: "7z-nonsolid", url: try bundledFixture("nonsolid", "7z"),
                expectedNames: ["p0.png", "p1.png", "p2.png", "p3.png"],
                expectedDirectories: [false, false, false, false],
                expectedSolidGroups: [-1, -1, -1, -1]),
            Fixture(
                name: "7z-solid", url: try bundledFixture("solid", "7z"),
                expectedNames: ["p0.png", "p1.png", "p2.png", "p3.png"],
                expectedDirectories: [false, false, false, false],
                expectedSolidGroups: [0, 0, 0, 0]),
            Fixture(
                name: "7z-blocks", url: try bundledFixture("blocks", "7z"),
                expectedNames: ["p0.png", "p1.png", "p2.png", "p3.png"],
                expectedDirectories: [false, false, false, false],
                expectedSolidGroups: [0, 0, 1, 1]),
            Fixture(
                name: "rar4-solid", url: rarURL,
                expectedNames: ["hello.txt", "tiny.txt"],
                expectedDirectories: [false, false],
                expectedSolidGroups: [0, 0]),
            Fixture(
                name: "lzh", url: try bundledFixture("book", "lzh"),
                expectedNames: ["p0.png", "p1.png", "p2.png", "p3.png"],
                expectedDirectories: [false, false, false, false],
                expectedSolidGroups: [-1, -1, -1, -1]),
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

    private func assertEquivalent(_ expected: any ArchiveEngine,
                                  _ actual: any ArchiveEngine,
                                  context: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertEqual(actual.numberOfEntries(), expected.numberOfEntries(),
                       "\(context):entry count", file: file, line: line)
        XCTAssertEqual(actual.isEncrypted(), expected.isEncrypted(),
                       "\(context):archive encryption", file: file, line: line)

        let expectedEntries = observations(of: expected, context: context,
                                           file: file, line: line)
        let actualEntries = observations(of: actual, context: context,
                                         file: file, line: line)
        XCTAssertEqual(actualEntries.count, expectedEntries.count,
                       "\(context):observed count", file: file, line: line)
        for (index, pair) in zip(expectedEntries, actualEntries).enumerated() {
            let (expectedEntry, actualEntry) = pair
            XCTAssertEqual(
                comparableName(actualEntry.name,
                               isDirectory: actualEntry.isDirectory),
                comparableName(expectedEntry.name,
                               isDirectory: expectedEntry.isDirectory),
                "\(context):\(index):name", file: file, line: line)
            XCTAssertEqual(actualEntry.hasSize, expectedEntry.hasSize,
                           "\(context):\(index):hasSize", file: file, line: line)
            XCTAssertEqual(actualEntry.size, expectedEntry.size,
                           "\(context):\(index):size", file: file, line: line)
            XCTAssertEqual(actualEntry.isDirectory, expectedEntry.isDirectory,
                           "\(context):\(index):directory", file: file, line: line)
            XCTAssertEqual(actualEntry.isEncrypted, expectedEntry.isEncrypted,
                           "\(context):\(index):encryption", file: file, line: line)
            XCTAssertEqual(actualEntry.digest, expectedEntry.digest,
                           "\(context):\(index):SHA-256", file: file, line: line)
            XCTAssertEqual(actualEntry.solidGroupOrdinal, expectedEntry.solidGroupOrdinal,
                           "\(context):\(index):solidGroup", file: file, line: line)
        }
    }

    private func observations(of engine: any ArchiveEngine,
                              context: String,
                              file: StaticString,
                              line: UInt) -> [EntryObservation] {
        let count = engine.numberOfEntries()
        XCTAssertGreaterThan(count, 0, "\(context):empty archive", file: file, line: line)
        guard count > 0 else { return [] }

        let solidGroups = normalizedSolidGroups(in: engine)
        return (0..<count).map { index in
            let isDirectory = engine.entryIsDirectory(index)
            let contents = isDirectory ? nil : engine.contents(ofEntry: index)
            if !isDirectory {
                XCTAssertTrue(engine.entryHasSize(index),
                              "\(context):\(index):declared size",
                              file: file, line: line)
                XCTAssertNotNil(contents, "\(context):\(index):contents",
                                file: file, line: line)
            }
            return EntryObservation(
                name: engine.name(ofEntry: index),
                hasSize: engine.entryHasSize(index),
                size: engine.uncompressedSize(ofEntry: index),
                isDirectory: isDirectory,
                isEncrypted: engine.entryIsEncrypted(index),
                digest: contents.map(Self.sha256),
                solidGroupOrdinal: solidGroups[Int(index)]
            )
        }
    }

    private func firstFileIndex(in engine: any ArchiveEngine) -> Int32? {
        let count = engine.numberOfEntries()
        guard count > 0 else { return nil }
        return (0..<count).first { !engine.entryIsDirectory($0) }
    }

    private func names(in engine: any ArchiveEngine) -> [String] {
        let count = engine.numberOfEntries()
        guard count > 0 else { return [] }
        return (0..<count).compactMap { engine.name(ofEntry: $0) }
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

    private func comparableNames(in engine: any ArchiveEngine) -> [String?] {
        let count = engine.numberOfEntries()
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            comparableName(
                engine.name(ofEntry: index),
                isDirectory: engine.entryIsDirectory(index))
        }
    }

    private func comparableNames(_ names: [String],
                                 directoryFlags: [Bool]) -> [String?] {
        zip(names, directoryFlags).map { name, isDirectory in
            comparableName(name, isDirectory: isDirectory)
        }
    }

    private func directoryFlags(in engine: any ArchiveEngine) -> [Bool] {
        let count = engine.numberOfEntries()
        guard count > 0 else { return [] }
        return (0..<count).map { engine.entryIsDirectory($0) }
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
