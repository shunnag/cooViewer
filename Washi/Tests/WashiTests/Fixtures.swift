import Compression
import Foundation
@testable import Washi
@testable import WashiCore

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }
    mutating func appendLE32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }
    mutating func appendLE64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }
}

/// テスト用の最小 ZIP ライタ(store / deflate、zip64 強制モード付き)。
/// Washi 本体はリーダーしか持たないため、テスト側で正しい ZIP を手組みする
enum ZipBuilder {
    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var dst = Data(count: data.count + 4096)
        let capacity = dst.count
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
                compression_encode_buffer(
                    d.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return dst.prefix(written)
    }

    /// method: 0=store / 8=deflate
    static func build(_ entries: [(name: String, data: Data)],
                      method: UInt16 = 0, forceZip64: Bool = false) -> Data {
        var out = Data()
        var cd = Data()
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let payload = method == 8 ? deflate(data) : data
            let crc = CRC32.checksum(data)
            let offset = UInt32(out.count)
            out.appendLE32(0x0403_4B50)
            out.appendLE16(20)              // version needed
            out.appendLE16(0x0800)          // flags: UTF-8
            out.appendLE16(method)
            out.appendLE16(0)               // time
            out.appendLE16(0)               // date
            out.appendLE32(crc)
            out.appendLE32(UInt32(payload.count))
            out.appendLE32(UInt32(data.count))
            out.appendLE16(UInt16(nameBytes.count))
            out.appendLE16(0)               // extra len
            out.append(nameBytes)
            out.append(payload)

            cd.appendLE32(0x0201_4B50)
            cd.appendLE16(20)               // version made by
            cd.appendLE16(20)               // version needed
            cd.appendLE16(0x0800)
            cd.appendLE16(method)
            cd.appendLE16(0)
            cd.appendLE16(0)
            cd.appendLE32(crc)
            if forceZip64 {
                cd.appendLE32(0xFFFF_FFFF)
                cd.appendLE32(0xFFFF_FFFF)
            } else {
                cd.appendLE32(UInt32(payload.count))
                cd.appendLE32(UInt32(data.count))
            }
            cd.appendLE16(UInt16(nameBytes.count))
            var extra = Data()
            if forceZip64 {
                extra.appendLE16(0x0001)
                extra.appendLE16(24)
                extra.appendLE64(UInt64(data.count))     // uncompressed
                extra.appendLE64(UInt64(payload.count))  // compressed
                extra.appendLE64(UInt64(offset))
            }
            cd.appendLE16(UInt16(extra.count))
            cd.appendLE16(0)                // comment len
            cd.appendLE16(0)                // disk start
            cd.appendLE16(0)                // internal attrs
            cd.appendLE32(0)                // external attrs
            cd.appendLE32(forceZip64 ? 0xFFFF_FFFF : offset)
            cd.append(nameBytes)
            cd.append(extra)
        }
        let cdOffset = out.count
        out.append(cd)
        if forceZip64 {
            let zip64Offset = out.count
            out.appendLE32(0x0606_4B50)
            out.appendLE64(44)              // record size (残り 44 バイト)
            out.appendLE16(45)
            out.appendLE16(45)
            out.appendLE32(0)
            out.appendLE32(0)
            out.appendLE64(UInt64(entries.count))
            out.appendLE64(UInt64(entries.count))
            out.appendLE64(UInt64(cd.count))
            out.appendLE64(UInt64(cdOffset))
            out.appendLE32(0x0706_4B50)
            out.appendLE32(0)
            out.appendLE64(UInt64(zip64Offset))
            out.appendLE32(1)
            out.appendLE32(0x0605_4B50)
            out.appendLE16(0)
            out.appendLE16(0)
            out.appendLE16(0xFFFF)
            out.appendLE16(0xFFFF)
            out.appendLE32(0xFFFF_FFFF)
            out.appendLE32(0xFFFF_FFFF)
            out.appendLE16(0)
        } else {
            out.appendLE32(0x0605_4B50)
            out.appendLE16(0)
            out.appendLE16(0)
            out.appendLE16(UInt16(entries.count))
            out.appendLE16(UInt16(entries.count))
            out.appendLE32(UInt32(cd.count))
            out.appendLE32(UInt32(cdOffset))
            out.appendLE16(0)
        }
        return out
    }
}

/// EPUB フィクスチャ(縦組み小説・FXL 漫画)の構成ファイル生成
enum EPUBFixtures {
    static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    /// 縦組み小説(電書協ガイド風): rtl・vertical-rl・ルビ入り
    static let verticalNovelOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="ja">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
            <dc:title id="title">吾輩は猫である</dc:title>
            <meta refines="#title" property="title-type">main</meta>
            <meta refines="#title" property="file-as">わがはいはねこである</meta>
            <dc:creator id="creator">夏目漱石</dc:creator>
            <meta refines="#creator" property="role" scheme="marc:relators">aut</meta>
            <meta refines="#creator" property="file-as">なつめそうせき</meta>
            <dc:language>ja</dc:language>
            <dc:publisher>青空文庫</dc:publisher>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
            <meta property="belongs-to-collection" id="series">漱石全集</meta>
            <meta refines="#series" property="collection-type">series</meta>
            <meta refines="#series" property="group-position">1</meta>
            <meta property="schema:accessMode">textual</meta>
            <meta property="schema:accessMode">visual</meta>
            <meta property="schema:accessModeSufficient">textual,visual</meta>
            <meta property="schema:accessibilityFeature">structuralNavigation</meta>
            <meta property="schema:accessibilityHazard">noFlashingHazard</meta>
            <meta property="schema:accessibilitySummary">目次による構造ナビゲーションに対応。</meta>
            <meta property="dcterms:conformsTo">http://www.idpf.org/epub/a11y/accessibility-20170105.html#wcag-aa</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="style" href="style.css" media-type="text/css"/>
            <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="colophon" href="text/colophon.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine page-progression-direction="rtl" toc="ncx">
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
            <itemref idref="colophon" linear="no"/>
          </spine>
        </package>
        """

    static let navXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
        <head><title>目次</title></head>
        <body>
          <nav epub:type="toc">
            <h1>目次</h1>
            <ol>
              <li><a href="text/ch1.xhtml">第一章</a>
                <ol><li><a href="text/ch1.xhtml#sec1">一の一</a></li></ol>
              </li>
              <li><a href="text/ch2.xhtml">第二章</a></li>
            </ol>
          </nav>
          <nav epub:type="landmarks" hidden="">
            <ol>
              <li><a epub:type="bodymatter" href="text/ch1.xhtml">本文</a></li>
            </ol>
          </nav>
        </body>
        </html>
        """

    static let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="urn:uuid:12345678-1234-1234-1234-123456789abc"/></head>
          <docTitle><text>吾輩は猫である</text></docTitle>
          <navMap>
            <navPoint id="p1" playOrder="1">
              <navLabel><text>第一章</text></navLabel>
              <content src="text/ch1.xhtml"/>
              <navPoint id="p1-1" playOrder="2">
                <navLabel><text>一の一</text></navLabel>
                <content src="text/ch1.xhtml#sec1"/>
              </navPoint>
            </navPoint>
            <navPoint id="p2" playOrder="3">
              <navLabel><text>第二章</text></navLabel>
              <content src="text/ch2.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """

    static func chapterXHTML(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">
        <head><title>\(title)</title>
        <link rel="stylesheet" type="text/css" href="../style.css"/></head>
        <body class="vrtl">\(body)</body>
        </html>
        """
    }

    static let verticalCSS = """
        @charset "UTF-8";
        html { writing-mode: vertical-rl; -epub-writing-mode: vertical-rl; }
        body { font-family: "Hiragino Mincho ProN", serif; }
        """

    /// 1x1 PNG(最小の正当な PNG)
    static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg==")!

    /// 縦組み小説 EPUB 一式(パス → データ)
    static func verticalNovelEntries() -> [(name: String, data: Data)] {
        [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(verticalNovelOPF.utf8)),
            ("OEBPS/nav.xhtml", Data(navXHTML.utf8)),
            ("OEBPS/toc.ncx", Data(ncx.utf8)),
            ("OEBPS/style.css", Data(verticalCSS.utf8)),
            ("OEBPS/images/cover.png", tinyPNG),
            ("OEBPS/text/ch1.xhtml", Data(chapterXHTML(
                title: "第一章",
                body: """
                <h1>第一章</h1><p id="sec1"><ruby>吾輩<rt>わがはい</rt></ruby>は\
                <ruby>猫<rt>ねこ</rt></ruby>である。名前はまだ無い。</p>
                """).utf8)),
            ("OEBPS/text/ch2.xhtml", Data(chapterXHTML(
                title: "第二章", body: "<h1>第二章</h1><p>どこで生れたかとんと見当がつかぬ。</p>").utf8)),
            ("OEBPS/text/colophon.xhtml", Data(chapterXHTML(
                title: "奥付", body: "<p>奥付</p>").utf8)),
        ]
    }

    /// FXL 漫画(pre-paginated・rtl・page-spread 指定・単一画像ページ)
    static let fxlComicOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"
                 prefix="rend: http://www.idpf.org/vocab/rendition/#">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:87654321-4321-4321-4321-cba987654321</dc:identifier>
            <dc:title>テスト漫画 第1巻</dc:title>
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-02-02T00:00:00Z</meta>
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rend:spread">landscape</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="p1" href="p001.xhtml" media-type="application/xhtml+xml"/>
            <item id="p2" href="p002.xhtml" media-type="application/xhtml+xml"/>
            <item id="p3" href="p003.xhtml" media-type="application/xhtml+xml"/>
            <item id="i1" href="images/p001.png" media-type="image/png" properties="cover-image"/>
            <item id="i2" href="images/p002.png" media-type="image/png"/>
            <item id="i3" href="images/p003.png" media-type="image/png"/>
          </manifest>
          <spine page-progression-direction="rtl">
            <itemref idref="p1" properties="rendition:page-spread-center"/>
            <itemref idref="p2" properties="rendition:page-spread-left"/>
            <itemref idref="p3" properties="page-spread-right"/>
          </spine>
        </package>
        """

    static func fxlPageXHTML(image: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>page</title>
        <meta name="viewport" content="width=1200, height=1920"/></head>
        <body><div><img src="images/\(image)" alt=""/></div></body>
        </html>
        """
    }

    static let fxlNavXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Navigation</title></head>
        <body><nav epub:type="toc"><ol><li><a href="p001.xhtml">表紙</a></li></ol></nav></body>
        </html>
        """

    static func fxlComicEntries() -> [(name: String, data: Data)] {
        [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(fxlComicOPF.utf8)),
            ("OEBPS/nav.xhtml", Data(fxlNavXHTML.utf8)),
            ("OEBPS/p001.xhtml", Data(fxlPageXHTML(image: "p001.png").utf8)),
            ("OEBPS/p002.xhtml", Data(fxlPageXHTML(image: "p002.png").utf8)),
            ("OEBPS/p003.xhtml", Data(fxlPageXHTML(image: "p003.png").utf8)),
            ("OEBPS/images/p001.png", tinyPNG),
            ("OEBPS/images/p002.png", tinyPNG),
            ("OEBPS/images/p003.png", tinyPNG),
        ]
    }
}

/// extractText と WebKit DOM の対応を検証する spine 項目。
struct EPUBTextMappingFixture {
    let name: String
    let body: String
    let searchQuery: String
    var css = "html { writing-mode: horizontal-tb; }"
    var usesXHTMLDoctype = false
}

extension EPUBFixtures {
    /// appendPlainText / collapsingWhitespace の境界条件を個別に識別できる
    /// 忠実性フィクスチャ。各 query は少なくとも 1 個の可視 DOM Range を持つ
    static let textMappingFixtures: [EPUBTextMappingFixture] = [
        EPUBTextMappingFixture(
            name: "U+3000 字下げ",
            body: "<p>　字下げ検索　本文</p>",
            searchQuery: "字下げ検索"),
        EPUBTextMappingFixture(
            name: "整形空白ノード",
            body: "<p>整形前検索</p>\n<p>整形後検索</p>",
            searchQuery: "検索"),
        EPUBTextMappingFixture(
            // NSXML は要素間の半角スペースだけのノードを落とす → 両側とも "xy"
            name: "インライン間空白",
            body: "<p><span>xy検索</span> <span>語</span></p>",
            searchQuery: "xy検索語"),
        EPUBTextMappingFixture(
            // U+3000 は XML 空白ではないためノードが残り、両側とも空行 1 本になる
            name: "全角空白ノード",
            body: "<p>全角前</p>\u{3000}<p>全角後検索</p>",
            searchQuery: "全角後検索"),
        EPUBTextMappingFixture(
            // &#13; は NSXML でも U+000D として残る。段落末の CR の直後に要素境界の改行
            name: "CR 実体+段落末",
            body: "<p>x&#13;</p><p>y検索</p>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            name: "CR 実体+br",
            body: "<div>x&#13;<br/>y検索</div>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            // CR LF が 1 書記素になるケース(Character の split/hasSuffix の罠)
            name: "CRLF 実体",
            body: "<p>x&#13;&#10;</p><p>y検索</p>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            name: "CDATA 内 CRLF",
            body: "<p><![CDATA[x\r\n]]></p><p>y検索</p>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            // NSXML は空白 Text と隣接 CDATA を結合して残す → 両側とも "x y検索"
            name: "CDATA 隣接空白",
            body: "<p><b>x</b> <![CDATA[y検索]]></p>",
            searchQuery: "y検索"),
        EPUBTextMappingFixture(
            // 抽出本文には含まれるがレイアウト箱が無い → locateAndShow は null
            name: "非表示テキスト",
            body: "<p>可視</p><p style=\"display:none\">非表示検索</p>",
            searchQuery: "非表示検索"),
        EPUBTextMappingFixture(
            name: "br",
            body: "<p>改行前<br/>改行後検索</p>",
            searchQuery: "改行後検索"),
        EPUBTextMappingFixture(
            name: "ruby",
            body: "<p><ruby>葛<rp>（</rp><rt>かつ</rt><rp>）</rp></ruby>ルビ検索</p>",
            searchQuery: "ルビ検索"),
        EPUBTextMappingFixture(
            name: "入れ子インライン",
            body: "<p><span>入れ子<em>強調<a href=\"#nested\">リンク検索</a></em></span></p>",
            searchQuery: "強調リンク検索"),
        EPUBTextMappingFixture(
            name: "空行連続",
            body: "<p>空行前</p>\n\n\n<p>空行後検索</p>",
            searchQuery: "空行後検索"),
        EPUBTextMappingFixture(
            name: "IVS",
            body: "<p>異体字葛󠄀検索と通常字葛</p>",
            searchQuery: "葛󠄀検索"),
        EPUBTextMappingFixture(
            name: "CDATA",
            body: "<p><![CDATA[CDATA検索<&>]]></p>",
            searchQuery: "CDATA検索"),
        EPUBTextMappingFixture(
            name: "名前付き実体",
            body: "<p>実体&nbsp;検索&hellip;終端</p>",
            searchQuery: "検索…終端",
            usesXHTMLDoctype: true),
        EPUBTextMappingFixture(
            name: "pre",
            body: "<pre>  pre検索\n    二行目  </pre>",
            searchQuery: "pre検索"),
        EPUBTextMappingFixture(
            name: "table/td",
            body: "<table><tr><td>表セル</td><td>検索セル</td></tr></table>",
            searchQuery: "表セル検索セル"),
        EPUBTextMappingFixture(
            name: "縦書き",
            body: "<p>\(String(repeating: "縦書き本文。", count: 350))縦書き検索\(String(repeating: "後続本文。", count: 350))</p>",
            searchQuery: "縦書き検索",
            css: "html { writing-mode: vertical-rl; }"),
    ]

    static func textMappingEntries() -> [(name: String, data: Data)] {
        let manifest = textMappingFixtures.indices.map { index in
            "<item id=\"text\(index)\" href=\"text/f\(index).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let spine = textMappingFixtures.indices.map { index in
            "<itemref idref=\"text\(index)\"/>"
        }.joined()
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:text-map-fixtures</dc:identifier>
                <dc:title>Text map fixtures</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-02T00:00:00Z</meta>
              </metadata>
              <manifest>\(manifest)</manifest>
              <spine>\(spine)</spine>
            </package>
            """
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
        ]
        for (index, fixture) in textMappingFixtures.enumerated() {
            let doctype = fixture.usesXHTMLDoctype
                ? "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"
                : ""
            let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                + doctype
                + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"ja\">"
                + "<head><title>\(fixture.name)</title><style>\(fixture.css)</style></head>"
                + "<body>\(fixture.body)</body></html>"
            entries.append(("OEBPS/text/f\(index).xhtml", Data(xhtml.utf8)))
        }
        return entries
    }
}
