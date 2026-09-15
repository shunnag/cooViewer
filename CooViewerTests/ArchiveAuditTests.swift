import CryptoKit
import Foundation
import XCTest
@testable import cooViewer

/// 実コレクション監査の列挙・単一エンジン出力・非対話契約を固定する(開発ガイド §2.1)。
final class ArchiveAuditTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestFixtures.makeTempDir() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testLiveCollectionOrderHashesFailuresAndEncryption() throws {
        let payload = Data("audit payload".utf8)
        let zip = TestFixtures.storedZip(entries: [
            (Array("folder/".utf8), Data()),
            (Array("folder/page.txt".utf8), payload),
            (Array("empty.txt".utf8), Data()),
        ])
        try write(zip, "c-book.zip")
        try write(zip, "nested/b.cbz")
        try write(Data("not an archive".utf8), "a-broken.zip")
        try write(zip, "c-book.z01")
        try write(zip, "skipped.Z02")
        try write(zip, "skipped.r00")
        try write(zip, ".hidden.zip")
        try write(zip, ".hidden/book.zip")
        try write(zip, "Hidden.app/Contents/book.zip")
        try write(zip, "ignored.txt")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.zip"),
            withDestinationURL: root.appendingPathComponent("c-book.zip"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-folder"),
            withDestinationURL: root.appendingPathComponent("nested"))
        try makeEncryptedZIP()

        let urls = try ArchiveAudit.archiveURLs(in: root)
        XCTAssertEqual(urls.map(\.lastPathComponent),
                       ["a-broken.zip", "c-book.zip", "b.cbz", "z-encrypted.zip"])
        var records: [ArchiveAuditRecord] = []
        var progress: [Int] = []
        let summary = try ArchiveAudit().run(
            root: root, engines: [.kaitokit], includeHashes: true,
            progress: { progress.append($0.completed) },
            onArchive: { records.append(contentsOf: $0) })
        XCTAssertEqual(progress, [0, 1, 2, 3, 4])
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.map(\.path),
                       ["a-broken.zip", "c-book.zip", "nested/b.cbz", "z-encrypted.zip"])
        XCTAssertTrue(records.allSatisfy { $0.engine == "kaitokit" })
        XCTAssertEqual(records.prefix(1).map(\.status), [.openFailed])
        XCTAssertTrue(records.prefix(1).allSatisfy { $0.numberOfEntries == nil })
        for record in records[1..<3] {
            XCTAssertEqual(record.status, .ok)
            XCTAssertEqual(record.numberOfEntries, 3)
            XCTAssertEqual(record.files, 2)
            XCTAssertEqual(record.namesSHA256, sha("folder\nfolder/page.txt\nempty.txt"))
            let digests = [sha(Data()), sha(payload), sha(Data())]
            XCTAssertEqual(record.contentsSHA256, sha(digests.joined()))
            XCTAssertEqual(record.entries.map(\.sha256), digests.map(Optional.some))
            XCTAssertTrue(record.entries[0].isDirectory)
            XCTAssertTrue(record.entries[1].hasSize)
            XCTAssertEqual(record.entries[1].size, Int64(payload.count))
        }
        // .z01 の兄弟がある本はアプリ同様に file: を使う。
        XCTAssertEqual(records[1].entrypoint, .file)
        for record in records.suffix(1) {
            XCTAssertEqual(record.status, .ok)
            XCTAssertTrue(record.encrypted)
            XCTAssertTrue(record.entries.contains { $0.isEncrypted })
            XCTAssertNotNil(record.namesSHA256)
            XCTAssertNil(record.contentsSHA256)
            XCTAssertTrue(record.entries.allSatisfy { $0.sha256 == nil })
        }
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.failedArchives, 1)
        XCTAssertFalse(summary.succeeded)
    }

    func testEnumerationIncludesFirstVolumeAndRejectsSymlinkRoot() throws {
        try write(Data(), "z/book.001")
        try write(Data(), "z/book.002")
        try write(Data(), "a.zip")
        XCTAssertEqual(try ArchiveAudit.archiveURLs(in: root).map(\.lastPathComponent),
                       ["a.zip", "book.001"])
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try ArchiveAudit.archiveURLs(in: link))
        XCTAssertThrowsError(try ArchiveAudit.archiveURLs(in: root.appendingPathComponent("missing")))
    }

    func testEntrypointUsesApplicationPolicyWithoutFallback() throws {
        for name in ["book.zip", "span.zip", "span.z01", "book.rar"] { try write(Data(), name) }
        let factory = ArchiveEngineFactory(
            openFile: { _, _ in StubEngine(mode: .file) },
            openData: { _, _ in StubEngine(mode: .data) })
        let urls = try ArchiveAudit.archiveURLs(in: root.standardizedFileURL)
        let records = try collect(factory: factory).records
        for record in records {
            let url = try XCTUnwrap(urls.first { $0.lastPathComponent == record.path },
                                    "path=\(record.path), urls=\(urls.map(\.path))")
            let mapped = ArchiveSource.shouldMemoryMap(url: url)
            XCTAssertEqual(record.entrypoint, mapped ? .data : .file)
            XCTAssertEqual(record.entries.first?.name, mapped ? "data" : "file")
        }
        let failureFactory = ArchiveEngineFactory(
            openFile: { _, _ in throw StubError.open },
            openData: { _, _ in nil })
        let failures = try collect(factory: failureFactory)
        XCTAssertTrue(failures.records.allSatisfy { $0.status == .openFailed })
        XCTAssertFalse(failures.summary.succeeded)
    }

    func testFailureClassificationAndContinuation() throws {
        try write(Data(), "book.rar")
        try write(Data(), "next.rar")
        let cases: [(StubEngine.Mode, ArchiveAuditStatus)] = [
            (.negativeCount, .enumerationFailed), (.nilName, .enumerationFailed),
            (.unreadable, .entryUnreadable), (.exceptionName, .enumerationFailed),
            (.exceptionContents, .entryUnreadable),
        ]
        for (mode, status) in cases {
            let factory = ArchiveEngineFactory(
                openFile: { _, path in
                    StubEngine(mode: path.hasSuffix("book.rar") ? mode : .file)
                },
                openData: { _, _ in nil })
            let result = try collect(factory: factory)
            XCTAssertEqual(result.records[0].status, status)
            XCTAssertEqual(result.records[1].status, .ok)
            XCTAssertEqual(result.summary.total, 2)
            XCTAssertEqual(result.summary.failedArchives, 1)
            XCTAssertFalse(result.summary.succeeded)
            if status == .entryUnreadable {
                XCTAssertEqual(result.records[0].entries.map(\.sha256), ["unreadable", sha("payload")])
                XCTAssertEqual(result.records[0].contentsSHA256, "unreadable")
            }
        }
        let exceptionFactory = ArchiveEngineFactory(openFile: { _, _ in
            NSException(name: .genericException, reason: "監査 open 試験").raise()
            return nil
        }, openData: { _, _ in nil })
        let result = try collect(factory: exceptionFactory)
        XCTAssertTrue(result.records.allSatisfy { $0.status == .openFailed })
        XCTAssertTrue(result.records.allSatisfy { $0.error?.contains("監査 open 試験") == true })
    }

    func testEncryptedAndMetadataOnlyNeverReadContents() throws {
        try write(Data(), "book.rar")
        for mode in [StubEngine.Mode.encrypted, .mixedEncrypted] {
            let factory = ArchiveEngineFactory(
                openFile: { _, _ in StubEngine(mode: mode) }, openData: { _, _ in nil })
            let result = try collect(factory: factory)
            XCTAssertTrue(result.summary.succeeded)
            XCTAssertTrue(result.records.allSatisfy { $0.encrypted && $0.contentsSHA256 == nil })
        }
        let factory = ArchiveEngineFactory(
            openFile: { _, _ in StubEngine(mode: .mustNotRead) }, openData: { _, _ in nil })
        let result = try collect(factory: factory, includeHashes: false)
        XCTAssertTrue(result.summary.succeeded)
        XCTAssertTrue(result.records.allSatisfy { $0.contentsSHA256 == nil })
    }

    func testSummaryAndDirectoryNormalization() throws {
        var record = ArchiveAuditRecord(path: "book.zip", engine: "kaitokit", entrypoint: .data)
        var summary = ArchiveAuditSummary()
        summary.include([record])
        XCTAssertTrue(summary.succeeded)
        record.status = .entryUnreadable
        summary.include([record])
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.failedArchives, 1)
        XCTAssertFalse(summary.succeeded)
        XCTAssertEqual(summary.diagnostic, "audit: total=2 failed=1")
        for directory in [true, false] {
            let entry = ArchiveAuditEntry(index: 0, name: "a/\\/", isDirectory: directory,
                                          hasSize: true, size: 0, isEncrypted: false)
            XCTAssertEqual(entry.comparisonName, directory ? "a" : "a/\\/")
        }
    }

    func testEmptyArchiveSingleEngineAndCodable() throws {
        try write(Data(), "empty.rar")
        var records: [ArchiveAuditRecord] = []
        let factory = ArchiveEngineFactory(openFile: { _, _ in StubEngine(mode: .empty) },
                                           openData: { _, _ in nil })
        let summary = try ArchiveAudit(engineFactory: factory).run(
            root: root, engines: [.kaitokit], includeHashes: true,
            onArchive: { records += $0 })
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.namesSHA256, sha(""))
        XCTAssertEqual(record.contentsSHA256, sha(""))
        XCTAssertTrue(summary.succeeded)
        XCTAssertEqual(try JSONDecoder().decode(ArchiveAuditRecord.self,
                                                from: JSONEncoder().encode(record)), record)
        XCTAssertEqual(try JSONDecoder().decode(ArchiveAuditSummary.self,
                                                from: JSONEncoder().encode(summary)), summary)
    }

    func testTSVSnapshotAndArguments() throws {
        var record = ArchiveAuditRecord(path: "dir/a\t.zip", engine: "kaitokit", entrypoint: .data)
        record.numberOfEntries = 1
        record.elapsedMilliseconds = 7
        record.namesSHA256 = "names"
        record.contentsSHA256 = "unreadable"
        record.status = .entryUnreadable
        record.error = "entry 0:\n失敗"
        record.entries = [.init(index: 0, name: "\"a\\b\r\n.txt", isDirectory: false,
                                hasSize: false, size: .max, isEncrypted: false, sha256: "unreadable")]
        XCTAssertEqual(ArchiveAuditRecord.tsvHeader + "\n" + record.tsvRow,
            "path\tengine\tentrypoint\tstatus\tentries\tfiles\tencrypted\telapsed_ms\tnames_sha256\tcontents_sha256\terror\n"
            + "dir/a\\t.zip\tkaitokit\tdata\tentry-unreadable\t1\t1\tfalse\t7\tnames\tunreadable\tentry 0:\\n失敗\n")
        XCTAssertEqual(ArchiveAuditRecord.entriesTSVHeader + "\n" + record.entriesTSVRows,
            "path\tengine\tindex\tname\tsize\tsha256\n"
            + "dir/a\\t.zip\tkaitokit\t0\t\"a\\\\b\\r\\n.txt\t\tunreadable\n")
        let base = ["cooViewer", "--audit-archives", root.path]
        let defaults = try ArchiveAuditCommand.Options(arguments: base)
        XCTAssertEqual(defaults.engines, [.kaitokit])
        XCTAssertEqual(defaults.progressInterval, 20)
        XCTAssertNil(defaults.output)
        let single = try ArchiveAuditCommand.Options(arguments: base + [
            "--audit-engines", "kaitokit", "--audit-hash", "--audit-progress", "3"])
        XCTAssertEqual(single.engines, [.kaitokit])
        XCTAssertTrue(single.includeHashes)
        XCTAssertEqual(single.progressInterval, 3)
        // 旧版のエンジン指定は、単一エンジン制約を明示して拒否する。
        for name in ["xadmaster", "kaitokit,xadmaster"] {
            XCTAssertThrowsError(try ArchiveAuditCommand.Options(
                arguments: base + ["--audit-engines", name])) { error in
                XCTAssertTrue(error.localizedDescription.contains("この版では KaitoKit のみ"))
            }
        }
        for extra in [["--audit-engines", "bad"], ["--audit-engines", "kaitokit,kaitokit"],
                      ["--audit-engines", "kaitokit,"], ["--audit-output"],
                      ["--audit-progress", "0"], ["--audit-output", "book.zip"],
                      ["--audit-output", "same.tsv", "--audit-entries", "same.tsv"]] {
            XCTAssertThrowsError(try ArchiveAuditCommand.Options(arguments: base + extra))
        }
    }

    func testCommandWritesResultsAndReturnsExitCodes() throws {
        try write(TestFixtures.storedZip(entries: [(Array("page.txt".utf8), Data("page".utf8))]),
                  "book.zip")
        let output = root.appendingPathComponent("out.tsv")
        let entries = root.appendingPathComponent("entries.tsv")
        let arguments = ["cooViewer", "--audit-archives", root.path,
                         "--audit-output", output.path, "--audit-entries", entries.path,
                         "--audit-hash"]
        XCTAssertEqual(ArchiveAuditCommand.run(arguments: arguments), 0)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.contains("book.zip\tkaitokit\t"))
        XCTAssertEqual(try String(contentsOf: entries, encoding: .utf8)
            .split(separator: "\n").count, 2)
        XCTAssertEqual(ArchiveAuditCommand.run(arguments: arguments + ["--audit-engines", "bad"]), 1)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), text)
        try write(Data("broken".utf8), "broken.zip")
        XCTAssertEqual(ArchiveAuditCommand.run(arguments: arguments), 1)
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("open-failed"))
        XCTAssertEqual(ArchiveAuditCommand.run(arguments: [
            "cooViewer", "--audit-archives", root.path, "--audit-output",
            root.appendingPathComponent("missing/out.tsv").path]), 1)
    }

    private func collect(factory: ArchiveEngineFactory, includeHashes: Bool = true) throws
        -> (records: [ArchiveAuditRecord], summary: ArchiveAuditSummary) {
        var records: [ArchiveAuditRecord] = []
        let summary = try ArchiveAudit(engineFactory: factory).run(
            root: root, engines: [.kaitokit], includeHashes: includeHashes,
            onArchive: { records += $0 })
        return (records, summary)
    }

    private func write(_ data: Data, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func makeEncryptedZIP() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/zip"))
        // 既存 ArchiveEngineTests と同じ長さの deflate 本文で ZipCrypto を検証する。
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var state: UInt32 = 0x1234_5678
        let payload = Data((0..<32_768).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return alphabet[Int(state >> 26)]
        })
        try write(payload, "secret.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-P", "audit-test", "-q", "z-encrypted.zip", "secret.txt"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func sha(_ value: String) -> String { sha(Data(value.utf8)) }
    private func sha(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    private enum StubError: Error { case open }

    private final class StubEngine: ArchiveEngine {
        enum Mode: Sendable {
            case file, data, empty, negativeCount, nilName, unreadable, encrypted, mixedEncrypted
            case exceptionName, exceptionContents, mustNotRead
        }
        let mode: Mode
        init(mode: Mode) { self.mode = mode }
        init?(file path: String) { mode = .file }
        init?(data: Data) { mode = .data }
        func numberOfEntries() -> Int32 {
            switch mode { case .empty: 0; case .negativeCount: -1; default: 2 }
        }
        func name(ofEntry index: Int32) -> String? {
            if mode == .nilName { return nil }
            if mode == .exceptionName { NSException(name: .genericException, reason: "列挙試験").raise() }
            return mode == .data ? "data" : "file"
        }
        func contents(ofEntry index: Int32) -> Data? {
            if [.encrypted, .mixedEncrypted, .mustNotRead].contains(mode) {
                XCTFail("暗号化書庫またはメタデータ監査で contents を呼びました")
            }
            if mode == .unreadable, index == 0 { return nil }
            if mode == .exceptionContents, index == 0 {
                NSException(name: .genericException, reason: "内容試験").raise()
            }
            return Data("payload".utf8)
        }
        func uncompressedSize(ofEntry index: Int32) -> Int64 { 7 }
        func entryHasSize(_ index: Int32) -> Bool { true }
        func entryIsDirectory(_ index: Int32) -> Bool { false }
        func entryIsEncrypted(_ index: Int32) -> Bool { mode == .encrypted || (mode == .mixedEncrypted && index == 1) }
        func isEncrypted() -> Bool { mode == .encrypted }
        func setPassword(_ password: String) { XCTFail("監査でパスワードを設定しました") }
        func solidGroup(ofEntry index: Int32) -> Int32 { -1 }
        func extractEntry(_ index: Int32, to directory: String) -> Bool { false }
        static var defaultZipLazyLocalHeaders: Bool { true }
        static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {}
    }
}
