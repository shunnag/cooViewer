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

    func testWrongKeyDoesNotClobberAndReportsUnavailable() async {
        let vault = makeVault()
        let bookKey = PasswordVault.Key.file(path: "/tmp/a.zip")
        await vault.save("orig", for: bookKey)
        // 鍵違い(キーチェーンリセット相当)は unavailable = 照会も保存もしない。
        // 平文には決して見えず、かつ既存ファイルを潰さない
        let other = makeVault(key: SymmetricKey(size: .bits256))
        let available = await other.isAvailable()
        XCTAssertFalse(available)
        let otherCount = await other.count()
        XCTAssertEqual(otherCount, 0)
        await other.save("new", for: bookKey)  // 上書きしないこと
        // 正しい鍵で再オープンすると元データが生存している
        let reloaded = makeVault()
        let password = await reloaded.password(for: bookKey)
        XCTAssertEqual(password, "orig")
        let count = await reloaded.count()
        XCTAssertEqual(count, 1)
    }

    func testCorruptVaultDoesNotClobberAndReportsUnavailable() async throws {
        let vault = makeVault()
        let bookKey = PasswordVault.Key.file(path: "/tmp/a.zip")
        await vault.save("orig", for: bookKey)
        let url = directory.appendingPathComponent("vault.enc")
        try Data("garbage".utf8).write(to: url)
        let reloaded = makeVault()
        let available = await reloaded.isAvailable()
        XCTAssertFalse(available)
        let count = await reloaded.count()
        XCTAssertEqual(count, 0)
        await reloaded.save("x", for: bookKey)
        // save が上書きしない = vault.enc は garbage のまま(バイト等価で証明)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, Data("garbage".utf8))
    }

    func testAbsentVaultIsWritable() async {
        // 空ディレクトリ(ファイル無し)は正常な初回として書ける
        let vault = makeVault()
        let bookKey = PasswordVault.Key.file(path: "/tmp/a.zip")
        let available = await vault.isAvailable()
        XCTAssertTrue(available)
        await vault.save("p", for: bookKey)
        let count = await vault.count()
        XCTAssertEqual(count, 1)
        let reloaded = makeVault()
        let password = await reloaded.password(for: bookKey)
        XCTAssertEqual(password, "p")
    }

    func testEmptyFileTreatedAsAbsent() async throws {
        // 0 バイト vault.enc(中断作成の残骸)は absent 扱いで書ける
        let url = directory.appendingPathComponent("vault.enc")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data().write(to: url)
        let vault = makeVault()
        let available = await vault.isAvailable()
        XCTAssertTrue(available)
        await vault.save("p", for: .file(path: "/tmp/a.zip"))
        let count = await vault.count()
        XCTAssertEqual(count, 1)
    }

    func testUnknownVersionIsUnavailable() async throws {
        // 未知の新版(version 2)は unavailable = 旧ビルドが上書き消去しない
        let vault = makeVault()
        await vault.save("orig", for: .file(path: "/tmp/a.zip"))
        let url = directory.appendingPathComponent("vault.enc")
        let futureJSON = Data(#"{"version":2,"entries":{}}"#.utf8)
        let sealed = try XCTUnwrap(SuperResCacheCrypto.seal(futureJSON, using: key))
        try sealed.write(to: url)
        let reloaded = makeVault()
        let available = await reloaded.isAvailable()
        XCTAssertFalse(available)
        await reloaded.save("x", for: .file(path: "/tmp/a.zip"))
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, sealed)  // 上書きしていない
    }

    func testDeleteAllRecoversUnavailableVault() async throws {
        // 破損で unavailable になった庫も deleteAll でリセットして再び書ける
        let vault = makeVault()
        await vault.save("orig", for: .file(path: "/tmp/a.zip"))
        let url = directory.appendingPathComponent("vault.enc")
        try Data("garbage".utf8).write(to: url)
        let reloaded = makeVault()
        let brokenCount = await reloaded.count()
        XCTAssertEqual(brokenCount, 0)  // load を強制し unavailable 化
        await reloaded.deleteAll()
        await reloaded.save("p", for: .file(path: "/tmp/b.zip"))
        let count = await reloaded.count()
        XCTAssertEqual(count, 1)
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
