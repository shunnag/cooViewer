import CryptoKit
import XCTest
@testable import cooViewer

/// 超解像キャッシュ暗号化(AES-GCM)の往復・鍵違い・改竄・破損の検証。
/// 鍵導出そのもの(キーチェーン)は I/O 依存なので、ここでは純粋なシール/
/// オープンだけを対象にする(SuperResCacheKeyStore は結合部の薄いグルー)。
final class SuperResCacheCryptoTests: XCTestCase {
    func testSealOpenRoundTrip() {
        let key = SymmetricKey(size: .bits256)
        let plain = Data((0..<4096).map { UInt8($0 & 0xff) })
        guard let sealed = SuperResCacheCrypto.seal(plain, using: key) else {
            return XCTFail("seal returned nil")
        }
        XCTAssertNotEqual(sealed, plain)  // 暗号文は平文と一致しない
        XCTAssertEqual(SuperResCacheCrypto.open(sealed, using: key), plain)
    }

    func testWrongKeyFailsToOpen() {
        let key = SymmetricKey(size: .bits256)
        let other = SymmetricKey(size: .bits256)
        let plain = Data("secret decrypted page".utf8)
        guard let sealed = SuperResCacheCrypto.seal(plain, using: key) else {
            return XCTFail("seal returned nil")
        }
        XCTAssertNil(SuperResCacheCrypto.open(sealed, using: other))
    }

    func testTamperedBlobFailsToOpen() {
        let key = SymmetricKey(size: .bits256)
        let plain = Data("secret decrypted page".utf8)
        guard var sealed = SuperResCacheCrypto.seal(plain, using: key) else {
            return XCTFail("seal returned nil")
        }
        // 末尾(GCM タグ)を 1 バイト反転 → 認証に失敗して復号できない
        sealed[sealed.count - 1] ^= 0xff
        XCTAssertNil(SuperResCacheCrypto.open(sealed, using: key))
    }

    func testGarbageAndEmptyAreNotDecryptable() {
        let key = SymmetricKey(size: .bits256)
        XCTAssertNil(SuperResCacheCrypto.open(Data([0x00, 0x01, 0x02]), using: key))
        XCTAssertNil(SuperResCacheCrypto.open(Data(), using: key))
    }

    func testEmptyPlaintextRoundTrips() {
        let key = SymmetricKey(size: .bits256)
        guard let sealed = SuperResCacheCrypto.seal(Data(), using: key) else {
            return XCTFail("seal returned nil")
        }
        XCTAssertEqual(SuperResCacheCrypto.open(sealed, using: key), Data())
    }
}
