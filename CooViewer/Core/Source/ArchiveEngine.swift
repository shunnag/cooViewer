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
    /// 失敗理由を保ったまま展開する。パスワード検証のプローブが、読み取り失敗
    /// (`KaitoError.io` 等)と誤パスワードを区別するために使う(cooViewer-3tfd)。
    /// 既定は `contents(ofEntry:)` の nil を「見つからない」として投げる
    func readContents(ofEntry index: Int32) throws -> Data
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

extension ArchiveEngine {
    /// nil しか返せないエンジン(テストの偽エンジン)向けの既定。環境要因ではない
    /// エラーにして、プローブの分類では従来どおり誤パスワード側に落とす
    func readContents(ofEntry index: Int32) throws -> Data {
        guard let data = contents(ofEntry: index) else {
            throw KaitoError.notFound("entry \(index)")
        }
        return data
    }
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

/// 自動並列数・物理メモリ・メモリ圧迫段階は open 時点の値を入力する純関数(設計書 §5)。
/// 明示値を使う展開係もこの値から導き、アプリ側の省エネ判定と同じく
/// 低電力モードまたは温度圧迫(serious / critical)で絞る。
/// 開いた reader は KaitoKit が設定を固定するため、電力方針と同じく以後の open から反映する。
struct ArchiveDecodeBudget: Sendable, Equatable {
    let decodeThreads: Int?
    let parallelDecodeMemory: UInt64
    let powerPolicy: DecodePowerPolicy = .reduceInLowPowerModeOrThermalPressure

    /// 主書庫の先行復号予算の下限・上限(展開係はその半分)。
    static let minimumPrimaryDecodeMemory: UInt64 = 64 << 20
    static let maximumPrimaryDecodeMemory: UInt64 = 256 << 20

    init(role: ArchiveReaderRole, automaticThreads: Int,
         physicalMemory: UInt64, memoryPressure: MemoryPressureLevel) {
        switch role {
        case .primary:
            decodeThreads = nil
        case .extractor(let poolSize):
            let auto = max(1, automaticThreads)
            // 2 を下限にして RAR5 先行復号・7z LZMA2 分割並列を維持する。
            // 自動値が 1 の機械では 1 とし、主書庫と同じ電力制約を守る。
            decodeThreads = min(auto, max(2, auto / max(1, poolSize)))
        }
        parallelDecodeMemory = Self.parallelDecodeMemory(
            role: role, physicalMemory: physicalMemory, memoryPressure: memoryPressure)
    }

    /// 先行復号の保持予算(開いた書庫ごと。設計書 §5)。
    /// 主書庫 = clamp(物理メモリ / 64, 64 MiB, 256 MiB)、展開係はその半分。
    /// - 上限 256 MiB は 16 GB でちょうど到達するので、16 GB 以上の Mac は従来の
    ///   256 / 128 MiB のまま(主 256 + 展開係最大 6×128 ≒ 1 GiB / 書庫)。
    /// - 1/64 にすると書庫 1 つの合計(主 + 6 展開係 = 主の 4 倍)が物理メモリの 1/16 に
    ///   収まる: 8 GB では 128 + 6×64 = 512 MiB で、ページキャッシュ 15%・リサンプル 1/5
    ///   と合わせても OS とほかのアプリに半分以上を残せる。
    /// - 下限 64 MiB は RAR5 / 7z solid ストリームの先行復号が数ページぶん働く最小量
    ///   (これ未満では展開係の並列が待ちばかりになる)。
    /// - 圧迫中に開く reader はキャッシュと同じ 1/2・1/4 の係数で更に絞る。
    ///   予算は復号処理ごとに適用されるため厳密な上限ではない(KaitoKit の仕様)。
    static func parallelDecodeMemory(role: ArchiveReaderRole, physicalMemory: UInt64,
                                     memoryPressure: MemoryPressureLevel) -> UInt64 {
        let primary = min(maximumPrimaryDecodeMemory,
                          max(minimumPrimaryDecodeMemory, physicalMemory / 64))
        let configured = switch role {
        case .primary: primary
        case .extractor: primary / 2
        }
        return UInt64(MemoryBudgetPolicy.effectiveLimit(
            configured: Int(clamping: configured), level: memoryPressure))
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

    /// 電力状態と同じく、物理メモリと圧迫段階も open 時点の値を固定する(設計書 §5)。
    private static func options(role: ArchiveReaderRole) -> ReaderOptions {
        ArchiveDecodeBudget(
            role: role,
            automaticThreads: ReaderOptions.automaticDecodeThreads(
                powerPolicy: .reduceInLowPowerModeOrThermalPressure),
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            memoryPressure: MemoryPressureMonitor.shared.memoryPressureLevel)
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
        try? readContents(ofEntry: index)
    }

    /// 従来の nil 条件(無効な番号・未設定パスワード)も KaitoError で表す
    func readContents(ofEntry index: Int32) throws -> Data {
        guard let entry = entry(at: index) else { throw KaitoError.notFound("entry \(index)") }
        guard !entry.isEncrypted || reader.password != nil else { throw KaitoError.passwordRequired }
        return try readAll(entry)
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

extension PasswordCheck {
    /// プローブ展開の失敗を分類する(cooViewer-3tfd)。環境要因と断定できるものだけを
    /// unreadable にし、残りは従来どおり誤パスワード(rejected)として扱う。
    /// - `KaitoError.io`: FileByteSource の open/pread の errno(NAS/SMB の切断・
    ///   スリープ)。暗号化形式の復号経路から io は投げられない。
    /// - `CancellationError`: オープン取消。正否は判定できていない。
    ///
    /// KaitoKit の誤パスワード報告(各形式。rejected に落ちる根拠):
    /// - zip ZipCrypto: 検査値 1 byte の不一致は wrongPassword(ZipCrypto.swift)。誤通過時の
    ///   展開中の malformed / truncated / checksumMismatch も ZipPasswordAmbiguousDecompressor
    ///   が wrongPassword へ正規化する(ZipReader.swift 冒頭。不完全エントリは除く)。
    /// - zip WinZip AES: 検証値 2 byte の不一致と HMAC 不一致が wrongPassword(WinZipAES.swift)。
    ///   AE-1 の CRC 不一致だけは checksumMismatch。
    /// - RAR5: 検査値一致なら wrongPassword 確定(RAR5Crypto.swift)。検査値なし・不一致の
    ///   復号では RARPasswordAmbiguousDecompressor が malformed / truncated を、CRC・BLAKE2sp
    ///   不一致は mismatchIsWrongPassword が wrongPassword へ(RAR5Reader.swift、RAR5Integrity.swift)。
    /// - RAR4: 独立した検査値がなく、ヘッダ CRC 不一致・構造エラー・CRC 不一致を wrongPassword
    ///   へ正規化する(RAR4VolumeParser.swift、RAR4Reader.swift の checksumMismatchIsWrongPassword)。
    /// - 7z AES: 認証タグがないため、暗号化 folder の malformed / truncated / checksumMismatch を
    ///   wrongPasswordIfStructural が wrongPassword へ(SevenZipFolderPipeline.swift)。
    /// - StuffIt X / StuffIt 5: 検証値(2 byte / MD5 先頭 5 byte)の不一致が wrongPassword
    ///   (StuffItXCrypto.swift、StuffItCrypto.swift)。StuffIt X は検証値衝突時の展開失敗を
    ///   正規化しないため、誤パスワードが truncated / checksumMismatch のまま届き得る。
    ///
    /// truncated を unreadable にしない理由: 上記のとおり誤パスワード由来の truncated が
    /// StuffIt X(衝突)と WinZip AES(検証値衝突後の展開)で残り、KaitoKitEngine.readAll も
    /// 宣言サイズ不足を truncated で報告する。「誤パスワードからは生じない」と示せないため、
    /// 書き込み途中のファイル等で試行回数を消費する残余は受け入れて rejected に留める。
    static func classifyProbeFailure(_ error: Error) -> PasswordCheck {
        if error is CancellationError { return .unreadable }
        if case .io? = error as? KaitoError { return .unreadable }
        return .rejected
    }
}
