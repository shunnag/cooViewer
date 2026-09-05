import Darwin
import XCTest
@testable import Washi
@testable import WashiCore

/// 不正入力(攻撃的 EPUB)への耐性の検証
final class HardeningTests: XCTestCase {
    private func residentByteCount() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self, capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }

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
        // 中央ディレクトリの uncompressed size(4 バイト)を
        // 1,000,000(0x000F4240)に偽装。512 MB 上限の手前で、小さな
        // deflate ペイロードに対する 1032:1 比率検査へ確実に到達させる。
        // CD シグネチャを探して +24 を書き換える
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let start = zip.firstRange(of: Data(cdSig))?.lowerBound else {
            return XCTFail("CD が見つからない")
        }
        let declaredSize: UInt32 = 1_000_000
        for i in 0..<4 {
            zip[start + 24 + i] = UInt8((declaredSize >> (i * 8)) & 0xFF)
        }
        // 併せてローカル側は触らない(CD の値が使われることの確認になる)
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(forEntry: "b.bin")) { error in
            guard case ZipError.corruptEntry("b.bin") = error else {
                return XCTFail("比率検査の corruptEntry ではない: \(error)")
            }
        }
    }

    /// 展開後サイズの絶対上限(512 MB)を超える宣言は展開前に弾く
    func testZipBombDeclarationOverSizeLimitRejected() throws {
        var zip = ZipBuilder.build([("b.bin", Data(repeating: 0, count: 100))],
                                   method: 8)
        let cdSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard let start = zip.firstRange(of: Data(cdSig))?.lowerBound else {
            return XCTFail("CD が見つからない")
        }
        for i in 0..<4 { zip[start + 24 + i] = 0xFF }

        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(forEntry: "b.bin")) { error in
            guard case ZipError.entryTooLarge(
                "b.bin", declaredSize: UInt64(UInt32.max)) = error
            else {
                return XCTFail("サイズ上限の entryTooLarge ではない: \(error)")
            }
        }
    }

    /// UTF-8 の文書に名前付き HTML 実体(&nbsp; 等)があっても従来どおり
    /// 救済して解釈できる(符号化対応の刷新で最頻出の UTF-8 経路が壊れない)
    func testUTF8NamedEntityStillRecovered() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>\
        <p>猫&nbsp;である&mdash;名前</p></body></html>
        """
        let document = try WashiXML.document(from: Data(xml.utf8))
        let text = document.rootElement()?.stringValue ?? ""
        XCTAssertTrue(text.contains("猫"))
        XCTAssertTrue(text.contains("である"))
        XCTAssertTrue(text.contains("名前"))
    }

    /// 外部 DTD 参照付き DOCTYPE(XHTML 1.1)の本文でも、名前付き実体は数値参照へ
    /// 畳まれて保持される(cooViewer-aj4)。libxml2 は外部実体を読まず未定義実体を
    /// 空展開するため、前処理 sanitize で救済する
    func testXHTMLDoctypeNamedEntityPreserved() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" \
        "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml"><body>\
        <p>実体&nbsp;検索&hellip;終端</p></body></html>
        """
        let document = try WashiXML.document(from: Data(xml.utf8))
        let text = document.rootElement()?.stringValue ?? ""
        XCTAssertTrue(text.contains("\u{00A0}"), "NBSP が保持される")
        XCTAssertTrue(text.contains("\u{2026}"), "hellip(…)が保持される")
    }

    /// cooViewer-oxr.10/13: WHATWG のセミコロン付き実体表から XML 定義済み
    /// 5 名だけを除いた全エントリが生成済みであることを検証する。
    func testWHATWGNamedEntityTableIsComplete() {
        XCTAssertEqual(HTMLEntities.table.count, 2_120)
        for name in ["amp", "lt", "gt", "quot", "apos"] {
            XCTAssertNil(HTMLEntities.table[name])
        }
        XCTAssertEqual(HTMLEntities.table["yen"], "&#165;")
        XCTAssertEqual(HTMLEntities.table["NotEqualTilde"], "&#8770;&#824;")
    }

    /// cooViewer-oxr.10/13: XHTML 1.1 の外部 DTD が解決されなくても、従来の
    /// 頻出 15 名以外を含む WHATWG 名前実体を数値参照へ救済する。
    func testXHTML11WHATWGNamedEntitiesArePreserved() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" \
        "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>&yen;&ensp;&emsp;&thinsp;&rarr;</p>
        </body></html>
        """
        let document = try WashiXML.document(from: Data(xml.utf8))
        let text = try XCTUnwrap(document.rootElement()?.stringValue)
        XCTAssertTrue(text.contains("¥"))
        XCTAssertTrue(text.contains("\u{2002}"))
        XCTAssertTrue(text.contains("\u{2003}"))
        XCTAssertTrue(text.contains("\u{2009}"))
        XCTAssertTrue(text.contains("→"))
    }

    /// cooViewer-oxr.10/13: 表にない実体名は別の文字へ置換せず、従来どおり
    /// XML の未定義実体エラーとして扱う。
    func testUnknownNamedEntityRemainsParseError() {
        XCTAssertThrowsError(try WashiXML.document(from: Data("<r>&foo;</r>".utf8)))
    }

    /// cooViewer-oxr.12/90: XML 宣言がなくても meta charset を使い、CP932 の
    /// 拡張文字と名前実体を同時に失わず復号する。
    func testMetaShiftJISWithoutXMLDeclarationIsDecodedAsCP932() throws {
        let encoding = try XCTUnwrap(
            XMLCharsetDetector.encoding(forCharsetName: "Shift_JIS"))
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><meta charset="Shift_JIS"/></head>
        <body><p>①髙㈱&nbsp;&hellip;</p></body></html>
        """
        let publication = try publicationWithChapter(
            try XCTUnwrap(chapter.data(using: encoding)), name: "meta-cp932")
        let text = try publication.extractText(forSpineIndex: 0)
        XCTAssertTrue(text.contains("①髙㈱"))
        XCTAssertTrue(text.contains(" "))
        XCTAssertTrue(text.contains("…"))
    }

    /// cooViewer-oxr.12: UTF-8 として妥当な本文では古い meta 宣言より
    /// 実バイトを優先し、名前実体の救済時にも文字化けさせない。
    func testUTF8TextWinsOverStaleMetaCharsetDuringExtraction() throws {
        let chapter = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><meta charset="Shift_JIS"/></head>
        <body><p>日本語&nbsp;本文</p></body></html>
        """.utf8)
        let publication = try publicationWithChapter(chapter, name: "stale-meta")
        XCTAssertEqual(try publication.extractText(forSpineIndex: 0), "日本語 本文")
    }

    /// cooViewer-oxr.90: Shift_JIS の実在別名はすべて CP932、EUC-JP は
    /// japaneseEUC へ写される。
    func testJapaneseCharsetAliasesUseCP932AndEUCJP() throws {
        let cp932 = try XCTUnwrap(
            XMLCharsetDetector.encoding(forCharsetName: "CP932"))
        let aliases = [
            "Shift_JIS", "shift_jis", "SJIS", "MS_Kanji", "csShiftJIS",
            "Windows-31J", "MS932", "CP932",
        ]
        for alias in aliases {
            let declaration = Data(
                "<?xml version=\"1.0\" encoding=\"\(alias)\"?><r/>".utf8)
            XCTAssertEqual(
                XMLCharsetDetector.declaredEncoding(in: declaration)?.rawValue,
                cp932.rawValue,
                alias)
        }
        XCTAssertEqual(
            XMLCharsetDetector.encoding(forCharsetName: "EUC-JP")?.rawValue,
            String.Encoding.japaneseEUC.rawValue)
    }

    private func publicationWithChapter(_ chapter: Data,
                                        name: String) throws -> EPUBPublication {
        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                 unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(name)</dc:identifier>
            <dc:title>Charset fixture</dc:title><dc:language>ja</dc:language>
          </metadata>
          <manifest><item id="chapter" href="chapter.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(package.utf8)),
            ("OEBPS/chapter.xhtml", chapter),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/\(name).epub"))
    }

    /// Shift_JIS 宣言の XML に名前付き HTML 実体があっても、実際の符号化で
    /// 復号して救済し、UTF-8 で再パースできる(旧来の日本語 EPUB 対応)
    func testShiftJISWithNamedEntityRecovered() throws {
        let xml = """
        <?xml version="1.0" encoding="Shift_JIS"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>\
        <p>著作権&copy;2020 猫&nbsp;である</p></body></html>
        """
        let data = xml.data(using: .shiftJIS)!
        let document = try WashiXML.document(from: data)
        let text = document.rootElement()?.stringValue ?? ""
        XCTAssertTrue(text.contains("著作権"))
        XCTAssertTrue(text.contains("猫"))
        XCTAssertTrue(text.contains("である"))
    }

    /// UTF-16(BOM)宣言 + 名前付き実体も救済される
    func testUTF16WithNamedEntityRecovered() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-16"?>
        <r>a&mdash;b&nbsp;猫</r>
        """
        var data = Data([0xFF, 0xFE])
        data.append(xml.data(using: .utf16LittleEndian)!)
        let document = try WashiXML.document(from: data)
        let text = document.rootElement()?.stringValue ?? ""
        XCTAssertTrue(text.contains("猫"))
    }

    /// 細工された zip64 EOCD ロケータ(巨大 64bit オフセット)でクラッシュせず
    /// エラーになる(Int(UInt64) のトラップ回避)
    func testZip64LocatorOverflowRejected() throws {
        var zip = ZipBuilder.build([("a.txt", Data("x".utf8))], forceZip64: true)
        // zip64 EOCD locator(sig 0x07064b50)直後の 8 バイトオフセットを
        // Int.max 超へ偽装する
        let sig: [UInt8] = [0x50, 0x4B, 0x06, 0x07]
        guard let start = zip.firstRange(of: Data(sig))?.lowerBound else {
            return XCTFail("zip64 locator が見つからない")
        }
        for i in 0..<8 { zip[start + 8 + i] = 0xFF }  // オフセット = 0xFFFF...
        XCTAssertThrowsError(try ZipArchive(data: zip))  // トラップせず throw
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

    /// cooViewer-oxr.85: UTF-32 の BOM で ASCII の DTD 検査を迂回する
    /// 実体爆弾は、libxml2 に渡して展開する前に一定時間・小メモリで拒否する。
    func testUTF32EntityBombRejectedBeforeParsing() {
        let xml = """
        <?xml version="1.0" encoding="UTF-32"?>
        <!DOCTYPE r [
          <!ENTITY a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">
          <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
          <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
          <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">
          <!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;">
        ]><r>&e;</r>
        """
        let residentBefore = residentByteCount()
        let started = ContinuousClock.now
        for (encoding, bom) in [
            (String.Encoding.utf32LittleEndian, Data([0xFF, 0xFE, 0x00, 0x00])),
            (.utf32BigEndian, Data([0x00, 0x00, 0xFE, 0xFF])),
        ] {
            var data = bom
            data.append(xml.data(using: encoding)!)
            XCTAssertThrowsError(try WashiXML.document(from: data)) { error in
                guard case EPUBError.malformed(let detail) = error else {
                    return XCTFail("UTF-32 専用の拒否ではない: \(error)")
                }
                XCTAssertEqual(detail, "UTF-32 XML is not supported")
            }
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))

        // BOM を持たない ASCII バイトでも、宣言が UTF-32 なら同じく拒否する。
        let declared = Data(
            "<?xml version=\"1.0\" encoding=\"UTF-32\"?><r/>".utf8)
        XCTAssertThrowsError(try WashiXML.document(from: declared))
        if let residentBefore, let residentAfter = residentByteCount() {
            let growth = residentAfter > residentBefore
                ? residentAfter - residentBefore : 0
            XCTAssertLessThan(
                growth, 128 * 1024 * 1024,
                "UTF-32 の拒否処理が RSS を過大に増やした: \(growth) bytes")
        }
    }

    /// cooViewer-oxr.86: 未終端 DOCTYPE に大量のコメント/ENTITY 開始トークンを
    /// 連ねても、正規表現へ全入力を渡さず 64 KiB の単一走査で打ち切る。
    func testUnterminatedDoctypeScanIsBounded() {
        let xml = "<!DOCTYPE r ["
            + String(repeating: "<!--<!ENTITY", count: 32_000)
        let started = ContinuousClock.now
        XCTAssertThrowsError(try WashiXML.document(from: Data(xml.utf8))) { error in
            guard case EPUBError.malformed(let detail) = error else {
                return XCTFail("malformed ではない: \(error)")
            }
            XCTAssertTrue(detail.contains("DOCTYPE"), detail)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
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

    /// cooViewer-oxr.18: URI 解決の .. は root で clamp する。
    /// FolderContainerReader 自身の未正規化パス拒否は別に維持する。
    func testNormalizeCollapsesEscapes() {
        XCTAssertEqual(ContainerPath.normalize("../../etc/passwd"), "etc/passwd")
        XCTAssertEqual(ContainerPath.normalize("a/../../b"), "b")
        XCTAssertEqual(ContainerPath.normalize("a/./b"), "a/b")
        // sanitize はデコードしない(% を名前に含むファイルを壊さない)
        XCTAssertEqual(ContainerPath.sanitize("OEBPS/100%20.png"), "OEBPS/100%20.png")
        XCTAssertEqual(ContainerPath.sanitize("../x"), "x")
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

    /// cooViewer-oxr.77: defaultFontFamily の改行/制御文字は CSS 文字列トークンを終端させ後続を
    /// 新規規則として注入できるため、除去されること(値は UserDefaults 由来だが
    /// コメントの「注入されないように」を真にする)
    func testDefaultFontFamilyStripsNewlinesToPreventCSSInjection() throws {
        func defaultFontCSS(for settings: EPUBReaderSettings) throws -> String {
            let metrics = EPUBScreenMetrics(
                viewportSize: CGSize(width: 400, height: 400), settings: settings)
            let data = try XCTUnwrap(
                metrics.censusOptionsJSON.data(using: .utf8))
            let options = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(options["defaultFontCSS"] as? String)
        }

        var settings = EPUBReaderSettings()
        settings.fontScale = 1.0
        settings.defaultFontFamily = "Foo\n} body{display:none}"
        let css = try defaultFontCSS(for: settings)
        // 改行を除去すると内容は 1 行の font-family 文字列トークン内に閉じ込められ、
        // 規則注入は成立しない(残る "}" 等は文字列内では不活性)。危険なのは生の
        // 改行が文字列トークンを終端させることなので、それが消えていることを検証する
        XCTAssertFalse(css.contains("\n} body{display:none}"),
                       "改行で文字列トークンが終端し規則が注入されないこと")
        XCTAssertTrue(css.contains("font-family: \"Foo} body{display:none}\""),
                      "内容は 1 行の引用文字列内に収まる(改行除去済み)")
        XCTAssertFalse(settings.composedUserCSS(isDark: false).contains("font-family"),
                       "既定フォントは書籍 CSS より後ろへ重複注入しない")
        // U+2028/2029 も除去される
        settings.defaultFontFamily = "Bar\u{2028}x"
        let css2 = try defaultFontCSS(for: settings)
        XCTAssertFalse(css2.unicodeScalars.contains("\u{2028}"))
    }
}
