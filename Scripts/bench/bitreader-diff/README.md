# CSInputBuffer 64bit レザバー化の差分ハーネス(measured-and-deferred)

2026-08-28 の第 6 ラウンドで、`CSInputBuffer` のビットレザバーを 32bit →
64bit にして fill 頻度を半減+単一ロード化する案を検討した際の**差分検証
ハーネス**。フォークの流儀(LZSS.h の 1.5M ケース差分検証、変更 #10)に
倣い、実装前に「旧(32bit)と新(64bit)を同一バイト列・同一 op 列で並走
させ、返り値・BufferOffset・BitOffset・**未消費レザバー内容**を突き合わせる」
スタンドアロン C ハーネスを先に作った。

## 状態: 延期(harness がゲートとして機能した)

- **動機は実測済み**: LHA lh6 の `sample` プロファイルで `_CSInputFillBits` が
  シンボル復号(`CSInputNextSymbolUsingCode`)の **~25-30%** を占めることを確認。
  fill 半減で LHA/RAR の huffman 復号に意味のある利得(見込み ~8-10%)。
- **harness が新実装の相違を検出**(精密な切り分け結果):
  - **LE: 境界内の実相違 = 真のブロッカー**。`nextlongLE` の 25+7 分割などの
    有効な op 列で、未消費レザバー内容(消費可能ビット)が参照実装と相違する
    (seed 11400714819323198485, step 38, currbyte=45 で在境界)。根因は
    非整列 numbits での fill placement(`startoffset=numbits>>3`, `<< numbits`)が
    旧(32bit・fill 少)と新(64bit・fill 多)で読むバイトの置き場所を変える点。
  - **BE: 境界内の相違は検出されず**。BE-only で観測されたシフト UB /
    heap-overflow は**ハーネスが EOF を越えて読む driver アーティファクト**で、
    OLD 参照(`old_peekbits`/`old_fillbits`)も同一箇所で同じ OOB を起こす
    (実コードの `_CSInputPeekByteWithoutEOF` も境界チェック無し=デコーダが
    宣言長で先に止まる前提)。BE の 64bit 化自体は健全に見えるが、EOF で止まる
    driver に直さないと完全グリーンは示せない(下記「既知の driver 制約」)。
- **判断**: 全デコーダ共有インフラにサイレント破壊のリスクを持ち込まないため、
  差分ハーネスが**完全グリーンになるまで出荷しない**。延期の根拠は LE の境界内
  相違に一本化される(BE は driver 完成待ち)。この harness が「将来の 64bit
  実装が必ず通すべきゲート」として残る(bd cooViewer-7ni)。

## 使い方

```
clang -O2 -fsanitize=address,undefined -fno-sanitize-recover=undefined bitdiff.c -o bitdiff
./bitdiff [nseeds=200000] [nops=400]
# OK ... no divergence → 新実装は旧と byte-identical(採用可)
# DIVERGE / RESERVOIR-DIVERGE ... → 相違点を出力(seed/step/kind/nb で再現)
```

`OldBuf`/`old_*` は現行 `CSInputBuffer.[hm]` の 32bit 実装をそのまま移植した
参照。`NewBuf`/`new_*` が 64bit 候補実装。次に 64bit 化を試すときは `new_*` を
正しく直し、このハーネスが `OK ... no divergence` を出すことを**先に**確認して
から、フォークの `CSInputBuffer.[hm]` を触ること。op 列は NextBit/NextBitString
(1..25)/LongBitString(26..32)/Peek+Skip/SkipBits/SkipToByteBoundary/
SkipTo16BitBoundary/境界での NextByte を BE/LE 別に網羅する。

## 既知の driver 制約(この harness の前提。false-positive を避けるため必読)

このセッションで driver に 3 つの制約が判明した。実デコーダはこれらを守るので、
harness も守らせないと「無効な使い方」で偽の相違を出す:

1. **byte 読み(NextByte 等)は必ずバイト境界で**。リザーバに残ビットがある
   状態で NextByte すると currbyte だけ進みリザーバと desync する(実コードは
   byte 読みの前に SkipToByteBoundary する)。→ 現 driver は case 7 で
   skiptobyte を先に呼ぶ。
2. **1 ストリームは BE か LE のどちらか固定**。実デコーダは BE/LE を混在
   しない。→ 現 driver は seed 毎に LE を固定し、`nextlong` も LE 版へ分岐。
3. **EOF で止まる**。この harness はメモリ背景(refill 無し)で、currbyte が
   バッファ末尾を越えると old/new とも OOB 読み(実コードの peek も境界
   チェック無し)。BE の完全グリーン検証には、fill が末尾に達する前に op を
   止める(残バイト数で打ち切る)driver 改良が要る。現状は LE の境界内相違が
   先に出るため未対応。
