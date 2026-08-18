import CoreGraphics
import CryptoKit
import XCTest
@testable import cooViewer

/// ネスト解除係が「暗号化された子を解除した」ことを記録するかの検証。
/// この記録(sawUnlockedChild)が、フォルダ内/ネスト書庫内の復号済み保護
/// コンテンツを含む本を超解像キャッシュ暗号化の対象にする判定の土台になる(CWE-312)。
final class NestedUnlockerTests: XCTestCase {
    /// テスト用の暗号化子ソース。password と一致すれば解除成功。
    private actor MockEncryptedSource: BookSource {
        nonisolated let url = URL(fileURLWithPath: "/tmp/mock-nested")
        nonisolated var supportsDateSort: Bool { false }
        private let password: String
        private var unlocked = false
        init(password: String) { self.password = password }
        func entries() async throws -> [PageEntry] { [] }
        func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
            throw BookSourceError.pageLoadFailed("mock")
        }
        func isEncrypted() async -> Bool { !unlocked }
        func checkAndSetPassword(_ password: String) async -> Bool {
            if password == self.password { unlocked = true; return true }
            return false
        }
    }

    func testKnownPasswordUnlockRecordsUnlockedChild() async {
        let unlocker = NestedUnlocker(knownPasswords: ["pw"])
        let child = MockEncryptedSource(password: "pw")
        let ok = await unlocker.unlock(child, name: "secret.cbz")
        XCTAssertTrue(ok)
        let sawUnlocked = await unlocker.sawUnlockedChild
        XCTAssertTrue(sawUnlocked)
    }

    func testProviderUnlockRecordsUnlockedChild() async {
        let unlocker = NestedUnlocker(provider: { _, _ in
            NestedPasswordAnswer(password: "pw", saveRequested: false)
        })
        let child = MockEncryptedSource(password: "pw")
        let ok = await unlocker.unlock(child, name: "secret.cbz")
        XCTAssertTrue(ok)
        let sawUnlocked = await unlocker.sawUnlockedChild
        XCTAssertTrue(sawUnlocked)
    }

    func testFailedUnlockDoesNotRecordUnlockedChild() async {
        // provider なし・既知パスワード不一致 → 解除失敗(=保護コンテンツを
        // 束ねていない)。sawUnlockedChild は立たず、sawSkippedChild が立つ
        let unlocker = NestedUnlocker(knownPasswords: ["wrong"])
        let child = MockEncryptedSource(password: "pw")
        let ok = await unlocker.unlock(child, name: "secret.cbz")
        XCTAssertFalse(ok)
        let sawUnlocked = await unlocker.sawUnlockedChild
        let sawSkipped = await unlocker.sawSkippedChild
        XCTAssertFalse(sawUnlocked)
        XCTAssertTrue(sawSkipped)
    }

    // MARK: - PasswordVault 連携(設計書 §2.4 パスワードマネージャー)

    private func makeVault() -> (PasswordVault, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unlocker-vault-\(UUID().uuidString)")
        return (PasswordVault(key: SymmetricKey(size: .bits256), directory: dir), dir)
    }

    func testVaultPasswordUnlocksWithoutPrompt() async {
        let (vault, dir) = makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = PasswordVault.Key.file(path: "/tmp/books/locked.zip")
        await vault.save("pw", for: key)
        // provider が呼ばれたら失敗扱い(自動解錠はダイアログゼロ)
        let unlocker = NestedUnlocker(provider: { _, _ in
            XCTFail("保存済みがあるのにダイアログが出た")
            return nil
        }, vault: vault)
        let child = MockEncryptedSource(password: "pw")
        let ok = await unlocker.unlock(child, name: "locked.zip", persistenceKey: key)
        XCTAssertTrue(ok)
        let sawUnlocked = await unlocker.sawUnlockedChild
        XCTAssertTrue(sawUnlocked)
    }

    func testDialogSaveRequestedPersistsToVault() async {
        let (vault, dir) = makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = PasswordVault.Key.file(path: "/tmp/books/new.zip")
        let unlocker = NestedUnlocker(provider: { _, _ in
            NestedPasswordAnswer(password: "pw", saveRequested: true)
        }, vault: vault)
        let child = MockEncryptedSource(password: "pw")
        _ = await unlocker.unlock(child, name: "new.zip", persistenceKey: key)
        let saved = await vault.password(for: key)
        XCTAssertEqual(saved, "pw")
    }

    func testDialogWithoutSaveRequestDoesNotPersist() async {
        let (vault, dir) = makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = PasswordVault.Key.file(path: "/tmp/books/no-save.zip")
        let unlocker = NestedUnlocker(provider: { _, _ in
            NestedPasswordAnswer(password: "pw", saveRequested: false)
        }, vault: vault)
        let child = MockEncryptedSource(password: "pw")
        _ = await unlocker.unlock(child, name: "no-save.zip", persistenceKey: key)
        let saved = await vault.password(for: key)
        XCTAssertNil(saved, "同意なしのパスワードは絶対に永続化しない")
    }

    func testConsentExtendsSaveToKnownPasswordChildren() async {
        // 最上位ダイアログで保存に同意したパスワードが、同じパスワードの
        // ネスト子の解錠時に子のキーへも保存される(コレクションの展延)
        let (vault, dir) = makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unlocker = NestedUnlocker(knownPasswords: ["pw"], vault: vault)
        await unlocker.noteSaveConsent("pw")
        let childKey = PasswordVault.Key.file(path: "/tmp/books/child.zip")
        let child = MockEncryptedSource(password: "pw")
        _ = await unlocker.unlock(child, name: "child.zip", persistenceKey: childKey)
        let saved = await vault.password(for: childKey)
        XCTAssertEqual(saved, "pw")
    }

    func testKnownPasswordWithoutConsentDoesNotPersist() async {
        let (vault, dir) = makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unlocker = NestedUnlocker(knownPasswords: ["pw"], vault: vault)
        let childKey = PasswordVault.Key.file(path: "/tmp/books/child2.zip")
        let child = MockEncryptedSource(password: "pw")
        _ = await unlocker.unlock(child, name: "child2.zip", persistenceKey: childKey)
        let saved = await vault.password(for: childKey)
        XCTAssertNil(saved)
    }
}
