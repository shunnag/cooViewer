import CoreGraphics
import Foundation
import KaitoKit
import os
import XCTest
@testable import cooViewer

/// パスワード検証が「誤パスワード」と「読み取り失敗」を区別すること(cooViewer-3tfd)。
/// 不安定なネットワークボリュームで、正しい保存パスワードが試行回数を燃やさないための土台
final class PasswordCheckTests: XCTestCase {
    /// 暗号化エントリ 1 件の偽エンジン。プローブ展開で failure を投げる(nil なら成功)。
    /// setPassword の呼び出しは lock 経由で外から観測する(actor 所有の非 Sendable 実体のため)
    private final class ProbeEngine: ArchiveEngine {
        private let failure: (any Error)?
        private let passwords: OSAllocatedUnfairLock<[String]>

        init(failure: (any Error)?, passwords: OSAllocatedUnfairLock<[String]>) {
            self.failure = failure
            self.passwords = passwords
        }
        init?(file path: String, role: ArchiveReaderRole) { return nil }
        init?(data: Data, role: ArchiveReaderRole) { return nil }

        func numberOfEntries() -> Int32 { 1 }
        // 型情報サービスに依存せず画像として列挙される拡張子(ArchiveEngineTests と同じ)
        func name(ofEntry index: Int32) -> String? { "page.avifs" }
        func contents(ofEntry index: Int32) -> Data? { try? readContents(ofEntry: index) }
        func readContents(ofEntry index: Int32) throws -> Data {
            if let failure { throw failure }
            return TestFixtures.pngData(width: 2, height: 3)
        }
        func uncompressedSize(ofEntry index: Int32) -> Int64 { 1 }
        func entryHasSize(_ index: Int32) -> Bool { true }
        func entryIsDirectory(_ index: Int32) -> Bool { false }
        func entryIsEncrypted(_ index: Int32) -> Bool { true }
        func isEncrypted() -> Bool { true }
        func setPassword(_ password: String) { passwords.withLock { $0.append(password) } }
        func solidGroup(ofEntry index: Int32) -> Int32 { -1 }
        static var defaultZipLazyLocalHeaders: Bool { true }
        static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {}
    }

    /// 解除係が addKnown で覚えたパスワードを観測するための子
    private actor MockChild: BookSource {
        nonisolated let url = URL(fileURLWithPath: "/tmp/mock-child")
        nonisolated var supportsDateSort: Bool { false }
        private let password: String
        private var unlocked = false
        init(password: String) { self.password = password }
        func entries() async throws -> [PageEntry] { [] }
        func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
            throw BookSourceError.pageLoadFailed("mock")
        }
        func isEncrypted() async -> Bool { !unlocked }
        func checkAndSetPassword(_ password: String) async -> PasswordCheck {
            if password == self.password { unlocked = true; return .accepted }
            return .rejected
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    /// プローブが failure を投げる書庫を、偽エンジンで開く。
    /// .rar は mmap 対象外なので file 入口だけが使われる(ArchiveEngineTests と同じ手法)
    private func makeSource(failure: (any Error)?, unlocker: NestedUnlocker,
                            passwords: OSAllocatedUnfairLock<[String]>) throws -> ArchiveSource {
        let url = tempDir.appendingPathComponent("probe.rar")
        try Data([0]).write(to: url)
        let factory = ArchiveEngineFactory(
            openFile: { _, _, _ in ProbeEngine(failure: failure, passwords: passwords) },
            openData: { _, _, _ in ProbeEngine(failure: failure, passwords: passwords) })
        return try ArchiveSource(url: url, unlocker: unlocker, engineFactory: factory)
    }

    func testProbeIOFailureIsUnreadableAndDoesNotStorePassword() async throws {
        let passwords = OSAllocatedUnfairLock(initialState: [String]())
        let unlocker = NestedUnlocker()
        let source = try makeSource(failure: KaitoError.io(EIO), unlocker: unlocker,
                                    passwords: passwords)
        let check = await source.checkAndSetPassword("pw")
        XCTAssertEqual(check, .unreadable)
        XCTAssertEqual(passwords.withLock { $0 }, ["pw"], "プローブ前の setPassword は従来どおり")
        // 正否不明なので既知パスワードには載らない(子の解錠に使われない)
        let reused = await unlocker.unlock(MockChild(password: "pw"), name: "child.zip")
        XCTAssertFalse(reused)
    }

    func testProbeLimitExceededIsUnreadable() async throws {
        let passwords = OSAllocatedUnfairLock(initialState: [String]())
        let source = try makeSource(failure: KaitoError.limitExceeded("probe"),
            unlocker: NestedUnlocker(), passwords: passwords)
        let check = await source.checkAndSetPassword("pw")
        XCTAssertEqual(check, .unreadable)
    }

    func testProbeCancellationIsUnreadable() async throws {
        let passwords = OSAllocatedUnfairLock(initialState: [String]())
        let source = try makeSource(failure: CancellationError(), unlocker: NestedUnlocker(),
                                    passwords: passwords)
        let check = await source.checkAndSetPassword("pw")
        XCTAssertEqual(check, .unreadable)
    }

    /// 誤パスワードを表す、または環境要因と断定できないエラーは従来どおり拒否
    func testProbePasswordAndStructuralFailuresAreRejected() async throws {
        let failures: [KaitoError] = [
            .wrongPassword, .checksumMismatch(entry: 0), .malformed("probe"),
            .truncated, .unsupportedMethod("probe"),
            .passwordRequired, .notFound("probe"),
        ]
        for failure in failures {
            let passwords = OSAllocatedUnfairLock(initialState: [String]())
            let source = try makeSource(failure: failure, unlocker: NestedUnlocker(),
                                        passwords: passwords)
            let check = await source.checkAndSetPassword("pw")
            XCTAssertEqual(check, .rejected, "\(failure)")
        }
    }

    func testProbeSuccessIsAcceptedAndStoresPassword() async throws {
        let passwords = OSAllocatedUnfairLock(initialState: [String]())
        let unlocker = NestedUnlocker()
        let source = try makeSource(failure: nil, unlocker: unlocker, passwords: passwords)
        let check = await source.checkAndSetPassword("pw")
        XCTAssertEqual(check, .accepted)
        XCTAssertEqual(passwords.withLock { $0 }, ["pw"])
        // 受理したパスワードはネストの子でも再利用される(addKnown)
        let reused = await unlocker.unlock(MockChild(password: "pw"), name: "child.zip")
        XCTAssertTrue(reused)
        // 受理後はページも読め、展開係のエンジンにも同じパスワードが渡る
        let entries = try await source.entries()
        let image = try await source.image(for: XCTUnwrap(entries.first), maxPixelSize: nil)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(passwords.withLock { $0 }, ["pw", "pw"])
    }

    /// 分類の純関数: io・取消・読取上限は unreadable
    func testClassifyProbeFailure() {
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(KaitoError.io(ENXIO)), .unreadable)
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(CancellationError()), .unreadable)
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(KaitoError.wrongPassword), .rejected)
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(KaitoError.truncated), .rejected)
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(KaitoError.checksumMismatch(entry: 1)), .rejected)
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(KaitoError.malformed("x")), .rejected)
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(KaitoError.limitExceeded("x")), .unreadable)
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(KaitoError.unsupportedMethod("x")), .rejected)
        XCTAssertEqual(PasswordCheck.classifyProbeFailure(BookSourceError.pageLoadFailed("x")), .rejected)
    }

    // MARK: - 保存パスワードの自動試行方針

    /// 読み取り失敗だけを一度やり直し、二度目の結果をそのまま返す
    func testSavedPasswordPolicyRetriesOnceOnlyAfterUnreadable() async {
        let cases: [(script: [PasswordCheck], expected: PasswordCheck, calls: Int)] = [
            ([.accepted], .accepted, 1),
            ([.rejected], .rejected, 1),
            ([.unreadable, .accepted], .accepted, 2),
            ([.unreadable, .rejected], .rejected, 2),
            ([.unreadable, .unreadable], .unreadable, 2),
        ]
        for item in cases {
            // 台本と呼び出し回数(Sendable クロージャから触るので lock で守る)
            let state = OSAllocatedUnfairLock(initialState: (remaining: item.script, calls: 0))
            let result = await SavedPasswordPolicy.verify {
                state.withLock { state in
                    state.calls += 1
                    return state.remaining.removeFirst()
                }
            }
            XCTAssertEqual(result, item.expected, "\(item.script)")
            XCTAssertEqual(state.withLock { $0.calls }, item.calls, "\(item.script)")
        }
    }
}
