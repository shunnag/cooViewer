#!/bin/zsh
# ベンチマークコーパス(画像+各形式の書庫)を $BENCH_WORK/corpus に生成する。
# 必要ツール: zip(標準)、7zz(brew install sevenzip)、LHa(任意 — 書庫作成に
# 対応した正統 LHa。無ければ LHA 系はスキップ)、rar(任意 — RAR4 は
# rar 6.x が必要。7.x は -ma4 が削除済み。無ければ RAR 系はスキップ)。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${BENCH_WORK:-/tmp/cooviewer-bench}"
C="$W/corpus"; A="$C/archives"
mkdir -p "$A" "$W/bin"

# Homebrew の lha(Lhasa)は展開専用なので、正統 LHa だけを書庫作成に使う。
LHA_BIN="${LHA:-$(command -v lha 2>/dev/null || true)}"
LHA_CREATE=0
if [[ -x "$LHA_BIN" ]]; then
    LHA_VERSION="$("$LHA_BIN" --version 2>&1 || true)"
    if [[ "$LHA_VERSION" == *"LHa for UNIX"* ]]; then
        LHA_CREATE=1
    else
        echo "警告: $LHA_BIN は書庫作成対応の LHa ではないため LHA 系をスキップ" >&2
    fi
else
    echo "警告: 書庫作成対応の LHa が無いため LHA 系をスキップ" >&2
fi

# 1) 画像生成(決定論的。JPEG 200p / PNG 100p / サムネイル 2000)
if [[ ! -x "$W/bin/makecorpus" ]]; then
    swiftc -O -o "$W/bin/makecorpus" "$HERE/makecorpus.swift"
fi
"$W/bin/makecorpus" "$C"

# 2) 非圧縮性の対照として PNG→無圧縮 TIFF(圧縮が効くデータ)
mkdir -p "$C/pages-tiff"
for f in "$C"/pages-png/*.png; do
    out="$C/pages-tiff/$(basename "${f%.png}").tiff"
    [[ -e "$out" ]] || sips -s format tiff "$f" --out "$out" > /dev/null 2>&1
done

# 3) 書庫作成
cd "$C/pages-jpeg"
[[ -e "$A/book-stored.cbz" ]]  || zip -q -0 -X "$A/book-stored.cbz" *.jpg
[[ -e "$A/book-deflate.cbz" ]] || zip -q -6 -X "$A/book-deflate.cbz" *.jpg
[[ -e "$A/book-solid.7z" ]]    || 7zz a -t7z -m0=lzma2 -mx=5 -ms=on -bso0 -bsp0 "$A/book-solid.7z" '*.jpg'
[[ -e "$A/book-enc.7z" ]]      || 7zz a -ptestpass -t7z -m0=lzma2 -mx=5 -ms=off -bso0 -bsp0 "$A/book-enc.7z" page00*.jpg page01*.jpg
if (( LHA_CREATE )); then
    # 入力名を basename に固定し、絶対パスの出力先へ決定論的な順序で格納する。
    [[ -e "$A/book-lh5.lzh" ]] || "$LHA_BIN" a -q2 -o5 -w="$A" "$A/book-lh5.lzh" *.jpg
    [[ -e "$A/book-lh6.lzh" ]] || "$LHA_BIN" a -q2 -o6 -w="$A" "$A/book-lh6.lzh" *.jpg
    [[ -e "$A/book-lh7.lzh" ]] || "$LHA_BIN" a -q2 -o7 -w="$A" "$A/book-lh7.lzh" *.jpg
fi
if command -v rar > /dev/null; then
    [[ -e "$A/book-rar4.cbr" ]] || rar a -ma4 -m3 -ep -idq "$A/book-rar4.cbr" *.jpg || echo "RAR4 スキップ(rar 6.x が必要)"
    [[ -e "$A/book-rar5.cbr" ]] || rar a -ma5 -m3 -ep -idq "$A/book-rar5.cbr" *.jpg
fi
cd "$C/pages-png"
[[ -e "$A/book-png.cbz" ]] || zip -q -6 -X "$A/book-png.cbz" *.png
cd "$C/pages-tiff"
[[ -e "$A/book-tiff.cbz" ]] || zip -q -6 -X "$A/book-tiff.cbz" *.tiff
[[ -e "$A/book-tiff.7z" ]]  || 7zz a -t7z -m0=lzma2 -mx=5 -ms=on -bso0 -bsp0 "$A/book-tiff.7z" '*.tiff'
if (( LHA_CREATE )); then
    [[ -e "$A/book-tiff-lh5.lzh" ]] || "$LHA_BIN" a -q2 -o5 -w="$A" "$A/book-tiff-lh5.lzh" *.tiff
    [[ -e "$A/book-tiff-lh6.lzh" ]] || "$LHA_BIN" a -q2 -o6 -w="$A" "$A/book-tiff-lh6.lzh" *.tiff
    [[ -e "$A/book-tiff-lh7.lzh" ]] || "$LHA_BIN" a -q2 -o7 -w="$A" "$A/book-tiff-lh7.lzh" *.tiff
fi
if command -v rar > /dev/null; then
    [[ -e "$A/book-tiff-rar4.cbr" ]] || rar a -ma4 -m3 -ep -idq "$A/book-tiff-rar4.cbr" *.tiff || true
    [[ -e "$A/book-tiff-rar5.cbr" ]] || rar a -ma5 -m3 -ep -idq "$A/book-tiff-rar5.cbr" *.tiff
fi
cd "$C/tiny-jpeg"
[[ -e "$A/sjis2000.zip" ]]  || python3 "$HERE/makesjiszip.py" "$C/tiny-jpeg" "$A/sjis2000.zip"
[[ -e "$A/ascii2000.zip" ]] || zip -q -6 -X "$A/ascii2000.zip" *.jpg

# 4) マイクロベンチ用の実データ連結
[[ -e "$C/jpeg64.bin" ]] || cat "$C"/pages-jpeg/page0[0-3]*.jpg > "$C/jpeg64.bin"
[[ -e "$C/tiff64.bin" ]] || cat "$C"/pages-tiff/page00*.tiff "$C"/pages-tiff/page01*.tiff > "$C/tiff64.bin"

ls -lh "$A"
echo "corpus ready: $C"
