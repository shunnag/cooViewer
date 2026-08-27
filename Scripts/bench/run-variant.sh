#!/bin/zsh
# バリアントのベンチマークを直列実行し、$BENCH_WORK/results/all.tsv に追記する。
# 使い方: run-variant.sh <name> [quick]
# 注意: 計測は必ず直列で行い、他のビルド・重負荷と並走させない。
# バリアント間の比較は「時間的に隣接した交互実行ペア」で行うこと
# (時間の離れたスイート間では熱・Spotlight 等で最大 ±10% ドリフトする — 実測)。
set -euo pipefail
W="${BENCH_WORK:-/tmp/cooviewer-bench}"
NAME="$1"
MODE="${2:-full}"
V="$W/variants/$NAME"
A="$W/corpus/archives"
R="$W/results"
mkdir -p "$R"
OUT="$R/all.tsv"
BIN="$V/MacOS"

# ページキャッシュを温める(全バリアント同条件のウォームキャッシュ方針)
cat "$A"/*.cbz "$A"/*.cbr "$A"/*.7z "$A"/*.zip > /dev/null 2>&1

run() { # run <bin> <mode> <archive> <reps> [count]
    local line
    line=$("$BIN/$1" "$2" "$A/$3" "$4" "${5:-}")
    printf '%s\t%s\t%s\n' "$NAME" "$(date +%H:%M:%S)" "$line" >> "$OUT"
}
runsw() { # runsw <archive> <reps>
    local line
    line=$("$BIN/xadbench-swift" "$A/$1" "$2")
    printf '%s\t%s\t%s\n' "$NAME" "$(date +%H:%M:%S)" "$line" >> "$OUT"
}

run xadbench open sjis2000.zip 7
run xadbench open ascii2000.zip 7
run xadbench data-open sjis2000.zip 7
run xadbench extract book-stored.cbz 3
run xadbench extract book-deflate.cbz 3
run xadbench extract book-png.cbz 5
if [[ "$MODE" == "full" ]]; then
    run xadbench extract book-rar4.cbr 3
    run xadbench extract book-rar5.cbr 3
    run xadbench extract book-solid.7z 3
    run xadbench extract book-tiff.cbz 3
    run xadbench extract book-tiff.7z 3
    run xadbench extract book-tiff-rar4.cbr 3
    run xadbench extract book-tiff-rar5.cbr 3
    run xadbench random book-stored.cbz 3 80
    runsw book-stored.cbz 3
    runsw book-png.cbz 5
    # 暗号化 7z(パスワード testpass で作成した book-enc.7z がある場合)
    if [[ -e "$A/book-enc.7z" ]]; then
        XADBENCH_PASSWORD=testpass run xadbench extract book-enc.7z 3
        XADBENCH_PASSWORD=testpass run xadbench random book-enc.7z 3 10
    fi
fi
echo "run $NAME ($MODE) done"
