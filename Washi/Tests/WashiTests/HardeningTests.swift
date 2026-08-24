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

    /// 内部 DTD の実体爆弾(billion laughs)は展開前に拒否される
    func testEntityBombRejected() {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE bomb [
          <!ENTITY a "aaaaaaaaaaaaaaaaaaaa">
          <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
          <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
        ]>
        <bomb>&c;</bomb>
        """
        XCTAssertThrowsError(try WashiXML.document(from: Data(xml.utf8)))
    }

    /// 内部サブセット内の処理命令に隠した実体宣言も見逃さない
    /// (PI 内の ']' で DOCTYPE スキャナを早期終了させるバイパス)
    func testEntityBombHiddenInPIRejected() {
        let xml = """
        <!DOCTYPE r [ <?p ] ?> <!ENTITY a "aaaaaaaaaa">\
        <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">\
        <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;"> ]><r>&c;</r>
        """
        XCTAssertThrowsError(try WashiXML.document(from: Data(xml.utf8)))
    }

    /// UTF-16 で書かれた実体爆弾もガードを迂回できない
    func testEntityBombUTF16Rejected() {
        let xml = """
        <?xml version="1.0" encoding="UTF-16"?>
        <!DOCTYPE r [
          <!ENTITY a "aaaaaaaaaa">
          <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
          <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
        ]><r>&c;</r>
        """
        // BOM 付き LE / BE 両方
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            var data = Data([0xFF, 0xFE])
            if encoding == .utf16BigEndian { data = Data([0xFE, 0xFF]) }
            data.append(xml.data(using: encoding)!)
            XCTAssertThrowsError(try WashiXML.document(from: data),
                                 "\(encoding) 実体爆弾が通った")
        }
    }

    /// DTD 内部サブセットのコメントに入れた `<!ENTITY` は宣言ではないので、
    /// 正当な XML を誤って拒否しない
    func testCommentedOutEntityAccepted() throws {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE html [<!-- <!ENTITY evil "x"> はコメント -->
          <!ENTITY ok "&#160;">]>
        <html><p>a&ok;</p></html>
        """
        XCTAssertNoThrow(try WashiXML.document(from: Data(xml.utf8)))
    }

    /// 定義済み実体(&lt; 等)を値に含むシムは許容される(再帰しないので安全)
    func testPredefinedEntityInShimAccepted() throws {
        let xml = """
        <!DOCTYPE x [<!ENTITY arrow "&lt;-&gt;">]><x>a&arrow;b</x>
        """
        XCTAssertNoThrow(try WashiXML.document(from: Data(xml.utf8)))
    }

    /// 実在ファイルの互換シム(&nbsp; 等の短い文字参照実体)は許容される
    func testBenignEntityShimAccepted() throws {
        let xml = """
        <?xml version="1.0"?>
        <!-- 前置コメント -->
        <!DOCTYPE html [<!ENTITY nbsp "&#160;"><!ENTITY copy '&#169;'>]>
        <html><p>a&nbsp;b&copy;</p></html>
        """
        let document = try WashiXML.document(from: Data(xml.utf8))
        XCTAssertEqual(document.rootElement()?.name, "html")
    }

    /// 文字参照密輸(&#38; → 参照後付け)・巨大値・大量宣言も拒否される
    func testEntityEdgeCasesRejected() {
        let smuggle = """
        <!DOCTYPE x [<!ENTITY a "&#38;b;"><!ENTITY b "y">]><x>&a;</x>
        """
        XCTAssertThrowsError(try WashiXML.document(from: Data(smuggle.utf8)))
        let huge = "<!DOCTYPE x [<!ENTITY a \"\(String(repeating: "z", count: 100))\">]><x/>"
        XCTAssertThrowsError(try WashiXML.document(from: Data(huge.utf8)))
        // 上限(64)を超える大量宣言は拒否。20 個程度の実在シム集は許容する
        let many = "<!DOCTYPE x ["
            + (0..<80).map { "<!ENTITY e\($0) \"v\">" }.joined() + "]><x/>"
        XCTAssertThrowsError(try WashiXML.document(from: Data(many.utf8)))
        let modest = "<!DOCTYPE x ["
            + (0..<20).map { "<!ENTITY e\($0) \"v\">" }.joined() + "]><x/>"
        XCTAssertNoThrow(try WashiXML.document(from: Data(modest.utf8)))
        // SYSTEM 文字列内の "]>" で検査を早期終了させて後続宣言を隠す抜け道
        let hidden = """
        <!DOCTYPE x SYSTEM "u]>v" [<!ENTITY a "&#38;">]><x/>
        """
        XCTAssertThrowsError(try WashiXML.document(from: Data(hidden.utf8)))
    }

    /// 外部 DTD 参照のみの DOCTYPE(NCX / XHTML1.1 実在形)は従来どおり通る
    func testExternalDoctypeStillAccepted() throws {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
          "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"/>
        """
        XCTAssertNoThrow(try WashiXML.document(from: Data(xml.utf8)))
    }

    /// 異常に深い要素ネストは(下流の再帰ウォーカーが走る前に)拒否される
    func testDeepNestingRejected() throws {
        let deep = String(repeating: "<a>", count: 5000)
            + String(repeating: "</a>", count: 5000)
        XCTAssertThrowsError(try WashiXML.document(from: Data(deep.utf8)))
        let normal = String(repeating: "<a>", count: 50)
            + String(repeating: "</a>", count: 50)
        XCTAssertNoThrow(try WashiXML.document(from: Data(normal.utf8)))
    }

    /// 比率検査(1032:1)を通る「本物の高圧縮 deflate」でも、宣言サイズが
    /// 上限(maxEntrySize)を超えるエントリは展開前に拒否される
    func testOversizedEntryRejected() throws {
        // ゼロ埋め 4000 バイト → deflate 数十バイト(比率は 1032:1 以内)
        let zip = ZipBuilder.build(
            [("big.bin", Data(repeating: 0, count: 4000))], method: 8)
        let archive = try ZipArchive(data: zip, maxEntrySize: 1024)
        XCTAssertThrowsError(try archive.data(forEntry: "big.bin")) { error in
            guard case ZipError.entryTooLarge("big.bin", declaredSize: 4000) = error
            else { return XCTFail("entryTooLarge ではない: \(error)") }
        }
        // 既定上限では通常どおり読める
        let permissive = try ZipArchive(data: zip)
        XCTAssertEqual(try permissive.data(forEntry: "big.bin").count, 4000)
    }

    /// フォルダコンテナ内のシンボリックリンクはコンテナ外の実体を晒さない
    func testFolderContainerRejectsSymlinkEscape() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("washi-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, data) in EPUBFixtures.verticalNovelEntries() {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let secret = dir.deletingLastPathComponent()
            .appendingPathComponent("washi-secret-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        // パス成分としては安全な位置にコンテナ外を指すリンクを置く
        let link = dir.appendingPathComponent("OEBPS/leak.txt")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: secret)

        let publication = try EPUBPublication(url: dir)
        XCTAssertThrowsError(try publication.resource(at: "OEBPS/leak.txt"))
        XCTAssertFalse(publication.resourceExists(at: "OEBPS/leak.txt"))
        // コンテナ内を指すリンク経由でない実体は従来どおり読める(回帰確認)
        XCTAssertNoThrow(try publication.resource(at: "OEBPS/nav.xhtml"))
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
