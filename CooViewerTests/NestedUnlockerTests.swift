import CoreGraphics
import CryptoKit
import XCTest
@testable import cooViewer

/// ネスト解除係が「暗号化された子を解除した」ことを記録するかの検証。
/// この記録(sawUnlockedChild)が、フォルダ内/ネスト書庫内の復号済み保護
/// コンテンツを含む本を超解像キャッシュ暗号化の対象にする判定の土台になる(CWE-312)。
final class NestedUnlockerTests: XCTestCase {
    /// テスト用の暗号化子ソース。password と一致すれば解除成功。
    /// fixedOutcome を与えると、パスワードに関係なくその結果を返す(読み取り失敗の再現)
    private actor MockEncryptedSource: BookSource {
        nonisolated let url = URL(fileURLWithPath: "/tmp/mock-nested")
        nonisolated var supportsDateSort: Bool { false }
        private let password: String
        private let fixedOutcome: PasswordCheck?
        private var unlocked = false
        private(set) var checkCount = 0
        init(password: String, fixedOutcome: PasswordCheck? = nil) {
            self.password = password
            self.fixedOutcome = fixedOutcome
        }
        func entries() async throws -> [PageEntry] { [] }
        func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
            throw BookSourceError.pageLoadFailed("mock")
        }
        func isEncrypted() async -> Bool { !unlocked }
        func checkAndSetPassword(_ password: String) async -> PasswordCheck {
            checkCount += 1
            if let fixedOutcome { return fixedOutcome }
            if password == self.password { unlocked = true; return .accepted }
            return .rejected
        }
    }

    /// provider の呼び出し(ダイアログが出た子の名前と試行番号)を記録する
    private actor PromptCounter {
        private(set) var prompts: [(name: String, attempt: Int)] = []
        var count: Int { prompts.count }
        private let answer: String?
        init(answer: String?) { self.answer = answer }
        func provide(_ name: String, _ attempt: Int) -> NestedPasswordAnswer? {
            prompts.append((name, attempt))
            return answer.map { NestedPasswordAnswer(password: $0, saveRequested: false) }
        }
    }

    func testAutomaticFailuresStopAfterEightChildren() async {
        let unlocker = NestedUnlocker(knownPasswords: ["a", "b"])
        var checks = 0
        for index in 0..<100 {
            let child = MockEncryptedSource(password: "secret")
            let accepted = await unlocker.unlock(child, name: "\(index).zip")
            XCTAssertFalse(accepted)
            checks += await child.checkCount
        }
        XCTAssertEqual(checks, 8 * 2)
    }

    func testAutomaticSuccessResetsConsecutiveFailures() async {
        let unlocker = NestedUnlocker(knownPasswords: ["pw"])
        for index in 0..<100 {
            let child = MockEncryptedSource(password: index % 8 == 7 ? "pw" : "other")
            let accepted = await unlocker.unlock(child, name: "\(index).zip")
            let checks = await child.checkCount
            XCTAssertEqual(accepted, index % 8 == 7)
            XCTAssertEqual(checks, 1)
        }
    }

    func testPromptStillWorksAfterAutomaticBudgetIsExhausted() async {
        let prompts = PromptCounter(answer: "pw")
        let unlocker = NestedUnlocker(knownPasswords: ["wrong"])
        for index in 0..<8 {
            _ = await unlocker.unlock(MockEncryptedSource(password: "pw"), name: "\(index).zip")
        }
        await unlocker.setProvider { await prompts.provide($0, $1) }
        let child = MockEncryptedSource(password: "pw")
        let accepted = await unlocker.unlock(child, name: "prompt.zip")
        let checks = await child.checkCount
        XCTAssertTrue(accepted)
        XCTAssertEqual(checks, 1, "上限到達後は入力された値だけを試す")
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

    // MARK: - 読み取り失敗(cooViewer-3tfd)

    /// 保存パスワードの検証が読み取り失敗なら、既知パスワードもダイアログも試さずに
    /// その子を外す(死にかけたボリュームへ総当たりしない)。保存値は残る
    func testUnreadableSavedPasswordSkipsChildWithoutFurtherAttempts() async {
        let (vault, dir) = makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = PasswordVault.Key.file(path: "/tmp/books/flaky.zip")
        await vault.save("pw", for: key)
        let prompts = PromptCounter(answer: "pw")
        let unlocker = NestedUnlocker(provider: { await prompts.provide($0, $1) },
                                      knownPasswords: ["a", "b"], vault: vault)
        let child = MockEncryptedSource(password: "pw", fixedOutcome: .unreadable)
        let ok = await unlocker.unlock(child, name: "flaky.zip", persistenceKey: key)
        XCTAssertFalse(ok)
        let checks = await child.checkCount
        let promptCount = await prompts.count
        XCTAssertEqual(checks, 1, "保存パスワードの 1 回で打ち切る")
        XCTAssertEqual(promptCount, 0, "読めない子にダイアログを出さない")
        let sawSkipped = await unlocker.sawSkippedChild
        let sawUnlocked = await unlocker.sawUnlockedChild
        XCTAssertTrue(sawSkipped)
        XCTAssertFalse(sawUnlocked)
        let saved = await vault.password(for: key)
        XCTAssertEqual(saved, "pw", "保存パスワードは消さない")
    }

    /// 既知パスワードの試行中に読み取り失敗が返れば、残りの既知パスワードもダイアログも試さない
    func testUnreadableKnownPasswordStopsAtFirstCheck() async {
        let prompts = PromptCounter(answer: "pw")
        let unlocker = NestedUnlocker(provider: { await prompts.provide($0, $1) },
                                      knownPasswords: ["a", "b", "c"])
        let child = MockEncryptedSource(password: "pw", fixedOutcome: .unreadable)
        let ok = await unlocker.unlock(child, name: "flaky.zip")
        XCTAssertFalse(ok)
        let checks = await child.checkCount
        let promptCount = await prompts.count
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(promptCount, 0)
        let sawSkipped = await unlocker.sawSkippedChild
        XCTAssertTrue(sawSkipped)
    }

    /// ダイアログの回答が読み取り失敗なら、その子の問い合わせは終えるが、
    /// キャンセルとは違って他の子への問い合わせは続く
    func testUnreadableDuringPromptAllowsSilentUnlockOfOtherChildren() async {
        let prompts = PromptCounter(answer: "pw")
        let unlocker = NestedUnlocker(provider: { await prompts.provide($0, $1) })
        let flaky = MockEncryptedSource(password: "pw", fixedOutcome: .unreadable)
        let flakyOK = await unlocker.unlock(flaky, name: "flaky.zip")
        XCTAssertFalse(flakyOK)
        let flakyChecks = await flaky.checkCount
        let promptsAfterFlaky = await prompts.count
        XCTAssertEqual(flakyChecks, 1, "読めない子に再入力を求めない")
        XCTAssertEqual(promptsAfterFlaky, 1)
        let healthy = MockEncryptedSource(password: "pw")
        let healthyOK = await unlocker.unlock(healthy, name: "healthy.zip")
        XCTAssertTrue(healthyOK, "別の子はダイアログで解錠できる")
        // 検証未了の回答も兄弟で再利用し、同じ回答を再入力させない(設計書 §2.4、§7.4)。
        let recorded = await prompts.prompts
        XCTAssertEqual(recorded.map(\.name), ["flaky.zip"])
        XCTAssertEqual(recorded.map(\.attempt), [1])
        let sawSkipped = await unlocker.sawSkippedChild
        let sawUnlocked = await unlocker.sawUnlockedChild
        XCTAssertTrue(sawSkipped)
        XCTAssertTrue(sawUnlocked)
    }

    // MARK: - PasswordVault 連携(設計書 §2.4 パスワードマネージャー)

    private func makeVault() -> (PasswordVault, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unlocker-vault-\(UUID().uuidString)")
        return (PasswordVault(key: SymmetricKey(size: .bits256), directory: dir), dir)
    }

    func testUnreadableAnswerIsRetriedSilentlyAndSavedOnlyAfterAcceptance() async throws {
        let (vault, dir) = makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = PasswordVault.Key.file(path: "/tmp/books/retrying.zip")
        let prompts = PromptCounter(answer: "pw")
        let unlocker = NestedUnlocker(provider: { name, attempt in
            _ = await prompts.provide(name, attempt)
            return NestedPasswordAnswer(password: "pw", saveRequested: true)
        }, vault: vault)
        do {
            _ = try await unlocker.unlockForAssembly(
                MockEncryptedSource(password: "pw", fixedOutcome: .unreadable),
                name: "retrying.zip", persistenceKey: key)
            XCTFail("未検証の回答は合本の再試行へ戻す")
        } catch { XCTAssertEqual(SourceReadFailure.retryClass(error), .transient) }
        let pending = await vault.password(for: key)
        XCTAssertNil(pending)
        let accepted = try await unlocker.unlockForAssembly(
            MockEncryptedSource(password: "pw"), name: "retrying.zip", persistenceKey: key)
        let count = await prompts.count
        let saved = await vault.password(for: key)
        XCTAssertTrue(accepted)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(saved, "pw")
    }

    func testCancelledQueuedUnlockNeverPromptsAndDoesNotCancelPreviousUnlock() async throws {
        let prompting = expectation(description: "先行する回答を待機")
        let queued = expectation(description: "後続の解除依頼")
        let gate = AssemblyTestGate()
        let prompts = PromptCounter(answer: "pw")
        let unlocker = NestedUnlocker(provider: { name, attempt in
            let answer = await prompts.provide(name, attempt)
            if name == "first.zip" { prompting.fulfill(); await gate.wait() }
            return answer
        })
        let first = Task {
            try await unlocker.unlockForAssembly(MockEncryptedSource(password: "pw"), name: "first.zip",
                persistenceKey: .file(path: "/tmp/first.zip"))
        }
        await fulfillment(of: [prompting], timeout: 1)
        let second = Task {
            queued.fulfill()
            return try await unlocker.unlockForAssembly(MockEncryptedSource(password: "other"), name: "late.zip",
                persistenceKey: .file(path: "/tmp/late.zip"))
        }
        await fulfillment(of: [queued], timeout: 1)
        second.cancel()
        await gate.open()
        let accepted = try await first.value
        XCTAssertTrue(accepted)
        do { _ = try await second.value; XCTFail("後続の依頼だけを取り消す") }
        catch { XCTAssertTrue(error is CancellationError) }
        let recorded = await prompts.prompts
        XCTAssertEqual(recorded.map(\.name), ["first.zip"])
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
