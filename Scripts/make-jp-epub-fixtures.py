#!/usr/bin/env python3
"""Washi の解析・表示検証に使う日本語 EPUB 合成フィクスチャ生成器。

使い方:
  python3 Scripts/make-jp-epub-fixtures.py <outdir> [--big]

第三者パッケージは不要で、Python 標準ライブラリだけを使用する。

生成物(<outdir> 配下):
  jp-vertical-novel.epub   EPUB 3.3 縦書き小説(電書連風構成、ルビ/縦中横/圏点/注釈 noteref/page-list/landmarks/linear=no)
  jp-sjis-epub2.epub       EPUB 2.0.1 Shift_JIS(OPF/NCX/XHTML すべて Shift_JIS、名前付き実体、NCX のみ)
  jp-manga-fxl.epub        固定レイアウト漫画 40p(SVG ラッパー/img 混在、page-spread、spread=landscape、rtl)
  jp-mixed.epub            FXL 表紙+リフロー本文+見開き画像ページ(itemref properties で切替)
  jp-cp932-names.epub      ZIP エントリ名が CP932(UTF-8 フラグ無し)、href は生の日本語と %-encoded の混在
  jp-utf8-names.epub       上記と同じ日本語名を UTF-8 フラグ付き ZIP エントリで格納
  jp-mimetype-bad.epub     mimetype が先頭でなく deflate 圧縮、container.xml が複数 rootfile
  jp-mimetype-newline.epub mimetype の末尾に改行
  jp-data-descriptor.epub  ZIP の data descriptor(bit3)、local header のサイズ 0
  jp-bom-crlf-dtd.epub     XHTML に BOM+CRLF+外部 DTD DOCTYPE+名前付き実体、CSS に @import
  jp-webtoon.epub          縦スクロール漫画(rendition:flow=scrolled-continuous)
  jp-nested-toc.epub       深い目次(5 段)+目次 href に fragment、NCX と nav の両方(内容が食い違う)
  jp-nfd-names.epub        ZIP エントリ名が NFD、OPF/nav の href が NFC
  jp-big-manga.epub        --big 指定時のみ。100p × 600x900 の性能プローブ(約 54 MB)
"""
import io, os, struct, sys, zlib, zipfile, random

OUT = ""
random.seed(20260903)

# ---------------------------------------------------------------- PNG writer
FONT = {  # 3x5 ビットマップ数字
    '0': ["111","101","101","101","111"], '1': ["010","110","010","010","111"],
    '2': ["111","001","111","100","111"], '3': ["111","001","111","001","111"],
    '4': ["101","101","111","001","001"], '5': ["111","100","111","001","111"],
    '6': ["111","100","111","101","111"], '7': ["111","001","001","001","001"],
    '8': ["111","101","111","101","111"], '9': ["111","101","111","001","111"],
    'L': ["100","100","100","100","111"], 'R': ["110","101","110","101","101"],
}

def png(width, height, rgb, label="", noise=False, level=6):
    """単色背景に大きな数字ラベルを描いた PNG(RGB 8bit)。noise=True で非圧縮に近い乱数画素。"""
    rows = []
    bg = bytes(rgb)
    scale = max(4, min(width, height) // 12)
    tw = len(label) * 4 * scale
    x0 = (width - tw) // 2
    y0 = (height - 5 * scale) // 2
    pix = bytearray(bg * width)
    for y in range(height):
        if noise:
            row = bytes(random.getrandbits(8) for _ in range(width * 3))
        else:
            row = bytearray(pix)
            gy = (y - y0) // scale
            if 0 <= gy < 5:
                for i, ch in enumerate(label):
                    g = FONT.get(ch)
                    if not g: continue
                    for gx in range(3):
                        if g[gy][gx] == '1':
                            xs = x0 + (i * 4 + gx) * scale
                            for x in range(max(0, xs), min(width, xs + scale)):
                                row[x*3:x*3+3] = b"\x10\x10\x10"
            row = bytes(row)
        rows.append(b"\x00" + row)
    raw = b"".join(rows)
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, level)) + chunk(b"IEND", b""))

# ---------------------------------------------------------------- 日本語本文
SENTENCES = [
    "吾輩は猫である。名前はまだ無い。", "どこで生れたかとんと見当がつかぬ。",
    "何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。",
    "吾輩はここで始めて人間というものを見た。", "しかもあとで聞くとそれは書生という人間中で一番獰悪な種族であったそうだ。",
    "この書生というのは時々我々を捕えて煮て食うという話である。",
    "しかしその当時は何という考もなかったから別段恐しいとも思わなかった。",
    "ただ彼の掌に載せられてスーと持ち上げられた時何だかフワフワした感じがあったばかりである。",
    "掌の上で少し落ちついて書生の顔を見たのがいわゆる人間というものの見始であろう。",
    "この時妙なものだと思った感じが今でも残っている。", "第一毛をもって装飾されべきはずの顔がつるつるしてまるで薬缶だ。",
    "その後猫にもだいぶ逢ったがこんな片輪には一度も出会わした事がない。",
    "のみならず顔の真中があまりに突起している。", "そうしてその穴の中から時々ぷうぷうと煙を吹く。",
    "どうも咽せぽくて実に弱った。", "これが人間の飲む煙草というものである事はようやくこの頃知った。",
]
RUBY = [("吾輩", "わがはい"), ("獰悪", "どうあく"), ("薬缶", "やかん"), ("片輪", "かたわ"), ("煙草", "たばこ"), ("咽", "む")]

def jp_paragraph(n_sent, with_marks=True, pnum=0):
    parts = []
    for i in range(n_sent):
        s = random.choice(SENTENCES)
        if with_marks:
            for base, rt in RUBY:
                if base in s and random.random() < 0.5:
                    s = s.replace(base, f"<ruby>{base}<rt>{rt}</rt></ruby>", 1)
                    break
            if random.random() < 0.15:
                s += f"それは<span class=\"tcy\">{random.randint(10,99)}</span>年前の話だ。"
            if random.random() < 0.1:
                s = s.replace("記憶", "<span class=\"em-sesame\">記憶</span>")
            if random.random() < 0.08:
                s += f"<a epub:type=\"noteref\" href=\"#note{pnum}\" class=\"noteref\">※{pnum}</a>"
        parts.append(s)
    return "".join(parts)

def xhtml(title, body, lang="ja", vertical=True, extra_head="", epub_ns=True, css="../style/book-style.css"):
    ns = ' xmlns:epub="http://www.idpf.org/2007/ops"' if epub_ns else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"{ns} xml:lang="{lang}" lang="{lang}" class="{'vrtl' if vertical else 'hltr'}">
<head>
<meta charset="UTF-8"/>
<title>{title}</title>
<link rel="stylesheet" type="text/css" href="{css}"/>
{extra_head}
</head>
<body class="p-text">
{body}
</body>
</html>
"""

EBPAJ_CSS = """@charset "UTF-8";
/* 電書協風 */
html { -epub-writing-mode: vertical-rl; -webkit-writing-mode: vertical-rl; writing-mode: vertical-rl; }
html.hltr { -epub-writing-mode: horizontal-tb; -webkit-writing-mode: horizontal-tb; writing-mode: horizontal-tb; }
body { margin: 0; padding: 0; font-family: serif-ja, "ヒラギノ明朝 ProN", serif; line-height: 1.75; text-align: justify; }
p { margin: 0; text-indent: 1em; }
h1, h2 { font-family: sans-serif-ja, sans-serif; font-weight: bold; margin: 0 0 1em 0; }
.tcy { -epub-text-combine: horizontal; -webkit-text-combine: horizontal; text-combine-upright: all; }
.em-sesame { -epub-text-emphasis-style: sesame; -webkit-text-emphasis-style: sesame; text-emphasis-style: sesame; }
ruby rt { font-size: 0.5em; }
.noteref { font-size: 0.7em; vertical-align: super; }
aside.footnote { font-size: 0.8em; border: 1px solid #999; padding: 0.5em; margin: 1em 0; }
.gaiji { height: 1em; }
img.fit { width: 100%; height: 100%; object-fit: contain; }
"""

def container_xml(rootfiles):
    rf = "".join(f'<rootfile full-path="{p}" media-type="application/oebps-package+xml"/>' for p in rootfiles)
    return f'<?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>{rf}</rootfiles></container>'

def write_epub(name, entries, mimetype_first=True, compress_mimetype=False, data_descriptor=False):
    """entries: list of (name, bytes[, flags]) 。name は str か bytes(生バイト名)。"""
    path = os.path.join(OUT, name)
    buf = io.BytesIO()
    zf = zipfile.ZipFile(buf, "w")
    order = list(entries)
    if mimetype_first:
        order.sort(key=lambda e: 0 if e[0] == "mimetype" else 1)
    else:
        order.sort(key=lambda e: 1 if e[0] == "mimetype" else 0)
    for e in order:
        n, data = e[0], e[1]
        zi = zipfile.ZipInfo(n if isinstance(n, str) else n.decode("cp437"), date_time=(2026, 9, 3, 0, 0, 0))
        if n == "mimetype" and not compress_mimetype:
            zi.compress_type = zipfile.ZIP_STORED
        else:
            zi.compress_type = zipfile.ZIP_DEFLATED
        if isinstance(n, bytes):
            zi.flag_bits &= ~0x800  # cp437 で往復させて UTF-8 フラグを立てない
        if data_descriptor and n != "mimetype":
            zi.flag_bits |= 0x08
        zf.writestr(zi, data)
    zf.close()
    raw = buf.getvalue()
    if data_descriptor:
        raw = add_data_descriptors(raw)
    with open(path, "wb") as f:
        f.write(raw)
    print(f"{name}: {len(raw)/1e6:.1f} MB, {len(entries)} entries")

def write_epub_raw(name, entries):
    """zipfile を使わない素の ZIP ライタ(store のみ)。bytes 名はそのまま書き UTF-8 フラグを立てない。
    Python の zipfile は非 ASCII 名を必ず UTF-8+bit11 にするため、CP932 名の再現にはこれが要る。"""
    path = os.path.join(OUT, name)
    out = io.BytesIO(); cd = io.BytesIO()
    for n, data in entries:
        nb = n if isinstance(n, bytes) else n.encode("utf-8")
        flags = 0 if isinstance(n, bytes) else (0x800 if any(b > 127 for b in nb) else 0)
        crc = zlib.crc32(data) & 0xffffffff
        off = out.tell()
        out.write(b"PK\x03\x04" + struct.pack("<HHHHHIIIHH", 20, flags, 0, 0, 0x5923, crc, len(data), len(data), len(nb), 0) + nb + data)
        cd.write(b"PK\x01\x02" + struct.pack("<HHHHHHIIIHHHHHII", 20, 20, flags, 0, 0, 0x5923, crc, len(data), len(data), len(nb), 0, 0, 0, 0, 0, off) + nb)
    cd_off = out.tell(); cdb = cd.getvalue(); out.write(cdb)
    out.write(b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, len(entries), len(entries), len(cdb), cd_off, 0))
    with open(path, "wb") as f: f.write(out.getvalue())
    print(f"{name}: {out.tell()/1e6:.1f} MB, {len(entries)} entries (raw)")

def add_data_descriptors(raw):
    """zipfile は bit3 を立てても local header にサイズを書くので、bit3 付きエントリの local header の
    crc/サイズを 0 にし、データ末尾に data descriptor を挿入して central directory のオフセットを付け直す。"""
    out = io.BytesIO()
    pos = 0
    entries = []
    # central directory を読む
    eocd = raw.rfind(b"PK\x05\x06")
    cd_size, cd_off = struct.unpack("<II", raw[eocd+12:eocd+20])
    cd = raw[cd_off:cd_off+cd_size]
    # local entries を順に処理
    p = 0
    offsets = {}
    while p < cd_off:
        sig = raw[p:p+4]
        if sig != b"PK\x03\x04": break
        flags, method = struct.unpack("<HH", raw[p+6:p+10])
        crc, csize, usize = struct.unpack("<III", raw[p+14:p+26])
        nlen, xlen = struct.unpack("<HH", raw[p+26:p+30])
        name = raw[p+30:p+30+nlen]
        header_end = p + 30 + nlen + xlen
        data = raw[header_end:header_end+csize]
        new_off = out.tell()
        offsets[name] = new_off
        if flags & 0x08:
            hdr = raw[p:p+14] + struct.pack("<III", 0, 0, 0) + raw[p+26:header_end]
            out.write(hdr); out.write(data)
            out.write(b"PK\x07\x08" + struct.pack("<III", crc, csize, usize))
        else:
            out.write(raw[p:header_end+csize])
        p = header_end + csize
    new_cd_off = out.tell()
    q = 0
    while q < len(cd):
        nlen, xlen, clen = struct.unpack("<HHH", cd[q+28:q+34])
        name = cd[q+46:q+46+nlen]
        rec = bytearray(cd[q:q+46+nlen+xlen+clen])
        rec[42:46] = struct.pack("<I", offsets[name])
        out.write(bytes(rec))
        q += 46 + nlen + xlen + clen
    new_cd = out.tell() - new_cd_off
    e = bytearray(raw[eocd:eocd+22])
    e[12:16] = struct.pack("<I", new_cd)
    e[16:20] = struct.pack("<I", new_cd_off)
    out.write(bytes(e))
    return out.getvalue()

# ---------------------------------------------------------------- 1. 縦書き小説
def gen_vertical_novel():
    chapters = 12
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["item/standard.opf"]).encode()),
               ("META-INF/com.apple.ibooks.display-options.xml",
                b'<?xml version="1.0" encoding="UTF-8"?><display_options><platform name="*"><option name="specified-fonts">true</option></platform></display_options>'),
               ("item/style/book-style.css", EBPAJ_CSS.encode())]
    manifest, spine, toc, pagelist = [], [], [], []
    cover = png(1200, 1800, (230, 220, 200), "0")
    entries.append(("item/image/cover.jpg.png", cover))
    manifest.append('<item id="cover-image" href="image/cover.jpg.png" media-type="image/png" properties="cover-image"/>')
    entries.append(("item/xhtml/p-cover.xhtml", xhtml("表紙", '<div class="cover"><img class="fit" src="../image/cover.jpg.png" alt="表紙"/></div>', vertical=False).encode()))
    manifest.append('<item id="p-cover" href="xhtml/p-cover.xhtml" media-type="application/xhtml+xml"/>')
    spine.append('<itemref idref="p-cover" linear="yes" properties="rendition:page-spread-center"/>')
    # 扉
    entries.append(("item/xhtml/p-titlepage.xhtml", xhtml("扉", "<h1>吾輩は猫である</h1><p>夏目漱石</p>").encode()))
    manifest.append('<item id="p-titlepage" href="xhtml/p-titlepage.xhtml" media-type="application/xhtml+xml"/>')
    spine.append('<itemref idref="p-titlepage"/>')
    toc.append(('扉', 'xhtml/p-titlepage.xhtml', []))
    page_no = 1
    for c in range(1, chapters + 1):
        paras = []
        notes = []
        for i in range(random.randint(25, 45)):
            pn = c * 100 + i
            paras.append(f"<p>{jp_paragraph(random.randint(2, 5), pnum=pn)}</p>")
            if f"note{pn}" in paras[-1]:
                notes.append(f'<aside epub:type="footnote" id="note{pn}" class="footnote"><p>※{pn} これは注釈本文である。<span class="tcy">{pn % 100}</span>番。</p></aside>')
            if i % 8 == 0:
                paras.append(f'<span epub:type="pagebreak" id="page{page_no}" title="{page_no}"/>')
                pagelist.append((page_no, f"xhtml/p-{c:03d}.xhtml#page{page_no}"))
                page_no += 1
        sec = f'<h2 id="ch{c}">第{c}章 ある日の出来事</h2>' + "".join(paras) + f'<h3 id="ch{c}-2">第{c}章 その二</h3>' + "".join(f"<p>{jp_paragraph(3, pnum=c*1000+k)}</p>" for k in range(15)) + "".join(notes)
        entries.append((f"item/xhtml/p-{c:03d}.xhtml", xhtml(f"第{c}章", sec).encode()))
        manifest.append(f'<item id="p-{c:03d}" href="xhtml/p-{c:03d}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="p-{c:03d}"/>')
        toc.append((f"第{c}章 ある日の出来事", f"xhtml/p-{c:03d}.xhtml#ch{c}", [(f"第{c}章 その二", f"xhtml/p-{c:03d}.xhtml#ch{c}-2", [])]))
    # 挿絵(画像単独ページ、横向き)
    entries.append(("item/image/i-001.png", png(1600, 1000, (200, 230, 240), "1")))
    manifest.append('<item id="i-001" href="image/i-001.png" media-type="image/png"/>')
    entries.append(("item/xhtml/p-illust.xhtml", xhtml("挿絵", '<div class="illust"><img class="fit" src="../image/i-001.png" alt="挿絵"/></div>', vertical=False).encode()))
    manifest.append('<item id="p-illust" href="xhtml/p-illust.xhtml" media-type="application/xhtml+xml"/>')
    spine.insert(5, '<itemref idref="p-illust"/>')
    # 奥付(linear=no)
    entries.append(("item/xhtml/p-colophon.xhtml", xhtml("奥付", "<h2>奥付</h2><p>合成フィクスチャ 2026-09-03 発行</p>").encode()))
    manifest.append('<item id="p-colophon" href="xhtml/p-colophon.xhtml" media-type="application/xhtml+xml"/>')
    spine.append('<itemref idref="p-colophon" linear="no"/>')
    toc.append(("奥付", "xhtml/p-colophon.xhtml", []))
    # nav
    def ol(items):
        return "<ol>" + "".join(f'<li><a href="{h}">{t}</a>{ol(ch) if ch else ""}</li>' for t, h, ch in items) + "</ol>"
    nav = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" lang="ja">
<head><meta charset="UTF-8"/><title>目次</title></head>
<body>
<nav epub:type="toc" id="toc"><h1>目次</h1>{ol(toc)}</nav>
<nav epub:type="page-list" hidden="hidden"><ol>{"".join(f'<li><a href="{h}">{n}</a></li>' for n, h in pagelist)}</ol></nav>
<nav epub:type="landmarks" hidden="hidden"><ol>
<li><a epub:type="cover" href="xhtml/p-cover.xhtml">表紙</a></li>
<li><a epub:type="toc" href="navigation-documents.xhtml">目次</a></li>
<li><a epub:type="bodymatter" href="xhtml/p-001.xhtml">本文</a></li>
</ol></nav>
</body></html>"""
    entries.append(("item/navigation-documents.xhtml", nav.encode()))
    manifest.append('<item id="toc" href="navigation-documents.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" xml:lang="ja" unique-identifier="unique-id" prefix="ebpaj: http://www.ebpaj.jp/ rendition: http://www.idpf.org/vocab/rendition/#">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title id="title">吾輩は猫である(合成)</dc:title>
<meta refines="#title" property="file-as">わがはいはねこである</meta>
<dc:creator id="creator01">夏目漱石</dc:creator>
<meta refines="#creator01" property="role" scheme="marc:relators">aut</meta>
<meta refines="#creator01" property="file-as">なつめそうせき</meta>
<dc:publisher>合成出版</dc:publisher>
<dc:language>ja</dc:language>
<dc:identifier id="unique-id">urn:uuid:8f3c0f2e-0000-4000-8000-20260903000001</dc:identifier>
<meta property="dcterms:modified">2026-09-03T00:00:00Z</meta>
<meta property="belongs-to-collection" id="series">猫シリーズ</meta>
<meta refines="#series" property="collection-type">series</meta>
<meta refines="#series" property="group-position">1</meta>
<meta property="ebpaj:guide-version">1.1.3</meta>
<meta name="primary-writing-mode" content="vertical-rl"/>
<meta property="schema:accessMode">textual</meta>
<meta property="schema:accessMode">visual</meta>
<meta property="schema:accessibilityFeature">tableOfContents</meta>
<meta property="schema:accessibilitySummary">合成テスト用のアクセシビリティ要約。</meta>
<meta property="rendition:layout">reflowable</meta>
<meta property="rendition:spread">auto</meta>
</metadata>
<manifest>
{chr(10).join(manifest)}
</manifest>
<spine page-progression-direction="rtl">
{chr(10).join(spine)}
</spine>
</package>"""
    entries.append(("item/standard.opf", opf.encode()))
    write_epub("jp-vertical-novel.epub", entries)
    # 展開ディレクトリ版も出す(フォルダコンテナ検証用)
    d = os.path.join(OUT, "jp-vertical-novel")
    for n, data in entries:
        p = os.path.join(d, n)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f: f.write(data)
    return entries

# ---------------------------------------------------------------- 2. Shift_JIS EPUB 2
def gen_sjis_epub2():
    def sj(s): return s.encode("shift_jis", errors="replace")
    chapters = 5
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["OEBPS/content.opf"]).encode())]
    entries.append(("OEBPS/style.css", sj("body { writing-mode: vertical-rl; -webkit-writing-mode: vertical-rl; font-family: serif; }")))
    entries.append(("OEBPS/cover.png", png(600, 900, (240, 200, 200), "0")))
    manifest = ['<item id="css" href="style.css" media-type="text/css"/>',
                '<item id="cover" href="cover.png" media-type="image/png"/>',
                '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>']
    spine, navpoints = [], []
    for c in range(1, chapters + 1):
        body = f"<h2>第{c}章&nbsp;昔の本</h2>" + "".join(f"<p>{jp_paragraph(4, with_marks=False)}&hellip;&copy;</p>" for _ in range(30))
        doc = f"""<?xml version="1.0" encoding="Shift_JIS"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">
<head><meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"/><title>第{c}章</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body>{body}</body></html>"""
        entries.append((f"OEBPS/ch{c}.html", sj(doc)))
        manifest.append(f'<item id="ch{c}" href="ch{c}.html" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="ch{c}"/>')
        navpoints.append(f'<navPoint id="np{c}" playOrder="{c}"><navLabel><text>第{c}章 昔の本</text></navLabel><content src="ch{c}.html"/></navPoint>')
    ncx = f"""<?xml version="1.0" encoding="Shift_JIS"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="sjis-book-001"/></head>
<docTitle><text>昔の本(Shift_JIS)</text></docTitle>
<navMap>{"".join(navpoints)}</navMap></ncx>"""
    entries.append(("OEBPS/toc.ncx", sj(ncx)))
    opf = f"""<?xml version="1.0" encoding="Shift_JIS"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>昔の本(Shift_JIS)</dc:title>
<dc:creator opf:role="aut" opf:file-as="むかし たろう">昔 太郎</dc:creator>
<dc:language>ja</dc:language>
<dc:identifier id="BookId">sjis-book-001</dc:identifier>
<meta name="cover" content="cover"/>
</metadata>
<manifest>{"".join(manifest)}</manifest>
<spine toc="ncx" page-progression-direction="rtl">{"".join(spine)}</spine>
<guide><reference type="cover" title="表紙" href="ch1.html"/></guide>
</package>"""
    entries.append(("OEBPS/content.opf", sj(opf)))
    write_epub("jp-sjis-epub2.epub", entries)

# ---------------------------------------------------------------- 3. 漫画 FXL
def fxl_page(i, w, h, use_svg, spread_prop=""):
    img = f"../image/p{i:03d}.png"
    if use_svg:
        body = f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" width="100%" height="100%" viewBox="0 0 {w} {h}"><image width="{w}" height="{h}" xlink:href="{img}"/></svg>'
    else:
        body = f'<div class="main"><img src="{img}" alt="p{i}"/></div>'
    head = f'<meta name="viewport" content="width={w}, height={h}"/>'
    return xhtml(f"p{i}", body, vertical=False, extra_head=head, css="../style/fixed-layout.css")

def gen_manga_fxl():
    W, H, N = 1200, 1600, 40
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["item/standard.opf"]).encode()),
               ("item/style/fixed-layout.css", b"html,body{margin:0;padding:0;width:100%;height:100%} .main{width:100%;height:100%} img{width:100%;height:100%}")]
    manifest, spine = [], []
    for i in range(N):
        color = (random.randint(150, 255), random.randint(150, 255), random.randint(150, 255))
        entries.append((f"item/image/p{i:03d}.png", png(W, H, color, str(i))))
        manifest.append(f'<item id="img{i}" href="image/p{i:03d}.png" media-type="image/png"{" properties=\"cover-image\"" if i == 0 else ""}/>')
        entries.append((f"item/xhtml/p{i:03d}.xhtml", fxl_page(i, W, H, use_svg=(i % 2 == 1)).encode()))
        manifest.append(f'<item id="p{i}" href="xhtml/p{i:03d}.xhtml" media-type="application/xhtml+xml"{" properties=\"svg\"" if i % 2 == 1 else ""}/>')
        prop = "rendition:page-spread-center" if i == 0 else ("page-spread-right" if i % 2 == 1 else "page-spread-left")
        spine.append(f'<itemref idref="p{i}" properties="{prop}"/>')
    nav = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body>
<nav epub:type="toc"><ol><li><a href="xhtml/p000.xhtml">表紙</a></li><li><a href="xhtml/p002.xhtml">第1話</a></li><li><a href="xhtml/p020.xhtml">第2話</a></li></ol></nav></body></html>"""
    entries.append(("item/navigation-documents.xhtml", nav.encode()))
    manifest.append('<item id="toc" href="navigation-documents.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" xml:lang="ja" unique-identifier="uid" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>合成漫画 第1巻</dc:title><dc:creator>合成 作画</dc:creator><dc:language>ja</dc:language>
<dc:identifier id="uid">urn:uuid:8f3c0f2e-0000-4000-8000-20260903000003</dc:identifier>
<meta property="dcterms:modified">2026-09-03T00:00:00Z</meta>
<meta property="rendition:layout">pre-paginated</meta>
<meta property="rendition:spread">landscape</meta>
<meta property="rendition:orientation">auto</meta>
<meta name="cover" content="img0"/>
</metadata>
<manifest>{chr(10).join(manifest)}</manifest>
<spine page-progression-direction="rtl">{chr(10).join(spine)}</spine>
</package>"""
    entries.append(("item/standard.opf", opf.encode()))
    write_epub("jp-manga-fxl.epub", entries)

# ---------------------------------------------------------------- 4. 混在本
def gen_mixed():
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["OEBPS/package.opf"]).encode()),
               ("OEBPS/style/book-style.css", EBPAJ_CSS.encode()),
               ("OEBPS/style/fixed-layout.css", b"html,body{margin:0;width:100%;height:100%} img{width:100%;height:100%}")]
    entries.append(("OEBPS/image/cover.png", png(1200, 1600, (220, 230, 210), "0")))
    entries.append(("OEBPS/image/spreadL.png", png(1200, 1600, (210, 210, 240), "L")))
    entries.append(("OEBPS/image/spreadR.png", png(1200, 1600, (240, 210, 210), "R")))
    entries.append(("OEBPS/xhtml/cover.xhtml", fxl_page(0, 1200, 1600, False).replace("../image/p000.png", "../image/cover.png").encode()))
    entries.append(("OEBPS/xhtml/spreadL.xhtml", fxl_page(0, 1200, 1600, True).replace("../image/p000.png", "../image/spreadL.png").encode()))
    entries.append(("OEBPS/xhtml/spreadR.xhtml", fxl_page(0, 1200, 1600, True).replace("../image/p000.png", "../image/spreadR.png").encode()))
    manifest = ['<item id="css" href="style/book-style.css" media-type="text/css"/>',
                '<item id="fcss" href="style/fixed-layout.css" media-type="text/css"/>',
                '<item id="cover-img" href="image/cover.png" media-type="image/png" properties="cover-image"/>',
                '<item id="sL" href="image/spreadL.png" media-type="image/png"/>',
                '<item id="sR" href="image/spreadR.png" media-type="image/png"/>',
                '<item id="cover" href="xhtml/cover.xhtml" media-type="application/xhtml+xml"/>',
                '<item id="spreadL" href="xhtml/spreadL.xhtml" media-type="application/xhtml+xml" properties="svg"/>',
                '<item id="spreadR" href="xhtml/spreadR.xhtml" media-type="application/xhtml+xml" properties="svg"/>']
    spine = ['<itemref idref="cover" properties="rendition:layout-pre-paginated rendition:page-spread-center"/>']
    for c in range(1, 5):
        body = f"<h2 id=\"c{c}\">第{c}章</h2>" + "".join(f"<p>{jp_paragraph(4, pnum=c*10+k)}</p>" for k in range(40))
        entries.append((f"OEBPS/xhtml/ch{c}.xhtml", xhtml(f"第{c}章", body).encode()))
        manifest.append(f'<item id="ch{c}" href="xhtml/ch{c}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="ch{c}"/>')
        if c == 2:
            spine.append('<itemref idref="spreadR" properties="rendition:layout-pre-paginated rendition:page-spread-right"/>')
            spine.append('<itemref idref="spreadL" properties="rendition:layout-pre-paginated rendition:page-spread-left"/>')
    nav = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body>
<nav epub:type="toc"><ol><li><a href="xhtml/cover.xhtml">表紙</a></li><li><a href="xhtml/ch1.xhtml#c1">第1章</a></li><li><a href="xhtml/ch2.xhtml#c2">第2章</a></li><li><a href="xhtml/spreadR.xhtml">見開き図</a></li><li><a href="xhtml/ch3.xhtml#c3">第3章</a></li><li><a href="xhtml/ch4.xhtml#c4">第4章</a></li></ol></nav></body></html>"""
    entries.append(("OEBPS/nav.xhtml", nav.encode()))
    manifest.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" xml:lang="ja" unique-identifier="uid" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>混在本(FXL 表紙+リフロー)</dc:title><dc:language>ja</dc:language>
<dc:identifier id="uid">urn:uuid:8f3c0f2e-0000-4000-8000-20260903000004</dc:identifier>
<meta property="dcterms:modified">2026-09-03T00:00:00Z</meta>
<meta property="rendition:layout">reflowable</meta>
</metadata>
<manifest>{chr(10).join(manifest)}</manifest>
<spine page-progression-direction="rtl">{chr(10).join(spine)}</spine>
</package>"""
    entries.append(("OEBPS/package.opf", opf.encode()))
    write_epub("jp-mixed.epub", entries)

# ---------------------------------------------------------------- 5. CP932 エントリ名
def gen_cp932_names():
    def cp(s): return s.encode("cp932")
    body1 = "<h2>第一章</h2>" + "".join(f"<p>{jp_paragraph(3)}</p>" for _ in range(20))
    body2 = "<h2>第二章</h2>" + "".join(f"<p>{jp_paragraph(3)}</p>" for _ in range(20))
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["本/標準.opf"]).encode()),
               (cp("本/本文/第一章.xhtml"), xhtml("第一章", body1, css="../スタイル/本.css").encode()),
               (cp("本/本文/第二章.xhtml"), xhtml("第二章", body2, css="../スタイル/本.css").encode()),
               (cp("本/スタイル/本.css"), EBPAJ_CSS.encode()),
               (cp("本/画像/表紙 画像.png"), png(600, 900, (200, 240, 200), "0"))]
    nav = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目次</title></head><body>
<nav epub:type="toc"><ol><li><a href="本文/第一章.xhtml">第一章</a></li><li><a href="%E6%9C%AC%E6%96%87/%E7%AC%AC%E4%BA%8C%E7%AB%A0.xhtml">第二章</a></li></ol></nav></body></html>"""
    entries.append((cp("本/目次.xhtml"), nav.encode()))
    opf = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>CP932 エントリ名の本</dc:title><dc:language>ja</dc:language>
<dc:identifier id="uid">cp932-001</dc:identifier><meta property="dcterms:modified">2026-09-03T00:00:00Z</meta>
</metadata>
<manifest>
<item id="nav" href="目次.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="c1" href="本文/第一章.xhtml" media-type="application/xhtml+xml"/>
<item id="c2" href="%E6%9C%AC%E6%96%87/%E7%AC%AC%E4%BA%8C%E7%AB%A0.xhtml" media-type="application/xhtml+xml"/>
<item id="css" href="スタイル/本.css" media-type="text/css"/>
<item id="cov" href="画像/表紙%20画像.png" media-type="image/png" properties="cover-image"/>
</manifest>
<spine page-progression-direction="rtl"><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>"""
    entries.append((cp("本/標準.opf"), opf.encode()))
    write_epub_raw("jp-cp932-names.epub", entries)
    # UTF-8 フラグ付き(正常)版も比較用に
    entries_u = [(n.decode("cp932") if isinstance(n, bytes) else n, d) for n, d in entries]
    write_epub("jp-utf8-names.epub", entries_u)

# ---------------------------------------------------------------- 6. mimetype 違反・複数 rootfile
def gen_mimetype_bad(novel_entries):
    ents = [e for e in novel_entries]
    ents = [(n, d) for n, d in ents if n != "META-INF/container.xml"]
    ents.append(("META-INF/container.xml", container_xml(["item/standard.opf", "item/alt.opf"]).encode()))
    ents.append(("mimetype-extra", b"x"))
    write_epub("jp-mimetype-bad.epub", ents, mimetype_first=False, compress_mimetype=True)
    ents2 = [(n, (d if n != "mimetype" else b"application/epub+zip\n")) for n, d in novel_entries]
    write_epub("jp-mimetype-newline.epub", ents2)

# ---------------------------------------------------------------- 7. data descriptor
def gen_data_descriptor(novel_entries):
    write_epub("jp-data-descriptor.epub", novel_entries, data_descriptor=True)

# ---------------------------------------------------------------- 8. BOM + CRLF + 外部 DTD + 実体
def gen_bom_crlf_dtd():
    body = "<h2>第一章&nbsp;&hellip;</h2>" + "".join(f"<p>{jp_paragraph(3)}&mdash;&copy;&#x3042;</p>" for _ in range(30))
    doc = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
<head><title>BOM CRLF</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body class="vrtl">{body}</body></html>"""
    doc = "﻿" + doc.replace("\n", "\r\n")
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["OEBPS/content.opf"]).encode()),
               ("OEBPS/style.css", b"@import url('base.css');\n@import \"vertical.css\";\nbody{font-family:serif-ja}"),
               ("OEBPS/base.css", b"p{text-indent:1em}"),
               ("OEBPS/vertical.css", b"body{writing-mode:vertical-rl;-webkit-writing-mode:vertical-rl}"),
               ("OEBPS/ch1.xhtml", doc.encode("utf-8"))]
    nav = "﻿" + """<?xml version="1.0" encoding="UTF-8"?>\r\n<!DOCTYPE html>\r\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">第一章</a></li></ol></nav></body></html>"""
    entries.append(("OEBPS/nav.xhtml", nav.encode("utf-8")))
    opf = "﻿" + """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>BOM&amp;CRLF&amp;DTD の本</dc:title><dc:language>ja</dc:language><dc:identifier id="uid">bom-001</dc:identifier><meta property="dcterms:modified">2026-09-03T00:00:00Z</meta></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/><item id="css" href="style.css" media-type="text/css"/><item id="b" href="base.css" media-type="text/css"/><item id="v" href="vertical.css" media-type="text/css"/></manifest>
<spine page-progression-direction="rtl"><itemref idref="c1"/></spine></package>""".replace("\n", "\r\n")
    entries.append(("OEBPS/content.opf", opf.encode("utf-8")))
    write_epub("jp-bom-crlf-dtd.epub", entries)

# ---------------------------------------------------------------- 9. 大容量漫画(性能)
def gen_big_manga():
    W, H, N = 600, 900, 100
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["item/standard.opf"]).encode())]
    manifest, spine = [], []
    for i in range(N):
        entries.append((f"item/image/p{i:03d}.png", png(W, H, (128, 128, 128), str(i), noise=True, level=0)))
        manifest.append(f'<item id="img{i}" href="image/p{i:03d}.png" media-type="image/png"/>')
        entries.append((f"item/xhtml/p{i:03d}.xhtml", fxl_page(i, W, H, use_svg=True).encode()))
        manifest.append(f'<item id="p{i}" href="xhtml/p{i:03d}.xhtml" media-type="application/xhtml+xml" properties="svg"/>')
        spine.append(f'<itemref idref="p{i}"/>')
    nav = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body><nav epub:type="toc"><ol><li><a href="xhtml/p000.xhtml">表紙</a></li></ol></nav></body></html>"""
    entries.append(("item/navigation-documents.xhtml", nav.encode()))
    manifest.append('<item id="toc" href="navigation-documents.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>大容量漫画</dc:title><dc:language>ja</dc:language><dc:identifier id="uid">big-001</dc:identifier><meta property="dcterms:modified">2026-09-03T00:00:00Z</meta><meta property="rendition:layout">pre-paginated</meta></metadata>
<manifest>{chr(10).join(manifest)}</manifest><spine page-progression-direction="rtl">{chr(10).join(spine)}</spine></package>"""
    entries.append(("item/standard.opf", opf.encode()))
    write_epub("jp-big-manga.epub", entries)

# ---------------------------------------------------------------- 10. webtoon(縦スクロール)
def gen_webtoon():
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["OEBPS/package.opf"]).encode())]
    imgs = "".join(f'<img src="image/s{i:02d}.png" alt="s{i}"/>' for i in range(8))
    for i in range(8):
        entries.append((f"OEBPS/image/s{i:02d}.png", png(800, 1200, (240, 240, 200), str(i))))
    body = f'<div class="strip">{imgs}</div>'
    entries.append(("OEBPS/ep1.xhtml", xhtml("第1話", body, vertical=False, css="style.css").encode()))
    entries.append(("OEBPS/style.css", b".strip img{display:block;width:100%}"))
    nav = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body><nav epub:type="toc"><ol><li><a href="ep1.xhtml">第1話</a></li></ol></nav></body></html>"""
    entries.append(("OEBPS/nav.xhtml", nav.encode()))
    opf = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>縦スクロール漫画</dc:title><dc:language>ja</dc:language><dc:identifier id="uid">webtoon-001</dc:identifier><meta property="dcterms:modified">2026-09-03T00:00:00Z</meta>
<meta property="rendition:layout">reflowable</meta><meta property="rendition:flow">scrolled-continuous</meta><meta property="rendition:spread">none</meta></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ep1" href="ep1.xhtml" media-type="application/xhtml+xml"/><item id="css" href="style.css" media-type="text/css"/>""" + "".join(f'<item id="s{i}" href="image/s{i:02d}.png" media-type="image/png"/>' for i in range(8)) + """</manifest>
<spine><itemref idref="ep1"/></spine></package>"""
    entries.append(("OEBPS/package.opf", opf.encode()))
    write_epub("jp-webtoon.epub", entries)

# ---------------------------------------------------------------- 11. 深い目次 + ncx/nav 食い違い
def gen_nested_toc():
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["OEBPS/package.opf"]).encode()),
               ("OEBPS/style.css", EBPAJ_CSS.encode())]
    manifest = ['<item id="css" href="style.css" media-type="text/css"/>', '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>']
    spine = []
    secs = []
    for p in range(1, 4):
        body = f'<h1 id="p{p}">第{p}部</h1>'
        for c in range(1, 4):
            body += f'<h2 id="p{p}c{c}">第{c}章</h2>'
            for s in range(1, 3):
                body += f'<h3 id="p{p}c{c}s{s}">第{s}節</h3>'
                for t in range(1, 3):
                    body += f'<h4 id="p{p}c{c}s{s}t{t}">項{t}</h4>' + "".join(f"<p>{jp_paragraph(3)}</p>" for _ in range(6))
                    body += f'<h5 id="p{p}c{c}s{s}t{t}u">小項</h5><p>{jp_paragraph(2)}</p>'
        entries.append((f"OEBPS/part{p}.xhtml", xhtml(f"第{p}部", body, css="style.css").encode()))
        manifest.append(f'<item id="part{p}" href="part{p}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="part{p}"/>')
    def li(p, c=None, s=None, t=None):
        pass
    nav_ol = "<ol>"
    for p in range(1, 4):
        nav_ol += f'<li><a href="part{p}.xhtml#p{p}">第{p}部</a><ol>'
        for c in range(1, 4):
            nav_ol += f'<li><a href="part{p}.xhtml#p{p}c{c}">第{c}章</a><ol>'
            for s in range(1, 3):
                nav_ol += f'<li><a href="part{p}.xhtml#p{p}c{c}s{s}">第{s}節</a><ol>'
                for t in range(1, 3):
                    nav_ol += f'<li><a href="part{p}.xhtml#p{p}c{c}s{s}t{t}">項{t}</a><ol><li><a href="part{p}.xhtml#p{p}c{c}s{s}t{t}u">小項</a></li></ol></li>'
                nav_ol += "</ol></li>"
            nav_ol += "</ol></li>"
        nav_ol += "</ol></li>"
    nav_ol += "</ol>"
    nav = f"""<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body><nav epub:type="toc"><h1>目次</h1>{nav_ol}</nav></body></html>"""
    entries.append(("OEBPS/nav.xhtml", nav.encode()))
    manifest.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    ncx = """<?xml version="1.0" encoding="UTF-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="nested-001"/></head><docTitle><text>深い目次(NCX は古い)</text></docTitle>
<navMap><navPoint id="n1" playOrder="1"><navLabel><text>旧・第1部</text></navLabel><content src="part1.xhtml"/></navPoint><navPoint id="n2" playOrder="2"><navLabel><text>旧・第2部</text></navLabel><content src="part2.xhtml"/></navPoint></navMap></ncx>"""
    entries.append(("OEBPS/toc.ncx", ncx.encode()))
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>深い目次の本</dc:title><dc:language>ja</dc:language><dc:identifier id="uid">nested-001</dc:identifier><meta property="dcterms:modified">2026-09-03T00:00:00Z</meta></metadata>
<manifest>{chr(10).join(manifest)}</manifest><spine toc="ncx" page-progression-direction="rtl">{chr(10).join(spine)}</spine></package>"""
    entries.append(("OEBPS/package.opf", opf.encode()))
    write_epub("jp-nested-toc.epub", entries)


# ---------------------------------------------------------------- 12. NFD エントリ名(旧 HFS+ 由来)× NFC href
def gen_nfd_names():
    import unicodedata
    nfd = lambda s: unicodedata.normalize("NFD", s)
    body1 = "<h2>第一章</h2>" + "".join(f"<p>{jp_paragraph(3)}</p>" for _ in range(20))
    entries = [("mimetype", b"application/epub+zip"),
               ("META-INF/container.xml", container_xml(["OEBPS/package.opf"]).encode()),
               (nfd("OEBPS/本文/ガイド.xhtml"), xhtml("ガイド", body1, css="../スタイル/ペ.css").encode()),
               (nfd("OEBPS/スタイル/ペ.css"), EBPAJ_CSS.encode()),
               (nfd("OEBPS/画像/ピ.png"), png(600, 900, (200, 220, 240), "0"))]
    nav = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目次</title></head><body><nav epub:type="toc"><ol><li><a href="本文/ガイド.xhtml">ガイド</a></li></ol></nav></body></html>"""
    entries.append(("OEBPS/nav.xhtml", nav.encode()))
    opf = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>NFD エントリ名の本</dc:title><dc:language>ja</dc:language><dc:identifier id="uid">nfd-001</dc:identifier><meta property="dcterms:modified">2026-09-05T00:00:00Z</meta></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="本文/ガイド.xhtml" media-type="application/xhtml+xml"/><item id="css" href="スタイル/ペ.css" media-type="text/css"/><item id="img" href="画像/ピ.png" media-type="image/png" properties="cover-image"/></manifest>
<spine page-progression-direction="rtl"><itemref idref="c1"/></spine></package>"""
    entries.append(("OEBPS/package.opf", opf.encode()))  # OPF/nav の href は NFC
    write_epub_raw("jp-nfd-names.epub", entries)

if __name__ == "__main__":
    arguments = sys.argv[1:]
    if (len(arguments) not in (1, 2)
            or arguments[0] == "--big"
            or (len(arguments) == 2 and arguments[1] != "--big")):
        print("使い方: python3 Scripts/make-jp-epub-fixtures.py <outdir> [--big]",
              file=sys.stderr)
        raise SystemExit(2)
    OUT = os.path.abspath(arguments[0])
    os.makedirs(OUT, exist_ok=True)

    novel = gen_vertical_novel()
    gen_sjis_epub2()
    gen_manga_fxl()
    gen_mixed()
    gen_cp932_names()
    gen_mimetype_bad(novel)
    gen_data_descriptor(novel)
    gen_bom_crlf_dtd()
    gen_webtoon()
    gen_nested_toc()
    gen_nfd_names()
    if len(arguments) == 2:
        gen_big_manga()
    print("done:", OUT)

