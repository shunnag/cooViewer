# cooViewer 2.0(macOS 26+ / Apple Silicon)

> **Note(EN)**: This is an **unofficial fork** of cooViewer, maintained independently.
> It is not affiliated with or endorsed by the original author (coo-ona) or the upstream
> repository ([plife18/cooViewer](https://github.com/plife18/cooViewer)). Please report
> issues with this fork here, not to the original author.
>
> **注意(日本語)**: 本リポジトリは cooViewer の**非公式フォーク**です。原作者
> (coo-ona 氏)および上流リポジトリ([plife18/cooViewer](https://github.com/plife18/cooViewer))
> とは無関係に独自に保守しています。本フォークに関する不具合報告等は原作者ではなく
> 当リポジトリへお願いします。

macOS 用の漫画・画像ビューア。フォルダ / zip / rar / 7z 等の書庫 / PDF を「本」として開き、
右→左(右綴じ)・左→右の読み方向、単ページ/見開き表示で快適に読むことができます。

このブランチは、Objective-C 製の旧 cooViewer 1.2b(coo-ona 氏作)を
**Swift 6 + AppKit/SwiftUI で全面的に書き直した近代化版**です。

- 対応環境: **macOS 26 (Tahoe) 以降 / Apple Silicon のみ**(x86_64 は打ち切り)
- 旧ソース一式は参照用に [`legacy/`](legacy/) にアーカイブしています(ビルド対象外)
- 書き直しにあたり旧アプリの全挙動を調査・記録した資料が
  [`Documentation/legacy-app-analysis.md`](Documentation/legacy-app-analysis.md)(詳細仕様)と
  [`Documentation/architecture.md`](Documentation/architecture.md)(設計方針)にあります

## ビルド

Xcode 26 以降が必要です。依存ライブラリ(XADMaster / UniversalDetector)はサブモジュールです。

```
$ git clone --recursive https://github.com/shunnag/cooViewer.git
$ cd cooViewer
$ xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Release build
```

- Xcode.app で `CooViewer.xcodeproj` を開いてビルドしても構いません。
- 初回ビルド時に XADMaster.framework / UniversalDetector.framework が `Frameworks/` に
  自動ビルドされます。サブモジュール更新後に作り直す場合は `rm -rf Frameworks` してから
  ビルドしてください。
- テスト: `xcodebuild -project CooViewer.xcodeproj -scheme cooViewer test`

## 主な機能

- 本 = 画像入りフォルダ / 書庫(zip, cbz, rar, cbr, lzh, lha, 7z, sit)/ PDF。
  単一の画像ファイルを開くと親フォルダを本として開きます
- 読み方向 4 種(右→左・左→右 × 見開き・単ページ)、見開き自動判定
  (縦横比しきい値+ページ毎の強制指定)
- 表示モード 4 種(全体フィット / 幅フィット / 原寸 / 幅フィット(横長分割))、回転、補間設定
- Finder 互換の自然順ソート / 日付順 / シャッフル
- 書庫ファイル名の文字コード自動判定(Shift-JIS の zip も文字化けしません)、
  パスワード付き書庫・PDF、書庫の中の書庫/PDF(ネスト)に対応
- キー / マウス / ホイール / トラックパッドジェスチャの操作割り当て
  (旧版の設定をそのまま引き継ぎます)
- しおり、最終ページの記憶と復元、履歴、同フォルダの次/前の本への移動、
  サブフォルダ移動、スライドショー、ゴミ箱へ移動、原寸表示、ページバー/ページ番号表示
- サムネイル一覧(⌘T。現在ページとしおりを表示、クリックでジャンプ)、
  ルーペ(全表示モード・回転対応)
- ネイティブフルスクリーン(カーソル自動非表示)

## 対応形式

### 本(コンテナ)

| 種類 | 形式 |
|---|---|
| フォルダ | 画像入りフォルダ(サブフォルダ読み込みは設定で切替)、旧 cooViewer バンドル(.cvbdl) |
| 書庫 | zip / cbz / rar / cbr / lzh / lha / 7z / sit |
| 分割書庫 | .001〜 / .r00〜 / .z01〜 系(先頭巻を開くと続き巻へ自動スパン) |
| PDF | ページをベクトルのまま表示サイズに合わせてレンダリング |
| ネスト | フォルダ内・書庫内の書庫/PDF を同じ本に統合(例: フォルダ内の zip 群を 1 冊として読む) |

パスワード付きの zip / rar / PDF に対応(ネストされた暗号化書庫も解除ダイアログを表示)。
書庫内ファイル名の文字コードは自動判定します(Shift-JIS の zip も文字化けしません)。

### ページ画像

判定は拡張子ベースで、**macOS の ImageIO が読める形式はそのまま表示できます**。
macOS 26 時点で動作を確認している主な形式:

| 分類 | 形式 |
|---|---|
| 一般 | JPEG、PNG、GIF、TIFF、BMP、WebP、HEIC / HEIF(.hif 含む)、AVIF、**JPEG XL (.jxl)**、JPEG 2000 (.jp2/.j2k)、MPO |
| アニメーション | GIF、APNG(.png)、WebP、AVIF (.avifs)、HEIC (.heics) — インライン再生 |
| HDR | ゲインマップ付き JPEG/HEIC の HDR 表示、OpenEXR (.exr)、Radiance (.hdr) |
| RAW | DNG と各社 RAW(CR2 / CR3 / NEF / ARW / RAF / ORF / RW2 ほか ImageIO 対応機種) |
| ベクトル | SVG (.svg) — 表示サイズに合わせてラスタライズ |
| レトロ日本形式 | **MAG (.mag / .max)**(MSX2+ の YJK スクリーンモード 10-12 含む)、**MAKI (.mki)**、**Pi (.pi)**、**PIC (.pic)**(X68000 15/16bit・16/256 色、FM-Towns/汎用ヘッダ)— PC-98 / X68000 / MSX 時代の形式を独自デコーダで表示。先頭マジックで判定するため、同じ拡張子の別形式ファイル(3ds Max の .max、Softimage の .pic 等)を誤描画することはありません |
| その他 | PSD、TGA、ICO / ICNS、DDS / KTX / ASTC(テクスチャ)、SGI、PICT、pbmplus 全種(PPM / PGM / PBM の ASCII・バイナリ両方と .pnm) |

独自デコーダの形式(MAG / MAKI / Pi / PIC / PBM P4)は設定の「高度」タブで個別に無効化できます。

非対応: Adobe Illustrator (.ai)、DjVu、PCX、PIC2 (.p2)、PC-88VA の PIC など。

### 旧版ユーザーへ: 設定の引き継ぎ

設定ドメインは旧版と同じ `jp.coo.cooViewer` を使い続けます。
キー/マウス割り当て・履歴・しおり・本ごとの設定は旧形式をそのまま読み込みます
(ファイル参照は旧 Carbon alias から URL ブックマークへ順次移行されます)。

### 旧版からの主な変更点

- 疑似フルスクリーン → ネイティブフルスクリーン
- 設定ウインドウは即時反映(旧: Cancel で全ロールバック)
- Apple Remote / Keyspan リモコン対応は削除(受信ハードウェアが現行 Mac に存在しないため)
- Spotlight 保存検索(.savedSearch)は未対応(将来課題)
- キー割り当ての編集 UI はあります。マウス/ホイール割り当ての編集 UI は未実装(既定割り当て+旧版から引き継いだ割り当ては動作します)
- カラーフィルタは未実装(将来課題)
- ページ番号入力の画面中央オーバーレイ(旧 pageMover)は簡易ダイアログでの提供、
  本を開いていない時の全しおり編集ウインドウは未対応(将来課題)
- 旧版の既知バグの扱いは仕様書 §13.3 の判断リストに従い、修正または意図的に維持しています

## 1.x に戻す場合 / Reverting to 1.x

2.0 は初回起動時に 1.x の設定・履歴・しおりを新形式へ変換します。旧データは
**変換時点の内容のまま残す**ため、2.0 を一度使っても 1.x はそのまま起動できます。
ただし 2.0 で進めた読書位置や新しく付けたしおりは 1.x には反映されません。

2.0 のデータを完全に消して初期状態へ戻したい場合は、アプリ終了後に
ターミナルで次を実行してください(1.x のデータも消えます):

```
defaults delete jp.coo.cooViewer
rm -rf ~/Library/Application\ Support/jp.coo.cooViewer
rm -rf ~/Library/Caches/jp.coo.cooViewer
```

EN: 2.0 imports 1.x data once at first launch and leaves the legacy data
frozen, so 1.x still runs after using 2.0 — but reading positions and
bookmarks made in 2.0 do not flow back. To reset everything, quit the app
and run the commands above (this also erases 1.x data).

## 謝辞 / Acknowledgments

**日本語**

本アプリの原作者である **coo-ona 氏**に、心より感謝申し上げます。2005 年から長年に
わたって開発・公開されてきた cooViewer は、右綴じ・見開き表示や柔軟な操作割り当てを
はじめ、漫画を快適に読むための工夫が隅々まで行き届いた素晴らしいアプリケーションでした。
本フォークの 2.0 系はコードこそ全面的に書き直していますが、その設計・挙動・使い心地は
すべて原作の丁寧な作り込みを土台にしており、原作なくして本フォークは存在しません。
また、旧ソースコードと[操作説明](docs/)を公開し続けてくださっていることが、
挙動の調査と互換性の維持を可能にしました。

あわせて、現代の macOS でビルドできるよう旧版を保守してくださった
[plife18 氏のフォーク](https://github.com/plife18/cooViewer)、および書庫展開と文字コード
判定を支える [XADMaster / UniversalDetector](https://github.com/MacPaw/XADMaster)
(MacPaw によるメンテナンス)の各開発者の皆さまに感謝します。

**English**

Our heartfelt thanks go to **coo-ona**, the original author of cooViewer. Developed and
shared since 2005, the original app was a beautifully crafted comic reader — right-to-left
spreads, flexible input bindings, and countless thoughtful touches for comfortable reading.
Although the 2.0 line is a complete rewrite, its design, behavior, and feel are all built
on the care that went into the original; this fork simply would not exist without it. The
continued availability of the original source code and [manual](docs/) is what made the
behavioral research and compatibility work possible.

We also thank [plife18's fork](https://github.com/plife18/cooViewer) for keeping the
legacy app buildable on modern macOS, and the maintainers of
[XADMaster / UniversalDetector](https://github.com/MacPaw/XADMaster) (maintained by
MacPaw), which power archive extraction and filename-encoding detection.

## ライセンス

- cooViewer 本体: MIT ライセンス([Licence.txt](Licence.txt))。Copyright (c) 2005- coo.
- [XADMaster](https://github.com/MacPaw/XADMaster) /
  [UniversalDetector](https://github.com/MacPaw/universal-detector): **LGPL 2.1**
  (動的リンクの .framework として同梱。各サブモジュールの LICENSE を参照)
- 旧版が同梱していた Remote Control Wrapper(MIT)は削除済みですが、
  ライセンス文書は参照用に [Licence_RemoteControlWrapper.txt](Licence_RemoteControlWrapper.txt)
  として残しています

旧版の README・操作説明は [docs/](docs/)(原作者による GitHub Pages)と
[`legacy/`](legacy/) を参照してください。
