import XCTest
@testable import Washi

/// 不正入力(攻撃的 EPUB)への耐性の検証
final class HardeningTests: XCTestCase {
    /// 偽装 zip64 の巨大 entryCount はクラッシュせずエラーになる
    func testForgedZip64EntryCountRejected() throws {
        var zip = ZipBuilder.build([("a.txt", Data("x".utf8))], forceZip64: true)
        // zip64 EOCD レコードの total entries(+24/+32)を最大値へ偽装
        let signature: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
        guard let start = zip.firstRange(of: Data(signature))?.lowerBound else {
            return XCTFail("zip64 EOCD が見つからない")
        }
        for offset in [24, 32] {
            for i in 0..<8 { zip[start + offset + i] = 0xFF }
        }
        XCTAssertThrowsError(try ZipArchive(data: zip))
    }

    /// 偽装 zip64 の巨大サイズ/オフセットはトラップせずエラーになる
    func testForgedZip64SizesRejected() throws {
        var zip = ZipBuilder.build([("a.txt", Data(repeating: 0x41, count: 64))],
                                   forceZip64: true)
        // 中央ディレクトリの zip64 拡張(id 0x0001)内の 3 つの 64bit 値を偽装
        let extraID: [UInt8] = [0x01, 0x00, 0x18, 0x00]
        guard let start = zip.firstRange(of: Data(extraID))?.lowerBound else {
            return XCTFail("zip64 拡張フィールドが見つからない")
        }
        for i in 0..<24 { zip[start + 4 + i] = 0xFF }
        let archive = try? ZipArchive(data: zip)
        if let archive {
            XCTAssertThrowsError(try archive.data(forEntry: "a.txt"))
        }
        // init 段階で弾かれるのも可(トラップしないことが要件)
    }

    /// 展開後サイズの偽装(zip 爆弾)は deflate 理論比 1032:1 で弾く
    func testZipBombDeclarationRejected() throws {
        var zip = ZipBuilder.build([("b.bin", Data(repeating: 0, count: 100))],
                                   method: 8)
        // 中央ディレクトリの uncompressed size(4 バイト)を巨大化
        // CD シグネチャを探して +24 を書き換える
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let start = zip.firstRange(of: Data(cdSig))?.lowerBound else {
            return XCTFail("CD が見つからない")
        }
        for i in 0..<4 { zip[start + 24 + i] = 0xFF }
        // 併せてローカル側は触らない(CD の値が使われることの確認になる)
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(forEntry: "b.bin"))
    }

    /// フォルダコンテナはコンテナ外への脱出参照を拒否する
    func testFolderContainerRejectsEscape() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("washi-escape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, data) in EPUBFixtures.verticalNovelEntries() {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url)
        }
        // コンテナ外に「秘密」ファイルを置く
        let secret = dir.deletingLastPathComponent()
            .appendingPathComponent("washi-secret-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        let publication = try EPUBPublication(url: dir)
        XCTAssertThrowsError(try publication.resource(
            at: "../" + secret.lastPathComponent))
        XCTAssertThrowsError(try publication.resource(
            at: "OEBPS/../../" + secret.lastPathComponent))
        XCTAssertFalse(publication.resourceExists(
            at: "../" + secret.lastPathComponent))
    }

    /// normalize は脱出パスをそのまま返さない(空 = 存在しないパス扱い)
    func testNormalizeCollapsesEscapes() {
        XCTAssertEqual(ContainerPath.normalize("../../etc/passwd"), "")
        XCTAssertEqual(ContainerPath.normalize("a/../../b"), "")
        XCTAssertEqual(ContainerPath.normalize("a/./b"), "a/b")
        // sanitize はデコードしない(% を名前に含むファイルを壊さない)
        XCTAssertEqual(ContainerPath.sanitize("OEBPS/100%20.png"), "OEBPS/100%20.png")
        XCTAssertEqual(ContainerPath.sanitize("../x"), "")
    }

    /// 同一文書内リンク(#id)のフラグメント抽出
    @MainActor
    func testFragmentExtraction() {
        XCTAssertEqual(EPUBReaderView.fragment(of: "#note1"), "note1")
        XCTAssertEqual(EPUBReaderView.fragment(of: "ch1.xhtml#sec2"), "sec2")
        XCTAssertNil(EPUBReaderView.fragment(of: "ch1.xhtml"))
        XCTAssertNil(EPUBReaderView.fragment(of: "ch1.xhtml#"))
    }

    /// EPUB 2.0 の dc-metadata ラッパー内の DCMES も読める
    func testEPUB2DCMetadataWrapper() throws {
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                    xmlns:opf="http://www.idpf.org/2007/opf">
            <dc-metadata>
              <dc:title>包まれた本</dc:title>
              <dc:identifier id="uid">wrapped-id</dc:identifier>
              <dc:language>ja</dc:language>
            </dc-metadata>
            <x-metadata>
              <meta name="cover" content="c"/>
            </x-metadata>
          </metadata>
          <manifest>
            <item id="c" href="cover.jpg" media-type="image/jpeg"/>
            <item id="p" href="p.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="p"/></spine>
        </package>
        """
        let package = try PackageDocumentParser.parse(
            data: Data(opf.utf8), at: "OEBPS/package.opf")
        XCTAssertEqual(package.metadata.mainTitle, "包まれた本")
        XCTAssertEqual(package.metadata.uniqueIdentifier, "wrapped-id")
        XCTAssertEqual(package.coverImageItem?.id, "c")
    }
}
