import Darwin
import Foundation

/// 実コレクションの監査用 CLI。通常のアプリ起動より先に完結させる(開発ガイド §2.1)。
enum ArchiveAuditCommand {
    struct Options: Sendable {
        let root: URL
        let output: URL?
        let entriesOutput: URL?
        let engines: [ArchiveEngineKind]
        let includeHashes: Bool
        let progressInterval: Int

        init(arguments: [String]) throws {
            let valued = ["--audit-archives", "--audit-output", "--audit-entries",
                          "--audit-engines", "--audit-progress"]
            var values: [String: String] = [:]
            var hashes = false
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--audit-hash", !hashes {
                    hashes = true
                } else if valued.contains(argument), values[argument] == nil,
                          index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    index += 1
                    values[argument] = arguments[index]
                } else {
                    throw ArchiveAuditException.Failure(message: "不正な監査引数: \(argument)")
                }
                index += 1
            }
            guard let folder = values["--audit-archives"], !folder.isEmpty else {
                throw ArchiveAuditException.Failure(message: "--audit-archives <folder> が必要です")
            }
            let names = (values["--audit-engines"] ?? "kaitokit,xadmaster")
                .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let engines = names.compactMap(ArchiveEngineKind.init(rawValue:))
            guard !engines.isEmpty, engines.count == names.count,
                  Set(engines).count == engines.count else {
                throw ArchiveAuditException.Failure(message: "--audit-engines は kaitokit,xadmaster から重複なしで指定してください")
            }
            guard let interval = Int(values["--audit-progress"] ?? "20"), interval > 0 else {
                throw ArchiveAuditException.Failure(message: "--audit-progress は正の整数を指定してください")
            }
            root = URL(fileURLWithPath: folder).standardizedFileURL
            output = values["--audit-output"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            entriesOutput = values["--audit-entries"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            self.engines = engines
            includeHashes = hashes
            progressInterval = interval
            if let output, let entriesOutput,
               output.resolvingSymlinksInPath() == entriesOutput.resolvingSymlinksInPath() {
                throw ArchiveAuditException.Failure(message: "監査 TSV と entry TSV は別のパスを指定してください")
            }
            for url in [output, entriesOutput].compactMap({ $0 }) {
                // 入力書庫を出力先の取り違えで破壊しない。
                guard !SupportedTypes.isArchive(url),
                      !SupportedTypes.isArchive(url.resolvingSymlinksInPath()) else {
                    throw ArchiveAuditException.Failure(message: "書庫パスを TSV 出力先には指定できません")
                }
            }
        }
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let options = try Options(arguments: arguments)
            // 一時ファイルへ逐次出力し、監査完了時に置換する。既存ファイルの hard link も壊さない。
            let output = try Output(destination: options.output)
            defer { output.cleanUp() }
            let entries = try options.entriesOutput.map { try Output(destination: $0) }
            defer { entries?.cleanUp() }
            try output.write(ArchiveAuditRecord.tsvHeader
                + (options.engines.count == 2 ? "\tmatch" : "") + "\n")
            try entries?.write(ArchiveAuditRecord.entriesTSVHeader + "\n")
            let summary = try ArchiveAudit().run(
                root: options.root, engines: options.engines, includeHashes: options.includeHashes,
                progress: { progress in
                    if progress.completed == 0 || progress.completed % options.progressInterval == 0
                        || progress.completed == progress.total {
                        diagnostic("audit: \(progress.completed)/\(progress.total) "
                            + ArchiveAuditRecord.escapeTSV(progress.path))
                    }
                }, onArchive: { records in
                    for record in records {
                        try output.write(record.tsvRow)
                        try entries?.write(record.entriesTSVRows)
                    }
                })
            try entries?.finish()
            try output.finish()
            diagnostic(summary.diagnostic)
            fflush(nil)
            return summary.succeeded ? 0 : 1
        } catch {
            diagnostic("audit: \(ArchiveAuditRecord.escapeTSV(error.localizedDescription))")
            fflush(nil)
            return 1
        }
    }

    private static func diagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }

    private final class Output {
        let destination: URL?
        let temporary: URL?
        let handle: FileHandle

        init(destination: URL?) throws {
            self.destination = destination
            if let destination {
                let temporary = destination.deletingLastPathComponent()
                    .appendingPathComponent(".archive-audit-\(UUID().uuidString).tmp")
                self.temporary = temporary
                // ファイル名を含む監査情報は所有者だけが読めるように作成する。
                let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            } else {
                temporary = nil
                handle = .standardOutput
            }
        }

        func write(_ value: String) throws {
            try handle.write(contentsOf: Data(value.utf8))
        }

        func finish() throws {
            guard let destination, let temporary else { return }
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        func cleanUp() {
            guard let temporary else { return }
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
