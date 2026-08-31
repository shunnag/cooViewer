# Scripts/bench — XADMaster 書庫ベンチマーク基盤

2026-08-27 の性能監査(XADMaster/MODERNIZATION.md 変更 51–56)で使った計測一式。
性能に触る変更をしたら、ここで**必ず実測してから**採否を判断する
(フラグや実装の優劣を推測で決めない — このバッチの教訓)。

## 前提ツール

- Xcode(`DEVELOPER_DIR` 既定 `/Applications/Xcode.app`)
- `brew install sevenzip`(7zz)
- LHA コーパスを作る場合のみ書庫作成対応の正統 LHa(`LHA=/path/to/lha` で指定可)
- RAR4/RAR5 コーパスを作る場合のみ rar **6.x**(7.x は `-ma4` 削除済み。
  RARLab の rarmacos-arm-624.tar.gz を展開し quarantine を外して使う)
- microbench の libdeflate 比較のみ `brew install libdeflate`

## 使い方

作業領域は環境変数 `BENCH_WORK`(既定 `/tmp/cooviewer-bench`)。コーパスは
合計 ~3GB 生成される。

```zsh
cd Scripts/bench
export BENCH_WORK=/tmp/cooviewer-bench

# 1) コーパス生成(画像は決定論的。書庫は存在すればスキップ)
./make-archives.sh

# 2) ハーネスをビルド(リンク先ヘッダはリポジトリの Frameworks/ を使う)
clang -O2 -fobjc-arc xadbench.m -o $BENCH_WORK/bin/xadbench \
    -F ../../Frameworks -framework XADMaster -framework Foundation \
    -Wl,-rpath,@executable_path/../Frameworks
swiftc -O xadbench-swift.swift -o $BENCH_WORK/bin/xadbench-swift \
    -F ../../Frameworks -Xlinker -rpath -Xlinker @executable_path/../Frameworks

# 3) バリアントをビルドして計測(結果は $BENCH_WORK/results/all.tsv に追記)
./build-variant.sh baseline GCC_OPTIMIZATION_LEVEL=2 LLVM_LTO=YES_THIN
./run-variant.sh baseline full
#   (XADMaster を変更 → 別名でビルド → 交互に実行して比較)
./build-variant.sh mychange GCC_OPTIMIZATION_LEVEL=2 LLVM_LTO=YES_THIN
./run-variant.sh mychange full
./run-variant.sh baseline full
./run-variant.sh mychange full

# 4) 集計(初回 rep 除外の中央値、baseline 比、SHA-256 相互検証)
python3 summarize.py $BENCH_WORK/results/all.tsv
```

`full` は JPEG/TIFF の lh5・lh6・lh7 も各 3 reps で計測する。LHA や
RAR の任意ツールが無く対応書庫を作れなかった場合、`run-variant.sh` は
欠落したケースをログへ出してスキップし、残りのスイートを続行する。

## 計測の作法(実測で確認済みの罠)

- **比較は時間的に隣接した交互実行ペアで**。時間の離れたスイート間は熱・
  Spotlight 等で最大 ±10% ドリフトする。直後比較のノイズは ±2–5%。
- ハーネスは全バリアントで**同一バイナリ**(`build-variant.sh` が
  `$BENCH_WORK/bin` からコピーする)。`@rpath` なので差し替えだけで効く。
- 正しさは summarize.py の SHA-256 相互検証で担保(全バリアント一致が前提)。
- マイクロベンチは**実データで**(乱数は deflate が stored ブロック化して
  memcpy を測ってしまう)。純関数は呼び出しを前結果に連鎖させないと
  ループ不変で畳まれて偽の GB/s が出る。

## その他のツール

```zsh
# CRC / inflate 実装比較(テーブル vs HW vs Apple zlib、zlib vs libcompression vs libdeflate)
clang -O2 -march=armv8-a+crc microbench.c -o $BENCH_WORK/bin/microbench \
    -lz -lcompression -I/opt/homebrew/opt/libdeflate/include \
    /opt/homebrew/opt/libdeflate/lib/libdeflate.a
$BENCH_WORK/bin/microbench $BENCH_WORK/corpus/jpeg64.bin $BENCH_WORK/corpus/tiff64.bin

# 破損入力バッテリー(ASan+UBSan バリアントに対して回す)
./build-variant.sh asan GCC_OPTIMIZATION_LEVEL=1 LLVM_LTO=NO \
    "OTHER_CFLAGS=-fsanitize=address,undefined -fno-sanitize-recover=undefined" \
    "OTHER_CPLUSPLUSFLAGS=-fsanitize=address,undefined -fno-sanitize-recover=undefined" \
    "OTHER_LDFLAGS=-fsanitize=address,undefined"
python3 makemutants.py <シード書庫...> $BENCH_WORK/mutants
#   → 各ミュータントを xadbench(ASan リンク版)extract で回し、シグナル/サニタイザ報告ゼロを確認
```

## results-2026-08-27/

監査時の生データ。`clean-ab.tsv` = baseline↔final 交互 2 巡+暗号化/open 追試
(レポートの累積表の出典)、`experiments.tsv` = フラグ行列と実験系列。
要約はレポート artifact「XADMaster 性能監査 2026-08」参照。

## pextract(group-aware 並列展開モード)

第 2 ラウンドで追加。`xadbench pextract <archive> <reps> [workers]` は
`solidGroupOfEntry` でエントリをグループ化し、グループ単位でワーカー
(独立 XADArchive)へ配分する(グループ内は前進ストリーミング)。
ダイジェストは extract モードと同一定義なので SHA で相互検証できる。
実測(M4 Max・6 並列): 非 solid 7z 192→37ms(5.2 倍)、64MB ブロック
solid 7z 6.41→1.20s(5.3 倍)。

## CooViewerTests/Fixtures/*.7z の出自

nonsolid/solid/blocks.7z は「PNG(4x6)+8KB 乱数パディング」×4 ページを
7zz で固めたもの(blocks は -ms=20k で 2 ブロック化)。再生成手順:
ページ生成の python スクリプトはレポート artifact のセッション記録参照、
または同等の PNG+パディングを用意して
`7zz a -t7z -m0=lzma2 -ms=off|on|20k fixture.7z *.png`。

## LHA(lh4-7)コーパスと fixture

`make-archives.sh` は JPEG 200 ページから `book-lh5/6/7.lzh`、圧縮が効く
TIFF 100 ページから `book-tiff-lh5/6/7.lzh` を作る。入力ディレクトリへ
移動して basename を決定論的な順序で渡し、`-w` で一時ファイルも
`$BENCH_WORK/corpus/archives` 内に固定する。書庫は他形式と同じく既存なら
スキップする。`LHA` 未指定時は `PATH` 上の `lha` を使う。

Lhasa(brew の lha)は展開専用なので、作成には正統 LHa が要る:
`brew install automake` 後に jca02266/lha をソースから
`autoreconf -i && ./configure && make`(バイナリは src/lha)。
`lha a -o5|o6|o7 out.lzh *.jpg` で lh5/6/7 を作成。
正統 LHa が無い、または `lha` が Lhasa の場合、警告を出して LHA 系だけを
スキップする。生成物は `lha v book-lh5.lzh` 等でメソッドとファイル一覧を、
`lha t book-lh5.lzh` 等で CRC を確認できる。
CooViewerTests/Fixtures/book.lzh は PNG×4 を lha -o5 で固めた lh5 fixture
(FastLZSS 移植のデコード正当性テスト testLZH5ArchiveExtractsCorrectly 用)。

## cold cache 計測

xadbench は open/data-open で rusage の物理 read バイト(diskread)とページイン
(pageins)も JSON に出す。cold の測り方は 2 通り:
- `coldopen.sh <variant> <archive>`: disk image(cold.sparseimage)を
  detach/attach してキャッシュを落とす。ただしスパースイメージ APFS は
  全ファイル readahead するため物理 read の差は出にくい(時間は測れる)。
- `sudo zsh purge-cold.sh`: 内蔵 SSD で `sudo purge` して真の cold を測る
  (認証が要る)。2026-08 の計測では zip open は cold でも全ファイルを
  readahead するため物理 read は不変・時間だけ −16〜18%(変更 63)。

zip の嘘 centralsize テスト書庫は EOCD の centralsize フィールドを過大/過小に
patch して作る(makemutants.py と同様の struct.pack_into)。

## ZIP open のローカルヘッダ省略上限(計測専用)

`zip-open-ceiling.patch` は、ZIP open 時の CD 走査からエントリごとの
ローカルヘッダ seek + read を完全に除いた場合の性能上限(改善幅の上限)を
測るための使い捨てパッチ。CD 側の名前を使い、data offset はローカル extra
長を無視して近似する。

**警告: このパッチ適用中の展開結果は INVALID。製品コードへ絶対に merge
しないこと。** `xadbench open` によるエントリ列挙だけを計測し、`extract` は
実行しない。

```zsh
cd /Users/nagash/cooViewer
export BENCH_WORK=/tmp/cooviewer-bench
export DEVELOPER_DIR=/Applications/Xcode.app

# コーパスが未生成の場合だけ、既存の生成スクリプトを使う
[[ -e "$BENCH_WORK/corpus/archives/ascii2000.zip" ]] || ./Scripts/bench/make-archives.sh

git -C XADMaster apply --check ../Scripts/bench/zip-open-ceiling.patch
git -C XADMaster apply ../Scripts/bench/zip-open-ceiling.patch
./Scripts/bench/build-variant.sh ceiling GCC_OPTIMIZATION_LEVEL=2 LLVM_LTO=YES_THIN
$BENCH_WORK/variants/ceiling/MacOS/xadbench open \
    $BENCH_WORK/corpus/archives/ascii2000.zip 3

# 成否にかかわらず必ず復元する
git -C XADMaster checkout -- .
git -C XADMaster status --short
```
