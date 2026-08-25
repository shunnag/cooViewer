#!/usr/bin/env python3
"""検証用サンプル EPUB の生成(縦組みリフロー小説 + FXL 漫画)"""
import sys, zipfile, os

OUT_DIR = sys.argv[1]
IMG_DIR = sys.argv[2]  # makepages.swift の出力

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

# ---------- 縦組みリフロー小説 ----------

NOVEL_CSS = """@charset "UTF-8";
html { -webkit-writing-mode: vertical-rl; -epub-writing-mode: vertical-rl; writing-mode: vertical-rl; }
body { font-family: "serif-ja", "Hiragino Mincho ProN", serif; line-height: 1.75; text-align: justify; }
h1 { font-size: 1.4em; margin-inline-end: 2em; }
p { margin: 0; text-indent: 1em; }
.tcy { -webkit-text-combine: horizontal; text-combine-upright: all; }
.em-sesame { -webkit-text-emphasis-style: filled sesame; text-emphasis-style: filled sesame; }
"""

CH1_BODY = """<h1>一</h1>
<p><ruby>吾輩<rt>わがはい</rt></ruby>は<ruby>猫<rt>ねこ</rt></ruby>である。名前はまだ無い。</p>
<p>どこで生れたかとんと<ruby>見当<rt>けんとう</rt></ruby>がつかぬ。何でも薄暗いじめじめした所で<span class="em-sesame">ニャーニャー</span>泣いていた事だけは記憶している。吾輩はここで始めて人間というものを見た。しかもあとで聞くとそれは書生という人間中で一番<ruby>獰悪<rt>どうあく</rt></ruby>な種族であったそうだ。</p>
<p>この書生というのは時々我々を<ruby>捕<rt>つかま</rt></ruby>えて煮て食うという話である。しかしその当時は何という考もなかったから別段恐しいとも思わなかった。ただ彼の<ruby>掌<rt>てのひら</rt></ruby>に載せられてスーと持ち上げられた時何だかフワフワした感じがあったばかりである。</p>
<p>明治<span class="tcy">38</span>年のことである。掌の上で少し落ちついて書生の顔を見たのがいわゆる人間というものの見始であろう。この時妙なものだと思った感じが今でも残っている。</p>
""" + "".join(f"<p>これは検証用の段落{i}である。縦組みのページ送りが行の途中で割れないこと、ルビが正しく振られること、右から左へページが進むことを確認する。長い文章を複数ページにわたって流し込むための埋め草として、同じ趣旨の文を繰り返し記す。</p>" for i in range(1, 40))

CH2_BODY = """<h1>二</h1>
<p>吾輩は人間と同居して彼等を観察すればするほど、彼等は<ruby>我儘<rt>わがまま</rt></ruby>なものだと断言せざるを得ないようになった。</p>
""" + "".join(f"<p>第二章の埋め草段落{i}。目次からの移動、章をまたぐページ送り、しおり位置の保存と復元を確認するための本文である。</p>" for i in range(1, 30))

def novel_xhtml(title, body):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" class="vrtl">
<head><meta charset="UTF-8"/><title>{title}</title>
<link rel="stylesheet" type="text/css" href="../style.css"/></head>
<body class="p-text">{body}</body>
</html>"""

NOVEL_OPF = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="ja">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:0f37c0e2-9d0f-4a5c-8000-washi-sample1</dc:identifier>
    <dc:title id="title">吾輩は猫である(検証用抜粋)</dc:title>
    <dc:creator id="creator">夏目漱石</dc:creator>
    <meta refines="#creator" property="role" scheme="marc:relators">aut</meta>
    <dc:language>ja</dc:language>
    <meta property="dcterms:modified">2026-08-19T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="style" href="style.css" media-type="text/css"/>
    <item id="cover-img" href="image/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine page-progression-direction="rtl">
    <itemref idref="cover"/>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
"""

# 電書協テンプレート風の表紙(画像 1 枚・hltr クラス)
NOVEL_COVER = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" class="hltr">
<head><meta charset="UTF-8"/><title>表紙</title>
<link rel="stylesheet" type="text/css" href="../style.css"/></head>
<body epub:type="cover" class="p-cover">
<p><img class="fit" src="../image/cover.png" alt="表紙"/></p>
</body>
</html>"""

NOVEL_NAV = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
<head><meta charset="UTF-8"/><title>目次</title></head>
<body>
<nav epub:type="toc"><h1>目次</h1>
<ol>
  <li><a href="text/ch1.xhtml">一</a></li>
  <li><a href="text/ch2.xhtml">二</a></li>
</ol>
</nav>
</body>
</html>"""

def write_epub(path, entries):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip",
                   compress_type=zipfile.ZIP_STORED)
        for name, data in entries:
            z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)

cover_png = open(os.path.join(IMG_DIR, sorted(
    p for p in os.listdir(IMG_DIR) if p.endswith(".png"))[0]), "rb").read()
write_epub(os.path.join(OUT_DIR, "vertical-novel.epub"), [
    ("META-INF/container.xml", CONTAINER),
    ("OEBPS/package.opf", NOVEL_OPF),
    ("OEBPS/nav.xhtml", NOVEL_NAV),
    ("OEBPS/style.css", NOVEL_CSS),
    ("OEBPS/image/cover.png", cover_png),
    ("OEBPS/text/cover.xhtml", NOVEL_COVER),
    ("OEBPS/text/ch1.xhtml", novel_xhtml("一", CH1_BODY)),
    ("OEBPS/text/ch2.xhtml", novel_xhtml("二", CH2_BODY)),
])

# ---------- FXL 漫画(電書協テンプレート風・SVG ラッパー) ----------

def fxl_page(image):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><meta charset="UTF-8"/><title>page</title>
<meta name="viewport" content="width=848, height=1200"/></head>
<body>
<div class="main">
<svg xmlns="http://www.w3.org/2000/svg" version="1.1"
     xmlns:xlink="http://www.w3.org/1999/xlink"
     width="100%" height="100%" viewBox="0 0 848 1200">
  <image width="848" height="1200" xlink:href="../image/{image}"/>
</svg>
</div>
</body>
</html>"""

pages = sorted(os.listdir(IMG_DIR))
pages = [p for p in pages if p.endswith(".png")]
manifest_items = "\n".join(
    f'    <item id="p{i}" href="xhtml/p{i:03d}.xhtml" media-type="application/xhtml+xml" properties="svg"/>'
    for i in range(1, len(pages) + 1)) + "\n" + "\n".join(
    f'    <item id="i{i}" href="image/{name}" media-type="image/png"{" properties=\"cover-image\"" if i == 1 else ""}/>'
    for i, name in enumerate(pages, 1))
spread = ["rendition:page-spread-center"] + [
    "page-spread-right" if i % 2 == 0 else "page-spread-left"
    for i in range(2, len(pages) + 1)]
spine_items = "\n".join(
    f'    <itemref linear="yes" idref="p{i}" properties="{spread[i-1]}"/>'
    for i in range(1, len(pages) + 1))

FXL_OPF = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:1f37c0e2-9d0f-4a5c-8000-washi-sample2</dc:identifier>
    <dc:title>検証用漫画 第1巻</dc:title>
    <dc:language>ja</dc:language>
    <meta property="dcterms:modified">2026-08-19T00:00:00Z</meta>
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="rendition:spread">landscape</meta>
    <meta property="belongs-to-collection" id="series">検証用漫画</meta>
    <meta refines="#series" property="collection-type">series</meta>
    <meta refines="#series" property="group-position">1</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
{manifest_items}
  </manifest>
  <spine page-progression-direction="rtl">
{spine_items}
  </spine>
</package>
"""

FXL_NAV = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><meta charset="UTF-8"/><title>Navigation</title></head>
<body><nav epub:type="toc"><ol><li><a href="xhtml/p001.xhtml">表紙</a></li></ol></nav></body>
</html>"""

fxl_entries = [
    ("META-INF/container.xml", CONTAINER),
    ("OEBPS/package.opf", FXL_OPF),
    ("OEBPS/nav.xhtml", FXL_NAV),
]
for i, name in enumerate(pages, 1):
    fxl_entries.append((f"OEBPS/xhtml/p{i:03d}.xhtml", fxl_page(name)))
    with open(os.path.join(IMG_DIR, name), "rb") as f:
        fxl_entries.append((f"OEBPS/image/{name}", f.read()))

write_epub(os.path.join(OUT_DIR, "fxl-comic.epub"), fxl_entries)
print("wrote", os.path.join(OUT_DIR, "vertical-novel.epub"), "and fxl-comic.epub")
