import XCTest
@testable import Washi

/// 自前 ZIP リーダーの検証(フィクスチャはテスト側の手組みライタで生成)
final class ZipArchiveTests: XCTestCase {
    private let sample: [(name: String, data: Data)] = [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data("<container/>".utf8)),
        ("OEBPS/日本語 ファイル.xhtml", Data(String(repeating: "縦組みのテキスト。", count: 200).utf8)),
        ("OEBPS/empty.txt", Data()),
    ]

    func testStoredRoundTrip() throws {
        let archive = try ZipArchive(data: ZipBuilder.build(sample, method: 0))
        XCTAssertEqual(archive.entries.count, 4)
        for (name, data) in sample {
            XCTAssertTrue(archive.contains(name), name)
            XCTAssertEqual(try archive.data(forEntry: name), data, name)
        }
    }

    func testDeflateRoundTrip() throws {
        let archive = try ZipArchive(data: ZipBuilder.build(sample, method: 8))
        for (name, data) in sample {
            XCTAssertEqual(try archive.data(forEntry: name), data, name)
        }
        // 圧縮が実際に効いていること(店晒し検出: deflate 経路を通った証拠)
        let info = try XCTUnwrap(archive.info(for: "OEBPS/日本語 ファイル.xhtml"))
        XCTAssertEqual(info.method, 8)
        XCTAssertLessThan(info.compressedSize, info.uncompressedSize)
    }

    func testZip64Structures() throws {
        let archive = try ZipArchive(data: ZipBuilder.build(sample, forceZip64: true))
        XCTAssertEqual(archive.entries.count, 4)
        for (name, data) in sample {
            XCTAssertEqual(try archive.data(forEntry: name), data, name)
        }
    }

    func testCRCMismatchDetected() throws {
        var zip = ZipBuilder.build([("a.bin", Data([1, 2, 3, 4, 5, 6, 7, 8]))])
        // ローカルヘッダ(30 バイト)+ 名前(5)の直後 = データ先頭を破壊
        zip[35] ^= 0xFF
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(forEntry: "a.bin")) { error in
            guard case ZipError.corruptEntry = error else {
                return XCTFail("corruptEntry であるべき: \(error)")
            }
        }
    }

    func testEncryptedEntryRejected() throws {
        var zip = ZipBuilder.build([("secret.txt", Data("x".utf8))])
        // 中央ディレクトリのフラグに暗号化ビットを立てる(EOCD から辿る)
        // 手組みフィクスチャの構造上、CD はローカル(30+10+1)の直後
        let cdOffset = 30 + "secret.txt".utf8.count + 1
        XCTAssertEqual(zip[cdOffset], 0x50)  // CD シグネチャ確認
        zip[cdOffset + 8] |= 0x01
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(forEntry: "secret.txt")) { error in
            guard case ZipError.encryptedEntryUnsupported = error else {
                return XCTFail("encryptedEntryUnsupported であるべき: \(error)")
            }
        }
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ZipArchive(data: Data("これは ZIP ではない".utf8)))
        XCTAssertThrowsError(try ZipArchive(data: Data()))
    }

    func testUnknownEntry() throws {
        let archive = try ZipArchive(data: ZipBuilder.build(sample))
        XCTAssertThrowsError(try archive.data(forEntry: "nonexistent")) { error in
            guard case ZipError.entryNotFound = error else {
                return XCTFail("entryNotFound であるべき: \(error)")
            }
        }
    }

    /// ZIP コメント内に偽 EOCD シグネチャがあっても正しい EOCD を選ぶ
    func testEOCDWithTrailingComment() throws {
        var zip = ZipBuilder.build(sample)
        // コメント付き EOCD に書き換える: 末尾 2 バイト(comment len)を書き換えて
        // 偽シグネチャ入りコメントを付与
        let comment = Data([0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00])
        zip[zip.count - 2] = UInt8(comment.count & 0xFF)
        zip[zip.count - 1] = UInt8(comment.count >> 8)
        zip.append(comment)
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(archive.entries.count, 4)
        XCTAssertEqual(try archive.data(forEntry: "mimetype"),
                       Data("application/epub+zip".utf8))
    }
}
