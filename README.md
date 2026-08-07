# cooViewer 2.0(macOS 26+ / Apple Silicon)

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
$ git clone --recursive https://github.com/plife18/cooViewer.git
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
  パスワード付き書庫・PDF に対応
- キー / マウス / ホイール / トラックパッドジェスチャの操作割り当て
  (旧版の設定をそのまま引き継ぎます)
- しおり、最終ページの記憶と復元、履歴、同フォルダの次/前の本への移動、
  サブフォルダ移動、スライドショー、ゴミ箱へ移動、原寸表示、ページバー/ページ番号表示
- サムネイル一覧(⌘T。現在ページとしおりを表示、クリックでジャンプ)、
  ルーペ(全表示モード・回転対応)
- ネイティブフルスクリーン(カーソル自動非表示)

### 旧版ユーザーへ: 設定の引き継ぎ

設定ドメインは旧版と同じ `jp.coo.cooViewer` を使い続けます。
キー/マウス割り当て・履歴・しおり・本ごとの設定は旧形式をそのまま読み込みます
(ファイル参照は旧 Carbon alias から URL ブックマークへ順次移行されます)。

### 旧版からの主な変更点

- 疑似フルスクリーン → ネイティブフルスクリーン
- 設定ウインドウは即時反映(旧: Cancel で全ロールバック)
- Apple Remote / Keyspan リモコン対応は削除(受信ハードウェアが現行 Mac に存在しないため)
- Spotlight 保存検索(.savedSearch)は未対応(将来課題)
- キー/マウス割り当ての編集 UI は未実装(既定割り当て+旧版から引き継いだ割り当ては動作します)
- カラーフィルタ、ページバーの詳細カスタマイズ(位置・色・フォント)は未実装(将来課題)
- 旧版の既知バグの扱いは仕様書 §13.3 の判断リストに従い、修正または意図的に維持しています

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
