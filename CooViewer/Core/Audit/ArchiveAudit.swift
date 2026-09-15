import CryptoKit
import Foundation

@_silgen_name("CooArchiveAuditCatchException")
private func catchArchiveAuditException(_ operation: @convention(block) () -> Void)
    -> UnsafeMutableRawPointer?

/// エンジン境界の例外だけを捕捉する。失敗した呼び出しの結果は利用しない。
enum ArchiveAuditException {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func perform<T>(_ operation: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let exception = catchArchiveAuditException { result = Result { try operation() } }
        if let exception {
            let message = Unmanaged<NSString>.fromOpaque(exception).takeRetainedValue()
            throw Failure(message: message as String)
        }
        return try result!.get()
    }
}

enum ArchiveAuditStatus: String, Codable, Sendable {
    case ok
    case openFailed = "open-failed"
    case enumerationFailed = "enumeration-failed"
    case entryUnreadable = "entry-unreadable"
}

enum ArchiveAuditEntrypoint: String, Codable, Sendable {
    case data, file
}

struct ArchiveAuditEntry: Codable, Sendable, Equatable {
    let index: Int32
    let name: String
    let isDirectory: Bool
    let hasSize: Bool
    let size: Int64
    let isEncrypted: Bool
    var sha256: String?

    /// 既知の末尾区切り差だけを除く。保存名は entry TSV にそのまま残す
    /// (cooViewer-vwey.8、開発ガイド §2.1)。
    var comparisonName: String {
        guard isDirectory else { return name }
        var value = name
        while value.last == "/" || value.last == "\\" { value.removeLast() }
        return value
    }
}

struct ArchiveAuditRecord: Codable, Sendable, Equatable {
    let path: String
    let engine: String
    let entrypoint: ArchiveAuditEntrypoint
    var status: ArchiveAuditStatus = .ok
    var numberOfEntries: Int32?
    var entries: [ArchiveAuditEntry] = []
    var encrypted = false
    var elapsedMilliseconds: Int64 = 0
    var namesSHA256: String?
    var contentsSHA256: String?
    var error: String?

    var files: Int { entries.filter { !$0.isDirectory }.count }

    static let tsvHeader = "path\tengine\tentrypoint\tstatus\tentries\tfiles\tencrypted\telapsed_ms\tnames_sha256\tcontents_sha256\terror"
    static let entriesTSVHeader = "path\tengine\tindex\tname\tsize\tsha256"

    var tsvRow: String {
        let fields = [path, engine, entrypoint.rawValue, status.rawValue,
                      numberOfEntries.map(String.init) ?? "", String(files),
                      encrypted ? "true" : "false", String(elapsedMilliseconds),
                      namesSHA256 ?? "", contentsSHA256 ?? "", error ?? ""]
        return fields.map(Self.escapeTSV).joined(separator: "\t") + "\n"
    }

    var entriesTSVRows: String {
        entries.map { entry in
            [path, engine, String(entry.index), entry.name,
             entry.hasSize ? String(entry.size) : "", entry.sha256 ?? ""]
                .map(Self.escapeTSV).joined(separator: "\t") + "\n"
        }.joined()
    }

    /// 一行一レコードを維持し、パス内の制御文字も可逆に保存する。
    static func escapeTSV(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

struct ArchiveAuditSummary: Codable, Sendable, Equatable {
    var total = 0
    var failedArchives = 0

    var succeeded: Bool { failedArchives == 0 }

    var diagnostic: String {
        "audit: total=\(total) failed=\(failedArchives)"
    }

    mutating func include(_ records: [ArchiveAuditRecord]) {
        total += 1
        if records.contains(where: { $0.status != .ok }) { failedArchives += 1 }
    }
}

/// GUI・再試行・保管庫を介さず、KaitoKit だけを所有する同期監査。
/// 生成したエンジンはこの呼び出し内から出さない(設計書 §7.3、開発ガイド §2.1)。
struct ArchiveAudit: Sendable {
    let engineFactory: ArchiveEngineFactory

    init(engineFactory: ArchiveEngineFactory = .live) {
        self.engineFactory = engineFactory
    }

    struct Progress: Sendable {
        let completed: Int
        let total: Int
        let path: String
    }

    /// 書庫単位で出力してメモリを解放し、大規模コレクションでも全 entry を保持しない。
    func run(root: URL, engines: [ArchiveEngineKind], includeHashes: Bool,
             progress: (Progress) -> Void = { _ in },
             onArchive: ([ArchiveAuditRecord]) throws -> Void) throws -> ArchiveAuditSummary {
        guard !engines.isEmpty, Set(engines).count == engines.count else {
            throw ArchiveAuditException.Failure(message: "監査エンジンは重複なしで指定してください")
        }
        let urls = try Self.archiveURLs(in: root)
        // /var → /private/var 等の祖先別名は列挙 URL と基準を揃える。
        // ルート自身のリンク拒否は正規化前に archiveURLs が行う。
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var summary = ArchiveAuditSummary()
        progress(Progress(completed: 0, total: urls.count, path: ""))
        for url in urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                .dropFirst(root.pathComponents.count)
                .joined(separator: "/")
            let entrypoint: ArchiveAuditEntrypoint = ArchiveSource.shouldMemoryMap(url: url)
                ? .data : .file
            let records = engines.map { kind in
                autoreleasepool {
                    inspect(url: url, path: path, kind: kind,
                            entrypoint: entrypoint, includeHashes: includeHashes)
                }
            }
            try onArchive(records)
            summary.include(records)
            progress(Progress(completed: summary.total, total: urls.count, path: path))
        }
        return summary
    }

    static func archiveURLs(in root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey,
                                       .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              rootValues.isPackage != true else {
            throw ArchiveAuditException.Failure(message: "監査ルートは通常のフォルダを指定してください")
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in traversalError = error; return true }) else {
            throw ArchiveAuditException.Failure(message: "監査ルートを列挙できません")
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true || values.isPackage == true || values.isHidden == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true, SupportedTypes.isArchive(url),
               !SupportedTypes.isSplitVolumeContinuation(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }
        // 読めなかった配下を「全件成功」と報告しない(設計書 §7.4)。
        if let traversalError { throw traversalError }
        return urls.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private func inspect(url: URL, path: String, kind: ArchiveEngineKind,
                         entrypoint: ArchiveAuditEntrypoint,
                         includeHashes: Bool) -> ArchiveAuditRecord {
        let start = DispatchTime.now().uptimeNanoseconds
        var record = ArchiveAuditRecord(path: path, engine: kind.rawValue, entrypoint: entrypoint)
        var failureStage: ArchiveAuditStatus = .openFailed
        do {
            // アプリと同じ初回入口を選び、監査では file 再試行せず入口ごとの成否を残す。
            let sourceData = entrypoint == .data
                ? try Data(contentsOf: url, options: .mappedIfSafe) : nil
            try withExtendedLifetime(sourceData) {
                guard let engine = try ArchiveAuditException.perform({
                    if let sourceData { return try self.engineFactory.openData(kind, sourceData) }
                    return try self.engineFactory.openFile(kind, url.path)
                }) else {
                    throw ArchiveAuditException.Failure(message: "エンジンが nil を返しました")
                }
                failureStage = .enumerationFailed
                record.encrypted = try ArchiveAuditException.perform { engine.isEncrypted() }
                let count = try ArchiveAuditException.perform { engine.numberOfEntries() }
                guard count >= 0 else {
                    throw ArchiveAuditException.Failure(message: "負のエントリ数: \(count)")
                }
                record.numberOfEntries = count
                for index in 0..<count {
                    let entry = try ArchiveAuditException.perform {
                        guard let name = engine.name(ofEntry: index) else {
                            throw ArchiveAuditException.Failure(message: "entry \(index): 名前が nil")
                        }
                        return ArchiveAuditEntry(
                            index: index, name: name, isDirectory: engine.entryIsDirectory(index),
                            hasSize: engine.entryHasSize(index), size: engine.uncompressedSize(ofEntry: index),
                            isEncrypted: engine.entryIsEncrypted(index))
                    }
                    record.entries.append(entry)
                    record.encrypted = record.encrypted || entry.isEncrypted
                }
                record.namesSHA256 = Self.sha256(Data(record.entries.map(\.comparisonName)
                    .joined(separator: "\n").utf8))
                // 混在書庫も全体を列挙してから暗号判定し、contents は一切呼ばない。
                guard includeHashes, !record.encrypted else { return }
                var total = SHA256()
                for index in record.entries.indices {
                    do {
                        let digest = try autoreleasepool {
                            let entry = record.entries[index]
                            if entry.isDirectory { return Self.sha256(Data()) }
                            guard let data = try ArchiveAuditException.perform({
                                engine.contents(ofEntry: entry.index)
                            }) else {
                                throw ArchiveAuditException.Failure(message: "contents が nil")
                            }
                            return Self.sha256(data)
                        }
                        record.entries[index].sha256 = digest
                        total.update(data: Data(digest.utf8))
                    } catch {
                        record.status = .entryUnreadable
                        record.entries[index].sha256 = "unreadable"
                        let message = "entry \(index): \(error.localizedDescription)"
                        record.error = [record.error, message].compactMap { $0 }.joined(separator: "; ")
                    }
                }
                // 欠けた entry があると total は定義できない。擬似 digest を作らない。
                record.contentsSHA256 = record.status == .ok
                    ? Self.hex(total.finalize()) : "unreadable"
            }
        } catch {
            record.status = failureStage
            record.error = error.localizedDescription
        }
        record.elapsedMilliseconds = Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return record
    }

    private static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
