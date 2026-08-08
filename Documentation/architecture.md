# cooViewer 近代化アーキテクチャ設計書

| メタ情報 | 内容 |
|---|---|
| 作成日 | 2026-08-07 |
| 前提文書 | [legacy-app-analysis.md](legacy-app-analysis.md)(以下「仕様書」。§n は仕様書の章番号) |
| ブランチ | `modernize/macos26` |
| 対象環境 | macOS 26 (Tahoe) 以降 / Apple Silicon (arm64) のみ |
| 実装優先度 | 1. 正しく動作 2. コードが読みやすい 3. コードが効率的 4. 実際の動作の快適さ(実装の速さは優先しない) |

---

## 1. 基本方針

**完全リライト**とする。理由:

- 旧実装は MRC(手動 retain/release)+ 廃止 API(AliasHandle、NSArchiver、detachNewThread+ビジーウェイト、Carbon OSType)の上に成立しており、部分改修では「単一 Controller 集中型」(§1.1)と手作りスレッド同期(§4.6)を温存することになる。仕様書 §12 の確定バグ 37 件・メモリ/スレッド危険 18 件の大半がこの構造に起因する。
- 挙動仕様は仕様書として完全に記録済みであり、「旧コードを開かずに同等機能を実装できる」状態を作った。リライトのリスク(挙動の取りこぼし)は仕様書と §13.2 互換性チェックリストで管理する。

### 1.1 言語・フレームワーク

| 項目 | 決定 | 根拠と代替案 |
|---|---|---|
| 言語 | **Swift 6**(言語モード 6、strict concurrency) | データ競合をコンパイル時に排除でき、旧実装のスレッド危険(§12.2)を構造的に消せる。ObjC 継続案は近代化にならず、却下 |
| アプリライフサイクル | **AppKit**(NSApplicationDelegate + プログラム構築メニュー) | 本アプリの核心は「完全カスタム入力バインディング+動的メニュー+全画面管理」(§5, §8)であり AppKit の領分。SwiftUI ライフサイクル案は Reader が結局 NSViewRepresentable になり、メニュー/イベントの制御点が増えるだけなので却下 |
| 読書ビュー | **AppKit カスタム NSView(layer-backed、CALayer 合成)** | ページ配置計算・スクロール端判定・カーソル管理・ルーペ等(§3-5)はピクセル単位の制御が必要。旧 BufferingMode=New の「ビュー側 2 枚並置描画」(§13.1)を踏襲 |
| 補助 UI | **SwiftUI**(設定・サムネイル・しおり編集) | フォーム/グリッド UI は SwiftUI が最も読みやすく、Tahoe の Liquid Glass 外観が自動で得られる |
| PDF | **PDFKit**(ページ毎独立レンダリング) | 旧 COPDFImageRep の共有 rep+setCurrentPage はスレッド不安全(§4.14)。白背景・ポイント原寸の描画特性は維持 |
| 書庫 | **XADMaster + UniversalDetector(サブモジュール継続、LGPL 2.1)** | rar/rar5/7z 対応とファイル名エンコーディング自動判定(§4.17)は本アプリの生命線。libarchive 案(ヘッダ非公開・エンコーディング検出なし)、ZIPFoundation 案(zip のみ)は機能後退のため却下。modulemap 付き .framework のため Swift から直接 `import XADMaster` 可能(確認済み) |
| ローカライズ | **String Catalog(.xcstrings)**、ja/en | 旧 Localizable.strings 6 世代連結(§10.1)はユニーク 136 キーへ正規化 |
| テスト | **XCTest ユニットテストターゲットを新設** | 旧アプリにはテストが皆無。ロジック層(ソート・合成判定・バインディング解決・移行)を重点的にテストする。「正しく動作」最優先の担保 |

### 1.2 配布・実行形態

- **arm64 のみ**(ARCHS=arm64、x86_64 打ち切り)。MACOSX_DEPLOYMENT_TARGET=26.0。
- **非サンドボックス継続**: 同フォルダ移動・任意パス履歴復元・ゴミ箱(§4)のUXはサンドボックスと相性が悪い。旧アプリ同様 Developer ID 直配布想定。署名はローカルでは ad-hoc。
- バンドル ID は **jp.coo.cooViewer を継続**し、既存ユーザーの defaults を初回起動時にスキーマ移行する(§13.5)。CFBundleShortVersionString を新設し **2.0.0** とする。

### 1.3 リポジトリ再編成

```
(root)
├── CooViewer.xcodeproj      ← 新規(手書き pbxproj、objectVersion 77 の
│                               fileSystemSynchronizedGroups 方式)
├── CooViewer/               ← 新 Swift ソース(§3 のモジュール構成)
├── CooViewerTests/          ← ユニットテスト
├── XADMaster/               ← サブモジュール(継続)
├── UniversalDetector/       ← サブモジュール(継続)
├── Documentation/           ← 仕様書・本設計書
├── Design/                  ← アイコン元画像(AppIcon.icon は Icon Composer 管理)
├── Frameworks/              ← build-frameworks.sh の成果物(ビルド時生成)
├── legacy/                  ← 旧ソース一式を git mv(*.m/*.h/xib/旧 xcodeproj/
│                               旧リソース)。参照用アーカイブでありビルド対象外
└── docs/                    ← GitHub Pages(原作者マニュアル)。当面そのまま
```

- 旧 cooViewer.xcodeproj と新 CooViewer.xcodeproj は大文字小文字非区別 FS で衝突するため、**旧一式を legacy/ へ移してから**新プロジェクトを root に置く。
- 孤児ファイル(COImageLoader_temp.m、info copy.plist、MainMenu~.nib、Controller.m_1.xcclassmodel、up.tiff 等 §11.4)は legacy/ にも持ち込まず削除。
- アイコン(icon.icns、coo_*.icns)・Credits.rtf・ライセンス文書は新アプリへ引き継ぐ。

### 1.4 XADMaster のビルド統合

- `Scripts/build-frameworks.sh`: XADMaster の xcodeproj を `xcodebuild -scheme XADMaster -configuration Release ARCHS=arm64` でビルドし `Frameworks/` へ配置。**成果物が新しければスキップ**(旧実装の毎回 clean build §11.2 を排除)。
- 新ターゲットの Run Script phase(input/output 宣言付き)から呼び、`Frameworks/XADMaster.framework` と `UniversalDetector.framework` をリンク+**Embed & Sign**(LGPL 2.1 の差し替え可能性要件を動的リンクで充足 §14)。

---

## 2. 機能の取捨選択

### 2.1 維持(同等実装)

§13.2 のチェックリスト全項目。骨子:

- 本 = フォルダ / XADMaster 対応書庫(zip/rar/rar5/7z/lha 等) / PDF。単一画像を開くと親フォルダを本として開く(§2.4)。
- 書庫内の書庫/PDF のネスト取り込み(§2.4): 一時領域へ展開して**子 BookSource**(ArchiveSource/PDFSource)を生成し、そのページを「書庫内パス/子の相対パス」で同じ本に取り込む(旧ネスト COImageLoader 相当)。zip 爆弾対策で 3 段まで。ネスト分は展開時点でローカル化されるためスプール対象外。
- **フォルダ内**の書庫/PDF も同様に統合する(`NestedFolderSource`。旧フォルダモードのネストローダー相当)。書庫/PDF を含む本は旧 canSortByDate 規則どおり日付ソート不可。画像だけのフォルダは従来どおり `FolderSource`(並列ロード・日付ソート可)。
- 暗号化されたネスト書庫/PDF は `NestedUnlocker`(本の全階層で共有)がロック解除する: 既知パスワード(外側書庫・入力済み)を先に試し、駄目ならダイアログで最大 3 回尋ねる(旧 askInArchivePassword 相当)。キャンセルでその子を本から外し、以降この本では尋ねない。
- readMode 4 値(既定 0=右→左見開き)、見開き合成の marks("N"/"N-M"、1 始まり)+ 縦横比 740 判定(§4.2)、switchSingle/Bind。
- フィットモード 4 値、最大拡大率、回転、補間設定、背景色。
- ソート: 名前自然順(localizedStandardCompare 相当 §4.4.3)/日付/シャッフル(Fisher-Yates へ置換)。
- ページキャッシュ+先読み(方向連動)、しおり、サムネイル一覧(右→左読みは右端列から充填)、スライドショー、ルーペ、ページバー+ページ番号(4 隅+色+フォント+自動隠し+クリックジャンプ+バブル)、Go to Page(簡易ダイアログ。旧 pageMover の画面中央数字表示は §2.2 で見送り)。
- カスタムキー/マウス/ホイール/ジェスチャバインディング: **旧 6 配列スキーマとの互換移行**(§5.1-5.2)、モード別解決順(§5.3。マウスクリックの非対称は「キーと同型」に統一し仕様変更として明記)、switchAction 入替ペア(§5.4)。
- 同フォルダ次/前の本(名前順・端ラップ)、サブフォルダ移動、loopCheck 4 値(1/2 の後方差含む §4.3.4)。
- GoToLastPage 復元(0=確認/1=自動/2=無効、page==0 は復帰なし §7.3)、RecentItems/LastPages/BookSettings の互換移行(キー基数 0/1 始まりを厳守 §13.2)。
- パスワード書庫(NSSecureTextField 化)、ゴミ箱(`trashItemAtURL` + 削除後のローダ再構築)、原寸表示、Finder 表示、ドラッグ&ドロップ。
- フルスクリーン: ネイティブ全画面へ移行しつつ「上端ホバーでメニューバー」「カーソル 3 秒自動隠し」を再現(§3.3)。
- 日英ローカライズ、About パネルの XAD クレジット表記(§14.2)。

### 2.2 削除(§13.1 準拠)

Apple Remote スタック全体 / GlobalKeyboardDevice / KeyspanFrontRowControl / BufferingMode=Old + ScreenCache / ChangeCreator・ChangeOpenWith / PrevPagePageBarPositionMode / AppleScript ゴミ箱 / AliasHandle 一式(→NSURL ブックマーク) / randomCompare シャッフル / NSNumberFormatter 全域上書き / IKImageEditPanel / SkipPage(移行時に読替のみ) / 孤児ファイル群。

**v2.0 では見送り(将来課題として README に明記)**:

- Spotlight 保存検索(.savedSearch、mode 3 §2.4)。NSMetadataQuery による再実装は可能だが利用頻度に対し複雑度が高い。
- カラーフィルタ(CIFilter)。§13.4 の「適用対象をページ画像のみに変更」案ごと保留。
- pageMover の画面中央数字入力(§5.8)。Go to Page は簡易ダイアログで提供する。
- 全しおり編集ウインドウ(本を開いていない時の一括編集 §4.7.3)。現在の本のしおり編集シート(§4.7.2)は実装済みで、コピー編集のため Cancel が有効(§13.3 の修正方針)。
- マウス/ホイール割り当ての編集 UI(既定割り当てと旧設定の移行・実行は動作する)。

### 2.3 バグの扱い(§13.3 準拠)

修正: getMouseAction case 5 フォールスルー / マウス 28・29 ラベル左右逆(移行時読替) / マウス版スライドショー停止不能 / しおり編集 Cancel 無効。
維持: ソート変更で先頭ページへ / goToPar 上限なし / loopCheck 1・2 の前方同一 / pageMover 中の修飾キー無視。

### 2.4 仕様変更として明記する点

| 変更 | 内容 |
|---|---|
| 設定ウインドウ | Cancel 全ロールバック(§6.3)→ **即時反映**(SwiftUI Settings 標準)。「デフォルトに戻す」は「高度」タブの高度な設定に対して提供 |
| フルスクリーン | 疑似(hidesOnDeactivate)→ ネイティブ。esc で解除、3 勘所(§13.2)は再現 |
| マウスクリックのモード解決 | fitScreenMode 3 のとき Mode2 参照(§5.3)→ キーと同じ Mode3 参照に統一 |
| シャッフル | 非決定的比較器 → Fisher-Yates(シャッフル順の再現性はもともと保証されていない) |
| 保存タイミング | ⌘Q 時にも本の状態を保存(§7.7 の穴を塞ぐ) |
| ページバーバブル | サムネイル表示の既定 OFF(§6.1 PageBarShowThumbnail)→ **ON**(旧ドメインに明示保存された値は尊重) |
| 暗号化ネスト書庫のキャンセル | 旧: ページは残り表示のたび失敗 → **解除できない子は本から外す**(§4.17 の黙殺方針に統一)。キャンセル後は同じ本で再度尋ねない |
| 保存ページ・しおりの照合キー | RecentItems/LastPages エントリに `pagepath`、しおりに `path`(いずれも**新規キー**。旧アプリは無視)としてページの書庫内パスを併記。ネスト展開の失敗や並び替えでエントリ列が変わっても同じファイルへ復元する。保存形式の既存キーは §13.2 のまま不変 |
| サムネイル見開きモード | ページ組はサムネイル生成で得た縦横比により旧 isSmallImage 規則へ**漸進的に収束**(未生成ページは縦長とみなして先に組む) |
| 自動更新 | 旧実装には無い **Sparkle 2** による自動更新を追加(2.0b3〜)。フィードは master の `appcast.xml`(raw URL)、更新 zip は EdDSA 署名。フレームワークは公式バイナリ配布をバージョン+SHA-256 固定で取得(`Scripts/fetch-sparkle.sh`)。検証スナップショット実行(`--snapshot`)ではアップデーターを起動しない |

---

## 3. 新実装のモジュール構成

```
CooViewer/
├── App/
│   ├── main.swift                  — NSApplication 起動
│   ├── AppDelegate.swift           — ライフサイクル・openFile・起動時キャッシュ掃除・
│   │                                 検証用スナップショット引数(CLAUDE.md 参照)
│   └── MainMenuBuilder.swift       — メニューバー構築(しおり/最近使った本の
│                                     サブメニューは NSMenuDelegate で動的再構築)
├── Core/
│   ├── Source/
│   │   ├── BookSource.swift        — プロトコル+既定実装(パスワード・スプール・ルーペ)
│   │   ├── FolderSource.swift      — フォルダ走査(readSubFolder 意味論 §4.1)
│   │   ├── ArchiveSource.swift     — actor。XADMaster ラッパ+ローカルスプール(§5)
│   │   └── PDFSource.swift         — actor。PDFKit(ページ毎独立レンダリング)
│   ├── Book/
│   │   ├── Book.swift              — @MainActor。ページ列・現在位置・見開き(§4.2)・
│   │   │                             ナビゲーション・先読み(計画時の Navigator/
│   │   │                             Prefetcher はここへ統合)
│   │   ├── PageLayout.swift        — 見開き合成判定(marks + 740 比率 §4.2)
│   │   └── ReadMode.swift
│   ├── Cache/
│   │   ├── PageCache.swift         — actor。バイト基準 LRU+メモリ圧迫トリム(§5)
│   │   └── ThumbnailCache.swift    — actor。メモリ+ディスク、世代一致の待ち手管理
│   ├── Rendering/
│   │   ├── ImageResampler.swift    — 表示ピクセルへの事前リサンプル(§5 描画品質)
│   │   └── MetalFXUpscaler.swift   — MetalFX Spatial 拡大(RGBA 正規化必須)
│   ├── Sort/PageSorter.swift       — 自然順ほか SortMode 全種(§4.4.3)
│   └── ImageDecoding / AnimatedImage / SupportedTypes
├── Input/
│   ├── ReaderAction.swift          — 全アクション enum(旧番号 §5.5-5.6 は移行用対応表)
│   ├── Bindings.swift              — 旧 6 配列互換の読み書き・解決順(§5.3)・
│   │                                 switchAction(§5.4)
│   └── ActionNames.swift           — 表示名(設定のバインディング編集用)
├── UI/
│   ├── Reader/
│   │   ├── ReaderWindowController.swift(+Input/+Library/+Thumbnails 拡張)
│   │   │                           — 開くフロー・表示更新・入力ディスパッチ・
│   │   │                             付随機能・ページ番号/バーの配置と自動隠し
│   │   ├── ReaderView.swift        — layer-backed。1/2 ページ配置・フィット・回転・
│   │   │                             内部スクロール端判定・リサンプル差し替え
│   │   ├── PageBarView.swift       — ページバー(色・進捗・クリック/ホバー)
│   │   ├── LoupeController.swift / PlaceholderImage.swift
│   ├── Thumbnails/ (SwiftUI)       — ThumbnailOverlayModel / ThumbnailOverlayView /
│   │                                 ThumbnailGridLayout(ウインドウ内オーバーレイ §4.8)
│   ├── Bookmarks/ (SwiftUI)        — BookmarkEditorView(しおり編集シート §4.7.2)
│   └── Settings/ (SwiftUI)         — SettingsView(一般/表示/操作/キー/高度)+
│                                     KeyBindingsPane
├── Persistence/
│   ├── SettingsStore.swift         — 型付きアクセサ。旧キーを直接読み書きし、色/
│   │                                 フォント等の旧 NSArchiver データは読み替え(§13.5)
│   └── BookHistoryStore.swift      — BookSettings/RecentItems/LastPages
│                                     (スキーマ §7.1-7.3 互換、URL ブックマーク)
└── Resources/
    ├── Localizable.xcstrings       — ja/en
    ├── Credits.rtf                 — XAD クレジット維持(§14.2)
    └── coo_*.icns / broken.png / empty.png
CooViewerTests/                     — ソート・ソース(スプール/暗号化 zip 含む)・Book・
                                      バインディング移行・履歴・ページ/サムネイル
                                      キャッシュ・リサンプル/MetalFX 色回帰・設定の
                                      ユニットテスト(旧 defaults 移行は §6 リスク表の
                                      とおりフィクスチャで担保)
```

計画時との主な差分: LegacyMigration の一括移行方式は「各ストアが旧キーを
そのまま読み書き+新形式へ読み替え」方式に変更(§13.2 のキー互換はそのまま
成立)。アイコンは Assets.xcassets ではなく Icon Composer の AppIcon.icon。

### 3.1 並行性設計(旧 §4.6 の置換)

- UI・Navigator・表示状態は `@MainActor`。
- キャッシュは actor。先読みは `Task` ベースで、ページ移動のたびに前回の
  先読みタスクをキャンセルして作り直す。**完了待ちはしない**(キャッシュ挿入は
  冪等で、表示経路は先読み結果に依存しない)。表示の一貫性は
  ReaderWindowController の世代番号(displayGeneration)で守る。
  NSLock+ビジーウェイト+threadStop は持ち込まない。
- 書庫展開(XADMaster)は ObjC 同期 API のため、専用 actor(`ArchiveSource` 内)で直列化。solid rar の逐次展開特性を前提にシーケンシャルな先読みを優先する(§13.4)。

### 3.2 描画設計(旧 §4.9-4.11 の置換)

- ReaderView は layer-backed。ページ毎に CALayer(contents=CGImage)、位置・スケールは CGAffineTransform。補間は `magnificationFilter`(+§5 の事前リサンプル)。フィルタ(CIFilter)は §2.2 で見送り。
- スクロールは view 内オフセット管理(NSScrollView は使わない)。scrollTo の端到達判定(純垂直移動のみ YES §13.2)、PageUp+PrevPage 系の意味論を Navigator 側で再現。
- 画像デコードは ImageIO(CGImageSource)で Data→CGImage。壊れ画像は broken 相当のプレースホルダでページ数を保つ(§4.17 のエラー黙殺方針を維持)。

---

## 4. 実装マイルストーン(タスク #3-#9 対応)

| # | 内容 | 完了条件 |
|---|---|---|
| 3 | 骨組み: legacy/ 再編成、新 pbxproj、空アプリ+メニュー+ウインドウ、XADMaster 統合ビルド、テストターゲット | `xcodebuild` 一発でビルド・起動 |
| 4 | Core: BookSource 3 実装+ソート+キャッシュ/先読み+ユニットテスト | フォルダ/zip/rar/PDF を開いて全ページ列挙・画像取得がテストで通る |
| 5 | Reader UI: 表示・見開き合成・フィット/回転・ページ送り・全画面・ページバー | 実書庫を開いて読める |
| 6 | 入力+設定: バインディング解決・既定バインディング(§5.7)・Settings・移行 | 旧既定操作が全て効く。旧 defaults からの移行テストが通る |
| 7 | 付随機能: サムネイル・しおり・スライドショー・ルーペ・履歴・同フォルダ移動・ゴミ箱・フィルタ | §13.2 挙動互換チェックリストを満たす |
| 8 | 文書・整理: README 全面改訂、CLAUDE.md 更新、ライセンス表記、docs 注記 | — |
| 9 | 検証: 全ビルド構成、実データでの動作確認、多視点レビュー、§12 バグ非再現確認 | — |

## 5. キャッシュ・先読み設計(2026-08 改訂)

想定ユースケース「ネットワークドライブ上の圧縮ファイル」で、ボトルネックは
デコードではなく **I/O(ネットワーク遅延と solid 書庫のランダムアクセス)** である。
近年の Mac(Apple Silicon・メモリ 16GB+)では「I/O を 1 回で済ませ、メモリを
潤沢に使う」方針が最も効くため、次の 5 層で構成する。

| 層 | 実装 | 既定値 |
|---|---|---|
| 書庫スプール | `ArchiveSource.beginSpooling`: 開いた直後にバックグラウンドで全ページ画像をローカル一時領域(`tmp/cooViewer-spool/<pid>-<uuid>/`)へ**書庫順に逐次展開**。以降のページ取得・サムネイル生成はローカル読み。展開中の要求はオンデマンド経路で応え、1 エントリ毎に譲る。ネストした書庫/PDF(`<pid>-<uuid>-nested/`)は entries() 確定時に展開済みのためスプール対象外 | 合計展開サイズ 4GB まで。超過書庫はオンデマンドのみ |
| メディア速度適応 | `MediaSpeedProbe` が本を開くとき置き場所を判定(statfs でネットワーク → IOKit の Medium Type で SSD/回転 → 不明なら 16MB/250ms 上限の実測ベンチ。結果はマウントポイント単位でセッションキャッシュ)。`MediaProfile` の方針表: **fastLocal**=zip 系スプール省略(solid 系と分割書庫はスプール)・フォルダ読み 6 並列・サムネイル 6 並列 / **slowLocal(HDD)**=全スプール・読み 2 並列・先読み 16/4 / **network**=全スプール・読み 3 並列・先読み 20/4 / **unknown**=従来動作と同一。フォルダの本は `SourceReadGate` で全読者(サムネイルのセル読み含む)の同時読み取りを制御。整合規則は「**明示は自動に勝つ**」: 先読み深さの適応は高度設定 OFF のときのみ(ON では明示値)、書庫スプールは「高度」タブの三択(自動=メディア速度で判断/常に行う/行わない)が最優先(自動調整 OFF でも明示は有効)。「メディア速度に応じた自動調整」(既定 ON)で判定自体を無効化可 | プローブは開くフローと並行実行・時間バジェット付き |
| ページキャッシュ | `PageCache`: デコード済み CGImage の**バイト基準** LRU。メモリ圧迫通知(DispatchSource)で半減トリム | 物理メモリの 15%(上限 6GB)。`PageCacheMegabytes` で明示指定可。旧 `ImageCache`(枚数)は廃止 |
| 先読み | `Book.schedulePrefetch`: 進行方向 12 ページ+逆方向 3 ページ。ジャンプでキャンセル。`supportsParallelPageLoads` なソース(フォルダ)は 4 並列デコード | — |
| 表示解像度キャップ | 表示用デコードは長辺 `displayPixelCap` に制限(縦横比不変のため見開き判定に影響なし)。原寸表示は `fullResolutionImage(at:)` でキャッシュ非経由のフル解像度 | 4096px |
| サムネイル | `ThumbnailCache`: メモリ LRU(400 枚)+ディスク(`Caches/jp.coo.cooViewer/Thumbnails/<bookKey>/`)。bookKey は本のパス+更新日時+サイズ由来で、本の更新でキーごと無効化 | ディスクは 30 日でトリム |

後始末: スプールは ArchiveSource 解放時に削除し、起動時に**生存していない PID の
残骸を掃除**する(旧実装の temp 残り問題 §4.17 の対策)。サムネイルの旧キー
フォルダも起動時トリムで回収する。

**高度な設定(2026-08 追加)**: 上表の既定値は設定タブ「高度」で調整できる。
マスタースイッチ `AdvancedSettingsEnabled` が OFF の間は保存値を無視して既定値で
動作する(`SettingsStore.AdvancedDefault` が唯一の既定値定義)。新設キー:
`AdvancedMemoryPercent`(物理メモリ %、5-50。ON 時は標準の 6GB 上限を適用しない)/
`AdvancedPrefetchAhead`(2-64)/`AdvancedPrefetchBehind`(0-16、0 で無効)/
`AdvancedDisplayPixelCap`(2048-8192)/`AdvancedSpoolLimitGB`(1-64)/
`AdvancedPrepareNextBookPages`(0-20、0 で無効)/`AdvancedThumbnailCacheDays`
(1-365)。いずれも新設キーのため旧ドメインと衝突しない。範囲外の保存値は
読み出し時に丸める。「デフォルトに戻す」は保存値を既定値で上書きする。

**描画品質(2026-08 追加)**: CALayer の trilinear 拡縮(スクリーントーンの
モアレ・甘さが出る)の代わりに、レイアウト確定後 150ms のデバウンスを挟んで
表示ピクセルサイズへ事前リサンプルし、等倍(1:1)画像に差し替える
(`ImageResampler` + ReaderView)。縮小は CG の高品質補間(Lanczos 相当)、
補間設定「高」では拡大に **MetalFX Spatial**(`MetalFXUpscaler`。2 倍超は
テクスチャのまま段階適用、非対応環境は CG フォールバック)。補間設定の意味:
なし=nearest / 低=GPU linear のみ / 既定=高品質縮小 / 高=+MetalFX 拡大。
注意: MTKTextureLoader は premultipliedFirst 系 CGImage のバイト順を誤読する
ため、入力は必ず RGBA 正規化してから渡す(色化けの回帰テストあり)。

## 6. リスクと対策

| リスク | 対策 |
|---|---|
| 入力バインディング移行の取りこぼし(6 配列×modifier 符号化) | 旧スキーマの実データ(§5.7 既定+§7.6 の各版追記)をフィクスチャにした移行ユニットテストを先に書く |
| XADMaster の Swift 連携で未知の穴(例外・スレッド) | ArchiveSource actor で直列化+ObjC 例外を NSException キャッチのブリッジで吸収 |
| 見開き合成・ナビゲーションのエッジケース(§4.2-4.3 の複雑な相互作用) | PageLayout/Navigator を純粋ロジックとして切り出しテーブル駆動テスト |
| 「Tahoe らしさ」と挙動互換の衝突(全画面・設定即時反映) | §2.4 の仕様変更表で明示管理。迷ったら挙動互換を優先 |
| 旧 NSArchiver データ(色/フォント)の読替 | 読めなければ既定値へフォールバック(§13.5 が許容) |
