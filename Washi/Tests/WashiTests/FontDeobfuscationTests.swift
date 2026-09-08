import CryptoKit
import XCTest
@testable import Washi
@testable import WashiCore

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

    // MARK: - cooViewer-oxr.46 C47: 解除結果の妥当性検証

    func testFontMagicRecognition() {
        for magic in [Data([0x00, 0x01, 0x00, 0x00]), Data("true".utf8),
                      Data("ttcf".utf8), Data("OTTO".utf8),
                      Data("wOFF".utf8), Data("wOF2".utf8)] {
            XCTAssertTrue(FontDeobfuscator.looksLikeFont(magic + Data(count: 64)),
                          "\(magic as NSData) を見落とした")
        }
        XCTAssertFalse(FontDeobfuscator.looksLikeFont(Data("PK\u{03}\u{04}".utf8)))
        XCTAssertFalse(FontDeobfuscator.looksLikeFont(Data([0x00, 0x01])))
        XCTAssertFalse(FontDeobfuscator.looksLikeFont(Data()))
    }

    /// 宣言だけ残って実際には難読化されていない本(Sigil/calibre 編集の典型)。
    /// XOR を掛けるとフォントが壊れるので、素のデータをそのまま返す。
    func testUnobfuscatedFontWithStaleDeclarationIsReturnedIntact() throws {
        let font = Data("OTTO".utf8) + Data((0..<2048).map { UInt8($0 % 251) })
        let publication = try makePublication(fontData: font,
                                              identifier: "urn:uuid:11111111-2222-3333-4444-555555555555")
        let read = try publication.resource(at: "OEBPS/fonts/f.otf")
        XCTAssertEqual(read.data, font, "難読化されていないフォントを壊している")
    }

    /// 難読化された本は従来どおり解除できる(退行防止)。
    func testObfuscatedFontIsStillDeobfuscated() throws {
        let uid = "urn:uuid:11111111-2222-3333-4444-555555555555"
        let font = Data("wOFF".utf8) + Data((0..<2048).map { UInt8($0 % 251) })
        let obfuscated = FontDeobfuscator.deobfuscate(font, algorithm: .idpf,
                                                      uniqueIdentifier: uid)
        XCTAssertNotEqual(obfuscated, font)
        let publication = try makePublication(fontData: obfuscated, identifier: uid)
        let read = try publication.resource(at: "OEBPS/fonts/f.otf")
        XCTAssertEqual(read.data, font, "難読化を解けていない")
    }

    /// unique-identifier が編集で差し替わり、別の dc:identifier が本来の鍵の場合。
    func testFallsBackToAnotherDeclaredIdentifier() throws {
        let real = "urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let font = Data("OTTO".utf8) + Data((0..<2048).map { UInt8(($0 * 7) % 251) })
        let obfuscated = FontDeobfuscator.deobfuscate(font, algorithm: .idpf,
                                                      uniqueIdentifier: real)
        let publication = try makePublication(
            fontData: obfuscated, identifier: "urn:uuid:00000000-0000-0000-0000-000000000000",
            extraIdentifiers: [real])
        let read = try publication.resource(at: "OEBPS/fonts/f.otf")
        XCTAssertEqual(read.data, font, "別の dc:identifier で救済できていない")
    }

    private func makePublication(fontData: Data, identifier: String,
                                 extraIdentifiers: [String] = []) throws
        -> EPUBPublication {
        let extras = extraIdentifiers
            .map { "<dc:identifier>\($0)</dc:identifier>" }.joined()
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">\(identifier)</dc:identifier>
                \(extras)
                <dc:title>難読化</dc:title><dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-09T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/>
                <item id="f" href="fonts/f.otf" media-type="font/otf"/>
              </manifest>
              <spine><itemref idref="c"/></spine>
            </package>
            """
        let encryption = """
            <?xml version="1.0"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                        xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
                <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/f.otf"/></enc:CipherData>
              </enc:EncryptedData>
            </encryption>
            """
        let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/package.opf"
                media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
        let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>本文</p></body></html>"
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("META-INF/encryption.xml", Data(encryption.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/c.xhtml", Data(xhtml.utf8)),
            ("OEBPS/fonts/f.otf", fontData),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-obfuscation.epub"))
    }
}
