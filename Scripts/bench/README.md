# Scripts/bench — XADMaster 書庫ベンチマーク基盤

2026-08-27 の性能監査(XADMaster/MODERNIZATION.md 変更 51–56)で使った計測一式。
性能に触る変更をしたら、ここで**必ず実測してから**採否を判断する
(フラグや実装の優劣を推測で決めない — このバッチの教訓)。

## 前提ツール

- Xcode(`DEVELOPER_DIR` 既定 `/Applications/Xcode.app`)
- `brew install sevenzip`(7zz)
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
