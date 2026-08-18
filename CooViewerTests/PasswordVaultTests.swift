import CryptoKit
import XCTest
@testable import cooViewer

/// PasswordVault の検証(鍵注入で Keychain 非依存。SuperResCacheCryptoTests と
/// 同じ分離方針)
final class PasswordVaultTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeVault(key: SymmetricKey? = nil) -> PasswordVault {
        PasswordVault(key: key ?? self.key, directory: directory)
    }

    func testRoundTripAcrossInstances() async {
        let vault = makeVault()
        let bookKey = PasswordVault.Key.file(path: "/tmp/books/secret.zip")
        await vault.save("hunter2", for: bookKey)
        // 別インスタンス(=別プロセス相当)でも同じ鍵なら読める
        let reloaded = makeVault()
        let password = await reloaded.password(for: bookKey)
        XCTAssertEqual(password, "hunter2")
        let count = await reloaded.count()
        XCTAssertEqual(count, 1)
    }

    func testOverwriteUpdatesPassword() async {
        let vault = makeVault()
        let bookKey = PasswordVault.Key.file(path: "/tmp/a.zip")
        await vault.save("old", for: bookKey)
        await vault.save("new", for: bookKey)
        let password = await vault.password(for: bookKey)
        XCTAssertEqual(password, "new")
        let count = await vault.count()
        XCTAssertEqual(count, 1)
    }

    func testDeleteAllRemovesFileAndEntries() async {
        let vault = makeVault()
        await vault.save("x", for: .file(path: "/tmp/a.zip"))
        await vault.deleteAll()
        let count = await vault.count()
        XCTAssertEqual(count, 0)
        let reloaded = makeVault()
        let password = await reloaded.password(for: .file(path: "/tmp/a.zip"))
        XCTAssertNil(password)
    }

    func testWrongKeyReadsAsEmpty() async {
        let vault = makeVault()
        await vault.save("x", for: .file(path: "/tmp/a.zip"))
        // 鍵違い(キーチェーンリセット相当)は空扱い=平文には決して見えない
        let other = makeVault(key: SymmetricKey(size: .bits256))
        let count = await other.count()
        XCTAssertEqual(count, 0)
    }

    func testCorruptVaultReadsAsEmpty() async throws {
        let vault = makeVault()
        await vault.save("x", for: .file(path: "/tmp/a.zip"))
        let url = directory.appendingPathComponent("vault.enc")
        try Data("garbage".utf8).write(to: url)
        let reloaded = makeVault()
        let count = await reloaded.count()
        XCTAssertEqual(count, 0)
    }

    func testVaultFileIsNotPlaintext() async throws {
        let vault = makeVault()
        await vault.save("SuperSecretPassword", for: .file(path: "/tmp/a.zip"))
        let data = try Data(contentsOf: directory.appendingPathComponent("vault.enc"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self)
            .contains("SuperSecretPassword"))
    }

    // MARK: - キー設計

    func testFileKeySharesAcrossPathVariants() {
        // コレクション内(生 URL 由来)と単体オープン(標準化済み)が同一キーに
        // なる — 正規化はキー生成側の責務(FolderSource の URL は生のまま)
        let plain = PasswordVault.Key.file(path: "/tmp/books/a.zip")
        let dotted = PasswordVault.Key.file(path: "/tmp/./books//a.zip")
        XCTAssertEqual(plain, dotted)
        XCTAssertEqual(plain.storageString, dotted.storageString)
    }

    func testNestedKeyIsInjective() {
        // JSON 配列の構造化により、区切り文字を含むパスでも衝突しない
        let a = PasswordVault.Key.file(path: "/tmp/a.zip").nested(entryPath: "b#c.zip")
        let b = PasswordVault.Key.file(path: "/tmp/a.zip#b").nested(entryPath: "c.zip")
        XCTAssertNotEqual(a.storageString, b.storageString)
        // 深さ 2 も安定
        let deep = a.nested(entryPath: "inner.zip")
        XCTAssertEqual(deep.components.count, 3)
    }

    func testNestedKeyRoundTrip() async {
        let vault = makeVault()
        let nested = PasswordVault.Key.file(path: "/tmp/outer.zip")
            .nested(entryPath: "書庫/内側.zip")
        await vault.save("ネストパスワード", for: nested)
        let reloaded = makeVault()
        let password = await reloaded.password(for: nested)
        XCTAssertEqual(password, "ネストパスワード")
    }
}
