import Foundation
import KaitoKitCompat
import os
import XADMaster

/// 書庫実装を切り替えて実本で比較するための最小境界(設計書 §2.4)。
/// 非スレッド安全な実体は `ArchiveSource` または展開係の actor が一つずつ所有する。
protocol ArchiveEngine: AnyObject {
    init?(file path: String)
    init?(data: Data)

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
    func extractEntry(_ index: Int32, to directory: String) -> Bool

    static var defaultZipLazyLocalHeaders: Bool { get }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool)
}

/// XADMaster と KaitoKit の選択値。保存値は将来の名称変更に影響されない識別子にする。
enum ArchiveEngineKind: String, CaseIterable, Sendable {
    case xadmaster
    case kaitokit

    var displayName: String {
        switch self {
        case .xadmaster: "XADMaster"
        case .kaitokit: "KaitoKit"
        }
    }
}

/// 既定の XADMaster 動作を境界内へ閉じ込めるアダプター(設計書 §2.4)。
final class XADMasterEngine: ArchiveEngine {
    private let archive: XADMaster.XADArchive

    init?(file path: String) {
        guard let archive = XADMaster.XADArchive(file: path) else { return nil }
        self.archive = archive
    }

    init?(data: Data) {
        guard let archive = XADMaster.XADArchive(data: data) else { return nil }
        self.archive = archive
    }

    func numberOfEntries() -> Int32 { archive.numberOfEntries() }
    func name(ofEntry index: Int32) -> String? { archive.name(ofEntry: index) }
    func contents(ofEntry index: Int32) -> Data? { archive.contents(ofEntry: index) }
    func uncompressedSize(ofEntry index: Int32) -> Int64 {
        guard archive.entryHasSize(index) else { return .max }
        return archive.uncompressedSize(ofEntry: index)
    }
    func entryHasSize(_ index: Int32) -> Bool { archive.entryHasSize(index) }
    func entryIsDirectory(_ index: Int32) -> Bool { archive.entryIsDirectory(index) }
    func entryIsEncrypted(_ index: Int32) -> Bool { archive.entryIsEncrypted(index) }
    func isEncrypted() -> Bool { archive.isEncrypted() }
    func setPassword(_ password: String) { archive.setPassword(password) }
    func solidGroup(ofEntry index: Int32) -> Int32 {
        Int32(clamping: archive.solidGroup(ofEntry: index))
    }
    func extractEntry(_ index: Int32, to directory: String) -> Bool {
        archive.extractEntry(index, to: directory)
    }

    static var defaultZipLazyLocalHeaders: Bool {
        XADMaster.XADArchive.defaultZipLazyLocalHeaders()
    }

    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {
        XADMaster.XADArchive.setDefaultZipLazyLocalHeaders(enabled)
    }
}

/// KaitoKit の互換面を同じ境界へ収める試験用アダプター(設計書 §2.4)。
final class KaitoKitEngine: ArchiveEngine {
    private let archive: KaitoKitCompat.KaitoArchive

    init?(file path: String) {
        guard let archive = KaitoKitCompat.KaitoArchive(file: path) else { return nil }
        self.archive = archive
    }

    init?(data: Data) {
        guard let archive = KaitoKitCompat.KaitoArchive(data: data) else { return nil }
        self.archive = archive
    }

    func numberOfEntries() -> Int32 { archive.numberOfEntries() }
    func name(ofEntry index: Int32) -> String? { archive.name(ofEntry: index) }
    func contents(ofEntry index: Int32) -> Data? { archive.contents(ofEntry: index) }
    func uncompressedSize(ofEntry index: Int32) -> Int64 {
        guard archive.entryHasSize(index) else { return .max }
        return archive.uncompressedSize(ofEntry: index)
    }
    func entryHasSize(_ index: Int32) -> Bool { archive.entryHasSize(index) }
    func entryIsDirectory(_ index: Int32) -> Bool { archive.entryIsDirectory(index) }
    func entryIsEncrypted(_ index: Int32) -> Bool { archive.entryIsEncrypted(index) }
    func isEncrypted() -> Bool { archive.isEncrypted() }
    func setPassword(_ password: String) { archive.setPassword(password) }
    func solidGroup(ofEntry index: Int32) -> Int32 { archive.solidGroup(ofEntry: index) }
    func extractEntry(_ index: Int32, to directory: String) -> Bool {
        archive.extractEntry(index, to: directory)
    }

    static var defaultZipLazyLocalHeaders: Bool {
        KaitoKitCompat.KaitoArchive.defaultZipLazyLocalHeaders
    }

    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {
        KaitoKitCompat.KaitoArchive.setDefaultZipLazyLocalHeaders(enabled)
    }
}

/// 実装生成を差し替え可能にし、KaitoKit の失敗時だけ XADMaster を一度試すための窓口。
/// クロージャは不変で、生成した非スレッド安全な実体を呼び出し側 actor が所有する。
struct ArchiveEngineFactory: Sendable {
    typealias FileOpener = @Sendable (ArchiveEngineKind, String) throws
        -> (any ArchiveEngine)?
    typealias DataOpener = @Sendable (ArchiveEngineKind, Data) throws
        -> (any ArchiveEngine)?

    let openFile: FileOpener
    let openData: DataOpener

    static let live = ArchiveEngineFactory(
        openFile: { kind, path in
            switch kind {
            case .xadmaster: XADMasterEngine(file: path)
            case .kaitokit: KaitoKitEngine(file: path)
            }
        },
        openData: { kind, data in
            switch kind {
            case .xadmaster: XADMasterEngine(data: data)
            case .kaitokit: KaitoKitEngine(data: data)
            }
        }
    )
}

/// KaitoKit から XADMaster へ退避した回数と直近理由をプロセス内で保持する。
/// デバッグ表示は複数の本・ネスト書庫を含む比較実行全体の退避を確認するため累積値を使う。
enum ArchiveEngineDiagnostics {
    struct Snapshot: Sendable, Equatable {
        let fallbackCount: Int
        let lastError: String?
    }

    private struct State {
        var fallbackCount = 0
        var lastError: String?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func recordFallback(_ error: Error) {
        recordFallback(message: String(describing: error))
    }

    static func recordFallback(message: String) {
        state.withLock {
            $0.fallbackCount += 1
            $0.lastError = message
        }
    }

    static func snapshot() -> Snapshot {
        state.withLock {
            Snapshot(fallbackCount: $0.fallbackCount, lastError: $0.lastError)
        }
    }

    /// XCTest ごとにプロセス累積値を分離するためのテスト専用リセット。
    static func resetForTesting() {
        state.withLock { $0 = State() }
    }
}
