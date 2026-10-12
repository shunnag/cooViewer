import Foundation
import KaitoKit
import os

/// 書庫の読み込みと展開を actor 内へ閉じ込める最小境界(設計書 §2.4)。
/// 非スレッド安全な実体は `ArchiveSource` または展開係の actor が一つずつ所有する。
protocol ArchiveEngine: AnyObject {
    init?(file path: String, role: ArchiveReaderRole)
    init?(data: Data, role: ArchiveReaderRole)

    func numberOfEntries() -> Int32
    func name(ofEntry index: Int32) -> String?
    func contents(ofEntry index: Int32) -> Data?
    /// 展開後サイズ。サイズ不明または無効な番号では `Int64.max` を返す。
    func uncompressedSize(ofEntry index: Int32) -> Int64
    func entryHasSize(_ index: Int32) -> Bool
    func entryIsDirectory(_ index: Int32) -> Bool
    func entryIsEncrypted(_ index: Int32) -> Bool
    func isEncrypted() -> Bool
    func setPassword(_ password: String)
    func solidGroup(ofEntry index: Int32) -> Int32

    static var defaultZipLazyLocalHeaders: Bool { get }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool)
}

/// 設定・CLI・監査で共通の識別子。保存値との互換のため文字列形式を維持する。
enum ArchiveEngineKind: String, CaseIterable, Sendable {
    case kaitokit

    var displayName: String {
        switch self {
        case .kaitokit: "KaitoKit"
        }
    }
}

/// 主書庫と展開係では、同時に抱える復号処理の予算を分ける(設計書 §5)。
enum ArchiveReaderRole: Sendable, Equatable {
    case primary
    case extractor(poolSize: Int)
}

/// 自動並列数は open 時点の電力方針を適用済みの値を入力する純関数(設計書 §5)。
/// 明示値を使う展開係もこの値から導き、温度ではなく低電力モードだけに連動する。
struct ArchiveDecodeBudget: Sendable, Equatable {
    let decodeThreads: Int?
    let parallelDecodeMemory: UInt64
    let powerPolicy: DecodePowerPolicy = .reduceInLowPowerMode

    init(role: ArchiveReaderRole, automaticThreads: Int) {
        switch role {
        case .primary:
            decodeThreads = nil
            // 開いた書庫ごとに主 256 + 展開係最大 6×128 MiB ≒ 1 GiB まで先行復号の保持を抑える。
            // 書庫内の書庫・合本の子・次の本は別に数え、物理メモリには比例しない(設計書 §5)。
            parallelDecodeMemory = 256 << 20
        case .extractor(let poolSize):
            let auto = max(1, automaticThreads)
            // 2 を下限にして RAR5 先行復号・7z LZMA2 分割並列を維持する。
            // 自動値が 1 の機械では 1 とし、主書庫と同じ電力制約を守る。
            decodeThreads = min(auto, max(2, auto / max(1, poolSize)))
            parallelDecodeMemory = 128 << 20
        }
    }

    func readerOptions(lazyLocalHeaders: Bool) -> ReaderOptions {
        ReaderOptions(limits: ReadLimits(parallelDecodeMemory: parallelDecodeMemory),
                      lazyLocalHeaders: lazyLocalHeaders,
                      decodeThreads: decodeThreads, decodePowerPolicy: powerPolicy)
    }
}

/// ネイティブ API を既存の nil/false 契約へ収める(設計書 §2.4、§5)。
final class KaitoKitEngine: ArchiveEngine {
    private let reader: ArchiveReader
    private let limits: ReadLimits
    private static let lazyLocalHeaders = OSAllocatedUnfairLock(initialState: true)

    private static func options(role: ArchiveReaderRole) -> ReaderOptions {
        ArchiveDecodeBudget(role: role, automaticThreads:
            ReaderOptions.automaticDecodeThreads(powerPolicy: .reduceInLowPowerMode))
            .readerOptions(lazyLocalHeaders: defaultZipLazyLocalHeaders)
    }

    init?(file path: String, role: ArchiveReaderRole) {
        let options = Self.options(role: role)
        guard let reader = try? ArchiveReader.open(url: URL(fileURLWithPath: path),
                                                   options: options) else { return nil }
        self.reader = reader
        limits = options.limits
    }

    init?(data: Data, role: ArchiveReaderRole) {
        let options = Self.options(role: role)
        guard let reader = try? ArchiveReader.open(data: data, options: options) else { return nil }
        self.reader = reader
        limits = options.limits
    }

    private func entry(at index: Int32) -> ArchiveEntry? {
        guard index >= 0, reader.entries.indices.contains(Int(index)) else { return nil }
        return reader.entries[Int(index)]
    }

    func numberOfEntries() -> Int32 { Int32(exactly: reader.entries.count) ?? .max }

    func name(ofEntry index: Int32) -> String? {
        guard let entry = entry(at: index) else { return nil }
        guard entry.kind == .directory else { return entry.name }
        var name = entry.name
        while name.last == "/" || name.last == "\\" { name.removeLast() }
        return name
    }

    func contents(ofEntry index: Int32) -> Data? {
        guard let entry = entry(at: index),
              !entry.isEncrypted || reader.password != nil else { return nil }
        return try? readAll(entry)
    }

    /// 互換層と同じ確保上限・256 KiB 単位・宣言サイズ不足時の失敗を保つ。
    /// サイズ不明の場合も、上限を確かめてから結果バッファを増やす(設計書 §2.4)。
    private func readAll(_ entry: ArchiveEntry) throws -> Data {
        let stream = try reader.stream(entry)
        if let declaredSize = entry.uncompressedSize {
            guard declaredSize <= limits.maxInMemorySize,
                  let size = Int(exactly: declaredSize) else {
                throw KaitoError.limitExceeded("in-memory entry size")
            }
            var result = Data(count: size)
            try result.withUnsafeMutableBytes { storage in
                var written = 0
                while written < size {
                    let upperBound = min(size, written + 256 * 1_024)
                    let count = try stream.read(into: UnsafeMutableRawBufferPointer(
                        rebasing: storage[written..<upperBound]))
                    guard count > 0 else { throw KaitoError.truncated }
                    written += count
                }
            }
            return result
        }
        var result = Data()
        result.reserveCapacity(Int(min(limits.maxInMemorySize, 256 * 1_024)))
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { break }
            let (nextSize, overflow) = UInt64(result.count).addingReportingOverflow(UInt64(count))
            guard !overflow, nextSize <= limits.maxInMemorySize else {
                throw KaitoError.limitExceeded("in-memory entry size")
            }
            result.append(contentsOf: buffer[..<count])
        }
        return result
    }

    func uncompressedSize(ofEntry index: Int32) -> Int64 {
        guard let size = entry(at: index)?.uncompressedSize else { return .max }
        return Int64(exactly: size) ?? .max
    }
    func entryHasSize(_ index: Int32) -> Bool { entry(at: index)?.uncompressedSize != nil }
    func entryIsDirectory(_ index: Int32) -> Bool { entry(at: index)?.kind == .directory }
    func entryIsEncrypted(_ index: Int32) -> Bool { entry(at: index)?.isEncrypted ?? false }
    func isEncrypted() -> Bool { reader.entries.contains { $0.isEncrypted } }
    func setPassword(_ password: String) { reader.password = password }
    func solidGroup(ofEntry index: Int32) -> Int32 {
        guard let group = entry(at: index)?.solidGroup else { return -1 }
        return Int32(exactly: group) ?? -1
    }

    // 開いた reader の設定は固定し、変更は以後の open へ反映する(設計書 §7.5)。
    static var defaultZipLazyLocalHeaders: Bool { lazyLocalHeaders.withLock { $0 } }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {
        lazyLocalHeaders.withLock { $0 = enabled }
    }
}

/// KaitoKit の生成窓口。テストでは open 失敗や列挙失敗を注入できる。
/// クロージャは不変で、生成した非スレッド安全な実体を呼び出し側 actor が所有する。
struct ArchiveEngineFactory: Sendable {
    typealias FileOpener = @Sendable (ArchiveEngineKind, String, ArchiveReaderRole) throws
        -> (any ArchiveEngine)?
    typealias DataOpener = @Sendable (ArchiveEngineKind, Data, ArchiveReaderRole) throws
        -> (any ArchiveEngine)?

    let openFile: FileOpener
    let openData: DataOpener

    static let live = ArchiveEngineFactory(
        openFile: { kind, path, role in
            switch kind {
            case .kaitokit: KaitoKitEngine(file: path, role: role)
            }
        },
        openData: { kind, data, role in
            switch kind {
            case .kaitokit: KaitoKitEngine(data: data, role: role)
            }
        }
    )
}

/// mmap→file 再試行の回数と最後のエラーをプロセス内で保持する。
/// デバッグ表示では複数の本を開いた実行全体の累積値を使う(設計書 §2.4)。
enum ArchiveEngineDiagnostics {
    struct Snapshot: Sendable, Equatable {
        let mmapRetryCount: Int
        let lastError: String?
    }

    private struct State {
        var mmapRetryCount = 0
        var lastError: String?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// mmap の解析失敗から file 入口を再試行した回数と理由を記録する。
    static func recordRetry(message: String) {
        state.withLock {
            $0.mmapRetryCount += 1
            $0.lastError = message
        }
    }

    /// 終端の open・列挙失敗は再試行回数を増やさずに記録する。
    static func recordError(message: String) {
        state.withLock { $0.lastError = message }
    }

    static func snapshot() -> Snapshot {
        state.withLock {
            Snapshot(mmapRetryCount: $0.mmapRetryCount,
                     lastError: $0.lastError)
        }
    }

    /// XCTest ごとにプロセス累積値を分離するためのテスト専用リセット。
    static func resetForTesting() {
        state.withLock { $0 = State() }
    }
}
