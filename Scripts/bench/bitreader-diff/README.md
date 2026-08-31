# CSInputBuffer 64bit レザバー化の差分ハーネス(gate: green)

`CSInputBuffer` のビットレザバーを 32bit から 64bit にし、fill 頻度の半減と
8 byte 単一ロード化を検討するためのスタンドアロン差分ハーネス。OLD は現行
32bit 実装の参照移植、NEW は 64bit 候補実装である。同一の入力と op 列を並走し、
返り値、EOF タイミング、BufferOffset、BitOffset、未消費レザバー内容を各 op 後に
比較する。

2026-08-31 に driver の偽陽性を修正し、ASan+UBSan 下で mixed、LE 固定、BE 固定の
全ゲートが緑になった。XADMaster 本体はこの検証では変更していない。

## 結果

指定の mixed ゲート:

```
clang -O2 -fsanitize=address,undefined -fno-sanitize-recover=undefined bitdiff.c -o /tmp/bitdiff
/tmp/bitdiff 200000 400 ; echo "exit=$?"
OK 200000 seeds, 44418251 ops, no divergence
exit=0
```

同じ sanitizer 条件で `int LE` を一時的に固定したゲート:

```
# LE 固定
OK 200000 seeds, 42030351 ops, no divergence
exit=0

# BE 固定
OK 200000 seeds, 46802927 ops, no divergence
exit=0
```

mixed 実行では seed の偶奇により LE/BE が各 100,000 seed 実行される。固定実行も
含め、ハーネスが生成した有効な op 列では OLD と NEW が全検証項目で一致した。

20,000 seed の op 数比較:

| 状態 | 実行結果 | seed あたり平均 op 数 |
| --- | --- | ---: |
| 修正前 | 最初の seed の偽陽性で `FAIL after 1 seeds, 39 ops` | 39.0（実行できた 1 seed） |
| 修正後 | `OK 20000 seeds, 4443792 ops, no divergence` | 222.1896 |

修正前は 20,000 seed を完走していないため、39.0 は末尾ガード単独の対照値ではない。
ただし修正後は要求された全 seed で 444 万 op を実行しており、末尾付近だけを止める
ガードによって網羅性を犠牲にして緑にした結果ではない。

末尾ガードだけを `sed 's/< 16/< -1000000/g'` で無効化し、同じ sanitizer 条件で
元の失敗 seed を再実行した対照実験でも、元の相違が末尾ガードによって隠されたのでは
ないことを確認した:

```
TRACE=1 ./bitdiff-noguard 1 400
step=36 kind=1 nb=8  LE=1 | OLD cb=41 nb=24 bits=0031f0dd | NEW cb=41 nb=56 bits=00031695bc31f0dd
step=37 kind=4 nb=21 LE=1 | OLD cb=44 nb=3  bits=00000001 | NEW cb=44 nb=35 bits=0000000018b4ade1
step=38 kind=1 nb=5  LE=1 | OLD cb=45 nb=22 bits=0005a56f | NEW cb=45 nb=30 bits=0000000000c5a56f
```

step 37 の case 4 直後は、修正前の OLD `1ba00000` / NEW
`d2b7863e1ba00000` という上位詰めから、修正後は両者とも下位詰めへ変わっており、
LE 充填へ是正されている。step 38 の下位 22bit も OLD `0x05A56F` / NEW
`0x05A56F` で一致し、`RESERVOIR-DIVERGE` は発生しない。したがって元の相違を
解消したのは case 4 の分岐修正であり、末尾ガードではない。

ガードを無効にしたまま続行すると、`old_peekbitsLE` で ASan の
heap-buffer-overflow に至る。最初に範囲外を読むのは OLD の参照実装側であり、
末尾の失敗は NEW の欠陥ではなく、論理終端を越えて op を発行するハーネス由来の
アーティファクトであることも確認できた。

## 偽陽性の原因と修正

1. **case 4 の BE/LE 分岐漏れ**
   driver は LE stream でも BE 用 `skipbits` を呼んでいた。`skipbits` は要求 bit が
   レザバー外なら内部で fill するため、BE の上位詰めレザバーを作った直後に LE op が
   下位 bit を読む無効な混在列になった。32bit と 64bit の幅の差がレザバー相違として
   現れていた。`XADMaster/CSInputBuffer.m` の `CSInputSkipBitsLE` を OLD/NEW に移植し、
   case 4 も stream の endian に応じて分岐させた。
2. **末尾での幅依存オーバーリード**
   メモリ背景で refill がないまま論理終端近くまで op を発行していた。OLD は最大
   4 byte、NEW は最大 8 byte を fill するため、終端付近の到達範囲が幅依存になって
   いた。各 op の発行前に OLD/NEW 双方の残り byte 数を確認し、16 byte 未満ならその
   seed を正常終了する。片側だけが条件を満たす場合は相違として失敗する。
3. **NEW fill の終端クランプ不足**
   NEW は `startoffset` が最大 7 になるため、読み込める byte 数を単なる `left` ではなく
   `max(left - startoffset, 0)` で制限するようにした。OLD は参照実装のまま変更していない。
4. **64bit シフトの未定義動作**
   NEW の skip-peeked は `n >= 64` ならレザバーを 0 にし、64bit 幅以上のシフトを
   実行しない。現 driver の `n <= 39` では経路に入らないが、本番移植に必要な防御である。

全 op の endian 監査では、分岐漏れは case 4 だけだった。case 0 は LE 時に case 1 の
LE 読みへ置換され、case 1/2/3 は既に LE/BE 分岐済み。case 5/6 はレザバーをリセット
するだけで fill せず、case 7 は byte 境界化後の byte 読み、case 8 は境界照会なので
共通処理でよい。

## 使い方

```
clang -O2 -fsanitize=address,undefined -fno-sanitize-recover=undefined bitdiff.c -o /tmp/bitdiff
/tmp/bitdiff [nseeds=200000] [nops=400]
# OK ... no divergence → ハーネスの 64bit 候補は参照実装と一致
# DIVERGE / RESERVOIR-DIVERGE ... → seed/step/kind/nb と状態を出力
```

op 列は NextBit、NextBitString(1..25)、LongBitString(26..32)、Peek+Skip、
SkipBits(0..39)、SkipToByteBoundary、SkipTo16BitBoundary、境界での NextByte、
OnByteBoundary を BE/LE 別に網羅する。

## 本実装フェーズの条件

- `OldBuf`/`old_*` は 32bit 本番実装の忠実な参照として変更しない。
- 1 stream の endian は固定し、fill を伴う op を含む全 op を正しい BE/LE API へ
  分岐する。byte 読みは byte 境界でだけ行う。
- 実デコーダの論理終端を越えて fill しない。ハーネスでは op 発行前の 16 byte
  headroom と OLD/NEW 双方の条件一致を維持する。
- 本番の `XADMaster/CSInputBuffer.h:81` にある `CSInputBufferLookAhead` は 4 から
  8 へ引き上げる。`_CSInputCheckAndFillBuffer`（同 h:97。`CSInputBufferLookAhead`
  の参照はここ 1 箇所のみ）は残り byte が LookAhead 以下のときだけ補充するため、
  現状で充填直後に保証される残り byte は 5 以上である。32bit 版は常に
  `startoffset + numbytes <= 4` で保証内に収まるが、64bit 版は `startoffset` が最大
  7、到達インデックスも最大 7 となり、LookAhead=4 の保証外を読む。
- `_CSInputFillBuffer` は現状、未消費の `left` byte を `memmove` でバッファ先頭へ
  保存し、その tail の直後へ refill して `currbyte=0` に戻す。LookAhead を 8 に
  上げても、この refill をまたぐ未消費 tail の保存が壊れないことを本番実装とテストで
  確認する。このハーネスはメモリ背景で refill 経路を持たないため、この問題を原理的に
  検出できない。
- 本番の 64bit fill も、NEW と同じく読み込み可能 byte 数を `startoffset` 込みの
  `max(left - startoffset, 0)` でクランプし、バッファのスラックに依存しない。
  64bit 幅以上のシフトも実行しない。
- bitstream API の呼び出し元は 35 ファイル・30 形式超に分散しているため、バイト
  同一性コーパスを LHA/RAR だけで構成してはならない。LHA、RAR 1.5/2/3/5、
  ARC 系 3 種、StuffIt 系 5 種、LZX / MS-LZX、Deflate、Zip Shrink / Implode、
  Unix compress、Quantum、PMarc、Zoo、LArc、DiskDoubler 系、ARJ、PDF 内蔵 LZW、
  および共用 `XADPrefixCode.m` を含む形式横断のリグレッションを行う。
- 返り値、EOF タイミング、未消費レザバー内容、BufferOffset、BitOffset の比較を
  削除・緩和せず、mixed、LE 固定、BE 固定の sanitizer ゲートをすべて通す。
- XADMaster の `CSInputBuffer.[hm]` を変更するのは、このゲートが緑の状態を維持した
  64bit 実装を用意してからとする。

今回のゲートは緑なので、64bit レザバー化は本実装フェーズへ進めてよい。これは
採用・出荷の確定ではなく、本番移植後にも同じゲートを再実行することが条件である。
