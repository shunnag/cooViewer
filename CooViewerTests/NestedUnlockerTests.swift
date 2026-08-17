import CoreGraphics
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
        let unlocker = NestedUnlocker(provider: { _, _ in "pw" })
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
}
