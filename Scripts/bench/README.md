# Scripts/bench — 書庫コーパスと計測

書庫エンジンに依存しない入力生成・計測ツールを置く。
削除したオラクル・旧エンジンのベンチ群の移設先は
[cooViewer-bench](https://github.com/shunnag/cooViewer-bench)。
git 履歴 **8b726c1** の `Scripts/bench/` にも残している。
削除・維持の判定は [PR 2 検証記録](../../Documentation/verification/2026-09-15-xadmaster-framework-removal.md)を参照。

## 残したツール

| ファイル | 用途・依存 |
|---|---|
| `make-archives.sh` | 画像から CBZ / ZIP / 7z / LHA / RAR のコーパスを生成。zip、7zz、sips、Swift。LHa / rar は任意 |
| `makecorpus.swift` | 決定論的な漫画風 JPEG / PNG と小型 JPEG の生成。Foundation / CoreGraphics / ImageIO |
| `makesjiszip.py` | cp932 名・UTF-8 フラグなしの ZIP を生成し、全ローカルヘッダ・中央ディレクトリの名前とフラグを検証。Python 標準ライブラリ |
| `makemutants.py` | シード書庫ごとに切詰め 12 件・ビット反転 20 件を決定論的に生成。Python 標準ライブラリ |
| `microbench.c` | CRC-32(テーブル / ARM 命令 / zlib)と inflate(zlib / libcompression / libdeflate)の独立比較 |
| `lzma2walk.c` | 単一フォルダ・単一 LZMA2 コーダの 7z のチャンクヘッダと辞書リセット位置を調査。標準 C のみ、復号はしない |
| `coldopen.sh` | ディスクイメージの detach/attach 後、指定コマンドを cold / warm の順で実行。hdiutil / time |
| `purge-cold.sh` | `sudo -n purge` 後に指定コマンドを一度実行。sudo / purge / time |

## コーパス生成

Xcode と `7zz`(Homebrew の sevenzip)が必要。LHA を作る場合は書庫作成対応の
LHa(`LHA=/path/to/lha`)、RAR4 は rar 6.x が必要(rar 7.x には `-ma4` がない)。
Lhasa は展開専用なので LHA 生成には使わない。任意ツールがなければ該当形式をスキップする。

```zsh
export BENCH_WORK=/tmp/cooviewer-bench
Scripts/bench/make-archives.sh
python3 Scripts/bench/makemutants.py "$BENCH_WORK/corpus/archives/book-deflate.cbz" "$BENCH_WORK/mutants"
```

既定の作業領域は `/tmp/cooviewer-bench`、全コーパスは約 3 GB。
生成済みの画像・書庫はスキップする。LHA は JPEG 200 ページと TIFF 100 ページを
それぞれ lh5 / lh6 / lh7 で固める。`lha v` / `lha t` で形式・内容と CRC を確認できる。

`sjis2000.zip` は cp932 名・UTF-8 フラグなしの文字コード判定用資産。
2026-08-31 以前の生成物は UTF-8 フラグ付きの文字化け名だったため、測定値を
新版と直接比較しない。`make-archives.sh` は旧フラグを検出すると作り直す。
単独生成は `python3 Scripts/bench/makesjiszip.py <画像ディレクトリ> <出力.zip>`。

## 独立マイクロベンチ・ヘッダ調査

`microbench.c` のみ libdeflate が必要(Homebrew の libdeflate)。Apple Silicon 向け:

```zsh
mkdir -p "$BENCH_WORK/bin"
clang -O2 -march=armv8-a+crc Scripts/bench/microbench.c -o "$BENCH_WORK/bin/microbench" \
  -lz -lcompression -I/opt/homebrew/opt/libdeflate/include \
  /opt/homebrew/opt/libdeflate/lib/libdeflate.a
"$BENCH_WORK/bin/microbench" "$BENCH_WORK/corpus/jpeg64.bin" "$BENCH_WORK/corpus/tiff64.bin"
clang -O2 Scripts/bench/lzma2walk.c -o "$BENCH_WORK/bin/lzma2walk"
"$BENCH_WORK/bin/lzma2walk" "$BENCH_WORK/corpus/archives/book-solid.7z"
```

CRC / inflate は実データで測る。乱数だけでは deflate が stored ブロックになり
コピー速度を測ってしまう。`lzma2walk` は packed ストリームがオフセット `0x20` に
ある前提の調査用で、汎用の 7z 検証器ではない。

## cold / warm 計測

ラッパーには**計測したいコマンドと引数**を渡す。特定のベンチの配置や JSON 出力には
依存しない。stdout は対象コマンドの出力、stderr は `time -p` の経過時間などを含む。
対象コマンドの失敗はその終了コードで中断する。

```zsh
# 事前に書庫入りのディスクイメージを用意する。再マウント先は /Volumes/BenchCold。
Scripts/bench/coldopen.sh "$BENCH_WORK/cold.sparseimage" \
  /path/to/kaito list --raw /Volumes/BenchCold/book-deflate.cbz

# 事前にターミナルで sudo 認証を済ませる。対象コマンドは通常ユーザーで動く。
Scripts/bench/purge-cold.sh /path/to/kaito list --raw "$BENCH_WORK/corpus/archives/book-deflate.cbz"
```

`coldopen.sh` は専用ボリューム `BenchCold` を detach/attach する。APFS の先読みが
入るため、物理 read の差が出るとは限らない。物理 read バイトなどが必要なら、対象
コマンド側で記録する。`purge-cold.sh` の認証がない場合は待たずに失敗する。
比較は同じ入力・同じ条件で時間的に隣接した交互実行にし、他の重負荷と並走させない。
時間だけでなく、展開内容の SHA-256 も別途照合する。

## CooViewerTests/Fixtures の出自

`nonsolid/solid/blocks.7z` は PNG(4×6)+8 KB 乱数パディングを 4 ページ固めたもの。
同等の PNG+パディングを用意して
`7zz a -t7z -m0=lzma2 -ms=off|on|20k fixture.7z *.png` で再生成する。
`book.lzh` は PNG 4 ページを LHa `-o5` で固めた lh5 fixture。
固定ゴールデンの扱いは開発ガイド §3.6 を参照する。
