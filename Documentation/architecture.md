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
| コレクションフォルダの自動オープン | 旧: 画像ゼロのフォルダは開くのを拒否(§4.1.2 手順 3)→ **明示オープン(Finder/ダイアログ/最近使った本)のみ**中の最初の本を自動で開く。次/前の本ナビゲーションではドリルしない: フォルダ自身に着地し(統合または「画像がありません」表示)、兄弟走査の階層を保つ。ドリル候補のサブフォルダは中のどこかに画像/本があるものだけ(パッケージと行き止まりディレクトリは飛ばす)。統合ソース(書庫/PDF 入りフォルダ)が 0 ページの場合は組み立て失敗なのでドリルしない |
| Finder で表示・ファイル情報 | Finder 表示(§4.13)はメニュー(File > Finder で表示 ⇧⌘R)にも追加し、**ページの実体ファイル**(単体画像はその画像、書庫/PDF 内のページは書庫/PDF 本体。BookSource.containerFileURL)を選択表示。**ファイル情報パネル(File > ファイル情報を表示 ⌘I)は新規**: PageFileInfo が ImageIO/FileManager からセクション(概要/画像/EXIF/位置情報/ファイル)を組む。パネルの高さは内容に自動追従(画面の 85% まで、超過時のみスクロール)。EXIF の GPS 座標があるときは MapKit の地図(ピン付き)を末尾に表示 |
| レトロ日本形式 (MAG/MAKI/Pi/PIC) | 旧実装には無い**新規**。RetroImageDecoding(Core)が MAG(MAKI02。16/256 色、パディング/切出し、機種別パレットビット: X68K は機種名文字列でも 5bit 判定、1:2 アスペクト伸長、**MSX2+ YJK スクリーン 10-12** の色変換込み)、MAKI01A/B(640x400 固定、4x4 マスク+XOR フィルタ、パレットは「非 0 上位ニブル \| 0x0F」規則)、**Pi**(デルタ符号 MTF 表+繰り返し列。16/256 色、パレットは RGB 順)、**PIC**(X68000 系: 変化点+チェーン+128 スロット LRU 色キャッシュ。15/16bit と 16/256 色パレット、FM-Towns/汎用 0x1F ヘッダ対応。PC-88VA は対象外)をデコード。**判定は拡張子でなく先頭マジック**— .max(3ds Max)や .pic(Softimage 等)の同拡張子別形式は誤描画しない。ImageIO 失敗時のフォールバックとして ImageDecoding から呼ぶ。**PBM P4**(pbmplus のバイナリ 1bit。ImageIO が P4 のみ非対応)も同経路でデコードし、.pnm 拡張子も登録。**各形式は高度設定タブのトグル(RetroFormatToggle、既定 ON)で個別に無効化可能**(一覧判定 SupportedTypes とデコード両方が参照。反映は次の本から)。検証: 一次仕様(Maki-chan 文書・柳沢氏の PIC 公式仕様)+実サンプル 16 点を公式レンダリング/RECOIL とピクセル照合(テストは RETRO_SAMPLE_DIR 指定時のみゴールデン比較)。PIC2 (.p2) は公式資料(実験版仕様・作者 C ソース・ヘッダ草案 5)を発掘済みだが、最終形式 pic2.x の検証手段が無いため未対応 |
| ウインドウ位置の復元 | サイズは AppKit の frame autosave("ReaderWindow")で常に復元。位置は**終了時(⌘Q/ウインドウクローズ)に記録した画面解像度(screen.frame サイズ、defaults `ReaderWindowScreenSize`)が現在接続中のいずれかの画面と一致するときだけ**復元し、不一致・初回起動時は従来どおり中央に置く(旧実装は "NormalWindow" autosave のみで解像度照合なし。autosave 文字列内の画面欄はメニューバー/Dock 状態に依存するため照合に使わない) |
| 表示モードの永続化と設定 UI | 旧: fitScreenMode は永続化されず毎回 0(全体フィット)で起動(§3.2)→ **defaults `FitMode`(新キー)にグローバル保存**し、次回起動時も復元。設定「表示」ペインのピッカーとメニュー ⌘1-4/キー巡回(action 42/51/52)は同じ値を共有(変更経路は ReaderWindowController.setFitMode に一本化)。方針: メニューにある設定的項目は必ず設定ウインドウにもあり、メニューは頻繁に切り替えるものの抜粋 |
| 表紙の単ページ表示 | 旧実装には無い**新規**(既定オフ)。defaults `SpreadCoverSingle`。ON のとき見開きモードで先頭ページ(表紙)を常に単ページにし、以降を (1,2)(3,4)… で組む(PageLayout.isSmall の coverSingle 判定。marks の強制ペア「1-2」が最優先)。サムネイル一覧の見開きセルも同じ規則で追従。設定「表示」の読み方向直下のトグルと、表示メニュー > 読み方向 > 「表紙を単ページで表示」の両方から切替(即時反映)。ペア判定は §4.2 どおり現在位置から局所的に決まるため、切替の瞬間だけ Book.reanchorToLeadingPartition が先頭起点の区分を歩き直して現在位置を整列させる(途中ページで切り替えても 3-4 → 2-3 のように即座に組み替わる。サイズ未取得ページは縦長とみなし、marks の強制指定は常に優先。検証フラグ `--then-toggle-cover-single`) |
| 設定ウインドウの構成 | 旧: 5 タブの TabView → **macOS のシステム設定風**(サイドバー+検索+詳細、NavigationSplitView。リサイズ可)。ペインは意味で再編: 一般(起動・履歴・記憶)/本(並び順・サブフォルダ・本の端)/表示(読み方向・表紙単ページ・見開きしきい値・表示モード・補間・サムネイル)/ページ番号/ページバー/操作/キー割り当て/デコーダ(高度から独立)/高度(チューニングのみ)。**検索**はペインごとの索引(タイトル+項目ラベル、SettingsSearch)でサイドバーを絞り込み、一致した項目名を行の下に注釈表示。選択ペインは defaults `SettingsSelectedTab`(旧 0-4 の意味を保持し新ペインは 5 以降。検証は `-SettingsSelectedTab n --snapshot-settings`、検索は `-SettingsSearchText 語` で注入)。ペインへ項目を足すときは SettingsView.searchTerms への追加も必須 |
| 書庫の並列展開プール | エントリ独立圧縮の形式(zip/cbz)のみ、ArchiveEntryExtractor(独立 XADArchive の actor)を最大 3 つプールし、未スプールのページ展開をエントリ間で並列化(PDFSource のレンダラープールと同型)。空き再利用が最優先で全員使用中のときだけ成長(直列読みでは 1 つのまま)。エントリ数不一致(差し替え)は成長を止めてメイン書庫の直列展開へ。solid 形式(rar/7z 等)は従来どおり直列 |
| 縮小リサンプルの GPU 化 | 表示ピクセルへの縮小を CoreImage(Metal)の Lanczos で行う(LanczosDownscaler)。従来の CGContext 高品質補間(CPU)はフォールバック。色空間の規則は CG 経路と同一(RGB 以外は sRGB)。CIImage(cgImage:) は CG と同じ向きのため反転補正は不要(色・向きの回帰テストあり) |
| 次スプレッドの事前リサンプル | refreshDisplay 後、進行方向の隣接スプレッド列(Book.predictedAdjacentSpreads が moveNext/movePrevious と同じ規則で予測)を表示ピクセルサイズ(ReaderView.predictedResampleSizes)へ先行リサンプルし、ImageResampler のキャッシュに載せる。めくった直後の最初の描画から等倍のシャープな画像になる。先へ進む量は**メモリ予算内**(PreresamplePolicy: 1 ページの表示サイズ×枚数 ≤ 物理メモリの 1/8・最大 4GB。ページ数上限 64 は小さすぎるページでの保険。ペアは分割しない)。ImageResampler のキャッシュは件数制(8)から**バイト基準 LRU**(物理メモリの 1/6・最大 4.5GB=先読み予算+表示中・ルーペ分の余裕、メモリ圧迫で半減トリム)に変更。現スプレッドのリサンプルと競合しないよう 250ms 遅延+**表示中スプレッドの補間完了を待ってから**積む(ML 実行は actor の FIFO のため、先に並ぶと見開き 2 枚目の表示処理が先読みに抜かれる)。表示要求が来たら先読みタスクを即キャンセルして ML キューを明け渡し(SR はタイル毎にキャンセルを確認)、表示確定後に組み直す。キャンセルされたページは次回の先読みで最初から再計算(完成済みは SR ディスクキャッシュで即復元)。表示世代が進んでいたら残りを捨てる |
| ページめくり効果 | 旧実装には無い**新規**(既定オフ)。defaults `PageTurnAnimation`(0=なし/1=フェード/2=スライド/3=ズームフェード/4=ページカール)。フェード/スライドは CATransition(スライドは読み方向連動: 右→左読みで進むと新ページが左から入る。PageTurnAnimation.entersFromLeft)、ズームフェードは container への軽い拡大+フェード。**ページカール**は本式のめくり: 画面をノド(中央)で左右に分割し、空く側の半面をストリップ列(12 本)として 0→π 回転+外側ほど大きい曲げ角(sin θ 比例)で紙のしなりを表現(piecewise 円筒近似。幾何は PageCurlGeometry の純関数)。リーフの表=旧内容の空く側半面、裏=新内容の着地側半面(実際の紙の裏=次のページ)で、α が π/2 を跨いだストリップから discrete キーフレームで裏面に切替。裏面用の複製は **180° 回転**(水平だけでなく垂直も反転): 裏面描画の向きは机上の行列計算では決められず、**CARenderer による実描画テスト**(PageCurlRenderTests: 実物の ReaderView に実経路のスナップショットを流し、終端の絵=ライブ表示の絵をピクセル比較する自己校正方式)で確定した。リーフは**帯(横割り 24)×ストリップ(縦割り 12)のパッチ格子**で、ストリップ角は α = min(π, θ×(1+curl×外側度)×(1+lead×下端度)) の巻き込み+ねじれモデル(自由端が先に裏返って丸まる Apple Books 風の剥がれ方で、**下の帯ほど先行**して下の角から持ち上がる)。ノイズ対策: ねじれは序盤に集中させ二乗フェードで中盤に 0 へ(帯間の食い違い=階段状の横線を消す)、パッチは 1.2pt 重ねる(丸め由来のヘアラインを消す)。**影はパッチに載せない**(パッチ毎の陰は重なり部分で二重に暗くなり格子が見える。過去実装の反省点): 幾何(ロール頂点の投影 x)に追従する単一レイヤー群 — 投影影(広く柔らかい)+接触影(芯)+綴じ目の陰影+着地側の影。紙の縁ハイライトは不採用: リーフは「画面の半分」でありページ実体より広いため、ページが画面より小さいとき明線が黒背景まで届いて白線ノイズになる(実装後に撤去)。ページ束の表現もユーザー判断で不採用。濃さはいずれも sin θ 比例で始端・終端は消える。キーフレームは 48 分割(120Hz 表示でも補間段差なし)。メモリ圧迫時はオーバーレイ(スナップショット 2 枚)を即時解放。白ページの行輝度走査でシームを検出する実描画テストあり。どの帯も連結はノドから始まるため**綴じは離れない**(リーフ全体の面内回転で角先行を作ると上端がノドから浮く。過去実装の反省点。ノド起点は幾何の単体テストで固定)。角に応じた陰(パッチ毎)と着地側の影も付く。非公開の CATransition "pageCurl" は macOS 26 ではフェードにフォールバックすることをプローブで確認済み(採用不可)。着地側には旧内容を静止表示する。**スナップショットの向きに注意**: flipped ビューの layer を直接 render すると上下逆の像になるため snapshotContent が補正する(この取り違えが「着地側が上下反転」の原因だった。裏面は水平鏡像の複製で正像に戻る)。**スワイプ追従**: 設定がページカールのとき、2 本指スワイプはオーバーレイを speed=0 で組んで timeOffset を指の移動量(350pt でめくり切り)でスクラブする。モデルは追従開始時に先へ進めておき、確定=残り再生、取消=巻き戻してからモデルを戻す(スワイプの向きが次/前ページに割り当てられている場合のみ追従。修飾キー付き・別割当・端到達は従来動作)。オーバーレイ構築は PageCurlOverlay(静止フレーム版 makeStatic がテスト用)。完了時にオーバーレイごと除去。回転表示・ルーペ表示中とリサイズ時は省略/打ち切り。適用はページ送り(次/前/半ページ・スライドショー)のみで、ジャンプ・設定変更の再表示には付けない(ReaderWindowController.pendingTurnForward の消費方式)。「視差効果を減らす」で自動無効。設定「表示」ペインと表示メニューの両方から切替(§7.5 の不変条件)。**めくりに使う絵はフィルタ済みを優先**: 表示前にリサンプル済みキャッシュを照会のみで引き当て(ImageResampler.cached → setPages の preResampled)、命中すれば最初のレイアウト=めくりのスナップショットから完成画像(ML 高画質化込み)が入る(次スプレッドの事前リサンプルが温めているため通常のページ送りはほぼ命中。未命中は従来どおり原画で開始し完成後に差し替え)。検証フラグ `--then-next-page` |
| メニューのキー割当の互換 | 旧 §8.1 のメニューショートカットを踏襲: ⌘, / ⌘O / **⇧⌘O(最後の本)** / ⌘W / ⌘1-4(表示モード)/ **⌘5・⌘6(回転)** / ⌘F(フルスクリーン)/ ⌘M。**編集メニュー**(⌘Z/⇧⌘Z/⌘X/⌘C/⌘V/⌘A、FirstResponder 接続)も旧同様に用意 — 無いとテキスト欄(パスワード・しおり名・ページ番号)でコピペのキーが効かない。旧の ⇧⌘F(フィルタ)は機能ごと見送り(§2.2)。新規追加: ⇧⌘R(Finder 表示)/ ⌘I(ファイル情報)/ ⌘T(サムネイル)/ **⌘L(ルーペ。旧実装はキー l のみでメニューなし。メニューからも切替可、チェックマーク付き)** |
| 補間=描画品質 5 段階(ML 高画質化統合) | 旧「補間」(4 種)と 2.0b16 の「圧縮ノイズ低減」を **UI 上 1 本の「補間」5 段階に統合**: なし(ニアレスト)/標準(高品質縮小)/高(+MetalFX 拡大)/**超高(+waifu2x の ML ノイズ除去)**/**最高(+Real-ESRGAN の ×4 ML 超解像)**(RenderQuality enum。設定「表示」ペインと表示メニュー「補間」の両方から選択・§7.5 の同値性維持。メニュー経由の ML 選択も NSAlert で同意を取る)。**保存は旧互換の 2 キーの組合せ**(SettingsStore.renderQuality): `Interpolation` は旧 0-3 のまま(1.x と共有するドメインに未知値を書かないため。なし→1/標準→0/高以上→3)、ML 段階は `NoiseReductionLevel`(超高→3/最高→4)。読み出しは ML 段階優先、旧「低」(2)は標準扱い(選択肢からは廃止)、旧 CI 弱・中(NR 1-2)は表示上は基礎補間だがパイプラインでは従来どおり効く。f キーのトグル(toggleInterpolationNone)は ML 段階も含めた品質単位で往復。**全ページ対象**(2.0b16 の JPEG 限定は撤廃 — waifu2x/Real-ESRGAN はアニメ・漫画絵全般の高画質化に有効なため)。適用範囲(メイン表示のみ/+ルーペ/原寸も。`NoiseReductionScope`)は ML 段階に対して従来どおり。**超高(waifu2x anime_noise2、MIT、約 1.2MB)**は配布元(imxieyi/waifu2x-mac)から、**最高(Real-ESRGAN x4plus anime 6B、BSD-3-Clause)**は自前 CoreML 変換(`Scripts/convert-realesrgan.py`、fp16 約 9MB、PyTorch パリティ最大誤差 0.003)を**本リポジトリのリリース資産(models-1 タグ)**から、いずれも**初回選択時の同意後・必要時にのみ** DL し SHA-256 ピン照合→コンパイル→Application Support/Models にキャッシュ(同意フラグ `NoiseReductionMLAccepted` / `NoiseReductionSRAccepted`、取得共通処理は MLModelInstaller、状態表示は MLModelInstallStatus.noise / .superResolution)。waifu2x は 128px タイル+7px 文脈で 1 タイル約 2ms(MLNoiseReducer)。Real-ESRGAN は入力 [1,3,256,256] の 0-1 → 出力 [1,3,1024,1024]、内容 240px タイル+8px 文脈で 1 タイル約 46ms(MLSuperResolver)。×4 はリサンプル前段で行い後段の表示縮小で画質向上を得る設計のため、**等倍系(ルーペ・原寸)は超高へ格下げ**(cappedForOriginalSize)し、**長辺 2048px 超の元画像も超高へフォールバック**。タイル継ぎ目は「マージン捨て」だけでは不十分(GAN は平坦部のトーンがタイル毎に Δ1-2 階調揺れ、帯として見える。実測): 右・下へ margin 分を余計に書き、次のタイルが**線形フェザーで合成**+8bit 量子化の残段差は **Bayer 8×8 の秩序ディザ**で分散(いずれも決定的処理)。×4 結果は HEIC でディスクキャッシュ(Caches/jp.coo.cooViewer/SuperRes/、キー=リサンプルキー+元サイズの SHA-256、サムネイルと同じ保持日数で起動時トリム)。未導入・失敗・XCTest 時は 1 段ずつフォールバック(最高→超高→中相当の CI)。メイン表示は ImageResampler のリサンプル前段で適用しレベル込みのキーでキャッシュ(事前リサンプルも同一条件)、ルーペは超解像前、原寸はフル解像度デコード後に適用 |
| オープン進捗表示 | 旧実装には無い**新規**。開くのに 0.35 秒を超えたら中央に HUD(スピナー+「“名前” を開いています…」)。統合ソースの組み立て中は「書庫 n/m」の進捗を併記(NestedFolderSource の進捗コールバック)。ドリルダウン中は畳まず引き継ぐ |
| 自動更新 | 旧実装には無い **Sparkle 2** による自動更新を追加(2.0b3〜)。フィードは master の `appcast.xml`(raw URL)、更新 zip は EdDSA 署名。フレームワークは公式バイナリ配布をバージョン+SHA-256 固定で取得(`Scripts/fetch-sparkle.sh`)。検証スナップショット実行(`--snapshot`)ではアップデーターを起動しない |

---

## 3. 新実装のモジュール構成

```
CooViewer/
├── App/
│   ├── main.swift                  — NSApplication 起動
│   ├── AppDelegate.swift           — ライフサイクル・文書オープン・起動時キャッシュ掃除・
│   │                                 Sparkle 自動更新・検証用スナップショット引数
│   │                                 (development-guide.md 参照)
│   └── MainMenuBuilder.swift       — メニューバー構築(しおり/最近使った本の
│                                     サブメニューは NSMenuDelegate で動的再構築)
├── Core/
│   ├── Source/
│   │   ├── BookSource.swift        — プロトコル+既定実装+BookSourceFactory
│   │   ├── FolderSource.swift      — 不変・並列。フォルダ走査(readSubFolder §4.1)
│   │   ├── ArchiveSource.swift     — actor。XADMaster ラッパ+ローカルスプール+
│   │   │                             書庫内書庫/PDF のネスト統合(§5)
│   │   ├── PDFSource.swift         — actor。PDFKit(ページ毎独立レンダリング+
│   │   │                             レンダラープールで並列化)
│   │   ├── NestedFolderSource.swift — actor。フォルダ内書庫/PDF の合本(組み立ては
│   │   │                              幅 4 並列、登録は候補順に直列)
│   │   └── NestedUnlocker.swift    — actor。ネスト書庫のパスワード解除係(1 冊で共有)
│   ├── Book/
│   │   ├── Book.swift              — @MainActor。ページ列・現在位置・見開き(§4.2)・
│   │   │                             ナビゲーション・先読み・サイズ索引
│   │   ├── PageLayout.swift        — 見開き合成判定(marks + 740 比率+表紙単ページ)
│   │   └── ReadMode.swift
│   ├── Cache/
│   │   ├── PageCache.swift         — actor。バイト基準 LRU+メモリ圧迫トリム(§5)
│   │   └── ThumbnailCache.swift    — actor。メモリ+ディスク(HEIC)、
│   │                                 世代一致の待ち手管理・失敗記録
│   ├── Rendering/
│   │   ├── ImageResampler.swift    — 表示ピクセルへの事前リサンプル(§5 描画品質)+
│   │   │                             ノイズ低減の振り分け(最高→強→CI)
│   │   ├── MetalFXUpscaler.swift   — MetalFX Spatial 拡大(RGBA 正規化+段階適用)
│   │   ├── NoiseReduction.swift    — レベル/適用範囲 enum+CINoiseReduction(弱・中)
│   │   ├── MLModelInstaller.swift  — ML モデルの DL・SHA 照合・コンパイル・ロード共通処理
│   │   ├── MLNoiseReducer.swift    — 強: waifu2x ノイズ除去(CoreML、128px タイル)
│   │   ├── MLSuperResolver.swift   — 最高: Real-ESRGAN ×4 超解像(CoreML、240px タイル
│   │   │                             +フェザー合成+ディザ、HEIC ディスクキャッシュ)
│   │   └── DisplayCapPolicy.swift  — ウインドウ実寸に応じたデコード上限(1024 刻み)
│   ├── Sort/PageSorter.swift       — 自然順ほか SortMode 全種(§4.4.3)
│   ├── ImageDecoding.swift         — ImageIO デコード(HDR ゲインマップ・SVG・
│   │                                 レトロ形式へのフォールバック)
│   ├── RetroImageDecoding.swift    — MAG/MAKI/Pi/PIC/PBM P4 の独自デコーダ
│   │                                 (先頭マジック判定・形式別トグル)
│   ├── AnimatedImage.swift         — アニメ画像の全フレーム読込
│   ├── SupportedTypes.swift        — 対応拡張子の判定(書庫・分割書庫・画像)
│   ├── MediaProfile.swift          — 置き場所の速度別ポリシー表+SourceReadGate
│   ├── MediaSpeedProbe.swift       — ボリューム速度判定(statfs/IOKit/実測)
│   └── PageFileInfo.swift          — ファイル情報パネルの内容組み立て(EXIF/GPS)
├── Input/
│   ├── ReaderAction.swift          — 全アクション enum(旧番号 §5.5-5.6 は移行用対応表)
│   ├── Bindings.swift              — 旧 6 配列互換の読み書き・解決順(§5.3)・
│   │                                 switchAction(§5.4)・既定バインディング
│   └── ActionNames.swift           — 表示名(設定のバインディング編集用)
├── UI/
│   ├── Reader/
│   │   ├── ReaderWindowController.swift(+Input/+Library/+Thumbnails 拡張)
│   │   │                           — 開くフロー・表示更新・入力ディスパッチ・
│   │   │                             付随機能・ページ番号/バーの配置と自動隠し・
│   │   │                             オープン進捗 HUD・ウインドウ位置復元
│   │   ├── ReaderView.swift        — layer-backed。1/2 ページ配置・フィット・回転・
│   │   │                             内部スクロール端判定・リサンプル差し替え・
│   │   │                             アニメ再生
│   │   ├── PageBarView.swift       — ページバー(色・進捗・クリック/ホバー)
│   │   ├── LoupeController.swift   — ルーペ(オーバーレイ CALayer 方式+超解像)
│   │   ├── FileInfoView.swift      — ファイル情報パネルの描画(地図含む)
│   │   └── PlaceholderImage.swift  — 壊れページ等の実行時生成プレースホルダ
│   ├── Thumbnails/ (SwiftUI)       — ThumbnailOverlayModel / ThumbnailOverlayView /
│   │                                 ThumbnailGridLayout(ウインドウ内オーバーレイ §4.8)
│   ├── Bookmarks/ (SwiftUI)        — BookmarkEditorView(しおり編集シート §4.7.2)
│   └── Settings/ (SwiftUI)         — SettingsView(システム設定風サイドバー+検索。
│                                     9 ペイン)+ SettingsSearch + KeyBindingsPane
├── Persistence/
│   ├── SettingsStore.swift         — 型付きアクセサ。旧キーを直接読み書きし、色/
│   │                                 フォント等の旧 NSArchiver データは読み替え(§13.5)
│   └── BookHistoryStore.swift      — 本ごとの状態の v2 ストア(1 冊 1 JSON+
│                                     recents.json。旧キーは初回に一括インポート)
└── Resources/
    ├── Localizable.xcstrings       — ja/en
    ├── Credits.rtf                 — XAD クレジット維持(§14.2)
    └── AppIcon.icon ほか
CooViewerTests/                     — ソート・ソース(スプール/暗号化 zip/ネスト含む)・
                                      Book・バインディング移行・履歴・キャッシュ・
                                      リサンプル/MetalFX 色回帰・レトロデコーダ・
                                      メディアプロファイル・設定・設定検索の
                                      ユニットテスト
```

計画時との主な差分: LegacyMigration の一括移行方式は「各ストアが旧キーを
そのまま読み書き+新形式へ読み替え」方式を経て、2.0b5 で本の状態のみ
v2 ストア(BookHistoryStore)へ一括インポート方式に変更(§13.2 のキー互換は
UserDefaults 側でそのまま成立)。アイコンは Assets.xcassets ではなく
Icon Composer の AppIcon.icon。

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
| サイズ索引と動的キャップ | ページ寸法索引(`BookSource.imageSize`: ヘッダのみ・EXIF 回転適用。フォルダ/スプール済み書庫/PDF/ネスト委譲)で**見開き判定をデコードなし**に。後方めくり・巻末ジャンプはデコードゼロ、確定した見開きは両ページ**並列取得**。寸法不明時は従来のデコード判定へフォールバック。表示デコード上限は fitToScreen のみウインドウ実寸の 1024 バケット(最低 2048)、noScale/fitWidth 系はユーザー上限。上げ方向はキャッシュ破棄+再デコード(飛行中の旧キャップ結果はキャッシュ照合で棄却)。書庫の並列先読みは「全スプール済み or 非 solid 形式」のみ動的に許可(solid ストリームの巻き戻し防止)。フォルダ内書庫は幅 4 で並列オープン(解錠は直列チェーンで多重ダイアログなし) | |
| デコード並列化 | Apple Silicon 前提の最適化(2.0b6): 書庫の**デコードは actor 外**(展開・スプールと並行)、フォルダの読み取りゲートは I/O のみ(デコードはゲート外で多コア並列)、Book はページデコードの**単一飛行**(表示要求が先読みの進行中デコードに合流し二重デコードなし)、スプール読みはメモリマップ、アニメ判定は静止画を記録して再判定せず+デコードはメイン外、リサンプルのデバウンスはライブリサイズ中のみ、同フォルダ一覧は 5 秒キャッシュ、applySettings は runloop 単位で一括。XADMaster は -O2+ThinLTO+現行ターゲットでビルド(フラグ版スタンプで再ビルド制御) | |
| 表示サイズ連動デコード | Apple Silicon 前提の最適化(2.0b6 続)。**PDF レンダラープール**: `PDFPageRenderer` actor(各自が独立の `PDFDocument` を保持、パスワードは解除時に引き継ぎ、ページ数一致を検証)で並列レンダリング。空きレンダラーの再利用が最優先で全員使用中のときだけ最大 3 まで成長(直列読みなら 1 つのまま)。ロック中は作らず、作成失敗/ページ数不一致は成長を恒久停止してメイン文書直列描画へフォールバック。アニメーションはウインドウ拡大が読み込みキャップを 1.25 倍超えたら再デコード(バケット内リサイズ対応)。**アニメーション**は表示枠ピクセル(`pageFramePixelSize`)を上限にデコード(GIF/APNG の原寸フレーム常駐をやめる。上限 2048 は維持)。**HDR** はゲインマップ検出時にまず表示キャップ付き HDR デコード(`kCGImageSourceDecodeToHDR` + ThumbnailMaxPixelSize)を試し、>8bit で得られたときのみ採用(8K 半精度フル解像度のキャッシュ占有を防止)。**MetalFX** は入力が既知の RGBA8 なら正規化再描画を省略し、出力は malloc バッファへ直接レンダリングして CGImage に所有権ごと渡す(全画素コピー 2 回削減) | |
| メディア速度適応 | `MediaSpeedProbe` が本を開くとき置き場所を判定(statfs でネットワーク → IOKit の Medium Type で SSD/回転 → 不明なら 16MB/250ms 上限の実測ベンチ。結果はマウントポイント単位でセッションキャッシュ)。`MediaProfile` の方針表: **fastLocal**=zip 系スプール省略(solid 系と分割書庫はスプール)・フォルダ読み 6 並列・サムネイル 6 並列 / **slowLocal(HDD)**=全スプール・読み 2 並列・先読み 16/4 / **network**=全スプール・読み 3 並列・先読み 20/4 / **unknown**=従来動作と同一。フォルダの本は `SourceReadGate` で全読者(サムネイルのセル読み含む)の同時読み取りを制御。整合規則は「**明示は自動に勝つ**」: 先読み深さの適応は高度設定 OFF のときのみ(ON では明示値)、書庫スプールは「高度」タブの三択(自動=メディア速度で判断/常に行う/行わない)が最優先(自動調整 OFF でも明示は有効)。「メディア速度に応じた自動調整」(既定 ON)で判定自体を無効化可 | プローブは開くフローと並行実行・時間バジェット付き |
| ページキャッシュ | `PageCache`: デコード済み CGImage の**バイト基準** LRU。メモリ圧迫通知(DispatchSource)で半減トリム | 物理メモリの 15%(上限 16GB)。高度な設定 ON のときのみ `PageCacheMegabytes`(MB 直指定)>メモリ%指定で上書き可(OFF では明示指定も無視して標準へ戻る)。旧 `ImageCache`(枚数)は廃止 |
| 先読み | `Book.schedulePrefetch`: 進行方向 12 ページ+逆方向 3 ページ。ジャンプでキャンセル。`supportsParallelPageLoads` なソース(フォルダ)は 4 並列デコード | — |
| 表示解像度キャップ | 表示用デコードは長辺 `displayPixelCap` に制限(縦横比不変のため見開き判定に影響なし)。原寸表示は `fullResolutionImage(at:)` でキャッシュ非経由のフル解像度 | 4096px |
| サムネイル | `ThumbnailCache`: メモリ LRU(400 枚)+ディスク(`Caches/jp.coo.cooViewer/Thumbnails-v2/<bookKey>/<id>.heic`)。v2: PNG → **HEIC**(ハードウェアエンコード、約 1/5 サイズ)。旧 Thumbnails/ は起動時に削除して作り直し。bookKey は本のパス+更新日時+サイズ由来で、本の更新でキーごと無効化 | ディスクは 30 日でトリム |
| 本の状態ストア v2 | `BookHistoryStore`: **1 冊 = 1 JSON**(パスの SHA-256 名)+ recents.json を Application Support に保存。パスから O(1) 参照・移動した本はミス時のみ URL ブックマークで再配置。旧形式(BookSettings/RecentItems/LastPages)は初回起動時に一括インポート変換(しおり 1 始まり文字列 → 0 始まり Int、保存ページは旧探索順を Recents 優先で再現)し、旧キーは 1.x 用に凍結保持。一覧外の本の復元可否は「閉じた時点」の AlwaysRememberLastPage を状態に固定保存(旧 LastPages の write-time 意味論)。消えた本は一覧から飛ばし(削除はしない)、移動した本はミス時のみ URL ブックマーク(マウント・UI 抑止)で再配置して一覧も付け替える | 旧形式の「表示名キー衝突解決+ブックマーク blob 逐次解決+配列全体の defaults 書き直し」を廃止 |

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
補間設定「高」以上では拡大に **MetalFX Spatial**(`MetalFXUpscaler`。2 倍超は
テクスチャのまま段階適用、非対応環境は CG フォールバック)。補間(描画品質)
5 段階の意味: なし=nearest / 標準=高品質縮小 / 高=+MetalFX 拡大 /
超高=+waifu2x の ML ノイズ除去 / 最高=+Real-ESRGAN の ×4 ML 超解像
(ML の詳細は §2.4 の統合行を参照。保存は旧互換 2 キーの組合せ)。
注意: MTKTextureLoader は premultipliedFirst 系 CGImage のバイト順を誤読する
ため、入力は必ず RGBA 正規化してから渡す(色化けの回帰テストあり)。
表示中スプレッドの読み込み〜リサンプル完成待ちの間は、ページバーの横に
同じ高さの控えめなスピナーを出す(ReaderView.onResampleActivityChanged →
ReaderWindowController.setResampleIndicator。チラつき防止に表示は 250ms
遅延、完了・キャッシュ命中時は出ない。ML 高画質化の初回ダウンロード中も
これが進行表示を兼ねる)。

## 6. リスクと対策

| リスク | 対策 |
|---|---|
| 入力バインディング移行の取りこぼし(6 配列×modifier 符号化) | 旧スキーマの実データ(§5.7 既定+§7.6 の各版追記)をフィクスチャにした移行ユニットテストを先に書く |
| XADMaster の Swift 連携で未知の穴(例外・スレッド) | ArchiveSource actor で直列化+ObjC 例外を NSException キャッチのブリッジで吸収 |
| 見開き合成・ナビゲーションのエッジケース(§4.2-4.3 の複雑な相互作用) | PageLayout/Navigator を純粋ロジックとして切り出しテーブル駆動テスト |
| 「Tahoe らしさ」と挙動互換の衝突(全画面・設定即時反映) | §2.4 の仕様変更表で明示管理。迷ったら挙動互換を優先 |
| 旧 NSArchiver データ(色/フォント)の読替 | 読めなければ既定値へフォールバック(§13.5 が許容) |

---

## 7. 設計指針と横断ルール(コードを読む・書く人向け)

個々の機能表(§2.4)とは別に、コードベース全体を貫く約束事をここにまとめる。
新しい変更はこの指針に沿わせ、外れる場合は本書に理由を書き足すこと。

### 7.1 仕様書駆動

- 挙動はすべて仕様書(legacy-app-analysis.md)を根拠にする。コード中の
  コメントは `仕様書 §n` / `設計書 §n` の形で該当章を引用する。
- 旧実装と意図的に変える挙動は必ず §2.4 の表へ 1 行追加する。
  「なんとなく改善」で挙動を変えない(利用者は旧挙動に最適化されている)。

### 7.2 永続データの互換性

- UserDefaults ドメイン `jp.coo.cooViewer` と旧キー(特にバインディング
  6 配列 `KeyArray*`/`MouseArray*`)は 1.x と互換のまま維持する。
  スキーマを変えるときは §13.5 に対応する移行マッピングが必須。
- 本ごとの状態(しおり・最終ページ・per-book 設定)は v2 ストア
  (`Application Support/jp.coo.cooViewer/BookStates/`、1 冊 1 JSON)。
  旧キー(BookSettings/RecentItems/LastPages)は初回に一括インポートした後
  **1.x 用に凍結保持**し、新実装からは読みも書きもしない。
- 新規の設定キーは既存キーと衝突しない名前にし、未設定時の既定値を
  コード側で保証する(registerDefaults か アクセサの補正)。

### 7.3 並行性

- UI と Book は `@MainActor`。スレッド安全でないライブラリを包むソース
  (XADArchive、PDFDocument)は actor で直列化する。
- 非同期の競合は**世代番号**で守るのが本アプリの定石:
  `openGeneration`(開くフローの連打)、`displayGeneration`(表示更新)、
  `resampleGeneration`(リサンプルの遅延書込)、ThumbnailCache の
  世代付き in-flight。await をまたいだら世代を照合してから状態に触れる。
- 同じ結果を二重に計算しない: Book.inFlightLoads・ThumbnailCache.inFlight の
  「単一飛行+合流」パターンを踏襲する。
- 読み取り I/O は SourceReadGate(メディア速度別の同時数)で絞る。
  ゲートは I/O だけを覆い、CPU デコードはゲート外で並列に行う。

### 7.4 エラーの扱い

- 旧実装の「エラー黙殺方針」(§4.17)を維持する: 開けない本はビープ、
  壊れページは理由入りプレースホルダでページ数を保つ。ダイアログの新設は
  パスワード入力のような対話が必須の場面だけ。

### 7.5 設定の反映

- 設定は即時反映(旧 Cancel ロールバックは廃止)。反映経路は
  「defaults 書込 → UserDefaults.didChangeNotification →
  ReaderWindowController.applySettings(連続書込は 1 回にまとめる)」に
  一本化する。メニューからの変更も同じ defaults を書く。
- **メニューにある設定的項目は必ず設定ウインドウにもある**。メニューは
  頻繁に切り替えるものの抜粋という位置付けを維持する。
- 設定ペインに項目を足したら SettingsView.searchTerms(検索索引)にも足す。

### 7.6 検証とテスト

- ロジック(ソート・見開き判定・バインディング解決・レイアウト・永続化・
  検索など)は必ず CooViewerTests にユニットテストを持つ。
- 見た目の変更はスナップショット CLI(development-guide.md 参照)で
  実画面を確認する。スクリーンショット権限が無くても検証できる。

### 7.7 Apple Silicon 前提の実装選択

- arm64 のみ・macOS 26 以降が前提。ハードウェア HEIC エンコード
  (サムネイルキャッシュ)、MetalFX Spatial(拡大)、EDR(HDR ゲイン
  マップ表示)、多コア並列デコード(読み取りゲートと分離)を積極的に使う。
- 大きなピクセルバッファは所有権移譲(malloc + CGDataProvider の
  releaseData)でコピーを避ける(MetalFXUpscaler・RetroImageDecoding 参照)。

### 7.8 コメント規約

- コメントは**日本語のみ**(英語併記はしない)。挙動が仕様書・設計書に
  由来する箇所は必ず章番号を引用する。
- 「何をしているか」より「なぜそうなのか(仕様・回避したバグ・性能理由)」を
  書く。周辺コードとの関係(誰が呼ぶか・何と競合するか)が自明でない場合は
  それも書く。
