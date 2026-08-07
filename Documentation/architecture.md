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
- readMode 4 値(既定 0=右→左見開き)、見開き合成の marks("N"/"N-M"、1 始まり)+ 縦横比 740 判定(§4.2)、switchSingle/Bind。
- フィットモード 4 値、最大拡大率、回転、補間設定、背景色。
- ソート: 名前自然順(localizedStandardCompare 相当 §4.4.3)/日付/シャッフル(Fisher-Yates へ置換)。
- ページキャッシュ+先読み(方向連動)、しおり、サムネイル一覧(右→左読みは右端列から充填)、スライドショー、ルーペ、ページバー+ページ番号(4 隅+色+フォント+自動隠し+クリックジャンプ)、pageMover(Go to Page)。
- カスタムキー/マウス/ホイール/ジェスチャバインディング: **旧 6 配列スキーマとの互換移行**(§5.1-5.2)、モード別解決順(§5.3。マウスクリックの非対称は「キーと同型」に統一し仕様変更として明記)、switchAction 入替ペア(§5.4)。
- 同フォルダ次/前の本(名前順・端ラップ)、サブフォルダ移動、loopCheck 4 値(1/2 の後方差含む §4.3.4)。
- GoToLastPage 復元(0=確認/1=自動/2=無効、page==0 は復帰なし §7.3)、RecentItems/LastPages/BookSettings の互換移行(キー基数 0/1 始まりを厳守 §13.2)。
- パスワード書庫(NSSecureTextField 化)、ゴミ箱(`trashItemAtURL` + 削除後のローダ再構築)、原寸表示、Finder 表示、ドラッグ&ドロップ。
- フルスクリーン: ネイティブ全画面へ移行しつつ「上端ホバーでメニューバー」「カーソル 3 秒自動隠し」を再現(§3.3)。
- フィルタ(CIFilter)。ただし適用対象を「ビュー全体」から「ページ画像のみ」へ変更(仕様変更として明記 §13.4)。
- 日英ローカライズ、About パネルの XAD クレジット表記(§14.2)。

### 2.2 削除(§13.1 準拠)

Apple Remote スタック全体 / GlobalKeyboardDevice / KeyspanFrontRowControl / BufferingMode=Old + ScreenCache / ChangeCreator・ChangeOpenWith / PrevPagePageBarPositionMode / AppleScript ゴミ箱 / AliasHandle 一式(→NSURL ブックマーク) / randomCompare シャッフル / NSNumberFormatter 全域上書き / IKImageEditPanel / SkipPage(移行時に読替のみ) / 孤児ファイル群。

**v2.0 では見送り(将来課題として README に明記)**: Spotlight 保存検索(.savedSearch、mode 3 §2.4)。NSMetadataQuery による再実装は可能だが利用頻度に対し複雑度が高い。

### 2.3 バグの扱い(§13.3 準拠)

修正: getMouseAction case 5 フォールスルー / マウス 28・29 ラベル左右逆(移行時読替) / マウス版スライドショー停止不能 / しおり編集 Cancel 無効。
維持: ソート変更で先頭ページへ / goToPar 上限なし / loopCheck 1・2 の前方同一 / pageMover 中の修飾キー無視。

### 2.4 仕様変更として明記する点

| 変更 | 内容 |
|---|---|
| 設定ウインドウ | Cancel 全ロールバック(§6.3)→ **即時反映**(SwiftUI Settings 標準)+「既定に戻す」ボタン |
| フルスクリーン | 疑似(hidesOnDeactivate)→ ネイティブ。esc で解除、3 勘所(§13.2)は再現 |
| マウスクリックのモード解決 | fitScreenMode 3 のとき Mode2 参照(§5.3)→ キーと同じ Mode3 参照に統一 |
| フィルタ適用対象 | ビュー全体 → ページ画像のみ |
| シャッフル | 非決定的比較器 → Fisher-Yates(シャッフル順の再現性はもともと保証されていない) |
| 保存タイミング | ⌘Q 時にも本の状態を保存(§7.7 の穴を塞ぐ) |

---

## 3. 新実装のモジュール構成

```
CooViewer/
├── App/
│   ├── main.swift                  — NSApplication 起動
│   ├── AppDelegate.swift           — ライフサイクル・openFile・Dock
│   └── MainMenuBuilder.swift       — メニューバー構築(タグ/セレクタ方式。
│                                     動的リネーム Next↔Previous は仕様維持 §8.3)
├── Core/
│   ├── Source/
│   │   ├── BookSource.swift        — プロトコル: 页列挙・画像取得・パスワード
│   │   ├── FolderSource.swift      — フォルダ走査(readSubFolder 意味論 §4.1)
│   │   ├── ArchiveSource.swift     — XADMaster ラッパ(エンコーディング検出込み)
│   │   └── PDFSource.swift         — PDFKit(ページ毎独立レンダリング)
│   ├── Book/
│   │   ├── Book.swift              — 開いている本(ページ列・ソート適用済み)
│   │   ├── PageLayout.swift        — 見開き合成判定(marks + 740 比率 §4.2)
│   │   └── Navigator.swift         — ページ遷移状態機械(loopCheck・同フォルダ・
│   │                                 サブフォルダ・しおり移動)
│   ├── Cache/
│   │   ├── PageCache.swift         — actor + NSCache(デコード済み CGImage)
│   │   └── Prefetcher.swift        — 方向連動先読み(Task キャンセルで §4.6 の
│   │                                 順序保証を再現、ビジーウェイト排除)
│   └── Sort/
│       └── NaturalSort.swift       — finderCompareS 互換(§4.4.3)+ SortMode
├── Input/
│   ├── ActionCatalog.swift         — 全アクション enum(キー 0-52/マウス 0-64 →
│   │                                 意味名。旧番号は移行専用の rawValue 対応表)
│   ├── Binding.swift               — Codable モデル(キー/マウス/ジェスチャ、
│   │                                 modifier 符号化の型安全表現)
│   ├── BindingResolver.swift       — モード別解決順(§5.3)+ switchAction(§5.4)
│   └── InputDispatcher.swift       — NSEvent → アクション実行
├── UI/
│   ├── Reader/
│   │   ├── ReaderWindowController.swift
│   │   ├── ReaderView.swift        — layer-backed NSView。1/2 ページ配置・
│   │   │                             スケール計算(§4.9)・スクロール端判定・回転
│   │   ├── PageBarView.swift       — ページバー+ホバーバブル+クリックジャンプ
│   │   ├── LoupeOverlay.swift
│   │   └── OverlayText.swift       — ページ番号/情報表示
│   ├── Thumbnails/ (SwiftUI)
│   ├── Bookmarks/  (SwiftUI)
│   └── Settings/   (SwiftUI)       — タブ構成は旧ペイン(§6)を整理統合
├── Persistence/
│   ├── SettingsStore.swift         — 型付き UserDefaults ラッパ(新キー体系)
│   ├── BookSettingsStore.swift     — BookSettings/RecentItems/LastPages
│   │                                 (スキーマ §7.1-7.3 互換、URL ブックマーク)
│   └── LegacyMigration.swift       — 旧 defaults 一括移行(§13.5 マッピング)
└── Resources/
    ├── Assets.xcassets             — アイコン(旧 icns 引き継ぎ)
    ├── Localizable.xcstrings       — ja/en
    └── Credits.rtf                 — XAD クレジット維持(§14.2)
CooViewerTests/                     — NaturalSort・PageLayout・BindingResolver・
                                      LegacyMigration・Navigator のユニットテスト
```

### 3.1 並行性設計(旧 §4.6 の置換)

- UI・Navigator・表示状態は `@MainActor`。
- `PageCache`/`Prefetcher` は actor。先読みは `Task` ベースで、**「大ジャンプ前に先読みをキャンセルして完了を待つ」「表示は先読み結果を待つ」という順序保証のみ**を旧実装から移植する(§13.4)。NSLock+ビジーウェイト+threadStop は持ち込まない。
- 書庫展開(XADMaster)は ObjC 同期 API のため、専用 actor(`ArchiveSource` 内)で直列化。solid rar の逐次展開特性を前提にシーケンシャルな先読みを優先する(§13.4)。

### 3.2 描画設計(旧 §4.9-4.11 の置換)

- ReaderView は layer-backed。ページ毎に CALayer(contents=CGImage)、位置・スケールは CGAffineTransform。補間は `magnificationFilter`、フィルタは CIFilter 配列をページ layer にのみ適用。
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
| 書庫スプール | `ArchiveSource.beginSpooling`: 開いた直後にバックグラウンドで全ページ画像をローカル一時領域(`tmp/cooViewer-spool/<pid>-<uuid>/`)へ**書庫順に逐次展開**。以降のページ取得・サムネイル生成はローカル読み。展開中の要求はオンデマンド経路で応え、1 エントリ毎に譲る | 合計展開サイズ 4GB まで。超過書庫はオンデマンドのみ |
| ページキャッシュ | `PageCache`: デコード済み CGImage の**バイト基準** LRU。メモリ圧迫通知(DispatchSource)で半減トリム | 物理メモリの 15%(上限 2GB)。`PageCacheMegabytes` で明示指定可。旧 `ImageCache`(枚数)は廃止 |
| 先読み | `Book.schedulePrefetch`: 進行方向 12 ページ+逆方向 3 ページ。ジャンプでキャンセル。`supportsParallelPageLoads` なソース(フォルダ)は 4 並列デコード | — |
| 表示解像度キャップ | 表示用デコードは長辺 `displayPixelCap` に制限(縦横比不変のため見開き判定に影響なし)。原寸表示は `fullResolutionImage(at:)` でキャッシュ非経由のフル解像度 | 4096px |
| サムネイル | `ThumbnailCache`: メモリ LRU(400 枚)+ディスク(`Caches/jp.coo.cooViewer/Thumbnails/<bookKey>/`)。bookKey は本のパス+更新日時+サイズ由来で、本の更新でキーごと無効化 | ディスクは 30 日でトリム |

後始末: スプールは ArchiveSource 解放時に削除し、起動時に**生存していない PID の
残骸を掃除**する(旧実装の temp 残り問題 §4.17 の対策)。サムネイルの旧キー
フォルダも起動時トリムで回収する。

## 6. リスクと対策

| リスク | 対策 |
|---|---|
| 入力バインディング移行の取りこぼし(6 配列×modifier 符号化) | 旧スキーマの実データ(§5.7 既定+§7.6 の各版追記)をフィクスチャにした移行ユニットテストを先に書く |
| XADMaster の Swift 連携で未知の穴(例外・スレッド) | ArchiveSource actor で直列化+ObjC 例外を NSException キャッチのブリッジで吸収 |
| 見開き合成・ナビゲーションのエッジケース(§4.2-4.3 の複雑な相互作用) | PageLayout/Navigator を純粋ロジックとして切り出しテーブル駆動テスト |
| 「Tahoe らしさ」と挙動互換の衝突(全画面・設定即時反映) | §2.4 の仕様変更表で明示管理。迷ったら挙動互換を優先 |
| 旧 NSArchiver データ(色/フォント)の読替 | 読めなければ既定値へフォールバック(§13.5 が許容) |
