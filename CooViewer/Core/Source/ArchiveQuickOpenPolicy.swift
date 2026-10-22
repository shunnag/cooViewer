import Foundation
import KaitoKit
import os

/// 不一致を検出した書庫だけを、プロセスの寿命の間 Quick Open の対象から外す(設計書 §2.4、CV2-5)。
enum ArchiveQuickOpenPolicy {
    struct Identity: Hashable, Sendable {
        let path: String
        let file: BookFileIdentity

        init(path: String) {
            ArchiveQuickOpenPolicy.identityStatObserver?()
            self.path = CanonicalPath.normalize(path)
            file = FileManagerProbe.blockingIdentity(at: URL(fileURLWithPath: self.path))
        }
    }

    private static let distrusted = OSAllocatedUnfairLock(initialState: Set<Identity>())
    @TaskLocal static var identityStatObserver: (@Sendable () -> Void)?
    @TaskLocal static var testingDistrustStore: OSAllocatedUnfairLock<Set<Identity>>?

    private static var distrustStore: OSAllocatedUnfairLock<Set<Identity>> { testingDistrustStore ?? distrusted }

    /// 不信任が一件もなければ通常 open に正規化・stat の費用を加えない(CV3-6)。
    static func identityForOpen(path: String) -> Identity? {
        guard !distrustStore.withLock({ $0.isEmpty }) else { return nil }
        return Identity(path: path)
    }

    /// 新設の隠し設定。起動時の既定値登録前でも有効にし、保存済みの false を優先する。
    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "RAR5QuickOpen") == nil || defaults.bool(forKey: "RAR5QuickOpen")
    }

    static func isDistrusted(_ identity: Identity) -> Bool {
        distrustStore.withLock { $0.contains(identity) }
    }

    static func distrust(_ identity: Identity) {
        distrustStore.withLock { _ = $0.insert(identity) }
    }

    static func isVerificationMismatch(_ error: any Error) -> Bool {
        guard case KaitoError.malformed(let message) = error else { return false }
        return message.hasPrefix("RAR5 quick-open")
    }
}
