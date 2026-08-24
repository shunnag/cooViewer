import CryptoKit
import XCTest
@testable import Washi

/// フォント難読化(IDPF / Adobe)の検証
final class FontDeobfuscationTests: XCTestCase {
    /// IDPF 鍵: XML 空白 4 種(U+20/09/0D/0A)だけを除去して SHA-1
    func testIDPFKeyDerivation() {
        let uid = " urn:uuid:1234\t5678\r\n-90ab "
        let expected = Insecure.SHA1.hash(
            data: Data("urn:uuid:12345678-90ab".utf8))
        XCTAssertEqual(FontDeobfuscator.idpfKey(uniqueIdentifier: uid),
                       Data(expected))
        // U+00A0(ノーブレークスペース)は除去しない
        let withNBSP = "a\u{00A0}b"
        XCTAssertEqual(
            FontDeobfuscator.idpfKey(uniqueIdentifier: withNBSP),
            Data(Insecure.SHA1.hash(data: Data("a\u{00A0}b".utf8))))
    }

    func testAdobeKeyDerivation() {
        let key = FontDeobfuscator.adobeKey(
            uniqueIdentifier: "urn:uuid:12345678-1234-1234-1234-123456789abc")
        XCTAssertEqual(key?.count, 16)
        XCTAssertEqual(key?.first, 0x12)
        XCTAssertEqual(key?.last, 0xBC)
        // UUID 形でなければ nil
        XCTAssertNil(FontDeobfuscator.adobeKey(uniqueIdentifier: "978-4-00-000000-0"))
    }

    /// XOR は対合: 2 回適用で元に戻る。1040/1024 バイト境界の外は不変
    func testRoundTripAndPrefixBoundary() {
        let uid = "urn:uuid:12345678-1234-1234-1234-123456789abc"
        let original = Data((0..<2000).map { UInt8($0 % 251) })

        for (algorithm, boundary) in
            [(EPUBEncryptionInfo.ObfuscationAlgorithm.idpf, 1040),
             (.adobe, 1024)] {
            let obfuscated = FontDeobfuscator.deobfuscate(
                original, algorithm: algorithm, uniqueIdentifier: uid)
            XCTAssertNotEqual(obfuscated.prefix(boundary),
                              original.prefix(boundary))
            XCTAssertEqual(obfuscated.suffix(from: boundary),
                           original.suffix(from: boundary),
                           "\(boundary) バイト以降は不変")
            let restored = FontDeobfuscator.deobfuscate(
                obfuscated, algorithm: algorithm, uniqueIdentifier: uid)
            XCTAssertEqual(restored, original)
        }
    }

    /// 1040 バイトより短いファイルは全体が XOR される
    func testShortFile() {
        let uid = "urn:uuid:12345678-1234-1234-1234-123456789abc"
        let original = Data([0x00, 0x01, 0x02, 0x03])
        let obfuscated = FontDeobfuscator.deobfuscate(
            original, algorithm: .idpf, uniqueIdentifier: uid)
        XCTAssertEqual(obfuscated.count, 4)
        XCTAssertEqual(FontDeobfuscator.deobfuscate(
            obfuscated, algorithm: .idpf, uniqueIdentifier: uid), original)
    }

    func testEncryptionXMLParsing() throws {
        let xml = """
        <?xml version="1.0"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/mincho.otf"/></enc:CipherData>
          </enc:EncryptedData>
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://ns.adobe.com/pdf/enc#RC"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/gothic.otf"/></enc:CipherData>
          </enc:EncryptedData>
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/text/ch1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let info = try EPUBEncryptionInfo.parse(data: Data(xml.utf8))
        XCTAssertEqual(info.obfuscatedResources["OEBPS/fonts/mincho.otf"], .idpf)
        XCTAssertEqual(info.obfuscatedResources["OEBPS/fonts/gothic.otf"], .adobe)
        XCTAssertEqual(info.unknownEncryptedResources["OEBPS/text/ch1.xhtml"],
                       "http://www.w3.org/2001/04/xmlenc#aes128-cbc")
    }
}
