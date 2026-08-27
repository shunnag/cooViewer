# cp932(Shift-JIS)エントリ名の zip を作る(UTF-8 フラグなし=レガシー Windows 相当)。
# zipfile は非 ASCII 名を UTF-8+フラグで書くため、cp932 バイト列を cp437 として
# デコードした str を渡すトリックで生バイトを温存する。
import sys, zipfile, os

src, dst = sys.argv[1], sys.argv[2]
files = sorted(os.listdir(src))
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for i, f in enumerate(files):
        vol = i // 200 + 1
        page = i % 200 + 1
        jp = f"第{vol:02d}巻/第{(i//20)%99+1:03d}話 ページ{page:04d} 扉絵つき.jpg"
        raw = jp.encode("cp932").decode("cp437")
        with open(os.path.join(src, f), "rb") as fh:
            z.writestr(zipfile.ZipInfo(raw, (2020, 1, 1, 0, 0, 0)), fh.read())
print("sjis zip done:", dst)
