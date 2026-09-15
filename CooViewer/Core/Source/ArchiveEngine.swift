import Foundation
import KaitoKitCompat
import os

/// 書庫の読み込みと展開を actor 内へ閉じ込める最小境界(設計書 §2.4)。
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

/// 設定・CLI・監査で共通の識別子。保存値との互換のため文字列形式を維持する。
enum ArchiveEngineKind: String, CaseIterable, Sendable {
    case kaitokit

    var displayName: String {
        switch self {
        case .kaitokit: "KaitoKit"
        }
    }
}

/// KaitoKit の互換面を書庫エンジン境界へ収めるアダプター(設計書 §2.4)。
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

/// KaitoKit の生成窓口。テストでは open 失敗や列挙失敗を注入できる。
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
            case .kaitokit: KaitoKitEngine(file: path)
            }
        },
        openData: { kind, data in
            switch kind {
            case .kaitokit: KaitoKitEngine(data: data)
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
