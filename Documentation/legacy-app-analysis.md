# cooViewer 旧アプリ詳細仕様書(レガシーコード完全解析)

> **本書の目的**: cooViewer(Objective-C / Cocoa 製 macOS 漫画・画像ビューア)の完全リライトに先立ち、
> リライト実装者が **旧アプリを起動・解読せずに同等機能を実装できる精度** で旧実装の仕様・挙動・癖を記録する。

| メタ情報 | 内容 |
|---|---|
| 調査日 | 2026-08-07 |
| 調査対象コミット | `f572957`(ブランチ `modernize/macos26`) |
| 対象バージョン | cooViewer 1.2b25(CFBundleVersion、CFBundleShortVersionString は存在しない) |
| バンドル ID | `jp.coo.cooViewer` |
| 調査方法 | サブシステム別の並列コードリーディング(controller-core / controller-input / preferences / image-loader / rendering / panels / remote-misc / resources / manual / build-system)+ NSUserDefaults キー全走査 + 公式マニュアル(docs/manual.html)との照合 + 追加深掘り調査(ループ・バッファリング・スレッド・永続化・エンコーディング等 16 テーマ) |
| 表記規約 | 根拠は `ファイル名:行番号` で示す。整数モード値は必ず「値→意味」対応表で示す。矛盾する調査結果は両論併記し **「要実機確認」** と明記する |

---

## 目次

1. [概要と全体像](#1-概要と全体像)
2. [対応フォーマットと文書タイプ](#2-対応フォーマットと文書タイプ)
3. [画面・ウインドウ構成](#3-画面ウインドウ構成)
4. [機能詳細](#4-機能詳細)
5. [入力システム](#5-入力システム)
6. [設定項目と NSUserDefaults 全キー表](#6-設定項目と-nsuserdefaults-全キー表)
7. [永続化](#7-永続化)
8. [メニュー構成](#8-メニュー構成)
9. [リモコン対応](#9-リモコン対応)
10. [ローカライズ](#10-ローカライズ)
11. [ビルドと依存関係](#11-ビルドと依存関係)
12. [既知の癖・バグ・デッドコード](#12-既知の癖バグデッドコード)
13. [近代化に向けたメモ](#13-近代化に向けたメモ)
14. [ライセンスと表記義務](#14-ライセンスと表記義務)

---

## 1. 概要と全体像

### 1.1 アプリケーション概要

cooViewer は「本」(=画像入りフォルダ、zip/rar 等の書庫、PDF、Spotlight 保存検索)を開き、
右→左/左→右の読み方向・単ページ/見開き合成・フルスクリーンで閲覧する画像ビューア。
UI 文字列・コメント・README は日本語中心。ARC 不使用(全ソース MRC)、nib 時代の設計を xib 化したもの
(cooViewer.xcodeproj/project.pbxproj、CLAUDE.md)。

特徴的な設計判断:

- **単一 Controller 集中型**: `Controller`(NSObject)が NSApp delegate・window delegate・ページナビゲータ・キャッシュ管理・メニュー動的構築を全て兼ねる。MainMenu.xib 内でインスタンス化される(Base.lproj/MainMenu.xib:29-47)。
- **完全ユーザー設定可能な入力系**: キー/マウス/ジェスチャ/Apple Remote が全て「バインディング辞書配列」(NSUserDefaults)経由でディスパッチされる(Controller_input.m 全域)。
- **Carbon AliasHandle による永続ファイル参照**: 本の履歴・設定・最終ページは alias(NSData)+ temppath(文字列)の二重キーで保存し、ファイル移動・リネームを追跡する(Controller.m:3141-3470)。
- **手作りスレッド同期**: 先読みは NSLock 1 本+ threadStop/threadCount フラグ+メインスレッドのビジーウェイトという独自プロトコル(Controller.m:39, 1231-1379, 1686-1714)。

### 1.2 アーキテクチャ図(テキスト)

```
                         MainMenu.xib(全ウインドウ・全コントローラを 1 枚に内包)
  ═══════════════════════════════════════════════════════════════════════════════════
                                        │ nib インスタンス化
                                        ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  Controller  (NSApp delegate / CustomWindow delegate / 中枢)                  │
  │  Controller.m      : 起動・移行・本を開く・表示・キャッシュ・永続化・メニュー   │
  │  Controller_input.m: (Input カテゴリ) 全入力ディスパッチ・ページ移動プリミティブ│
  └───┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬────────┘
      │          │          │          │          │          │          │
      ▼          ▼          ▼          ▼          ▼          ▼          ▼
  ┌────────┐ ┌────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌────────┐ ┌──────────┐
  │COImage │ │Custom  │ │Thumbnail│ │Bookmark │ │Preference│ │FullImage│ │FilterPanel│
  │Loader  │ │Window  │ │Controller│ │Controller│ │Controller│ │Panel/  │ │Controller │
  │(本 1 冊)│ │+Custom │ │+Matrix  │ │+Panel   │ │(設定画面)│ │View    │ │(CIフィルタ)│
  │        │ │ImageView│ │+Panel   │ │         │ │          │ │(原寸)  │ │           │
  └───┬────┘ └───┬────┘ └─────────┘ └─────────┘ └──────────┘ └────────┘ └───────────┘
      │          │
      │          ├─ AccessoryWindow + AccessoryView(透明子ウインドウ: ページバー/番号/pageMover)
      │          ├─ lensWindow + LoupeView(透明子ウインドウ: ルーペ)
      │          └─ NSScrollView(fitScreenMode 1/2/3 のときのみ動的に着脱)
      │
      ▼
  ┌───────────────┐   ┌──────────────┐   ┌───────────────────────────────┐
  │ XADWrapper    │──▶│ XADMaster.fw │──▶│ UniversalDetector.fw          │
  │ + XADItem     │   │ (書庫展開)    │   │ (ファイル名エンコーディング判定)│
  └───────────────┘   └──────────────┘   └───────────────────────────────┘
  ┌───────────────┐   ┌──────────────────────────────────────────────────┐
  │ COPDFImage    │──▶│ PDFKit / Quartz(弱リンク)                        │
  │ +COPDFImageRep│   │ NSPDFImageRep 派生 + PDFAnnotationLink 抽出      │
  └───────────────┘   └──────────────────────────────────────────────────┘
  ┌────────────────────────────────────────────────────────────────────┐
  │ RemoteControl / HIDRemoteControlDevice / AppleRemote /             │
  │ MultiClickRemoteBehavior(Apple Remote スタック、IOKit/Carbon)      │
  │ (KeyspanFrontRowControl / GlobalKeyboardDevice は未使用デッドコード)│
  └────────────────────────────────────────────────────────────────────┘
```

データフロー(1 ページ進む場合の典型):

```
入力(キー/マウス/リモコン)
  → Controller_input.m: バインディング配列検索(fitScreenMode 別 → mode0 フォールバック)
  → [lock lock];[lock unlock];(先読みスレッド完了待ち) → useComposedImage=YES
  → Controller.m: imageDisplay → lockedImageDisplay
      → imageMutableArray からページ取り出し(空ならビジーウェイト)
      → isSmallImage 判定 → 見開きなら composeImage / 事前合成 composedImage
      → [imageView setImage:/setImages:] → AccessoryView 更新
      → detachNewThreadSelector: lookahead(AndCompose)(次ページ先読みスレッド起動)
```

### 1.3 主要クラス一覧

| クラス | ファイル | 役割 | 根拠 |
|---|---|---|---|
| Controller | Controller.m(~114KB)/ Controller.h | 中枢。app/window delegate、開く・表示・キャッシュ・永続化・メニュー | Controller.m:32-3541 |
| Controller (Input) | Controller_input.m | 全入力ディスパッチ、ページ移動プリミティブ、スライドショー、ゴミ箱 | Controller_input.m 全域 |
| COImageLoader | COImageLoader.m | 本 1 冊の抽象化(フォルダ/書庫/savedSearch/PDF)。index→NSImage | COImageLoader.m:55-579 |
| XADWrapper / XADItem | XADWrapper.m / XADItem.m | XADMaster の XADArchive ラッパ | XADWrapper.m:15-171 |
| COPDFImage / COPDFImageRep | COPDFImage.m / COPDFImageRep.m | PDF ページの NSImage 化+リンク注釈抽出 | COPDFImageRep.m:42-93 |
| CustomWindow | CustomWindow.m | 疑似フルスクリーン・メニューバー隠し・カーソル自動非表示・キー転送 | CustomWindow.m:6-235 |
| CustomImageView | CustomImageView.m | ページ描画・配置計算・回転・入力受付・PDF リンク・ルーペ管理 | CustomImageView.m:13-1825 |
| AccessoryWindow / AccessoryView | AccessoryWindow.m / AccessoryView.m | 透明子ウインドウ上のページバー/ページ番号/情報表示/pageMover | AccessoryView.m:26-930 |
| LoupeView | LoupeView.m | ルーペ描画(回転・見開き境界またぎ対応) | LoupeView.m:12-223 |
| ThumbnailController / Matrix / Panel | ThumbnailController.m ほか | サムネイル一覧(NSMatrix、疑似非同期充填) | ThumbnailController.m:25-1503 |
| BookmarkController / BookmarkPanel | BookmarkController.m | しおり編集シート+全書籍しおり編集モーダル | BookmarkController.m:10-704 |
| FullImagePanel / FullImageView | FullImagePanel.m / FullImageView.m | 原寸表示ウインドウ | FullImagePanel.m:16-203 |
| PreferenceController | PreferenceController.m | 設定ウインドウ(4 タブ、モーダル、Cancel で全ロールバック) | PreferenceController.m:909-1625 |
| FilterPanelController | FilterPanelController.m | CIFilter 選択 UI → CALayer.filters 適用 | FilterPanelController.m:11-194 |
| COColorPopUpButton ほか | COColorPopUpButton.m 等 | 色ポップアップ/キー捕捉ビュー/ポップアップ付テキスト等の部品 | COColorPopUpButton.m:1-181 |
| RemoteControl 系 | RemoteControl.m ほか 5 ファイル | Apple Remote スタック(Martin Kahr 版 Remote Control Wrapper) | AppleRemote.m:50-315 |
| NSString_Compare ほかカテゴリ | NSString_Compare.m 等 | Finder 互換ソート・バージョン比較・バインディングソート等 | NSString_Compare.m:5-90 |

### 1.4 中枢概念: nowPage の二重意味(最重要)

`nowPage` は文脈により意味が変わる。**リライト時に最も壊れやすい箇所**。

| 状況 | nowPage の意味 | 根拠 |
|---|---|---|
| 表示処理前 | 次に表示する 0 始まりのページ index | Controller.m:1695 |
| 表示処理後 | 表示済み末尾ページの **1 始まり** 番号(見開きなら後のページ) | Controller.m:1721 |
| 永続化時 | secondImage 有=nowPage-2 / 無=nowPage-1 で 0 始まり先頭ページに変換して保存 | Controller.m:803-807, 2890-2894 |
| アクセサ `-nowPage` | 見開き時は nowPage-1 を返す | Controller.m:3099-3109 |
| しおり(bookmarks の page) | **1 始まり** の文字列。goBookmark で -1 して nowPage へ | Controller.m:2587, Controller_input.m:3046 |
| RecentItems/LastPages の page | **0 始まり** の NSNumber | Controller.m:824 |

---

## 2. 対応フォーマットと文書タイプ

### 2.1 COImageLoader の mode 値

| mode | 意味 | 代入箇所 | 備考 |
|---:|---|---|---|
| -1 | 初期値/エラー(不存在パス、非対応単体ファイル、パスワード断念) | COImageLoader.m:66, 376, 501 | `openPage` は mode<0 で開くのを拒否(Controller.m:733) |
| 0 | ディレクトリ(cvbdl パッケージ含む) | COImageLoader.m:445 | readSubFolder で再帰走査 |
| 1 | (HetimaUnZip 製 zip)**現行ビルドでは代入されないデッド値** | COImageLoader_temp.m のみ | ヘッダコメント「1=zip」は実態と不一致(COImageLoader.h:65) |
| 2 | XADMaster で開く書庫全般(zip/rar/7z/lzh…全部) | COImageLoader.m:386-388 | ヘッダコメント「2=rar」は実態と不一致 |
| 3 | savedSearch(Spotlight 保存検索) | COImageLoader.m:392-396 | MDQuery 同期実行 |
| 4 | PDF | COImageLoader.m:371-376 | COPDFImageRep 共有 |
| 5 | dummy。**条件式(COImageLoader.m:147)に現れるが代入箇所なし=デッド値** | — | — |

### 2.2 fileTypes / archiveTypes の動的生成

- `+fileTypes`: Info.plist の CFBundleDocumentTypes から全 CFBundleTypeExtensions を平坦化 → `[NSImage imageFileTypes]`(単葉画像)と `savedSearch` を除外 → 最後に `pdf` を明示再追加(pdf は imageFileTypes に含まれ一度除去されるため)。結果=「フォルダ・スマート検索・単葉画像以外に直接開ける種別」= 書庫系全拡張子 + cvbdl + pdf(COImageLoader.m:15-36)。
- `+archiveTypes`: fileTypes から `cvbdl` と `pdf` を除いたもの。exe・nds・分割番号拡張子(001 等)も全て mode 2 として XADMaster に渡る(COImageLoader.m:37-48)。
- オープンパネルの allowedFileTypes と同フォルダメニューのフィルタも `+fileTypes` を使用(Controller.m:649-650, 2411)。

### 2.3 CFBundleDocumentTypes 全表(Info.plist:7-1468、全 65 エントリ、全て Role=Viewer)

アーカイブ系(1-52)はアイコン coo_alt.icns、LSTypeIsPackage=false。UTI 宣言は一切なし(旧式拡張子/OSType 宣言のみ)。

| # | タイプ名 | 拡張子 | アイコン/特記 |
|---:|---|---|---|
| 1 | 7-Zip Archive | 7z, 7Z | coo_alt |
| 2 | LhA Archive | lha, lzh, LHA, LZH | coo_alt |
| 3 | StuffIt Archive | sit, sitx, SIT | coo_alt |
| 4 | BinHex File | hqx, HQX | coo_alt |
| 5 | MacBinary File | bin, macbin | coo_alt |
| 6 | Gzip File | gz, gzip, GZ | coo_alt |
| 7 | Gzip Tar Archive | tgz, tar-gz, TGZ | coo_alt |
| 8 | Bzip2 File | bz2, bzip2, bz, BZ2, BZ | coo_alt |
| 9 | Bzip2 Tar Archive | tbz2, tbz, TBZ | coo_alt |
| 10 | XZ File | xz, XZ | coo_alt |
| 11 | XZ Tar Archive | txz, TXZ | coo_alt |
| 12 | Tar Archive | tar, TAR | coo_alt |
| 13 | GNU Tar Archive | gtar | coo_alt |
| 14 | Unix Compress File | z, Z | coo_alt |
| 15 | Unix Compress Tar Archive | taz, tar-z | coo_alt |
| 16 | LZMA File | lzma | coo_alt |
| 17 | XAR Archive | xar, XAR | coo_alt |
| 18 | ACE Archive | ace, ACE | coo_alt |
| 19 | ARJ Archive | arj, ARJ | coo_alt |
| 20 | ARC Archive | arc, ARC, pak, PAK, spk, SPK | coo_alt |
| 21 | ZOO Archive | zoo, ZOO | coo_alt |
| 22 | LBR Archive | lbr, LBR, lqr, LQR, lzr, LZR | coo_alt |
| 23 | CAB Archive | cab, CAB | coo_alt |
| 24 | Linux RPM Archive | rpm, RPM | coo_alt |
| 25 | ALZip Archive | alz, ALZ | coo_alt |
| 26 | DiskDoubler Archive | dd, DD | coo_alt |
| 27 | Compact Pro Archive | cpt, CPT | coo_alt |
| 28 | PackIt Archive | pit, PIT | coo_alt |
| 29 | Now Compress Archive | now, NOW | coo_alt |
| 30 | Self-Extracting Archive | sea, SEA | coo_alt |
| 31 | Windows Self-Extracting Archive | exe, EXE | coo_alt |
| 32 | CPIO Archive | cpio | coo_alt |
| 33 | Gzip CPIO Archive | cpgz | coo_alt |
| 34 | Pax Archive | pax, PAX | coo_alt |
| 35 | HA Archive | ha, HA | coo_alt |
| 36 | Amiga Disk File | adf, ADF | coo_alt |
| 37 | Compressed Amiga Disk File | adz, ADZ | coo_alt |
| 38 | Amiga DMS Disk Archive | dms, DMS | coo_alt |
| 39 | Amiga LhF Archive | f, F | coo_alt |
| 40 | Amiga LZX Archive | lzx, LZX | coo_alt |
| 41 | Amiga DCS Disk Archive | dcs, DCS | coo_alt |
| 42 | Amiga PackDev Disk Archive | pkd, PKD | coo_alt |
| 43 | Amiga xMash Disk Archive | xms, XMS | coo_alt |
| 44 | Amiga Zoom Disk Archive | zom, ZOM | coo_alt |
| 45 | Amiga PowerPacker File | pp, PP | coo_alt |
| 46 | NSA Archive | nsa, NSA | coo_alt |
| 47 | SAR Archive | sar, SAR | coo_alt |
| 48 | Split File | 001〜049(ゼロ埋め 3 桁 49 個) | coo_alt。63 の RAR 000〜099 と重複 |
| 49 | Java Archive | jar, JAR | coo_alt |
| 50 | Comic Book Zip Archive | cbz, CBZ | coo_alt。**#60 と二重宣言** |
| 51 | Comic Book Rar Archive | cbr, CBR | coo_alt。**#61 と二重宣言** |
| 52 | Nintendo DS ROM file | nds, NDS | coo_alt |
| 53 | ComicViewer Comic | cvbdl | coo_cvbdl。OSType `CHcd`、**唯一 LSTypeIsPackage=true** |
| 54 | BMP Image | bmp | coo_bmp |
| 55 | TIFF Image | tiff, tif | coo_tiff |
| 56 | PNG Image | png | coo_png |
| 57 | GIF Image | gif | coo_gif |
| 58 | JPEG Image | jpg, jpeg | coo_jpeg |
| 59 | PDF Document | pdf | coo_pdf |
| 60 | CBZ Archive | cbz | coo_cbz(#50 の先勝ちでシャドウされる) |
| 61 | CBR Archive | cbr | coo_cbr(同上) |
| 62 | ZIP Archive | zip, ZIP, z01, Z01 | coo_zip |
| 63 | RAR Archive | rar, RAR, r00〜r99, R00〜R99, 000〜099(計 304 拡張子) | coo_rar |
| 64 | SavedSearch | savedSearch | アイコンなし |
| 65 | directory | (拡張子なし) | OSType `fold`、LSItemContentTypes=public.directory |

### 2.4 対応形式に関する注意

- 単葉画像ファイル(PDF 以外の NSImage 対応拡張子)を開くと、**親フォルダを本として開いて該当ページへジャンプ** する(Controller.m:720-728, 966-969)。
- 隠しファイル・AppleDouble(`._*.jpg`)・`__MACOSX` 配下の除外処理は **一切ない**。拡張子が合えばページ化され broken.png 表示になり得る(COImageLoader.m:444-473)。
- 書庫内の書庫/PDF は mkdtemp した一時ディレクトリ(`NSTemporaryDirectory()/cooViewer.XXXXXX`)へファイル展開し、ネストした COImageLoader を生成する(COImageLoader.m:518-530, 548-579)。通常の画像エントリはファイル展開せず表示のたびに全量メモリ展開(キャッシュなし。solid rar では都度再解凍)。
- 公式マニュアル(docs/manual.html:76-77)が明示する対応形式は「フォルダ・zip・rar」のみ。PDF・パスワード書庫・savedSearch・Apple Remote・ルーペはコードに存在するがマニュアル未記載。

---

## 3. 画面・ウインドウ構成

### 3.1 ウインドウ/パネル一覧(全て MainMenu.xib 内で定義)

| ウインドウ | クラス | xib id | 概要 | 根拠 |
|---|---|---|---|---|
| Viewer(メイン) | CustomWindow | 21 | 480x360、titled/closable/mini/resizable、**hidesOnDeactivate=YES**、releasedWhenClosed=NO、起動時非表示。contentView に CustomImageView + スピナー | MainMenu.xib:9-47 |
| アクセサリオーバレイ | AccessoryWindow | 2809 | borderless 強制・透明・マウス透過。メインの childWindow(NSWindowAbove)。ページバー/番号/pageMover を描画 | AccessoryWindow.m:14-33, CustomImageView.m:38-66 |
| ルーペ | NSWindow+LoupeView | (動的生成) | borderless・透明・ignoresMouseEvents・childWindow。LoupeSize 四方 | CustomImageView.m:1436-1453 |
| サムネイル一覧 | ThumbnailPanel | 1084 | titled+closable+utility、透明背景。ThumbnailMatrix(NSMatrix)+ツールバー帯 | MainMenu.xib:2557-2745 |
| 原寸表示 | FullImagePanel | 772 | utility+resizable。resignKeyWindow で自動クローズ | FullImagePanel.m:16-20 |
| しおり編集 | BookmarkPanel | 561 | シート(現在の本)。name/page テーブル | MainMenu.xib:2019-2182 |
| 全しおり編集 | BookmarkPanel | 983 | モーダル(本を開いていない時)。splitView で本一覧+しおり一覧 | MainMenu.xib:2342-2556 |
| パスワード | NSPanel | 742 | **runModalForWindow のアプリモーダル(シートではない)**。入力欄は通常 NSTextField(平文表示) | Controller.m:1107-1127, MainMenu.xib:2183-2280 |
| 環境設定 | NSPanel | 448 | titled のみ(閉じるボタン無し)。アプリモーダル、OK=128/Cancel=129 | PreferenceController.m:909-1625 |
| キー割当編集 | NSPanel | 520 | 設定のシート。COTextView でキー捕捉 | MainMenu.xib:1905-2018 |
| マウス割当編集 | NSPanel | 1436 | 設定のシート | MainMenu.xib:2746-2921 |
| 位置・サイズ設定 | NSPanel+AccessorySettingView | 2863 | ページ番号/ページバーのドラッグ配置プレビュー | AccessorySettingView.m:16-475 |
| フィルタ | NSPanel(HUD) | EcN-5h-84Q | utility+HUD。CIFilter 選択+IKFilterUIView 積層 | FilterPanelController.m:11-63 |
| 設定整理進捗 | NSPanel | 3296 | Disposing of settings のプログレスシート | PreferenceController.m:1818-1945 |

### 3.2 表示モード(fitScreenMode)

| 値 | メニュー表記 | ⌘キー | 挙動 | ビュー構成 | 根拠 |
|---:|---|---|---|---|---|
| 0 | Fit to Screen(画面内に収める) | ⌘1 | ウインドウ全体にフィット。スクロール不可 | imageView を contentView 直下に配置(NSScrollView なし) | Controller.m:2627-2653 |
| 1 | Fit to Screen Width(横幅に合わせる) | ⌘2 | 幅フィット・縦スクロール | NSScrollView を動的生成し documentView 化 | Controller.m:2655-2690 |
| 2 | No Scale(画面に合わせない) | ⌘3 | 無拡縮(**ポイント原寸**。ピクセル原寸ではない) | 同上 | Controller.m:2729-2760, CustomImageView.m:796-797 |
| 3 | Fit to Screen Width(divide) | ⌘4 | 1 枚の横長画像を「横半分=1 ページ幅」とみなす幅フィット。frame 幅は画面の 2 倍 | 同上 | Controller.m:2692-2727, CustomImageView.m:821-857 |

- 0↔1/2/3 の遷移時に NSScrollView を生成/replaceSubview で除去する(Controller.m:2626-2762)。
- fitScreenMode はキー/マウスのバインディング配列選択のコンテキストも兼ねる(§5.4)。
- 単位系は全て **ポイント**([NSImage size])。pixelsWide を使う正規化コードは全てコメントアウト済みデッドコード(Controller.m:1207-1222, CustomImageView.m:1308-1325)。Retina スケールを扱うコードは存在しない。

### 3.3 疑似フルスクリーン(ネイティブ全画面 API 不使用)

- `setFullScreen:`(CustomWindow.m:35-49): ON でダミー setFrame → `constrainFrameRect:` が `[NSScreen mainScreen] frame`(メニューバーを隠す設定なら **高さ+22px** してメニューバー領域を覆う)を返す方式。resizable=NO で以後の setFrame を無視。hidesOnDeactivate=YES。OFF で autosave 名 "NormalWindow" のフレームを復元。
- 状態は defaults `Fullscreen` に永続化。メニュー Window>Fullscreen の state と同期(Controller.m:2790-2817)。
- **対象スクリーンは常に呼び出し時点の `[NSScreen mainScreen]`(=キーウインドウのあるスクリーン)**。`[self screen]` は使わない。マルチディスプレイでは対象がフォーカス状態依存で不安定(CustomWindow.m:58-82)。
- メニューバー自動表示: mouseExited で「mainScreen frame を y-10 した矩形」の外(=画面上端 10px 帯より上)に出た時のみ表示、mouseEntered で再度隠す。trackingRect は更新のたび削除せず**累積**する(CustomWindow.m:170-198, Controller.m:1034)。
- カーソル自動非表示: フルスクリーン中 mouseMoved から 3 秒の非リピートタイマーで `setHiddenUntilMouseMoves:`。keyDown では即時非表示(CustomWindow.m:103-107, 201-220)。
- フルスクリーン+メニューバー非表示時の ⌘M: performKeyEquivalent が横取りし、メニューバー表示→0 秒タイマーで performMiniaturize(CustomWindow.m:116-139)。
- 非フルスクリーンの constrainFrameRect の画面超過フォールバックは `NSMakeRect(0,0,screen高/4,screen幅/4)` と**縦横が入れ替わっている**(バグと思われる。CustomWindow.m:66)。

### 3.4 アクセサリオーバレイ(ページバー/ページ番号/情報表示/pageMover)

- AccessoryWindow はメインウインドウの contentView と同サイズ・同位置に常時追従(CustomWindow.m:32 → CustomImageView.m:1420-1427)。マウスイベントは受けない描画専用レイヤ。
- **ページバー**: 位置は `PageBarPosition`(0=左上/1=右上/2=左下/3=右下)、寸法 `PageBarSize`。既読部分は進捗率×幅を readFromLeft に応じ左端/右端から塗る。BG/枠/既読色は各 clearColor なら描かない(AccessoryView.m:545-584, 825-860)。上配置時は上端から 17+height+margin+3 下げるマジックナンバーあり。
- **ページバーバブル**: ホバー中、相対位置からページ番号を算出した吹き出しを表示。`PageBarShowThumbnail` 非 0 ならサムネイル画像(ThumbnailController のキャッシュ共用)を最大 200x200 で吹き出し内に表示(AccessoryView.m:252-527)。
- **ページ文字列/情報文字列**: NSAttributedString をカプセル形背景付きで描画(NSAttributedString_Adding.m:15-75)。infoString は 2 秒タイマーで自動消去。`setInfoString` は既存インスタンスに再 init する不正ハック実装(AccessoryView.m:757-814)。
- **自動隠し**: `PageBarAutoHide`/`PageNumAutoHide` が YES のとき mouseMoved で復活+2 秒タイマーで非表示(AccessoryView.m:214-251, 729-755)。
- **pageMover**(ページ番号直接入力): 画面中央の角丸ボックスに入力中の数字を表示。状態は AccessoryView が保持(tempPageNum/pageMover。AccessoryView.m:862-907)。動作は §5.8。

---

## 4. 機能詳細

### 4.1 本を開く

#### 4.1.1 開く経路の全一覧

| # | 経路 | 挙動 | 根拠 |
|---:|---|---|---|
| 1 | `openTheLastPage:`(メニュー/Dock/キー action 48) | 表示中: RecentItems→LastPages を alias 解決で検索し保存ページへ goTo。非表示中: RecentItems[0] を解決して openPage:保存page last:NO | Controller.m:589-622 |
| 2 | `application:openFile:`(Finder/ドロップ) | タイマー停止 → setCurrentBookPathAndOldBookPath → openPage:0 last:NO。**戻り値は成功時も常に NO** | Controller.m:625-636 |
| 3 | `open:`(⌘O、NSOpenPanel) | canChooseDirectories=YES、allowedFileTypes=[COImageLoader fileTypes] | Controller.m:639-665 |
| 4 | `openFromSameDir:`(同フォルダメニュー/次・前の本) | representedObject のフルパスで openPage:0 last:isLast(last:YES 版は前の本を最終ページから開く) | Controller.m:668-678 |
| 5 | `openFromOpenRecent:`(履歴メニュー) | 辞書の alias を解決し、その page 値で openPage:page last:NO | Controller.m:680-686 |

#### 4.1.2 openPage:last:(中核処理、Controller.m:691-1106)の手順

1. window 前面化、progressIndicator 開始。
2. currentBookPath が「NSImage 対応拡張子かつ PDF 以外」なら fromFileName に退避し、**親フォルダを新しい currentBookPath にする**(単一画像→フォルダを開いて該当ページへ)。
3. `COImageLoader initWithPath:readSubFolder:controller:` を生成。失敗条件(nil / !checkPassword / mode<0 / itemCount<1)なら破棄し、表示中なら oldBook* に巻き戻し、非表示なら window performClose。**エラーダイアログは出さない**(Controller.m:733-756)。
4. 成功かつ表示中なら旧本の後始末: cacheArray/screenCacheArray 全消去 → 旧本の BookSettings 保存(§7.1)→ nowPage を -2/-1 補正して RecentItems 先頭挿入 → LastPages 更新(§7.2, 7.3)→ 各配列クリア・imageLoader 解放。
5. setSameFolderMenu、oldBook* 解放。
6. `searchFromBookSettings:more:YES` で currentBookSetting 復元(移動追跡・同名代用ダイアログ込み。§7.5)。
7. goToLastPageMode<2 && !last && page==0 なら RecentItems→LastPages の順で保存ページを探す。GoToLastPage: **0=「%iページに移動しますか」確認 / 1=自動移動 / 2 以上=無効**(page+1 表示。Controller.m:897-920)。
8. RecentItems 先頭に新しい本を挿入(LastPages のエントリ page を再利用)。
9. setOpenRecentMenu し先頭項目を On+disabled、defaults synchronize。
10. imageLoader/completeMutableArray(=`[imageLoader pathArray]` を retain。**ローダー内部配列と同一オブジェクト**)確定。sortMode は currentBookSetting → 無ければ defaults `SortMode`。0 以外なら `setSortMode:page:-1`。
11. fromFileName があれば page=そのファイルの index。
12. `last:YES` なら末尾 2 枚をロードし、[count-2] が isSmallImage==NO なら捨てて nowPage=count-1、小さければ nowPage=count-2(最終見開き)。`last:NO` なら page(範囲外は 0)と page+1 をロードし nowPage=page(Controller.m:963-999)。
13. readMode = defaults `ReadMode` → currentBookSetting の readMode で上書き。marksArray 復元。
14. window title=本名、composedImage 破棄、bookmarkArray 復元、setBookmarkMenu。
15. thumController に imageLoader と ThumbnailCache を設定。
16. progress 停止、updateTrackingRect、viewSet、imageDisplay。
17. サムネイル表示中か `ShowThumbnailWhenOpen` なら showThumbnail(見開きなら nowPage-1)。

#### 4.1.3 パスワード書庫

- 検証: `checkPassword`(COImageLoader.m:330-349)= 先頭エントリの展開を試み、失敗でも `describeLastError` が nil なら正解とみなす緩い判定。
- 入力 UI: `askInArchivePassword:`(Controller.m:1107-1127)。passPanel を **runModalForWindow のアプリモーダル** で表示。誤入力時は再帰的に再表示、キャンセル(129)でのみ脱出。入力欄は NSSecureTextField ではなく **平文表示**(xib id 747)。
- パスワードのバイト列化は XADMaster 側で「ファイル名から検出されたエンコーディング」にフォールバックする。エントリ名が ASCII のみだと cp1252 判定になり **Shift-JIS パスワードが通らない** ケースがある(XADArchiveParser.m:695-698, 1235-1243)。パスワードエンコーディングを選ぶ UI はない。
- サムネイル・先読み経路でパスワードを尋ねることはない(開く時のみ)。

#### 4.1.4 フォルダ監視(applicationDidBecomeActive)

`checkCurrentFolderUpdated`(Controller.m:3493-3541): `ChangeCurrentFolder`(0=確認/1=自動/2=無効)。alias 解決後の親フォルダが文字列上の親と異なる=本が移動された場合、確認の上 setSameFolderMenu:YES。親が同じならフォルダの fileModificationDate と lastSameFolderMenuUpdate を比較して同フォルダメニューのみ再構築。**imageLoader・キャッシュ・nowPage には一切触れない**。

### 4.2 ページ表示と見開き合成

#### 4.2.1 見開き対象判定 isSmallImage:page:(Controller.m:1383-1411)

1. marksArray 非空かつ page>=0 のとき: `"N"`(page 単体)が含まれれば **NO(強制単ページ)**、`"page-(page+1)"` または `"(page-1)-page"` が含まれれば **YES(強制ペア)**。
2. それ以外は `setTemp = singleSetting/1000.0`(既定 740→0.74)と `realTemp = width/height` を比較。**setTemp < realTemp(横長)なら NO、以下なら YES**。
3. 判定は `[image size]`(**ポイント**)の比率。絶対ピクセルではない。異方 DPI 画像でのみ DPI が結果に影響する。

#### 4.2.2 BufferingMode(0=Old / 1=New)の 2 実装

| 観点 | Old(0) | New(1) | 根拠 |
|---|---|---|---|
| 合成方式 | `returnComposeImage` で mainScreen サイズの合成 NSImage を生成し `setImage:` | 合成せず `setImages:` → drawRect が毎描画時に image1/image2 を並置描画 | Controller.m:1413-1547, CustomImageView.m:750-755 |
| screenCacheArray | 使用(合成済み見開きキャッシュ、容量 ScreenCache+2) | 不使用(returnComposeImage が冒頭で nil を返す。設定 UI でも ScreenCache 入力無効) | Controller.m:1416, PreferenceController.m:1639-1645 |
| composedImage(次見開き事前合成) | lookaheadAndCompose 後半で生成・保持 | 常に nil 化のみ | Controller.m:1297-1379 |
| リサイズ/フルスクリーン切替 | メインスレッドで再合成+lookaheadAndCompose | setImages/setImage の再指示のみ | Controller.m:2790-2817, 3004-3021 |
| 既定値 | — | `[NSObject respondsToSelector:@selector(finalize)]` が真なら registerDefaults で 1。**現代の macOS では実質常に 1(New)** | Controller.m:55-58 |
| 備考 | xib に「Old は Retina で正しく動かない」と注記 | — | MainMenu.xib(Advanced タブ) |

#### 4.2.3 returnComposeImage:and:(Old の見開き合成、Controller.m:1413-1547)

- 基準は `[NSScreen mainScreen] frame]`(ウインドウサイズではない)。
- fitScreenMode!=2: 各画像を `rate=min(screenW/2/w, screenH/h)` で拡縮、`maxEnlargement`!=0 なら rate をクランプ。合計幅が画面幅未満かつ fitScreenMode==1 ならさらに `screenW/(w1+w2)` で両方拡大(maxEnlargement 超過なら該当画像を**原寸に戻す**=クランプでない)。fitScreenMode==2 は原寸のまま。高さは 2 枚の最大値、垂直センタリング。
- 補間: 1=None, 2=Low, 3=High, その他=Default。
- 描画順: readMode 0/2 は image1 を左・image2 を右、readMode 1/3 は逆。**呼び出し側は常に image1=後のページ(secondImage)、image2=前のページ** なので、RTL では後ページが左になる。

#### 4.2.4 lockedImageDisplay(表示の中核、Controller.m:1643-1781)

- `imageDisplay` は NSDisableScreenUpdates で囲んで lockedImageDisplay を呼ぶだけ。
- 単ページ系(readMode 2/3): imageMutableArray が空の間 0.0001 秒スリープでビジーウェイト → firstImage=[0] を表示 → nowPage++ → lookahead を detached thread で起動。
- 見開き系(readMode 0/1): isSmallImage([0],page:nowPage+1)==YES なら、2 枚目の到着を threadCount>0 の間 0.001 秒スリープで待つ → 両方 small なら 2 枚確定、nowPage+=2。useComposedImage==YES かつ composedImage 有なら事前合成品を setImage、それ以外は composeImage。ペアにならなければ単ページ表示で nowPage++。最後に lookaheadAndCompose を detached thread で起動。
- 巻末(nowPage==count)到達時は loopCheck 分岐(§4.3.4)。

#### 4.2.5 描画パイプライン(CustomImageView)

- `drawRect:` → 画像なしなら super、あれば補間設定 → 2 ページモードなら drawImages:and:、それ以外 drawImage:。最後にルーペ描画。CPU/Quartz 描画(NSImage drawInRect:)。ビューは layer-backed(setWantsLayer:YES。CustomImageView.m:730-759, 13-25)。
- 配置計算 getDrawImageInfo/getDrawImagesInfo は結果を **NSMutableDictionary に文字列化して受け渡す**(NSStringFromRect/%f/%i。int 切り捨て多数。CustomImageView.m:761-887, 931-1267)。見開き時は contentView の幅高が奇数なら 1px 減らして偶数化してから左右分割(941-948)。
- 左右配置: readFromLeft=YES なら image1(先のページ)が左、NO なら右。描画順は image2→image1(CustomImageView.m:1216-1257)。
- 回転は NSAffineTransform を concat して座標系ごと回転(90/180/270。CustomImageView.m:888-929, 1279-1330)。
- 最大拡大率 maxEnlargement: 単ページ計算では rate を**クリップ**、見開き mode1/3 の最終段では超過時に**等倍へリセット**という非対称挙動(CustomImageView.m:780-782 vs 1051-1068)。

### 4.3 ナビゲーション

#### 4.3.1 「次のページ」はメソッドを持たない

次ページ送りは専用メソッドがなく、`[lock lock];[lock unlock]; useComposedImage=YES; [self imageDisplay];` のインライン列として各所に展開されている(例 Controller_input.m:215-221)。端超え処理も lockedImageDisplay 内(next 側)と prevPage/halfprevPage 内(prev 側)に分散する。

#### 4.3.2 prevPage / halfprevPage(Controller_input.m:2154-2452)

- 先頭到達判定: readMode>1 で nowPage<2、見開き単葉表示中で nowPage<2、見開き 2 葉表示中で nowPage<3。
- 通常時は threadStop 待ち→バッファ消去→nowPage を 2〜4 戻して lookahead → isSmallImage による見開き整列(横長画像は単独表示のため先頭を捨てて nowPage++)→表示。
- Old モード(bufferingMode==0 && screenCache>0)では `imageDisplayIfHasScreenCache` による合成キャッシュの先行表示(ページ文字列に " LoadingOriginals..." 付加)を先に試す(Controller_input.m:2201, 2242, 2271, 2302, 2321)。

#### 4.3.3 goTo / goToPar / goToLast / goToFirst

| メソッド | 挙動 | 根拠 |
|---|---|---|
| `goTo:page array:` | **array 引数は完全に無視(デッドパラメータ)**。page を [0,count-1] にクランプ→バッファ消去→lookahead→imageDisplay | Controller_input.m:2737-2757 |
| `goToPar:par` | page=(int)(count*par)。**上限クランプなし**: par=1.0 で nowPage=count となり巻末処理(loopCheck)に入る | Controller_input.m:2795-2813 |
| `goToLast` | 単=count-1、見開き=count-2 で isSmallImage 整列 | Controller_input.m:2454-2469 |
| `goToFirst` | nowPage=0 | Controller_input.m:2471-2484 |

#### 4.3.4 ループ設定(LoopCheck)4 択の実挙動

UI(設定>一般>「ループ」ポップアップ)のインデックスがそのまま値(PreferenceController.m:1227-1238)。

| 値 | UI 表記 | 前方(巻末超え) | 後方(巻頭超え) | 根拠 |
|---:|---|---|---|---|
| 0 | ループ | nowPage=0 にして先頭へループ | 本の末尾へループ(最終見開き/最終ページ) | Controller.m:1670-1684, Controller_input.m:2154- |
| 1 | 次/前のフォルダ・アーカイブの最初のページへ | nextFolder(次の本を openPage:0) | backFolder(前の本を openPage:0 **ただし GoToLastPage 復元が働き得る**) | Controller.m:1675-1678, Controller_input.m:2571-2641 |
| 2 | 次/前のフォルダ・アーカイブへ | nextFolder(**next 側は 1 と完全同一コード**) | backFolderLast(前の本を last:YES で開く=**必ず末尾から**。GoToLastPage 復元をバイパス) | Controller.m:897(!last 条件), 970-986 |
| 3(else) | しない | 何もしない(スライドショーはタイマー停止) | 何もしない | Controller.m:1680-1683 |

- 1 と 2 の差は **後方時のみ**。前方は同一挙動。
- nextFolder/backFolder は同フォルダメニューの NSOnState 項目を基準に走査し、端では**ラップアラウンド**(フォルダ内最後の本→最初の本)。On 項目が無い場合 nil のまま openFromSameDir が呼ばれる潜在バグあり(Controller_input.m:2571-2641)。
- スライドショー・ホイールめくり・Apple Remote も同じ分岐に合流する。

#### 4.3.5 サブフォルダ移動(nextSubFolder/prevSubFolder)

`imageLoader nextFolder:/prevFolder:` が返すインデックスへ goTo。COImageLoader 側は `stringByDeletingLastPathComponent` の一致で「同じフォルダ」を判定し、巡回探索する(COImageLoader.m:221-307)。引数 now は 1 始まり。PDF は全ページ同一フォルダ扱い。

#### 4.3.6 スキップ(skip/backskip)

キー action 13/14(マウス 5/19/20)。value(既定 10)ページ分移動。skip は `nowPage += value-2` → count 以上なら count-2 に丸め → lookahead → isSmallImage 整列。backskip は `nowPage -= value+2` → 負なら 0(Controller_input.m:374-430)。

### 4.4 ソートと読み方向

#### 4.4.1 readMode(読み方向)

| 値 | 意味 | 表示 | 根拠 |
|---:|---|---|---|
| 0 | Right to Left(右→左、見開き)= 日本式マンガ。**既定値** | 2 ページ合成、後のページが左 | Controller.m:2100-2258 |
| 1 | Left to Right(左→右、見開き) | 2 ページ合成、先のページが左 | 同上 |
| 2 | Right to Left (single)(右→左、単ページ) | 単ページ | 同上 |
| 3 | Left to Right (single) | 単ページ | 同上 |

- `readMode<2` が見開き系、`readFromLeft`(=readMode 1||3)が左綴じ判定(Controller.m:3058-3065)。
- **表記注意**: preferences サブシステム調査は ReadMode 0 を「左開き綴じ」と記述したが、controller-core・マニュアル(r キーのループ順「右から左→左から右→…」docs/manual.html:151)とは「0=右から左」で一致する。0=右→左(右開き相当)を正とするが、「開き」呼称の対応は **要実機確認**。
- 切替: r キー(action 19)で 0→1→2→3→0 巡回。メニューは 4 項目直接選択。changeReadMode は表示中画像をバッファへ戻して nowPage を巻き戻し再表示し、rememberBookSettings 時は本ごとの `readMode` に保存(Controller_input.m:2073-2109)。

#### 4.4.2 sortMode(ソート)

| 値 | 意味 | 比較器 | 条件 | 根拠 |
|---:|---|---|---|---|
| 0 | Name(名前順)。既定 | finderCompareS:(Finder 互換自然順) | 常時 | Controller_input.m:2110-2150 |
| 1 | Shuffle(シャッフル) | randomCompare:(呼び出し毎に再シードするランダム比較器) | 常時 | NSString_Compare.m:28-43 |
| 2 | Creation Date(作成日) | fileCreationDateCompare: | `canSortByDate`(フォルダ/savedSearch かつネスト書庫なし)のみ | COImageLoader.m:159-168 |
| 3 | Modification Date(変更日) | fileModificationDateCompare: | 同上 | 同上 |

- `setSortMode:mode page:p` は **必ず先に finderCompareS で名前順に正規化** してから指定ソートを適用。
- p の意味: **-1=ソートのみ(goTo せず、本ごとの sortMode 保存もしない)**。p>=0 なら rememberBookSettings 時に保存し goTo:p。**全呼び出し箇所が p==0 のため、ソート切替は常に先頭ページへ飛ぶ(nowPage 維持経路は存在しない)**。
- ソート対象の completeMutableArray はローダー内部配列 contentPathArray **そのもの**(共有可変状態)。サムネイル側 pathArray も同一(Controller.m:952, ThumbnailController.m:56)。
- **しおり・最終ページ・marks はすべて並び順依存のページ番号で保存され、ソート変更・シャッフル・ファイル増減のいずれでも再マッピングされない(ズレる)**。sortMode=1 を本ごとに保存すると開くたびに異なるランダム順が生成され、復元ページ・しおりは事実上無意味になる(Controller.m:960-962)。
- Old モードでは screenCacheArray がページ番号キーのままクリアされないため、ソート直後に古い合成見開きが誤ヒットし得る潜在バグ(Controller.m:1554-1579)。

#### 4.4.3 finderCompareS: の照合仕様(NSString_Compare.m:5-26)

Carbon `UCCompareTextDefault` + kUCCollateComposeInsensitiveMask(合成/分解同一視)| WidthInsensitiveMask(全角半角同一視)| CaseInsensitiveMask | DigitsOverrideMask+DigitsAsNumberMask(数字列を数値比較: "page2"<"page10")| PunctuationSignificantMask。**UniChar[1024] のスタックバッファに長さチェックなしでコピーするため、1024 UTF-16 単位超の文字列でスタックオーバーフローする潜在バグ**。近代 API では `localizedStandardCompare:` がほぼ等価。

### 4.5 キャッシュと先読み

#### 4.5.1 キャッシュ 3 種+1

| キャッシュ | 内容 | キー | 容量 | evict | 使用モード | 根拠 |
|---|---|---|---|---|---|---|
| cacheArray | 原寸 NSImage | `name`=フルパス文字列 | **ImageCache+4** | 追加後に先頭(最古)削除。ヒット時末尾へ MRU 移動 | 共通 | Controller.m:1154-1229 |
| screenCacheArray | 合成済み見開き NSImage | `page`="N-M" 文字列+`fitScreenMode` 一致 | **ScreenCache+2** | 同上(imageDisplayIfHasScreenCache だけ MRU 移動しない) | Old のみ | Controller.m:1315-1372, 1611-1641 |
| composedImage | 次見開きの事前合成 1 枚 | — | 1 | ページ操作毎に破棄 | Old のみ | Controller.m:1266-1379 |
| thumImageArray | 縮小済みサムネイル | `page`=index 文字列 | ThumbnailCache | 先頭削除+ヒット時 MRU | 共通 | ThumbnailController.m:73-156 |

- screenCacheArray のキー書式: readMode 0/2 は `"nowPage-(nowPage-1)"`(大-小)、1/3 は `"(nowPage-1)-nowPage"`(小-大)。1 始まり表示番号(Controller.m:1315-1340)。
- fitScreenMode 変更で旧キャッシュはヒットしなくなるが明示破棄されず容量あふれ待ち。**Interpolation/MaxEnlargement 変更時は screenCacheArray を消さないため旧合成が誤再利用され設定が反映されない**(Controller.m:1934-1958)。
- 全クリアは openPage(764-765)と windowWillClose(2976-2977)のみ。

#### 4.5.2 lookahead / lookaheadAndCompose(Controller.m:1231-1379)

- `lookahead`: [lock lock] → threadCount++ → `imageMutableArray` が 2 枚になるまで loadImage を追加(i=nowPage+count で毎回再計算)。threadStop が立てば即中断。終了時 threadStop=NO、threadCount--、unlock。
- `lookaheadAndCompose`: 前半は lookahead と同一。後半(Old のみ)は次見開き(nowPage+2)の合成キャッシュ検索→ミスなら isSmallImage 判定の上 returnComposeImage で事前合成し composedImage/screenCacheArray へ。**この判定はインデックスとページ番号の対応が逆([1]→nowPage+1, [0]→nowPage+2)で、marks による強制指定が先読み合成時のみずれる可能性**(Controller.m:1344-1345 vs 1712, 1717)。
- 起動は lockedImageDisplay 末尾からの `detachNewThreadSelector`(表示のたびに毎回新スレッドを使い捨て)+ goBookmark/ループ折返し時の同期呼び出し。**持続的な先読みスレッドは存在しない**(`lookaheadThread` はコメント内のみのデッド名。Controller.m:11-21)。

### 4.6 スレッドと排他(単一 NSLock プロトコル)

- ロックは単一の NSLock(Controller.m:39)。**保持して実行されるのは lookahead/lookaheadAndCompose の全身のみ**。この中で imageMutableArray 追加・cacheArray 更新・screenCacheArray 検索/追加・composedImage 差し替え・nowPage クランプ・threadCount 増減が行われる。
- メインスレッドは一切ロックを保持せず、`[lock lock];[lock unlock];` の**バリア・イディオム**(先読み完了待ち)を多用する。バリア箇所: esc(Controller_input.m:125-128)、nextpage(217-218)、halfnext/halfprev(240-254)、toppage(271-285)、bookmark/folder 移動(298-327)、skip 系(374-411、先に threadStop=YES)、close(752-756)、contextAction(1797-1798)、doSlideshow(2949-2950)、subFolder(2645-2654)、goToPar(2797-2800)、windowWillClose(Controller.m:2830-2831)。
- **ビジーウェイトは 3 箇所、すべて lockedImageDisplay 内**: (1) 1686 行(単ページ、0.0001 秒)、(2) 1710 行(見開き、0.0001 秒)、(3) 1714 行(2 枚目待ち、threadCount>0 ガード付き 0.001 秒)。lockedImageDisplay 全体が NSDisableScreenUpdates に挟まれるため、ここで固まると画面更新ごと止まる。
- threadStop はロック外で書かれロック内で読まれる volatile なしの BOOL。threadCount は lock 取得後に増えるため、**detach 直後に threadCount>0 チェックをすり抜けるレースがあり、その場合 2 枚目を待たず単ページ表示になる**(Controller.m:1713-1714)。
- 異常系: 先読みスレッド内で例外が起きるとロック保持のままスレッドが死に、以後の [lock lock] バリアで**恒久デッドロック**。ただし loadImage→itemAtIndex は失敗時 broken.png を返す設計で nil を返す経路は到達不能(COImageLoader.m:204-217)のため、broken.png がバンドル欠落した場合のみ現実化する。
- imageMutableArray/cacheArray/screenCacheArray は非スレッドセーフな NSMutableArray のままロック外(メインスレッドの表示処理・サムネイル充填)からも変更される。**サムネイル経路(ThumbnailController→controller loadImage)はロックもバリアも使わず、lock 保持中の先読みスレッドと cacheArray・XADArchive(単一ファイルポインタ・solid 展開状態を持ち再入不安全)へ同時アクセスし得る**(ThumbnailController.m:73-156, XADWrapper.m:89-93)。ページバーバブルのサムネイル取得も同様(AccessoryView.m:313)。
- openPage は lock バリアなしで旧 imageLoader を release するため、先読み実行中に履歴などから開き直すと解放済み loader に触れる余地がある(Controller.m:864)。thumController の imageLoader は retain されない生ポインタ(ThumbnailController.m:49-59)。
- windowWillClose は lock/unlock ペアで先読み完了を待ってから全リソースを解放し、currentBook* → oldBook* へ retain/release なしの所有権移動を行う(Controller.m:2828-2996)。

### 4.7 しおり(ブックマーク)

#### 4.7.1 データと操作

- データは `bookmarkArray`(要素 `{name:NSString, page:NSString(1 始まり)}`)。永続化先は BookSettings の `bookmarks`(§7.1)。**RememberBookSettings=NO でも bookmarks だけは保存される**(Controller.m:2863-2873)。
- 追加(addBookmark、キー a/action 10): 単=nowPage、見開き=nowPage-1 を `{name:"bookmarkN"(N=件数+1), page:"%d"}` で追加し setBookmarkMenu、infoString "Add bookmark"(Controller_input.m:2759-2793)。
- 削除(removeBookmark): 見開きは nowPage-1→ダメなら nowPage の順に試す。action 10/16 は削除失敗(NO)なら追加に転じるトグル。
- 移動(nextBookmark/backBookmark、キー c/d): page を昇順ソートし現在ページ(見開きは nowPage-1)より大きい最初/小さい最後へ。`nowPage=そのpage-1` にして lookahead+imageDisplay、しおり名を infoString 表示(Controller_input.m:2496-2569)。
- メニュー: 先頭 2 項目(Edit Bookmark...とセパレータ)を残して動的再構築。goBookmark: は representedObject(1 始まり)を -1 して nowPage に設定(Controller.m:2320-2362, 2582-2592)。

#### 4.7.2 しおり編集シート(現在の本)

- editBookmark: 画像表示中は bookmarkPanel をシート表示。**共有の NSMutableArray を直接編集するため Cancel しても取り消されない**(OK は setBookmarkMenu を呼ぶだけの差)(BookmarkController.m:75-150, Controller.m:2593-2607)。
- セル編集は「rowIndex+1 に新辞書 insert → 旧行 remove」方式。行削除は Delete キー(BookmarkPanel.keyDown 転送)かコンテキストメニュー。行 D&D 並べ替え対応(pasteboard タイプ "row"。BookmarkController.m:596-704)。
- 追加: ページ番号入力(1 未満は NSBeep 拒否)、名前は自動 "bookmarkN"。

#### 4.7.3 全しおり編集ウインドウ(本を開いていない時)

- BookSettings を浅いコピーし、`bookmarks` キーを持つ本だけを finderCompareS 順で左テーブルに列挙。runModalForWindow のモーダル。**こちらはコピー編集なので Cancel が有効**(現在の本のシートと非対称)(BookmarkController.m:153-251)。
- 本名側 Delete=その本の `bookmarks` キーを除去(残りが {alias} のみ 1 件なら本ごと削除。temppath 持ちの現行エントリは count==2 になるため実際にはエントリが残る)。本名リネームは重複時 NSBeep 拒否。
- Open ボタン=alias 解決パスを application:openFile: で自己オープン、Show in Finder=Finder 選択(BookmarkController.m:338-360)。
- スプリット位置は defaults `AllBookmarkSplitPotision`(**タイポのまま実キー**)に "左幅 右幅" 文字列で保存。
- OK で BookSettings 全体を書き戻し、controller strongSetBookmark(currentBookSetting/bookmarkArray 再取得+メニュー再構築)。

### 4.8 サムネイル一覧

- 表示: t キー(action 18)/コンテキストメニュー/ShowThumbnailWhenOpen。開始位置は nowPage を「1 画面のセル数 all=行×列」で量子化(ThumbnailController.m:480-522)。
- **充填はスレッドではなくメインスレッドの疑似非同期**: `performSelector:afterDelay:0.001` の連鎖で 1 セルずつ充填。中断は stop フラグ+doCount カウンタ(>1 で旧チェーン自滅)の 2 系統(ThumbnailController.m:525-760)。
- 充填順は readFromLeft=NO なら右端の列から左へ(右→左読み)、YES なら左から右。
- comicMode(mangaMode): 本体と同じ isSmallImage 判定で 2 枚を 1 セルに合成。readMode==0 は index+1 が左・index が右(ThumbnailController.m:158-345)。defaults `ThumbnailComicMode`。
- bookmarkMode(しおりのみ表示): controller bookmarkArray の各ページを敷き詰め。0 件なら "no bookmark"。defaults `ThumbnailOnlyBookmark`(ThumbnailController.m:351-476)。
- セル選択: alternateTitle(0 始まり index)で `goTo:` しパネルを閉じる(ThumbnailController.m:1186-1197)。
- キーボード: ThumbnailPanel.sendEvent が NSKeyDown を横取り。ESC=閉じる、**数字 1 文字=その数字×all のセル位置の画面へ(画面単位ジャンプ、複数桁不可)**、他は keyArray から action 0/1/4/5/8/9/18/35/36/46 のみ解釈(switchAction 反転付き)(ThumbnailPanel.m:61-68, ThumbnailController.m:1204-1385)。
- ホイール: 感度非 0 のとき ±sensitivity 超で 0.05 秒単発タイマー経由の prev:/next:(逆方向のみ排他。ThumbnailController.m:1388-1435)。
- ソートポップアップ: index 0/1/2 → sortMode 0/2/3(シャッフルは選択肢なし)。切替でサムネイルキャッシュ全消し+**メイン画面も先頭ページへ移動**(ThumbnailController.m:1468-1503)。
- しおりアイコン: ThumbnailMatrix.drawRect が「描画矩形がセル枠と完全一致するときだけ」bookmark_a.tiff を描く。**全面再描画ではアイコンが消える**(ThumbnailMatrix.m:16-80)。
- ツールバー: next: ボタンが left.tiff、prev: が right.tiff(**右→左読み前提の矢印逆転**。MainMenu.xib:2612-2633)。ファイル名表示は COPopUpTextField で「同じフォルダを開く」メニュー付き。
- コンテキストメニュー: Add/Remove Bookmark、Switch Single/Bind(mangaMode かつ見開きのみ)、Show in Finder(ThumbnailController.m:1000-1075)。

### 4.9 スライドショー

- 開始/停止(slideshow:、キー g/action 17、メニュー): 停止時 timer と dontSleepTimer(25 秒間隔で UpdateSystemActivity のスリープ抑止、**static 変数**)を invalidate。開始時 `SlideshowDelay` 秒間隔の繰返し NSTimer で doSlideshow(=lock 待ち→useComposedImage=YES→imageDisplay)(Controller_input.m:2916-2959)。
- **SlideshowDelay 未設定(0.0)だと interval 0 の最速連写になる(下限ガードなし)**(Controller_input.m:2929-2933)。
- あらゆるキー/マウス/ホイール入力の前処理で停止される。キー版(action 17)は前処理で止めた直後なら再開しない=トグルとして機能。**マウス版(action 23)は前処理で必ず止めた後に無条件で slideshow: を呼ぶため実質「停止できない」**(Controller_input.m:1428-1432)。
- 巻末到達時は loopCheck 分岐に従う(0=無限ループ、1/2=次の本へ移り再生継続、3=停止)。

### 4.10 ルーペ

- トグル(setLoupe、キー l/action 34、マウス中ボタン既定): lensWindow(borderless・透明・ignoresMouseEvents)を childWindow として生成しマウス中心に追従(CustomImageView.m:1361-1404)。
- サイズ=`LoupeSize`(既定 150、0 なら補正)、倍率=`LoupeRate`(既定 1.0)。**LoupeRate=1.0 で「lensRate×(原寸/表示縮尺)」=ピクセル等倍相当**(LoupeView.m:49-112)。
- 倍率増減は action 37/38(value 分、下限 1.0)で defaults に直接 setFloat(Controller_input.m:642-651)。
- 回転モード対応(座標系変換)、見開き 2 枚対応(レンズ矩形が隣画像と交差する場合は両方描いてページ境界をまたぐ。**副画像のスケール sx は計算されるが未使用で主画像の x を流用**)(LoupeView.m:113-217)。
- ルーペ表示中は cross.tiff カーソル(hotSpot 7,8)、ページバークリック判定は抑止される。

### 4.11 フィルタ(色調整)

- FilterPanelController(Filter パネル、⇧⌘F): CIPlugIn loadAllPlugIns 後、ColorAdjustment/ColorEffect/Sharpen/Blur カテゴリの CIFilter をポップアップに列挙。選択で IKFilterUIView(IKUISizeMini)を NSBox に包んで積層(FilterPanelController.m:11-159)。
- 全 inputKeys を KVO(Initial 付き)で監視し、変更のたび通知 `"FilterUIValueDidChange"`(object={keys,filters})+ defaults `CIFilters`(NSKeyedArchiver)/`CIFilterKeys` へ保存(FilterPanelController.m:118-194)。**removeObserver は一切呼ばれない(deleteFilter でも解除しない)**。
- CustomImageView が通知を受け `layer.filters` に適用(**フィルタはビュー全体=背景色ごとかかる**)。適用順は allValues 依存で **CIFilterKeys の順序と無関係=複数フィルタ時に順序不定**(CustomImageView.m:717-726)。
- 10.13+ の復元は `unarchivedObjectOfClass:[NSObject class]` でエラー無視(FilterPanelController.m:48)。
- 別系統: メニューの showFilterPanel: は IKImageEditPanel 共有パネルを出すだけの独立機能(Controller.m:2781-2785)。

### 4.12 ゴミ箱移動

- trashLeft(action 44/53): **i=nowPage-1(if/else 両分岐が同一値=デッド分岐)**。trashRight(action 43/52): 単=nowPage-1、見開き=nowPage-2(Controller_input.m:3057-3078)。
- **ゴミ箱系は switchAction 入替の対象外**。左開き(readMode1/3)では「right/left」の名称と画面上の左右が一致しない。
- trashFile(Controller_input.m:3079-3115): NSRunAlertPanel で確認 → `NSWorkspace performFileOperation:NSWorkspaceRecycleOperation`。失敗時フォールバック: Finder に selectFile → AppleScript `tell application "Finder" to delete selection` → cooViewer を再 activate。**ユーザーが Finder で選択を変えていた場合、無関係なファイルを削除し得る**。失敗してもユーザー通知なし。
- **削除後の再構築は一切行わない**: completeMutableArray/nowPage/ページ数表示/キャッシュは更新されず、削除済みページは cacheArray から追い出されるまでキャッシュ画像、その後は broken.png になる。本を開き直すまでずれたまま。
- 書庫/PDF では itemPathAtIndex が書庫本体パスを返すため、**開いている書庫ファイル自体がゴミ箱へ移動する**。同一ボリューム内 rename なのでファイルハンドルは有効なまま閲覧は継続できる(COImageLoader.m:135-152)。一時展開ディレクトリのパスが渡ることはない。

### 4.13 原寸表示(FullImagePanel)

- 起動: q/w キー(action 15/16=ViewOriginal right/left)、コンテキストメニュー。fullImageView に NSScaleNone で現在の firstImage/secondImage をセットし、必要サイズを contentSize に設定、画面幅でクランプ(Controller_input.m:1967-2068)。
- 配置: readMode 0/2 は First=画面右端(screenW-w,0)・Second=(0,5)、readMode 1/3 は左右逆。タイトル "original <ファイル名>"。
- キー操作(FullImagePanel.m:34-147): 矢印=20px スクロール、home/end/pgup/pgdn=固定処理、space=最下端なら次へ/shift+space=最上端なら前へ。その他は keyArray の **action 0/1 のみ** 解釈(**switchAction 入替なし=本体と非対称**)。
- nextOriginal/prevOriginal は **本体のページ位置(imageDisplay/prevPage)も同時に動かす**(Controller_input.m:2664-2720)。
- resignKeyWindow で自動 performClose(**フォーカス喪失で閉じる仕様**)、閉じる時に画像を nil 化。FitOriginal=YES ならページ送りのたび画像サイズにフィット+右端はみ出し補正(FullImagePanel.m:16-31, 149-203)。
- FullImageView: isFlipped=YES。ドラッグスクロールは垂直がドラッグ方向・水平が逆方向という独自系。spaceBarAction はデッドコード(FullImageView.m:11-197)。

### 4.14 PDF 対応とリンク

- COPDFImageRep(NSPDFImageRep 派生): 描画前に矩形を白塗り(透過対策)、合成 op を SourceOver に強制、pixelsWide/High をポイントサイズで返す=実効 72dpi 宣言(COPDFImageRep.m:25-40)。
- ファイルロード時に PDFKit の PDFDocument で開き直し、全ページの Link 注釈を `{rect, url}` 配列として収集(COPDFImageRep.m:42-93)。
- COPDFImage(NSImage 派生): **全ページで 1 個の COPDFImageRep を共有** し、draw のたび setCurrentPage で切替(共有可変状態、スレッド非安全)。setSize: は no-op(COPDFImage.m:8-69)。
- リンク: openLinkMode<2 のとき CustomImageView.setUrlRect が表示座標へ変換(回転対応)し pointingHandCursor 登録。クリックで openLink:(0=確認ダイアログ/1=即時/2=無視)→NSWorkspace openURL(CustomImageView.m:1719-1824, Controller.m:3023-3042)。

### 4.15 回転

- rotateMode: 0=通常, 1=左90°, 2=180°, 3=左270°(右90°)。rotateRight はデクリメント(<0 で 3)、rotateLeft はインクリメント(>3 で 0)(CustomImageView.h:16-18, CustomImageView.m:1492-1511)。
- 実回転状態は **CustomImageView 側**。Controller の rotateMode ivar は書き込み専用で誰も読まないデッド状態変数(Controller.m:2764-2779)。
- 合成キャッシュは無回転で保持され描画時に必ず現在の rotateMode 変換がかかるため、回転でのキャッシュ無効化は不要(ただし 90/270 時は再スケールで画質は非等価)。回転は永続化されない。

### 4.16 ホイール操作(canScrollMode)

fitScreenMode>0 のときの scrollWheel 挙動(Controller_input.m:1851-1933):

| 値 | UI 表記 | 挙動 |
|---:|---|---|
| 0 | Normal Scroll | scrollTo(deltaX*10, -deltaY*10) のみ。ページ移動なし |
| 1 | Scroll | スクロール不能(端)なら画像内の 1 画面送り(next/prev)。ページはめくらない |
| 2 | Scroll+TurnPage | 画像内でもう進めない時に実ページ移動(prev 側は PrevPageMode==1 で末尾から表示) |
| 3 | TurnPage | 常に感度式ページめくり(下記) |

- fitScreenMode==0 または canScrollMode==3: `WheelSensitivity`==0 なら無効。イベント毎の |deltaY| が感度以上で、interval 0.0 の単発タイマー経由で wheelDown(次)/wheelUp(前)。**閾値は累積でなくイベント毎、同方向連続は複数回発火し得る**。タイマーは逆方向排他と 1 ランループ遅延のためだけに存在。
- `scrollTo` の戻り値: YES=スクロールできなかった(端/全体可視)=ページ送りトリガ、NO=スクロールした(CustomImageView.m:436-467)。

### 4.17 その他

- **Dock メニュー**: 画像非表示時のみ「Open the last page」1 項目を動的生成(Controller.m:1131-1144)。
- **同フォルダメニュー**: 親フォルダを finderCompareS でソートし、先頭 "." の名前を除外、ディレクトリ無条件+fileTypes 該当ファイルを列挙。現本に state On。フォルダ mtime で再構築判定(Controller.m:2365-2449)。`fileExistsAtPath:isDirectory:` の戻り値未チェックで isDir 未初期化参照があり得る(2398-2400)。
- **一時ディレクトリの掃除**: COImageLoader dealloc の removeItemAtURL が唯一の削除箇所。**applicationWillTerminate は defaults synchronize のみで、⌘Q・クラッシュ時は temp ディレクトリが残る**(起動時の残骸掃除もなし。OS の /var/folders 自動清掃頼み)(COImageLoader.m:95-100, Controller.m:2993-2996)。開き替えの瞬間は新旧 2 冊分の temp が同時に存在する。
- **XADWrapper dealloc の怪**: release 直前に `[archive init]` を呼ぶ異常コード。現行 XADMaster では旧 parser とファイルハンドルがリークし、**本を閉じても書庫のファイルハンドルはプロセス終了まで開いたまま**(XADWrapper.m:64-73)。さらに XADItem↔wrapper の retain 循環で XADWrapper/XADArchive は毎回リークする。
- **エラー処理の哲学**: 読み込み・展開系エラーはダイアログを一切出さず broken.png / empty.png / 戻り値 NO に吸収。NSRunAlertPanel はアプリ全体で 5 箇所のみ(Go to the last page / Open URL / Setting is not found / Change current folder / Move to Trash)。※調査指示時の「10 箇所」という想定は現行コードと不一致(5 箇所が正)。
- **壊れた書庫**: 完全解析不能なら「empty.png 1 ページだけの本」として開いてしまう(mode=2 のまま itemCount==0→empty.png 追加が openPage のガードをすり抜ける)。途中まで壊れた書庫は解析済みエントリのみ列挙(COImageLoader.m:84-86, 477-481)。
- **ファイル名エンコーディング**: アプリ側に処理はなく XADMaster の XADStringSource が UniversalDetector で自動判定(信頼度閾値なし・検出不能時 cp1252)。デコード不能バイトは "%xx" エスケープの文字化け名になり列挙自体は必ず成功(XADString.m:340-444)。NFC/NFD 正規化処理はどこにもない。

---

## 5. 入力システム

### 5.1 バインディング配列の構造

NSUserDefaults に 6 本の辞書配列として保存される(KeyArray/KeyArrayMode2/KeyArrayMode3、MouseArray/MouseArrayMode2/MouseArrayMode3)。

キー配列要素:

| 内部キー | 型 | 意味 |
|---|---|---|
| action | int | アクション番号(キー用 0-52。§5.5) |
| key | NSString(1 文字) | 押下キー文字。比較は characterAtIndex:0 のみ。矢印等はファンクションキーコード、Apple Remote はボタン定数(1<<1〜1<<6)をそのまま unichar 化 |
| keyname | NSString | 表示名("shift+left arrow" 等)。マッチングには不使用 |
| modifier | int | 修飾フラグ(§5.2) |
| value | int/float(任意) | スキップ枚数/スクロール量/goto% パーセント/ルーペ倍率増分 |
| switchAction | BOOL(任意) | **オンのときだけキーが存在**。左開き時にアクション番号を対称ペアで入替(§5.4) |

マウス配列要素: key/keyname の代わりに `button`(int)。0-10=マウスボタン番号([NSEvent buttonNumber])、**1000=swipe right, 2000=swipe left, 3000=swipe up, 4000=swipe down, 5000=pinch in, 6000=pinch out, 7000=rotate right, 8000=rotate left** のマルチタッチ仮想ボタン(PreferenceController.m:815-880)。

### 5.2 modifier 符号化表

| 加算値 | キー側の意味 | マウス側の意味 | 根拠 |
|---:|---|---|---|
| +1 | shift | shift | Controller_input.m:143-157, 811-824 |
| +2 | option | option | 同上 |
| +4 | control | control | 同上 |
| +8 | テンキー(**矢印キーには意図的に付けない**) | — | Controller_input.m:152-157 |
| 100 | Apple Remote 固定値 | ドラッグ(方向不問)起点 | Controller_input.m:20-49, CustomImageView.m:149-155 |
| +200/+300/+400/+500 | — | drag left/right/up/down(マウスジェスチャ) | Controller_input.m:950-970 |
| +600〜+1000 | — | **設定コードに分岐はあるが xib メニューは 6 項目のみで到達不能のデッドコード** | PreferenceController.m:2112-2127 |

### 5.3 モード別配列の解決順(入力種別で不統一な点に注意)

| 入力種別 | fitScreenMode 0 | 1 | 2 | 3 | 根拠 |
|---|---|---|---|---|---|
| キー / Apple Remote | mode0 のみ | Mode2 → mode0 | Mode3 → mode0 | Mode3 → mode0 | Controller_input.m:159-169 |
| マルチタッチ | mode0 のみ | Mode2 → mode0 | Mode3 → mode0 | Mode3 → mode0 | Controller_input.m:937-947 |
| **マウスクリック** | mode0 のみ | **Mode2 → mode0** | **Mode3 → mode0** | **Mode2 → mode0(キーと異なる)** | Controller_input.m:848-858 |
| マウスドラッグジェスチャ | (mode0,cMod)→(mode0,100) | (Mode2,cMod)→(mode0,cMod)→(Mode2,100)→(mode0,100) | (Mode3,…同型) | (Mode3,…同型) | Controller_input.m:950-1031 |

- 方向別ドラッグの割当が無ければ modifier=100(方向不問ドラッグ)にフォールバックする。
- マニュアルが明文化する継承ルール「ノーマルモードの設定が基本、モード固有設定が優先」(docs/manual.html:366-376)に対応。

### 5.4 switchAction の入替ペア(readFromLeft=readMode 1||3 のとき)

| 系統 | 入替ペア | 根拠 |
|---|---|---|
| キー | 0↔1, 2↔3, 4↔5, 6↔7, 8↔9, 13↔14, 26↔27, 35↔36 | Controller_input.m:192-213 |
| マウス | 6↔7, 8↔9, 10↔11, 12↔13, 14↔15, 19↔20, 33↔34, 44↔45 | Controller_input.m:1054-1074 |

- **原寸(15/16, 21/22)・Finder(22/23, 28/29)・ゴミ箱(43/44, 52/53)は入替対象外**(対象選定に一貫した規則がない)。同一の入替表が ThumbnailController.m:1213-1233 にも重複実装されている。FullImagePanel は入替を実装しない。
- 設定 UI でチェック可能なアクション: キー 0-9,13,14,26,27,35,36 / マウス 6-15,19,20,33,34,44,45(PreferenceController.m:2577-2589, 2182-2196)。

### 5.5 キーアクション全表(action 0-52、Controller_input.m:214-799 / PreferenceController.m:667-722)

| # | 名称(設定 UI) | 挙動 |
|---:|---|---|
| 0 | NextPage | lock 待ち→useComposedImage=YES→imageDisplay |
| 1 | PreviousPage | prevPage |
| 2 | HalfNextPage | 見開きから 1 ページだけ進む(nowPage-- して先頭へ再挿入→表示) |
| 3 | HalfPreviousPage | halfprevPage(1 ページだけ戻る) |
| 4 | Go to LastPage | goToLast |
| 5 | Go to FirstPage | nowPage=0 へ(バッファ全消去→lookahead→表示) |
| 6 | NextBookmark | 次のしおりへ |
| 7 | PreviousBookmark | 前のしおりへ |
| 8 | NextFolder(Archive) | 同フォルダの次の本へ |
| 9 | PreviousFolder(Archive) | 同フォルダの前の本へ |
| 10 | Add/RemoveBookmark | removeBookmark が NO なら addBookmark(トグル) |
| 11 | SwitchSingle/Bind | 単ページ⇔見開き切替+marks 更新 |
| 12 | ShowNumber | ページ番号表示トグル(ShowNumber 即保存) |
| 13 | Skip | value(既定 10)ページ進む |
| 14 | BackSkip | value ページ戻る |
| 15 | ViewOriginal(right) | readMode 0/2→First、1/3→Second を原寸表示 |
| 16 | ViewOriginal(left) | 逆 |
| 17 | Slideshow | トグル(前処理で止めた直後は再開しない) |
| 18 | Show Thumbnail | サムネイル表示(見開き時 nowPage-1) |
| 19 | ChangeReadMode | 0→1→2→3→0 巡回 |
| 20 | ShowPageBar | ページバートグル(ShowPageBar 即保存) |
| 21 | Go to Page | pageMover 表示/確定(§5.8) |
| 22 | Show in Finder(right) | readMode 0/2→First、1/3→Second を Finder 表示 |
| 23 | Show in Finder(left) | 逆 |
| 24 | PageUp | [imageView scrollUp]=1 画面分**ページ先頭側**へ |
| 25 | PageDown | 1 画面分**ページ末尾側**へ |
| 26 | PageUp+PrevPage | 既に先頭端([imageView prev]==YES)なら prevPage(PrevPageMode==1 で末尾から表示) |
| 27 | PageDown+NextPage | 既に末尾端なら次ページ |
| 28 | ScrollToTop | ページ先頭へ(綴じ方向で右上/左上) |
| 29 | ScrollToEnd | ページ末尾へ |
| 30 | ScrollUp | scrollTo(0,-value)(既定 20px) |
| 31 | ScrollDown | scrollTo(0,+value) |
| 32 | ScrollLeft | scrollTo(+value,0) |
| 33 | ScrollRight | scrollTo(-value,0) |
| 34 | ShowLoupe | ルーペトグル |
| 35 | NextSubFolder(Archive) | 書庫/フォルダ内サブフォルダ単位で次へ |
| 36 | PreviousSubFolder(Archive) | 同前へ |
| 37 | LoupePower+ | LoupeRate += value |
| 38 | LoupePower- | LoupeRate -= value(下限 1.0) |
| 39 | Go to % | goToPar(value/100)。数字キー 0-9 に value 0..90 で既定割当 |
| 40 | Rotate Right | 右回転 |
| 41 | Rotate Left | 左回転 |
| 42 | ChangeViewMode | fitScreenMode 0→1→3→2→0 巡回(全体→幅→幅分割→原寸) |
| 43 | Move to Trash(right) | trashRight |
| 44 | Move to Trash(left) | trashLeft |
| 45 | ChangeSortMode | canSortByDate 時 0→2→3→1→0、不可時 0↔1 |
| 46 | Close | threadStop 待ち→performClose |
| 47 | Shuffle | setSortMode:1 page:0 |
| 48 | Open the last page | File メニュー項目を isEnabled 時に performAction |
| 49 | SwitchFullscreen | Window>Fullscreen をトグル |
| 50 | MinimizeWindow | Window>Minimize |
| 51 | EnlargeViewMode | 0→幅, 1→幅分割, 3→原寸(2 は無変化) |
| 52 | ReduceViewMode | 1→全体, 2→幅分割, 3→幅(0 は無変化) |

### 5.6 マウスアクション全表(action 0-64、Controller_input.m:1035-1789 / PreferenceController.m:746-812)

`**` 付きは「画面の左右どちらで操作したか」(readMode 考慮の NSDivideRect)で動作が変わる系。

| # | 名称 | 挙動/備考 |
|---:|---|---|
| 0 | Next/PrevPage** | left 側=次、右=prevPage(既定の左クリック) |
| 1 | HalfNext/PrevPage** | 半ページ版 |
| 2 | Last/TopPage** | left=最終ページ、右=先頭 |
| 3 | Next/PrevBookmark** | しおり移動 |
| 4 | Next/PrevFolder(Archive)** | 本移動 |
| 5 | Skip/BackSkip** | **【バグ】break 欠落で case 6(nextpage)へフォールスルー: skip 実行後さらに 1 ページ進む**(Controller_input.m:1179-1226) |
| 6 | NextPage | キー 0 相当 |
| 7 | PreviousPage | キー 1 相当 |
| 8 | HalfNextPage | |
| 9 | HalfPreviousPage | |
| 10 | Go to LastPage | |
| 11 | Go to FirstPage | |
| 12 | NextBookmark | |
| 13 | PreviousBookmark | |
| 14 | NextFolder(Archive) | |
| 15 | PreviousFolder(Archive) | |
| 16 | Add/RemoveBookmark | |
| 17 | SwitchSingle/Bind | |
| 18 | ShowNumber | |
| 19 | Skip | |
| 20 | BackSkip | |
| 21 | ViewOriginal(right) | |
| 22 | ViewOriginal(left) | |
| 23 | Slideshow | **無条件トグル=停止できない(§4.9)** |
| 24 | Show Thumbnail | |
| 25 | ChangeReadMode | |
| 26 | ShowPageBar | |
| 27 | ViewOriginal(L/R)** | left→Second、右→First |
| 28 | Show in Finder(left)(UI 表示名) | **実装は showInFinderR 相当。UI ラベルが実挙動と左右逆**(Controller_input.m:1476-1513) |
| 29 | Show in Finder(right)(UI 表示名) | 実装は showInFinderL 相当(同上) |
| 30 | Show in Finder(L/R)** | left→Second、右→First |
| 31 | PageUp | |
| 32 | PageDown | |
| 33 | PageUp+PrevPage | |
| 34 | PageDown+NextPage | |
| 35 | ScrollToTop | |
| 36 | ScrollToEnd | |
| 37 | ScrollUp(value) | |
| 38 | ScrollDown | |
| 39 | ScrollLeft | |
| 40 | ScrollRight | |
| 41 | DragScroll | getMouseAction 内は no-op。実処理は CustomImageView.mouseDown/mouseDragged(§5.7) |
| 42 | PageUp/Down+Prev/NextPage** | left=next 側 |
| 43 | ShowLoupe | |
| 44 | NextSubFolder(Archive) | |
| 45 | PreviousSubFolder(Archive) | |
| 46 | Next/PrevSubFolder(Archive)** | |
| 47 | LoupePower+ | |
| 48 | LoupePower- | |
| 49 | Rotate Right | |
| 50 | Rotate Left | |
| 51 | ChangeViewMode | |
| 52 | Move to Trash(right) | |
| 53 | Move to Trash(left) | |
| 54 | Move to Trash(L/R)** | left→trashLeft |
| 55 | Rotate(L/R)** | left→rotateLeft |
| 56 | ChangeSortMode | |
| 57 | Close | |
| 58 | Shuffle | setSortMode:1 page:0 |
| 59 | ContextualMenu | [NSMenu popUpContextMenu:[imageView menu] ...](右クリックメニューはこの経路のみ) |
| 60 | Open the last page | |
| 61 | SwitchFullscreen | |
| 62 | MinimizeWindow | |
| 63 | EnlargeViewMode | |
| 64 | ReduceViewMode | |

### 5.7 既定バインディング

#### 5.7.1 KeyArray 既定(Fit to Screen 用、PreferenceController.m:13-356)

| キー | action | 備考 |
|---|---:|---|
| z / ← / space | 0 NextPage | z・← は switchAction 付 |
| x / → / shift+space | 1 PreviousPage | x・→ は switchAction 付 |
| shift+z / shift+← | 2 HalfNext | switchAction 付 |
| shift+x / shift+→ | 3 HalfPrev | switchAction 付 |
| option+z / option+← | 4 LastPage | switchAction 付 |
| option+x / option+→ | 5 FirstPage | switchAction 付 |
| c / ↓ | 6 NextBookmark | |
| d / ↑ | 7 PrevBookmark | |
| control+c / control+↓ | 8 NextFolder | |
| control+d / control+↑ | 9 PrevFolder | |
| a | 10 Add/RemoveBookmark | |
| s | 11 SwitchSingle/Bind | |
| p | 12 ShowNumber | |
| tab(value 10) | 13 Skip | |
| shift+tab(value 10) | 14 BackSkip | |
| w | 15 ViewOriginal(right) | |
| q | 16 ViewOriginal(left) | |
| g | 17 Slideshow | |
| t | 18 ShowThumbnail | |
| r | 19 ChangeReadMode | |
| o | 20 ShowPageBar | 1.0b5 以前ユーザーは移行遺物で「@」の場合あり(docs/manual.html:150) |
| l | 34 ShowLoupe | |
| 数字 0-9(value 0,10,…,90) | 39 Go to % | |
| shift+control+C / shift+control+↓ | 35 NextSubFolder | |
| shift+control+D / shift+control+↑ | 36 PrevSubFolder | |
| num enter(mod 8)/ return | 21 Go to Page | |
| AppleRemote Volume up(mod 100) | 7 PrevBookmark | |
| AppleRemote Volume down(mod 100) | 6 NextBookmark | |
| AppleRemote Menu(mod 100) | 18 Thumbnail | |
| AppleRemote Play(mod 100) | 17 Slideshow | |
| AppleRemote Right(mod 100) | 1 PrevPage | switchAction 付 |
| AppleRemote Left(mod 100) | 0 NextPage | switchAction 付 |

#### 5.7.2 KeyArrayMode2 既定(幅フィット用、PreferenceController.m:362-411)

page up=24、page down=25、shift+space=26(PageUp+PrevPage)、space=27(PageDown+NextPage)、home=28、end=29、↑=30(value 20)、↓=31(value 20)。

#### 5.7.3 KeyArrayMode3 既定(原寸/幅分割用、PreferenceController.m:417-478)

Mode2 と同じ+←=32(value 20)、→=33(value 20)。

#### 5.7.4 MouseArray 既定(PreferenceController.m:484-555)

| 入力 | action |
|---|---:|
| button0 click | 0 Next/PrevPage** |
| button0+shift click | 1 HalfNext/PrevPage** |
| swipe left(2000) | 6 NextPage(switchAction 付) |
| swipe right(1000) | 7 PreviousPage(switchAction 付) |
| swipe down(4000) | 14 NextFolder |
| swipe up(3000) | 15 PreviousFolder |
| rotate right(7000) | 49 Rotate Right |
| rotate left(8000) | 50 Rotate Left |
| pinch out(6000) | 63 EnlargeViewMode |
| pinch in(5000) | 64 ReduceViewMode |
| button2 | 43 ShowLoupe |
| button1 / button0+control | 59 ContextualMenu |

#### 5.7.5 MouseArrayMode2/Mode3 既定(同一内容)

button0+modifier100(ドラッグ)=41 DragScroll、button0 click=42 PageUp/Down+Prev/NextPage**。

DragScroll の配布: applicationDidFinishLaunching で MouseArrayMode2 の action==41 エントリを `setDragScroll:mode:1`、Mode3 のものを mode:2/mode:3 に設定(Controller.m:531-556)。CustomImageView.mouseDown が cMod(100 起点+修飾)と button の一致で inDragScroll=YES にし 1:1 ドラッグスクロール(closedHandCursor)。ドラッグスクロールが起きた mouseUp ではクリック/ジェスチャ処理をしない(CustomImageView.m:141-193)。

### 5.8 pageMover(指定ページ入力)と 0-9 キーの競合解決

- 状態機械(すべて keyAction 起点、Controller_input.m:96-170, 522-539): action 21 で開始(drawPageMover:0)→ 数字キーで桁追加(tempPageNum*10+n、上限 999999)→ delete で桁削除 → esc でキャンセル → action 21 再打鍵で確定(goTo:tempPageNum-1)。
- **数字キーの分岐は「pageMover 表示中のみ」バインド検索より前に消費して早期 return する**。表示中でなければ既定バインドの action 39(Go to %)に到達する。つまり同じ 0-9 キーの意味が pageMover の ON/OFF で切り替わる。修飾キーは判定に使われない(control+5 も 5)。
- 非モーダル: 数字/esc/delete/action21 以外のキーは pageMover 表示中も通常どおり動作する(tempPageNum は保持)。マウス/リモコンにはチェックがない。
- esc は pageMover 非表示時「本を閉じる」(threadStop→lock 待ち→performClose)(Controller_input.m:119-131)。

### 5.9 マウスクリック・ジェスチャ・マルチタッチの検出仕様

- クリック(CustomImageView.m:182-258): mouseUp で移動 30px 未満・押下 1 秒以内・ページバー上でない・PDF リンク上でないときに mouseAction。**押下から 1 秒超のクリックは無視(長押しキャンセル)**。右/中ボタンも同一経路(menuForEvent: は mouseDown を呼んで nil を返しネイティブメニューを抑止)。
- ページバークリック: インジケータ有効かつルーペ非表示時、バー内相対位置(右綴じは左右反転)→ goToPar: の比率ジャンプ(CustomImageView.m:232-244)。
- ドラッグジェスチャ: 非ドラッグスクロール時、1 秒以内・±30px 超で方向判定(0=左,1=右,2=上,3=下)し gestureAction。**cursorMoved は NSMakePoint(newY,newX) と X/Y を意図的に入替えて蓄積**(x=縦、y=横。CustomImageView.m:179)。
- マルチタッチ(CustomImageView.m:283-355): swipe は deltaX<0→right(1000)/deltaX>0→left(2000)/deltaY<0→up(3000)/deltaY>0→down(4000)。pinch は累積 magnification ±0.2、rotate は累積 ±15 度で 1 ジェスチャ 1 回のみ発火。
- 左右判定の基準が不統一: mouseAction は window contentView frame、multiTouch/gesture は imageView frame(スクロール中はズレ得る)(Controller_input.m:832, 921, 994)。

### 5.10 page up / page down のマニュアル逆表記の解決

マニュアル(docs/manual.html:163-164, 175-176)は「1画面分下へ=page up/1画面分上へ=page down」と記すが、**実装は page up=ビューポートをページ先頭側(上)へ、page down=ページ末尾側(下)へ**(scrollUp/scrollDown、CustomImageView.m:491-524。ビューは非フリップ座標で firstScroll の初期位置=最上部)。マニュアルは「コンテンツの見かけの移動方向」で書いたと解釈すれば整合する。リライトはビューポート基準(コードの action 名どおり)を採用のこと。動作感の最終確認は**要実機確認**。

### 5.11 コンテキストメニュー(contextAction)

- メニュー実体は imageView の menu(xib の RightMenu)。**表示経路は action 59 のみ**。
- validateMenuItem(Controller.m:2259-2314)がカーソル位置の左右半分(readFromLeft 考慮)に応じて項目名を動的リネーム(Previous↔Next Bookmark、Go to FirstPage↔LastPage、Previous↔Next Folder)し、View at Original Size / Show in Finder の tag を left=1(Second)/右=0(First)に設定。Add/Remove Bookmark・Start/Stop Slideshow はトグル改名。
- contextAction(Controller_input.m:1791-1835)は**ローカライズ済みタイトル文字列比較**でディスパッチ。'Stop Slideshow' 分岐は前処理で停止済みのため実質 no-op。

---

## 6. 設定項目と NSUserDefaults 全キー表

永続化ドメインは `jp.coo.cooViewer`(README.md:58 がアンインストール対象として明記)。
既定値は 3 層: (1) registerDefaults(揮発性 9 キー、Controller.m:52-64)、(2) 未存在時に永続書込されるバインディング 6 配列(PreferenceController の +setDefault*Array)、(3) 起動時の 0 値フォールバック補正(LoupeSize 等、Controller.m:146-260)。

### 6.1 トップレベルキー全表

| キー | 型 | 既定値 | 意味/備考 | 根拠 |
|---|---|---|---|---|
| OpenLastFolder | BOOL | YES(registerDefaults) | 起動時に前回の本を自動で開く | Controller.m:52-64, 531-563 |
| Fullscreen | BOOL | YES(registerDefaults) | 疑似フルスクリーン状態(メニュー state と同期) | Controller.m:2790-2817, CustomWindow.m:6-25 |
| WheelSensitivity | float | 1.0(registerDefaults) | ホイールめくりの発火閾値。0=無効。**UI スライダーとの変換は双方向とも「v==0 ? 0 : 2.1-v」の反転写像**(既定 1.0=スライダー 1.1) | PreferenceController.m:1180-1184, 1422-1428 |
| PrevPageMode | int | 0(registerDefaults) | 前ページ復帰時の初期位置: 0=ページ先頭 / 1=ページ末尾(setStartFromEnd) | Controller_input.m:586-603 |
| CanScrollMode | int | 0(registerDefaults) | ホイール動作: 0=スクロールのみ/1=画像内送り/2=端でページめくり/3=常にめくり(§4.16) | Controller_input.m:1851-1933 |
| PrevPagePageBarPositionMode | int | 2(registerDefaults) | **registerDefaults のみで参照コードなしの隠しキー(設定 UI なし)** | Controller.m:52-64 |
| ShowPageBar | BOOL | YES(registerDefaults) | ページバー表示。action 20 で即保存。※controller-input 調査は既定 NO と記録したが registerDefaults が YES を登録するため実効既定は YES(**要実機確認**) | Controller.m:52-64 |
| ShowNumber | BOOL | YES(registerDefaults) | ページ番号表示。action 12 で即保存。同上の注意 | Controller.m:52-64 |
| OpenRecentLimit | int | 10(registerDefaults) | 履歴件数。**0 で RecentItems キー自体を削除(機能無効)** | Controller.m:821-828 |
| BufferingMode | int | 1(finalize 検出付き registerDefaults。**実質常に 1=New**) | 0=Old(Controller 側合成)/1=New(View 側合成)。§4.2.2 | Controller.m:55-58 |
| KeyArray | 配列 | +defaultKeyArray(未存在時に永続書込) | Fit to Screen 用キー割当(§5.7.1) | PreferenceController.m:13-356 |
| KeyArrayMode2 | 配列 | +defaultKeyArrayMode2 | 幅フィット用 | PreferenceController.m:362-411 |
| KeyArrayMode3 | 配列 | +defaultKeyArrayMode3 | 原寸/幅分割用 | PreferenceController.m:417-478 |
| MouseArray | 配列 | +defaultMouseArray | マウス/マルチタッチ共通割当 | PreferenceController.m:484-555 |
| MouseArrayMode2 | 配列 | drag=41, click=42 | §5.3 のモード対応参照 | PreferenceController.m:557-599 |
| MouseArrayMode3 | 配列 | Mode2 と同一 | 同上 | 同上 |
| SkipPage | int | 0(0 は 10 と解釈) | **旧キー**。現 UI になく、value 欠落バインディング(キー 13/14・マウス 5/19/20)への移行値としてのみ使用 | Controller.m:97-133 |
| BookSettings | 辞書 | 空辞書 | 本ごとの設定(§7.1) | Controller.m:264-268 |
| RecentItems | 配列 | 空配列 | 最近開いた項目(§7.2) | Controller.m:264-268 |
| LastPages | 配列 | (未登録) | 最終ページ記憶(§7.3) | Controller.m:829-856 |
| Version | 文字列 | (初回未登録) | 設定移行判定用の前回起動バージョン(CFBundleVersion 値) | Controller.m:292-524 |
| ReadMode | int | 0 | 既定読み方向(§4.4.1)。本ごとの readMode で上書き | Controller.m:1000-1006 |
| SortMode | int | 0 | 既定ソート(§4.4.2)。本ごとの sortMode で上書き。**UI index との対応ねじれ: 保存値 0/2/3/1 ↔ index 0/1/2/3** | PreferenceController.m:1009-1025 |
| RememberBookSettings | BOOL | NO | 本ごとに readMode/sortMode/marks を保存するか。**NO でも bookmarks は保存** | Controller.m:2863-2873 |
| SingleSetting | int | 740(0 は補正) | 見開き判定しきい値×1000(§4.2.1) | Controller.m:236-240 |
| MaxEnlargement | int | 0 | 最大拡大倍率。0=無制限。**UI 対応ねじれ: index0-4=保存値 1-5(~100〜500%)、index5(no limit)=0** | PreferenceController.m:1266-1278 |
| SlideshowDelay | float | 0.0 | スライドショー間隔秒。0 だと最速連写(§4.9) | Controller_input.m:2929-2933 |
| LoopCheck | int | 0 | 端超え動作 4 択(§4.3.4) | Controller.m:1667-1781 |
| GoToLastPage | int | 0 | 開く時の最終ページ復帰: 0=確認/1=自動/2=無効 | Controller.m:897-920 |
| ReadSubFolder | BOOL | NO | サブフォルダ再帰読み(COImageLoader へ) | COImageLoader.m:444-473 |
| OpenLinkMode | int | 0 | PDF リンク: 0=確認/1=即時/2=無視 | Controller.m:3023-3042 |
| ChangeCreator | BOOL | NO(**OK のたび NO 上書き**) | クリエータ変更。**UI 喪失(outlet 未接続)+参照コードはコメントアウト済みデッド** | PreferenceController.m:998-1007, Controller.m:1047-1069 |
| ChangeOpenWith | BOOL | NO(同上) | Open With 強制バインド。同上のデッド機能 | Controller.m:1070-1105 |
| ChangeCurrentFolder | int | 0 | 本の移動追従: 0=確認/1=自動/2=無効(§4.1.4) | Controller.m:3493-3541 |
| DontHideMenuBar | BOOL | NO | フルスクリーン等でメニューバーを隠さない(5 クラスが参照) | CustomWindow.m:71-89 ほか |
| ImageCache | int | 0(xib 初期表示 100) | 原画像キャッシュ枚数(実容量 +4) | Controller.m:1223-1227 |
| ScreenCache | int | 0(xib 初期表示 100) | 合成見開きキャッシュ枚数(実容量 +2)。New モードでは UI 無効 | Controller.m:1352-1372 |
| ThumbnailCache | int | 0(xib 初期表示 100) | サムネイルキャッシュ枚数 | ThumbnailController.m:153-154 |
| Interpolation | int | 0 | 補間: 0=Default/1=None/2=Low/3=High | CustomImageView.m:736-749 |
| UseCALayer | BOOL | NO | layer.drawsAsynchronously に使用(GPU 描画注記付き) | CustomImageView.m:81-84 |
| LoupeSize | int | 150(0 は補正) | ルーペ一辺 px | Controller.m:169-175 |
| LoupeRate | float | 1.0(0 は補正) | ルーペ倍率。action 37/38 が直接 setFloat | Controller_input.m:642-651 |
| ViewBackGroundColor | NSData(NSArchiver 化 NSColor) | 黒 | 背景色。適用時 alpha は 1 に強制 | Controller.m:177-184 |
| FitOriginal | BOOL | NO | 原寸パネルを画像サイズにフィット | FullImagePanel.m:149-186 |
| Thumbnail | 辞書 {row,column} | {row:2, column:3}(xib 初期表示 10/10) | サムネイル格子 | Controller.m:211-217 |
| ShowThumbnailWhenOpen | BOOL | NO | 開いた直後にサムネイル表示 | Controller.m:1038-1046 |
| ThumbnailComicMode | BOOL | NO | サムネイル見開きモード | ThumbnailController.m |
| ThumbnailOnlyBookmark | BOOL | NO | サムネイルしおりのみ表示 | ThumbnailController.m:1444-1454 |
| TextFont | NSData(NSFont) | controlContentFontOfSize:11 | ページ番号フォント | AccessoryView.m:26-213 |
| TextColor | NSData(NSColor) | 白 | ページ番号文字色 | 同上 |
| TextBGColor | NSData(NSColor) | 黒 α0.8 | 背景色。clearColor で光彩(NSShadow)描画に切替 | AccessoryView.m:223-235 |
| TextBorderColor | NSData(NSColor) | 白 | 枠色 | 同上 |
| PageNumPosition | int | 0 | ページ番号位置: 0=左上/1=右上/2=左下/3=右下 | AccessoryView.m:617-643 |
| PageNumAutoHide | BOOL | NO | ページ番号 2 秒自動隠し | AccessoryView.m:729-755 |
| Margin_Page | 辞書 {x,y} | {0,0}(未存在時書込) | ページ番号マージン | AccessoryView.m:145-160 |
| PageBarPosition | int | 0 | ページバー位置(同 4 値) | AccessoryView.m:545-584 |
| PageBarAutoHide | BOOL | NO | ページバー自動隠し | 同上 |
| PageBarShowThumbnail | int | 0 | バーホバーバブルにサムネイル表示 | AccessoryView.m:252-527 |
| PageBarSize | 辞書 {width,height} | {200,15}(未存在時書込) | ページバー寸法 | Controller.m:227-230 |
| PageBarTextFont | NSData(NSFont) | userFontOfSize:14 | バブル/pageMover フォント | AccessoryView.m |
| PageBarFontColor | NSData(NSColor) | 白 | | 同上 |
| PageBarBGColor | NSData(NSColor) | 黒 α0.8(1.2b14 移行で α0.8 適用) | | Controller.m:432-455 |
| PageBarBorderColor | NSData(NSColor) | 白 | | AccessoryView.m |
| PageBarReadedColor | NSData(NSColor) | 白 α0.5 | 既読部分色 | 同上 |
| Margin_PageBar | 辞書 {x,y} | {0,0} | ページバーマージン | AccessoryView.m:145-160 |
| AllBookmarkSplitPotision | 文字列 "左幅 右幅" | (未登録) | 全しおり画面のスプリット位置。**キー名タイポ(Potision)は実キーそのまま** | BookmarkController.m:186-206 |
| CIFilters | NSData(NSKeyedArchiver) | (未登録) | 選択中 CIFilter 辞書 | FilterPanelController.m:43-62 |
| CIFilterKeys | 配列 | (未登録) | 選択フィルタ名の順序配列 | 同上 |
| NSWindow Frame NormalWindow | 文字列(システム) | 初回 nib フレーム | 非フルスクリーン時フレーム(frameAutosaveName) | CustomWindow.m:6-25 |
| NSWindow Frame FilterPanel / Bookmark / AllBookmark | 文字列(システム) | nib フレーム | 各パネルの frameAutosaveName | FilterPanelController.m:13, BookmarkController.m |
| mac.remotecontrols.GlobalKeyboardDevice.{plus,minus,play,left,right,menu,playhold}_{keycode,modifiers} | int | F1-F7/cmd+shift+control | GlobalKeyboardDevice のホットキー上書き。**クラス自体未使用のため実質無効** | GlobalKeyboardDevice.m:31-241 |

### 6.2 設定ウインドウの UI ↔ 保存値のねじれ(互換上の要点)

| 項目 | UI index → 保存値 | 根拠 |
|---|---|---|
| Sort ポップアップ | 0→0(Name), 1→2(Creation), 2→3(Modification), 3→1(Shuffle) | PreferenceController.m:1009-1025 |
| Max enlargement | 0→1, 1→2, 2→3, 3→4, 4→5, 5(no limit)→0 | PreferenceController.m:1266-1278 |
| WheelSensitivity | 保存値 = (スライダー==0 ? 0 : 2.1-スライダー値)。読取も同式 | PreferenceController.m:1180-1184 |
| Loop / GoToLastPage / OpenLink / ChangeCurrentFolder / PrevPageMode / CanScrollMode / Interpolation / BufferingMode | index=保存値(素直) | PreferenceController.m 各所 |

### 6.3 設定ウインドウのトランザクション挙動

- runModalForWindow のアプリモーダル。OK(128)で**全キーを一括書込**して synchronize → `[controller setPreferences]` で全体反映。Cancel(129)は一切書き込まない=**完全ロールバック**(PreferenceController.m:909-1625)。
- setPreferences(Controller.m:1791-2035)の反映仕様: ReadMode/SortMode の既定変更は本ごとの上書きが無い場合のみ現在の本に適用(SortMode は goTo:0 も実行)。SingleSetting 変更時は現表示を再判定して見開き⇄単ページを組み替える。OpenRecentLimit 変更時は履歴を即トリム(本を開いていれば limit+1 件まで許容)。キャッシュ上限変更は即トリム。
- 「Disposing of settings」: BookSettings/LastPages から実在しないファイルのエントリを除去。performSelectorOnMainThread 連鎖の疑似非同期+プログレスシート。キャンセルは途中結果を保存しない(PreferenceController.m:1818-1945)。

---

## 7. 永続化

### 7.1 BookSettings(本ごとの設定)完全スキーマ

トップレベルキーは **本の表示名(パスの lastPathComponent)**。パスでも alias でもない。名前衝突時は "名前#2", "名前#3"… と連番(Controller.m:786-797, 2874-2885)。値の辞書:

| 内部キー | 型 | 意味 | 書込条件 | 根拠 |
|---|---|---|---|---|
| alias | NSData | AliasHandle を平坦化したファイル参照 | 保存時必ず | Controller.m:779, 2867 |
| temppath | NSString | 保存時点のフルパス(高速照合キャッシュ) | 保存時必ず | Controller.m:780, 2868 |
| bookmarks | 配列 [{name, page(1 始まり文字列)}] | しおり | 1 件以上のとき(0 件で removeObjectForKey)。**RememberBookSettings 無関係** | Controller.m:781-785, 2869-2873 |
| readMode | NSNumber int | 本ごとの読み方向 | RememberBookSettings=YES 時の changeReadMode | Controller_input.m:2092-2094 |
| sortMode | NSNumber int | 本ごとのソート | 同 YES かつ setSortMode の p>-1 | Controller_input.m:2144-2146 |
| marks | 配列 [NSString "N" / "N-M"] | 単ページ/見開き強制指定(1 始まり) | 同 YES 時の switchSingle 系 | Controller_input.m:2909-3016 |

- 保存タイミングは「別の本へ切替時(openPage)」と「windowWillClose」の 2 箇所のみ。いずれも `count>2`(alias+temppath 以外がある)ときだけ書き込む。RememberBookSettings=NO のときは close 時に currentBookSetting を全消去してから alias/temppath/bookmarks を再設定=**bookmarks だけ生存**。
- **最終ページは BookSettings に入らない**(RecentItems/LastPages の別系統)。
- 「設定を削除」(deleteSettings、Controller.m:2612-2623)は currentBookSetting から readMode/sortMode/marks の 3 キーのみ削除(bookmarks は残す)。**defaults の BookSettings は直接書き換えないため、その後 count<=2 のまま閉じると旧エントリが残存し次回復活し得る**エッジケースあり。

### 7.2 RecentItems(最近開いた項目)

- 配列、**先頭が最新**。要素 `{alias: NSData, page: NSNumber(0 始まり先頭表示ページ), temppath: NSString}`。
- 挿入は開く時(921-941)と閉じる/切替時(nowPage を -2/-1 補正した page 付き。802-828, 2889-2918)。既存エントリは削除してから先頭挿入。トリムは挿入前に `while(count >= limit) removeLastObject`(=実質 limit 件。setPreferences では表示中 limit+1 件まで許容)。
- OpenRecentLimit==0 なら **RecentItems キー自体を削除**。メニューは Clear 等の固定 2 項目を残して逆順挿入。alias 解決不能エントリはその場で削除、"file not found" 番兵はダミー disabled 項目(Controller.m:2452-2516)。

### 7.3 LastPages(最終ページ記憶)

- 配列、**追記型(末尾追加)**。要素は RecentItems と同形。
- `AlwaysRememberLastPage`=YES かつ nowPage>0 のとき追加(既存削除→append)。NO または nowPage==0 のとき既存エントリを削除(Controller.m:829-856, 2919-2949)。
- **page==0 の本は「復帰なし」と区別できない**ため、openPage の復帰判定は page==0 のときのみ発動する設計(1.2b10 移行で page==0 エントリを削除しているのはこのため。Controller.m:318-320, 897-920)。

### 7.4 Alias(Carbon AliasHandle)の扱い

- 変換: `aliasFromPath`(CFURL→FSRef→FSNewAlias)/`dataFromAlias`(HLock+CFDataCreate)/`aliasFromData`(PtrToHand)/`pathFromAlias`(FSResolveAliasWithMountFlags(kResolveAliasFileNoUI))(Controller.m:3141-3285)。
- 解決失敗時は FSCopyAliasInfo が保持するパス文字列 → それも失敗なら **番兵リテラル文字列 `@"file not found"`** を返し、setOpenRecentMenu が isEqualToString で判定する(Controller.m:3248, 2470)。
- `pathFromAlias` 内の `if (&tempRef != NULL)` はローカル変数のアドレスで常に真(3261)。`aliasFromData` の旧実装(3215-3226)は memmove の src/dst が逆のデッドコード。
- **全 API(FSNewAlias/FSResolveAliasWithMountFlags/FSCopyAliasInfo/PtrToHand)が廃止済み**。リライトでは NSURL ブックマークデータへの一括移行が必要(§13)。

### 7.5 searchFrom 系(検索と自己修復)

- 2 パス検索: (1) temppath 文字列一致かつ alias 解決一致 → (2) alias 解決一致のみ(=移動検出)なら **temppath を新パスに書き換えて defaults を即更新**(Controller.m:3289-3404)。
- `searchFromBookSettings:key:more:YES`(openPage/strongSetBookmark のみ)はさらに「同名ファイルで旧パスが消滅」のエントリを探し、「Setting of %@ is not found. Do you want to use a setting of %@?」ダイアログの OK で **LastPages/RecentItems/BookSettings 3 箇所の alias と temppath を新パス基準に張り替える**(リネーム/移動後の設定引継ぎ。Controller.m:3406-3470)。

### 7.6 バージョン移行(Controller.m:292-524)

| 条件 | 処理 |
|---|---|
| Version キー無し(1.2b10 以前) | BookSettings/LastPages/RecentItems の全要素に temppath を追記。LastPages の page==0 エントリを削除(削除→addObject のため順序が変わる) |
| oldVersion < 1.2b14 | 数字キー 0-9 に action 39(value 0..90)、Apple Remote 6 ボタンを KeyArray へ追加。PageBarBGColor に α0.8 を適用して再アーカイブ |
| oldVersion < 1.2b17 | MouseArray に action 59(button1 mod0 / button0 mod4)を追加 |
| oldVersion < 1.2b23 | マルチタッチ仮想ボタン(1000-8000)に action 6/7(switchAction),14,15,49,50,63,64 を追加 |
| 現行 CFBundleVersion が大きい | Version を更新 |

- 比較は `versionCompare:`(NSString_Compare.m:71-90): "b" で分割しベース部・ベータ部を**単純辞書式**比較(数値比較ではない。"1.10"<"1.2"、"b10"<"b2" になる潜在問題。現行の版番号体系では偶々顕在化しない)。
- 起動時の自己修復: SkipPage 0→10 補正+value 未設定バインディングへの注入、LoupeSize/LoupeRate/SingleSetting/Thumbnail/PageBarSize の 0 値補正(Controller.m:97-260)。

### 7.7 保存タイミングの穴

- 本の状態保存(BookSettings/RecentItems/LastPages)は openPage(切替時)と windowWillClose に依存。**applicationWillTerminate は defaults synchronize のみ**のため、ウインドウを閉じずに ⌘Q した場合は「最後に閉じた/切替えた時点」の状態しか保存されない(Controller.m:2993-2996)。

---

## 8. メニュー構成

### 8.1 メニューバー全ツリー(Base.lproj/MainMenu.xib:48-355)

```
MainMenu
├─ cooViewer
│   ├─ About cooViewer ................. orderFrontStandardAboutPanel:(Credits.rtf 表示)
│   ├─ Preferences… (⌘,) .............. preferences:(Controller)
│   ├─ Services ▸(systemMenu)
│   ├─ Hide cooViewer (⌘H) / Hide Others (⌥⌘H) / Show All
│   └─ Quit cooViewer (⌘Q) ............ terminate:
├─ File
│   ├─ Open... (⌘O) ................... open:
│   ├─ Open the last page (⇧⌘O) ....... openTheLastPage:
│   ├─ Open in Same Folder ▸ .......... (空サブメニュー=動的生成。openFromSameDir:)
│   ├─ Recent Books ▸ ................. (動的。autoenablesItems=NO。固定項目: ── / Clear→clearRecent:)
│   └─ Close (⌘W) ..................... performClose:(FirstResponder)
├─ Edit
│   └─ Undo(⌘Z)/Redo(⇧⌘Z)/Cut(⌘X)/Copy(⌘C)/Paste(⌘V)/Delete/Select All(⌘A)(全て FirstResponder)
├─ Slideshow
│   └─ Start/Stop ..................... slideshow:(timerSwitch でタイトルトグル)
├─ Bookmark
│   ├─ Edit Bookmark... ............... editBookmark:(表示中=シート/非表示=全しおり編集)
│   ├─ ──
│   └─ (以降しおりを動的生成 ......... goBookmark:、representedObject=1 始まり page)
├─ Setting
│   ├─ Read from ▸ Right to Left / Left to Right / Right to Left (single) / Left to Right (single)
│   │                                    changeReadModeMenu:(readMode 0/1/2/3、state On)
│   ├─ Sort ▸ Name / Creation Date / Modification Date / ── / Shuffle
│   │                                    changeSortModeMenu:(sortMode 0/2/3/1。日付 2 種は canSortByDate 必須)
│   ├─ Switch Single/Bind ............. switchSingle:
│   ├─ ──
│   └─ Delete Settings ................ deleteSettings:
├─ View
│   ├─ Fit to Screen (⌘1) ............. fitToScreen:          (fitScreenMode==0 で state On)
│   ├─ Fit to Screen Width (⌘2) ....... fitToScreenWidth:     (==1)
│   ├─ No Scale (⌘3) .................. noScale:              (==2)
│   ├─ Fit to Screen Width(divide) (⌘4) fitToScreenWidthDivide:(==3)
│   ├─ ──
│   ├─ Rotate Left (⌘5) ............... rotateLeft:
│   ├─ Rotate Right (⌘6) .............. rotateRight:
│   ├─ ──
│   └─ Filter (⇧⌘F) ................... openFilterPanel:(FilterPanelController)
└─ Window(systemMenu)
    ├─ Fullscreen (⌘F、xib 初期 state=on) fullscreen:
    └─ Minimize (⌘M) .................. performMiniaturize:
```

### 8.2 コンテキストメニュー(RightMenu、MainMenu.xib:2281-2341)

Go to FirstPage / Start Slideshow / ── / Previous Bookmark / Add Bookmark / ── / Previous Folder / ── / View at Original Size / Show Thumbnail / Show in Finder。全項目 `contextAction:` に接続され、validateMenuItem がカーソル左右で動的リネーム(§5.11)。

### 8.3 メニュー検証の実装方式(重要な癖)

`validateMenuItem`(Controller.m:2041-2316)は **ローカライズ済みタイトル文字列の比較** で分岐する(タグ/セレクタ方式でない)。言語切替・項目名変更に脆弱。"Edit Bookmark..." は非表示時も YES を返す(NO はコメントアウト済み)。キー action 48-50/60-62 も「メニュー項目をタイトル検索して performAction」という間接実行。

### 8.4 Dock メニュー

画像非表示時のみ「Open the last page」1 項目を動的生成(Controller.m:1131-1144)。

---

## 9. リモコン対応(Apple Remote)

### 9.1 スタック構成

```
AppleRemote(機種別 cookie マッピング)─ 継承 → HIDRemoteControlDevice(IOKit HID 共通)─ 継承 → RemoteControl(抽象基底)
        │ delegate
        ▼
MultiClickRemoteBehavior(ホールド/マルチクリック合成の中間層)
        │ remoteButton:pressedDown:clickCount:
        ▼
Controller(Controller_input.m:8-94)
```

- 構築(Controller.m:566-586): AppleRemote を**排他モード**(kIOHIDOptionsTypeSeizeDevice)で生成、MultiClickRemoteBehavior(simulateHoldEvent=YES、クリックカウント無効)を仲介デリゲートに。アプリのアクティブ化/非アクティブ化で startListening/stopListening。569 行の setDelegate:self は 578 行で即上書きされる無意味な呼び出し。
- KeyspanFrontRowControl と GlobalKeyboardDevice はプロジェクトに含まれ import されるが**一切インスタンス化されない完全なデッドコード**。

### 9.2 ボタンイベントとキーバインディングへの合流

- ボタン識別子はビットフラグ: Plus=1<<1, Minus=1<<2, Menu=1<<3, Play=1<<4, Right=1<<5, Left=1<<6(ホールドは <<6 シフト。RemoteControl.h:42-65)。
- **ボタン識別子の整数値をそのまま unichar 化した 1 文字文字列+modifier=100** で通常のキーバインディングとして KeyArray に格納・照合するハック(Controller_input.m:20-49)。
- remoteButton: は pressedDown==NO を無視し、毎回 UpdateSystemActivity でスリープ抑止。ホールド系は通常ボタンに読み替えて appleRemoteHoldDown=YES(static 変数)→ 0.1 秒間隔の performSelector 自己再帰で長押しリピート。
- サムネイル表示中は thumController.appleRemoteAction: へ委譲。設定のキー編集中(inKeyEdit=COTextView の背景色が lightGray かで判定するハック)は setKeyCharacters: に転送し、**リモコンボタンをキー割当に登録できる**(PreferenceController.m:2251-2330)。

### 9.3 HID 層の要点

- cookie 文字列("31_29_28_19_18_" 等)→ボタン ID のメモリ内辞書。AppKit バージョン(Tiger/Leopard/SnowLeopard 10.6.2+)で 3 セットを切替(AppleRemote.m:121-184)。アルミ 7 ボタンモデルの中央ボタンも Play に登録。
- 排他アクセスの譲り合いは分散通知 `mac.remotecontrols.RequestForRemoteControl` / `FinishedUsingRemoteControl`(RemoteControl.m:33-41, HIDRemoteControlDevice.m:520-529)。
- SecureEventInput の on/off で排他が失われる問題への対策として IORegistry の kIOBusyInterest 通知でデバイスを開き直す(AppleRemote.m:58-119, 267-315)。
- MultiClickRemoteBehavior: 0.4 秒でホールド合成、クリックカウント(0.35 秒窓)は cooViewer では未使用。Right/Left/Play/Menu 等 up イベントを送らないボタンには release を合成(AppleRemote.m:186-198)。
- **現代 macOS では IR レシーバも AppleIRController サービスも存在しないため initWithDelegate が nil を返し、スタック全体が事実上不活性**。

---

## 10. ローカライズ

### 10.1 構成

| 資産 | 内容 | 根拠 |
|---|---|---|
| knownRegions | en / Base / ja(developmentRegion=en) | project.pbxproj:669-675 |
| Base.lproj/MainMenu.xib | UI 実体(英語) | — |
| ja.lproj/MainMenu.strings | xib の日本語訳 | — |
| Localizable.strings | en(UTF-16LE)/ja(UTF-8)。en は genstrings 出力 6 世代分連結の 331 エントリ(ユニーク 136 キー)で、位置指定化 1 件を除き恒等マッピング | en.lproj/, ja.lproj/ |
| InfoPlist.strings | **リポジトリ直下(非 .lproj)= 全言語共通**。UTF-16BE。CFBundleName と NSHumanReadableCopyright "©coo, 2005" の 2 キーのみ | InfoPlist.strings:1-4 |
| en.lproj/MainMenu.strings | **プロジェクト未登録のデッドファイル**(現 xib に無い旧 ID を含み、Filter 系新 ID を欠く) | project.pbxproj |
| localize/*.xcloc | Xcode 11.3.1 の Export For Localization 出力。**ja.xliff が誤って Resources フェーズに登録されアプリバンドルへコピーされる** | project.pbxproj:250, 699 |
| localize_helper/ | 旧 32bit 版の AppleGlot 辞書(cooViewer.app.ad.txt、1640 項目)から ja.xliff へ訳を移植する localize.rb | localize_helper/localize.rb:1-38 |

### 10.2 既知のローカライズバグ

- **ja 訳の取り違え**: id3704(ReduceViewMode)=「表示モードを拡大」、id3888(EnlargeViewMode)=「表示モードを縮小」。結果としてマウス側は両方「拡大」、キーボード側は両方「縮小」と表示される(ja.lproj/MainMenu.strings:1105-1115)。
- 「Setting of %@ is not found...」だけ日本語未訳(ja.lproj/Localizable.strings:320)。
- 「Last/TopPage」の訳語順が MainMenu.strings と Localizable.strings で逆。
- 原文タイポ「Remember chenged book setting of all books」(xib id4368)。
- validateMenuItem・contextAction・アクションメニュー無効化が**ローカライズ済み文字列比較**のため、翻訳変更が挙動に影響し得る(§8.3)。

---

## 11. ビルドと依存関係

### 11.1 プロジェクト構成

- 単一 Xcode プロジェクト・単一 app ターゲット(objectVersion 45、LastUpgradeCheck 1130)。**ARC 全面無効(MRC)**。CLANG_ENABLE_OBJC_WEAK=YES。コード署名なし(CODE_SIGN_IDENTITY="")。
- ビルド構成 5 種: Development / Deployment / Development2 / Deployment2 / **Default(defaultConfigurationName。唯一 GCC_ENABLE_OBJC_EXCEPTIONS=NO)**。共有スキームは cooViewer(Run=Development)と cooViewer_deploy(Run=Deployment)。Development2/Deployment2/Default はスキーム未参照(project.pbxproj:1157-1181)。
- **INFOPLIST_FILE=info.plist(小文字)だが実ファイルは Info.plist**。ケースセンシティブ FS ではビルドが壊れる(project.pbxproj:882)。
- MACOSX_DEPLOYMENT_TARGET=10.8(形骸化。実効最小 OS はサブモジュール側 10.13/README の Monterey 12.5+ に律速)。
- コンパイル対象は 37 .m ファイル(project.pbxproj:747-790)。ZERO_LINK 等の廃止済み設定キーが残存。

### 11.2 XADMaster 再帰ビルド

- ビルド先頭の ShellScript フェーズが `cd XADMaster && xcodebuild -scheme XADMaster -configuration Release CONFIGURATION_BUILD_DIR=../ clean build` を実行し、**XADMaster.framework と UniversalDetector.framework をリポジトリルートに生成**。これを FRAMEWORK_SEARCH_PATHS=$(SRCROOT) でリンクし、CopyFiles(CodeSignOnCopy)で app の Frameworks/ に埋め込む(project.pbxproj:727-743, 864-869)。
- outputPaths が空のため**毎ビルド必ず実行され、しかも clean build で毎回フルリビルド**。ホストの -configuration/-arch は伝播しない(常に Release)。
- リンク: Cocoa, System(明示・レガシー), IOKit, Carbon(レガシー), XADMaster, UniversalDetector, Quartz(**弱リンク**)。

### 11.3 サブモジュール

| サブモジュール | URL | 役割 | ライセンス |
|---|---|---|---|
| XADMaster | https://github.com/plife18/XADMaster.git | 多形式アンアーカイバ(The Unarchiver エンジン)。RAR5 対応フォーク | LGPL 2.1(同梱 Licence_xad.txt は LGPL v3 全文。§14) |
| UniversalDetector | https://github.com/plife18/universal-detector.git | 文字コード自動判定(Mozilla universalchardet 移植) | LGPL 2.1 |

- XADMaster プロジェクトは `../UniversalDetector` を相対参照するため **兄弟ディレクトリ配置が前提**(XADMaster.xcodeproj projectReferences)。

### 11.4 孤児ファイル一覧(リポジトリにあるがビルド不参加)

| ファイル | 正体 |
|---|---|
| COImageLoader_temp.m | HetimaUnZip 併用時代の旧版ローダ(mode 1 が生きている等の差分あり)。pbxproj 未参照 |
| info copy.plist | Jaguar 時代の旧 Info.plist("1.0b4 for Jaguar") |
| ﾇPRODUCTNAMEﾈ-Info.plist | Xcode テンプレート(«»が文字化けしたファイル名) |
| version.plist | 旧 Xcode テンプレート残骸(NibPBTemplates) |
| MainMenu~.nib/ | 旧形式 nib バックアップ(内部に .svn) |
| Controller.m_1.xcclassmodel/ | Xcode 3 のクラスモデル図 |
| en.lproj/MainMenu.strings | プロジェクト未登録(§10.1) |
| docs/ | 旧公式サイト一式(index/manual/other.html) |
| localize/en.xcloc | 未参照(ja.xcloc 内 ja.xliff のみ誤参照) |
| localize_helper/ | 翻訳移行スクリプト一式 |
| cooViewer.xcodeproj/cookie.mode1/mode2/perspective | Xcode 2.x のユーザー UI 状態ファイル |
| .svn/(3 箇所) | SVN 1.x メタデータ(旧 pbxproj の svn-base に ppc/i386 設定が残存) |
| up.tiff | バンドルされるがコード・xib から未参照のデッドリソース |
| Licence*.txt(3 種) | **Resources フェーズに含まれずバンドルには入らない**(リポジトリ同梱のみ) |

### 11.5 リソース対応表(実行時に参照されるもの)

| リソース | 用途 | 根拠 |
|---|---|---|
| broken.png / empty.png | デコード失敗ページ/空ブックのプレースホルダ | COImageLoader.m:85, 216 |
| cross.tiff | ルーペ用十字カーソル | CustomImageView.m:1520-1521 |
| bookmark.tiff / bookmark_a.tiff | サムネイルのしおり印+onlyBookmark トグルボタン | ThumbnailMatrix.m:70 |
| comic.tiff / comic_a.tiff | comicMode トグルボタン | MainMenu.xib |
| base.tiff / left.tiff / right.tiff / close.tiff | サムネイルパネルのツールバー(next=左矢印) | MainMenu.xib:2612-2633 |
| updown.tiff | COPopUpTextField の装飾 | COPopUpTextField.m:27 |
| icon.icns + coo_*.icns 12 種 | アプリ/書類アイコン | Info.plist:1472-1473 |
| Credits.rtf | About パネル(XAD + Remote Control Wrapper クレジット) | §14 |

---

## 12. 既知の癖・バグ・デッドコード

本章は全サブシステム調査で検出された癖・バグ・デッドコードの**横断台帳**である。§4〜§11 で文脈と共に述べた項目も、リライト時のチェックリストとして再掲する。「挙動保存リライトの際にバグを含めて再現するか」の明示判断が必要な項目には ★ を付す(判断の指針は §13.3)。

### 12.1 確定バグ(現実の操作で観測され得るもの)

| # | 内容 | 影響 | 根拠 |
|---:|---|---|---|
| 1 | ★ getMouseAction case 5(Skip/BackSkip**)に break がなく case 6(nextpage)へフォールスルー | マウスに action 5 を割り当てると skip 実行後さらに 1 ページ進む | Controller_input.m:1179-1226 |
| 2 | ★ マウス action 28/29 の UI 表示名(Show in Finder left/right)が実装と左右逆 | ラベルと逆の側のファイルが Finder に表示される | Controller_input.m:1476-1513, PreferenceController.m:775-776 |
| 3 | ja 訳の取り違え: EnlargeViewMode=「表示モードを縮小」、ReduceViewMode=「表示モードを拡大」 | 設定画面の日本語ラベルが逆(§10.2) | ja.lproj/MainMenu.strings:1105-1115 |
| 4 | constrainFrameRect の非フルスクリーン画面超過フォールバックが NSMakeRect(0,0,画面高/4,画面幅/4) と縦横入替 | 異常時にウインドウが縦横比の壊れたサイズになる | CustomWindow.m:66 |
| 5 | lookaheadAndCompose の isSmallImage 判定でインデックスとページ番号の対応が逆([1]→nowPage+1, [0]→nowPage+2。表示側は [0]→nowPage+1) | marks の強制単ページ/強制ペア指定が先読み合成時のみ 1 ページずれ得る | Controller.m:1344-1345 vs 1712,1717 |
| 6 | openPage last:YES の isSmallImage が画像 [count-2] にページ番号 count-1 を渡す | 末尾から開く際 marks 判定が 1 ページずれ得る | Controller.m:970-986 |
| 7 | application:openFile: が成功時も常に NO を返す | AppKit には常に「開けなかった」と報告される | Controller.m:625-636 |
| 8 | goToPar: に上限クランプがない | par=1.0(数字 9 の次の 100% 相当は既定割当に無いが goToPar 直呼びで)nowPage=count → 巻末 loopCheck 処理へ入る | Controller_input.m:2795-2813 |
| 9 | Interpolation/MaxEnlargement 変更時に screenCacheArray を破棄しない | Old モードで旧設定の合成画像が誤再利用され、新設定が見開きに反映されない | Controller.m:1934-1958 |
| 10 | ソート変更時も screenCacheArray を破棄しない | Old モードでソート前の見開き合成が誤ヒットし得る | Controller.m:1554-1579, Controller_input.m:2110-2150 |
| 11 | nextFolder/backFolder で NSOnState 項目が無いと nil のまま openFromSameDir: が呼ばれる | 潜在クラッシュ/無動作 | Controller_input.m:2571-2641 |
| 12 | trashFile の AppleScript フォールバックが「Finder の現在の選択」を削除する | selectFile 失敗時やユーザーが選択を変えていた場合、無関係なファイルを削除し得る。削除失敗の通知もない | Controller_input.m:3095-3113 |
| 13 | ゴミ箱移動後にローダ・completeMutableArray・nowPage・ページ数表示・キャッシュを一切更新しない | 本を開き直すまで総数と表示がずれたまま。書庫/PDF では開いている書庫ファイル自体が Trash へ移動する(§4.12) | Controller_input.m:3079-3115, COImageLoader.m:135-152 |
| 14 | XADWrapper が nameOfEntry: の nil を検査せず addObject:nil する | ファイル名デコード不能エントリを含む書庫で NSInvalidArgumentException | XADWrapper.m:26-27 |
| 15 | itemForPath: で名前未発見時に NSNotFound を int に切り詰めて contentsOfEntry: へ渡す | 潜在的な範囲外アクセス | XADWrapper.m:85,92 |
| 16 | finderCompareS: が UniChar[MAXPATHLEN=1024] スタックバッファに長さ検査なしで getCharacters: する | 1024 UTF-16 単位超のパス/ファイル名でスタックバッファオーバーフロー | NSString_Compare.m:17-21 |
| 17 | setSameFolderMenu で fileExistsAtPath:isDirectory: の戻り値未チェック(isDir 未初期化参照の余地) | 未定義動作の余地 | Controller.m:2398-2400 |
| 18 | savedSearch 分岐でも isDir 未初期化参照+MDItemCopyAttribute が NULL の場合の CFRelease(NULL) | 検索結果パスが消えていると潜在クラッシュ | COImageLoader.m:411-424 |
| 19 | FilterPanelController が KVO removeObserver を一切呼ばない(deleteFilter でも解除しない) | リーク/解放後通知クラッシュの素地 | FilterPanelController.m:124, 169-178 |
| 20 | CIFilters 復元が unarchivedObjectOfClass:[NSObject class] でエラー無視 | NSSecureCoding 制約下で黙って nil になり得る(フィルタ設定消失) | FilterPanelController.m:48 |
| 21 | SlideshowDelay=0.0(未設定)のまま開始すると NSTimer interval 0 の最速連写(下限ガードなし) | 実質フリーズ的挙動 | Controller_input.m:2929-2933 |
| 22 | ★ マウス版スライドショー(action 23)は前処理で必ず停止した後に無条件で slideshow: を呼ぶ | マウス割当ではスライドショーを「停止できない」(キー版 action 17 のみフラグで停止維持) | Controller_input.m:804-808, 1428-1432 |
| 23 | cursorTimer が発火時に非フルスクリーン/非キーだと nil 化されない | 以後カーソル自動非表示が再スケジュールされない | CustomWindow.m:201-218 |
| 24 | ThumbnailMatrix のしおりアイコンは「描画矩形がセル枠と NSEqualRects で完全一致」した時のみ描画 | 全面再描画・ウインドウ再表示でアイコンが消える | ThumbnailMatrix.m:42-79 |
| 25 | removeBookmarkIconAtRow が配列走査中に removeObject し index を戻さない | 同一セルの複数登録時に取り逃す | ThumbnailMatrix.m:31 |
| 26 | OpenRecentLimit=0 のとき設定画面のフィールドに反映されない(真偽 if ガード) | UI 上は前回値が見えたまま | PreferenceController.m:1047-1049 |
| 27 | changeOpenWithCheck/changeCreatorCheck の outlet が xib 未接続 → [nil state]==NSOffState で OK のたび NO 上書き | ChangeOpenWith/ChangeCreator 機能は設定 UI から永久に OFF(参照コード自体もコメントアウト済み) | PreferenceController.h:26-27, PreferenceController.m:998-1007, Controller.m:1047-1105 |
| 28 | しおり編集シート(現在の本)は共有 NSMutableArray を直接編集し Cancel で取り消されない | 全しおり編集(コピー編集で Cancel 有効)と非対称(§4.7.2) | BookmarkController.m:75-150 |
| 29 | versionCompare: がベース部・ベータ部とも単純辞書式比較(数値比較でない) | "1.10"<"1.2"、"b10"<"b2"。現行の版番号体系(1.2b25 等)では偶々顕在化しない | NSString_Compare.m:71-90 |
| 30 | ホイールの同方向タイマー再スケジュール防止がない(本体・サムネイル両方) | 高速回転で複数回発火し得る。閾値もイベント毎判定(累積でない) | Controller_input.m:1903-1932, ThumbnailController.m:1388-1435 |
| 31 | 完全解析不能な書庫が「empty.png 1 ページだけの本」として開けてしまう | mode=2 のまま contents 空 → init 末尾の empty.png 追加が openPage のガード(itemCount<1)をすり抜ける | COImageLoader.m:84-86, 477-481 |
| 32 | パスワードのバイト列化がファイル名から検出したエンコーディングに依存 | エントリ名が ASCII のみの旧式 zip では cp1252 判定になり Shift-JIS パスワードが通らない。エンコーディング選択 UI なし | XADArchiveParser.m:695-698, 1235-1243 |
| 33 | NSNumberFormatter カテゴリが**アプリ内の全インスタンス**の部分入力を 0-9 と '.' に制限 | マイナス・カンマ・指数入力不可。'.' を許すのにエラー文言は "Input is not an integer" という矛盾 | NSNumberFormatter_Adding.m:14-24 |
| 34 | AccessorySettingView の pageBar リサイズ(mode3)に visibleRect 境界チェックがない | プレビュー上で画面外までリサイズできる(移動 mode2/4 は境界で巻き戻す) | AccessorySettingView.m:348-375 vs 317-321 |
| 35 | pathFromAlias の解決失敗番兵がリテラル文字列 @"file not found" で、setOpenRecentMenu が isEqualToString 判定 | 「file not found」という名前の実ファイルと衝突し得る理論的問題 | Controller.m:3248, 2470 |
| 36 | randomCompare: が呼び出し毎に srand(rand()%time(NULL)) で再シードする一貫性のない比較器 | sortUsingSelector: に非決定的比較器を渡すのは未定義動作に近く、シャッフル結果はソート実装依存で偏る | NSString_Compare.m:28-43 |
| 37 | ThumbnailController の疑似非同期充填とバブルサムネイルが Controller の lock を経由せず loadImage する | lock 保持中の先読みスレッドと cacheArray・XADArchive(再入不安全)へ同時アクセスし得る(§4.6) | ThumbnailController.m:73-156, AccessoryView.m:313 |

### 12.2 メモリ管理・スレッド安全性の危険箇所

MRC(手動 retain/release)前提。リライトでは ARC/Swift 化により大半が自然解消するが、**現挙動(リーク由来の「たまたま生きているオブジェクト」への依存)がないか**の確認用に列挙する。

| # | 内容 | 根拠 |
|---:|---|---|
| 1 | XADWrapper dealloc が release 直前に `[archive init]` を呼ぶ異常コード。現行 XADMaster では旧 parser とファイルハンドルがリークし、**本を閉じても書庫のファイルハンドルはプロセス終了まで開いたまま** | XADWrapper.m:64-73, XADMaster/XADArchive.m:71-89 |
| 2 | XADWrapper init で XADItem を autorelease せず配列へ追加(retain 2)+ XADItem が wrapper を retain する**循環参照**。COImageLoader が release しても XADWrapper/XADArchive は解放されない(書庫を開くたびにリーク) | XADWrapper.m:15-36, XADItem.m:14-38 |
| 3 | setCurrentBookPath: は旧値を解放しない(呼び出し側が事前 release する規約)。setCurrentBookPathAndOldBookPath: は既存 oldBook* を解放せず上書き=経路によりリーク | Controller.m:3474-3492 |
| 4 | windowWillClose が currentBook* → oldBook* へ retain/release なしの所有権移動 | Controller.m:2965-2970 |
| 5 | thumController の imageLoader は retain されない生ポインタ。openPage の旧 loader release(864 行)から thumController への差し替え(1028 行)までダングリング期間がある | ThumbnailController.m:49-59, Controller.m:864, 1028 |
| 6 | openPage は lock バリアなしで旧 imageLoader を release。先読みスレッド実行中に履歴等から開き直すと解放済み loader に触れる余地 | Controller.m:864 |
| 7 | メインスレッドのビジーウェイト 3 箇所(lockedImageDisplay 内、§4.6)。先読みスレッドの例外死で以後の [lock lock] バリアが**恒久デッドロック** | Controller.m:1686, 1710, 1714 |
| 8 | threadCount は lock 取得後に増えるため、detach 直後に threadCount>0 チェックをすり抜けるレース → 2 枚目を待たず単ページ表示になる | Controller.m:1713-1714 |
| 9 | imageMutableArray/cacheArray/screenCacheArray は非スレッドセーフな NSMutableArray のまま複数スレッドで共有 | Controller.m:764-765, 1700, 1735 |
| 10 | threadStop はロック外で書かれロック内で読まれる volatile なしの BOOL。static グローバル状態も複数(appleRemoteHoldDown / dontSleepTimer / GlobalKeyboardDevice の lastEvent) | Controller_input.m:8, 2916, GlobalKeyboardDevice.m:218 |
| 11 | AccessoryView の setInfoString/setPageString が生成済み NSAttributedString に**再 init** する不正ハック(現代ランタイムでは不正) | AccessoryView.m:757-814 |
| 12 | BookmarkController: bookName の retain/release が経路依存の綱渡り、directoryPath/pathDic は非 retain 参照 | BookmarkController.m:27-30, 79 |
| 13 | PreferenceController の lastInput のメモリ管理が新規追加(alloc)と編集(retain)で非対称 | PreferenceController.m:2144-2145, 2529-2530, 2644, 2691 |
| 14 | ThumbnailController の pathArray はローダ内部配列への非 retain 参照(clearAll の release はコメントアウト) | ThumbnailController.m:56 |
| 15 | MultiClickRemoteBehavior の executeClickCountEvent: が finalClickCount を @synchronized 外で読む競合+delegate 配送の合間に **メインスレッドを 0.1 秒 sleep でブロック** | MultiClickRemoteBehavior.m:117, 131 |
| 16 | HIDRemoteControlDevice initWithDelegate: がデバイス不在時に [super dealloc] を直接呼んで nil を返す危険イディオム(RemoteControl が retain 済みの delegate はリーク) | HIDRemoteControlDevice.m:93-95 |
| 17 | CustomWindow.updateTrackingRect が旧 trackingRect を削除せず**累積登録**する | CustomWindow.m:192-198, Controller.m:1034 |
| 18 | COPDFImage/COPDFImageRep の setLinkList: が旧値を release しない(init 経路 1 回のみで実害限定) | COPDFImageRep.m:100-108 |

### 12.3 デッドコード台帳

#### 12.3.1 ファイル/クラス単位

| 対象 | 内容 | 根拠 |
|---|---|---|
| COImageLoader_temp.m | HetimaUnZip 併用時代の旧版ローダ。pbxproj 未参照でビルド外。mode 1 が生きている・fileTypes ハードコード・SJIS 固定など現行版と差分多数(§11.4) | project.pbxproj(参照なし) |
| GlobalKeyboardDevice | Apple Remote をグローバルホットキー(cmd+shift+control+F1..F7)で模倣する Carbon クラス。Controller.h で import されるのみで**一切インスタンス化されない** | GlobalKeyboardDevice.m:31-241, Controller.h:12 |
| KeyspanFrontRowControl | Keyspan RF リモコン対応クラス。import のみで未インスタンス化 | KeyspanFrontRowControl.m:37-85, Controller.h:13 |
| 孤児ファイル群 | info copy.plist / ﾇPRODUCTNAMEﾈ-Info.plist / version.plist / MainMenu~.nib / Controller.m_1.xcclassmodel / en.lproj/MainMenu.strings / up.tiff / .svn ほか(§11.4 の全表参照) | §11.4 |

#### 12.3.2 コード断片単位

| 場所 | 内容 |
|---|---|
| Controller.m:11-30 | スレッド/計測テンプレのコメント(`lookaheadThread` の名前はここにのみ存在) |
| Controller.m:184 | `viewBackGround = [viewBackGround colorWithAlphaComponent:1]` の結果未使用(デッド代入) |
| Controller.m:501-519 | versionCompareTest(テストコードのコメントアウト) |
| Controller.m:698-717 | progressIndicator 周りのベジェ描画(コメントアウト) |
| Controller.m:1047-1105 | ChangeCreator/ChangeOpenWith ブロック全体(コメントアウト。CFBundleSignature 参照もここのみ) |
| Controller.m:1206-1222 | loadImage の rep ピクセル正規化ブロック(コメントアウト。§3.2 の「単位系はポイント」の根拠) |
| Controller.m:3215-3226 | aliasFromData の旧実装(しかも memmove の src/dst が逆) |
| Controller.m:2764-2779 / Controller.h:39 | Controller 側 rotateMode ivar は書き込み専用(実体は CustomImageView 側) |
| Controller.h | accWindow/recentItems/bookSettings/loopSwitch/fullscreenRect 等のコメントアウト ivar。lastInput ivar は Controller.m では未使用 |
| Controller_input.m:381-383, 1944-1949 | keyAction case 13 の空 if ブロック、Finder 表示のパッケージ判定(コメントアウト) |
| Controller_input.m:2737-2757 | `goTo:page array:` の array 引数は完全に無視されるデッドパラメータ |
| Controller_input.m:3057-3066 | trashLeft の if/else 両分岐が同一(デッド分岐) |
| Controller_input.m:945 | multiTouchAction のフォールバック行の単項 `!` による結果破棄(タイプミス、実害なし) |
| COImageLoader.m:147, COImageLoader.h:65 | mode==5(dummy)は条件式のみで代入なし。mode==1 も現行ビルドで到達不能。ヘッダの「1=zip, 2=rar」コメントは実態と不一致 |
| COImageLoader.m:217 | itemAtIndex: 末尾の `return nil;`(broken.png フォールバックにより到達不能) |
| COImageLoader.h:9, 25 | thumbnailArray / subArchiveContainer ivar(初期化/解放以外未使用) |
| CustomImageView.h/.m | ivar needFirstScroll/rightPage/timer/selector/lensRect/tempPageNum(ivar 版)、setting/wheelSetting:(代入のみ)、fillBG・CIImage 系ヘルパ・setLoupeRate 内表示コード(全てコメントアウト)、ファイルスコープ `NSTimeInterval elapsed=0`(CustomImageView.m:469) |
| CustomWindow.h:19 | view ivar に IBOutlet 宣言がない(nib 接続依存) |
| FullImageView.m | spaceBarAction(scrollToLast と同一実装、呼び出し元なし) |
| AccessoryView.h:37 | pageMoverNum ivar 未使用。resetCursorRects の十字カーソル処理もコメントアウト(AccessoryView.m:909-930) |
| AccessorySettingView.m:64, 179 | drawRect の `positionSettingMode>=0` は常に真 → 末尾の [super drawRect:] 到達不能 |
| COColorPopUpButton.m:5-9 | awakeFromNib の "Brown" 分岐(Brown 項目は追加されない) |
| COPopUpTextField.m:4-10 | sizeToFit の同一 setFrame 2 回呼び |
| PreferenceController.m | 旧 SkipPage フィールド関連・タブ高さ可変・willDisplayCell・pageBar 旧保存コード(コメントアウト各所)。mousePanelClickPopUpButton の +600〜+1000 分岐(xib メニュー 6 項目のため到達不能)。keyConfigAction の NSHomeFunctionKey 二重分岐(2 つ目デッド) |
| NSDictionary_Adding.m:54-56, 109-111 | ソート順序配列に無い action のフォールバックが NSString ポインタ比較(全 action が配列内のため到達しない) |
| NSNumberFormatter_Adding.m:25-55 | 範囲指定版 API 実装 2 つ(コメントアウト) |
| HIDRemoteControlDevice.m | remoteIdSwitchCookie(呼び出しゼロ)、previousRemainingCookieString 処理・cookies calloc・usage/usagePage 取得(未使用) |
| GlobalKeyboardDevice.m | unregisterHotKey(コメントアウト) |
| ThumbnailController.m | pathDic ivar(代入なし)、loadImage 内しおり直描きコード約 40 行(コメントアウト)、sort: の同値再代入分岐、infoDic の "last"(実質デッドペイロード)、setBookmarkImageCellWithInfo の "back"(コメントアウト) |
| main.m:1-10 | «PROJECTNAME» プレースホルダ未展開のテンプレコメント |
| docs/other.html:34-283 | 既知バグ・ToDo・実装メモが全て HTML コメント内のデッドコンテンツ |

### 12.4 廃止/非推奨 API 使用一覧

| API | 使用箇所 | 現代の代替 |
|---|---|---|
| AliasHandle 系(FSNewAlias / FSResolveAliasWithMountFlags / FSCopyAliasInfo / PtrToHand / DisposeHandle) | Controller.m:3141-3285 | NSURL ブックマークデータ(§13.5 の移行参照) |
| NSRunAlertPanel(全 5 箇所)/ NSBeginAlertSheet / NSOKButton / NSCancelButton | Controller.m:909, 3029, 3422, 3508, Controller_input.m:3081, PreferenceController.m | NSAlert(beginSheetModalForWindow) |
| runModalForWindow + stopModalWithCode(128/129) | Controller.m:1107-1127, PreferenceController.m:909-1625, BookmarkController.m | シート/非モーダルウインドウ |
| NSWorkspace performFileOperation:NSWorkspaceRecycleOperation | Controller_input.m:3090-3094 | NSWorkspace recycleURLs: / NSFileManager trashItemAtURL: |
| NSArchiver / NSUnarchiver(色・フォントの永続化) | PreferenceController.m:1458-1476, Controller.m:177-184, AccessoryView.m | NSSecureCoding / 成分値の辞書保存(§13.5) |
| NSDisableScreenUpdates / NSEnableScreenUpdates | Controller.m:1653-1655 | (廃止。CATransaction 等) |
| detachNewThreadSelector(表示のたび使い捨てスレッド) | Controller.m:1701, 1761, Controller_input.m:2843-2904 | serial DispatchQueue / Operation / Swift Concurrency |
| UpdateSystemActivity(OverallAct) | Controller_input.m:22, 2941 | IOPMAssertion / NSProcessInfo beginActivity |
| Carbon RegisterEventHotKey / InstallEventHandler | GlobalKeyboardDevice.m(デッドコード) | (移植不要) |
| UCCompareTextDefault(Carbon 照合) | NSString_Compare.m:5-26 | localizedStandardCompare: |
| [NSImage imageFileTypes] | COImageLoader.m:15-36, 66-69 | UTType(imageTypes) |
| NSMatrix(サムネイルグリッド) | ThumbnailController.m ほか | NSCollectionView |
| NSBorderlessWindowMask / NSCompositeSourceOver / NSOffState/NSOnState / NSScaleNone 等の旧定数 | AccessoryWindow.m, CustomImageView.m ほか全域 | 新名称の enum |
| MDQueryCreate 同期実行(savedSearch) | COImageLoader.m:392-443 | NSMetadataQuery(非同期) |
| bestRepresentationForDevice / removeFileAtPath: / directoryContentsAtPath: | COImageLoader_temp.m(ビルド外) | (移植不要) |
| IOKit HID(kIOHIDDeviceUserClientTypeID 直叩き) | HIDRemoteControlDevice.m | (Apple Remote 自体が §13.1 の削除候補) |
| カテゴリによる NSNumberFormatter メソッド上書き | NSNumberFormatter_Adding.m | サブクラス化 / formatter delegate |

### 12.5 表記・文言・データ形式の癖

- 原文タイポ「Remember **chenged** book setting of all books」(xib id4368)。
- defaults キー名タイポ `AllBookmarkSplitPotision`(**実キーとして稼働中**。互換維持時はタイポごと引き継ぐか一度だけの移行が必要)。
- マニュアルの誤植: page up/down の上下逆表記(§5.10 で実装側を正と確定)、「右の画像を Finder に表示」の説明が左のコピペ、「指定ページへ」説明 1 行目のコピペ、「フルクスリーン」、HTML 閉じタグ重複(docs/manual.html:446, 429, 118, 517-519)。
- ページバー表示の既定キーは o だが、1.0b5 以前を起動したことがある環境では @ が残る(保存済み設定を上書きしない移行方針の遺物。docs/manual.html:150)。
- 設定画面のキー/マウス表の表示順は NSDictionary_Adding.m:33-113 のハードコード順序配列が正式仕様(コメントに全 action 対応表あり)。
- setPreferences の ShowNumber トグル時の見開き書式は区切り " / " で readMode の左右順を考慮しない(通常表示 pageTextFieldString は " | " で順序考慮。Controller.m:1973 vs 2543-2545)。
- AppleRemote.h/HIDRemoteControlDevice.h のライセンスコメントに引用符の文字化け(エンコーディング混在の痕跡)。
- inKeyEdit(設定のキー入力待ち)判定が「COTextView の背景色が lightGray か」というハック(PreferenceController.m:2251-2257, COTextView.m:32-41)。
- キーの 1.2b14 移行で追加された Apple Remote バインディングは、ボタン定数(1<<1〜1<<6)をそのまま unichar 化した制御文字を "key" に持つ(§9.2)。バインディングデータの検証時に注意。

---

## 13. 近代化に向けたメモ

### 13.1 削除候補と根拠

| 削除候補 | 根拠 | 条件/注意 |
|---|---|---|
| Apple Remote スタック全体(RemoteControl / HIDRemoteControlDevice / AppleRemote / MultiClickRemoteBehavior) | 2013 年頃以降の Mac に IR レシーバがなく、AppleIRController サービスも存在しないため initWithDelegate が nil を返し**現行環境で事実上不活性**(§9.3)。排他モード HID・cookie マッピングは OS バージョン決め打ち | 既存ユーザーの KeyArray に残る modifier=100 エントリの互換処理(読み飛ばすか保持するか)だけ決める。代替するなら MPRemoteCommandCenter/メディアキー |
| GlobalKeyboardDevice / KeyspanFrontRowControl | 未インスタンス化の完全なデッドコード(§12.3.1) | 無条件で削除可 |
| COImageLoader_temp.m と HetimaUnZip 痕跡(mode 1)・mode 5 | ビルド外/到達不能(§12.3) | mode は error/directory/archive/savedSearch/pdf の 5 値 enum で十分 |
| BufferingMode=Old(0)+ screenCacheArray + composedImage + imageDisplayIfHasScreenCache | xib 自体に「Old は Retina で正しく動かない」と注記があり、既定は実質常に New(§4.2.2)。Old 専用のキャッシュ無効化バグ(§12.1 #9, #10)も一掃できる | New(ビュー側で 2 枚並置描画)相当へ一本化。ScreenCache 設定キーも廃止候補 |
| ChangeCreator / ChangeOpenWith(defaults キーと参照コード) | UI 喪失+コード全体コメントアウトの死んだ機能(§12.1 #27)。クリエータコード自体が廃止概念 | 削除。旧 defaults に残る値は無視 |
| PrevPagePageBarPositionMode | registerDefaults のみで参照コードのない隠しキー(§6.1) | 削除 |
| AppleScript によるゴミ箱フォールバック | 無関係ファイル削除リスク(§12.1 #12)。NSFileManager trashItemAtURL: で不要になる | 削除し、削除後のローダ再構築(§12.1 #13 の修正)を新規設計 |
| Carbon AliasHandle 系一式と番兵文字列 "file not found" | 全 API 廃止済み(§7.4) | NSURL ブックマークへ移行(§13.5)。番兵はエラー型で表現し直す |
| randomCompare: 方式のシャッフル | 非決定的比較器によるソートは未定義動作に近い(§12.1 #36) | Fisher-Yates 等へ。「シャッフル順の再現不能性」は現仕様でも実質保証されていないため挙動互換の縛りなし |
| NSNumberFormatter カテゴリの全域上書き | カテゴリによる既存メソッド置換は未定義動作扱い(§12.1 #33) | 個別フィールドの検証へ置換。'.' と整数の矛盾も整理 |
| 孤児ファイル群・.svn・ja.xliff のバンドルコピー・up.tiff | §11.4 / §12.3.1 | 新プロジェクトへ持ち込まない |
| SkipPage(旧 defaults キー) | 現 UI になく value 注入の移行専用(§6.1) | 一度だけの移行コードに読み替えて廃止 |
| en.lproj/Localizable.strings の 6 世代連結 | ユニーク 136 キーに正規化(§10.1) | 恒等マッピングなのでキー整理の好機 |
| IKImageEditPanel(メニューの showFilterPanel:) | 共有パネルを出すだけの独立機能で本フィルタ系と無関係(§4.11) | Filter パネル(CIFilter 系)へ一本化するか削除 |

### 13.2 維持必須の勘所(互換性チェックリスト)

**保存データ互換(既存ユーザーの defaults を引き継ぐ場合の正)**

- ページ番号の基数: RecentItems/LastPages の page は **0 始まり**、bookmarks・marks の page は **1 始まり文字列**(§1.4, §7)。
- BookSettings のトップレベルキーは**本の表示名+衝突時 "#N" 連番**(パスでも alias でもない。§7.1)。
- バインディング 6 配列のスキーマと modifier 符号化(+1/+2/+4/+8/100/+200..+500)、マルチタッチ仮想 button(1000-8000)、switchAction の「オン時のみキー存在」(§5.1-5.2)。
- SortMode/MaxEnlargement の UI index ↔ 保存値のねじれ、WheelSensitivity の「2.1-x」反転写像は**保存値側の意味を正**とする(§6.2)。
- marks の書式("N"=強制単ページ / "N-M"=強制見開き、1 始まり)と isSmallImage の判定順(marks → 比率)(§4.2.1)。
- Version キーによる移行ゲート(1.2b10/b14/b17/b23)を新実装の初回移行に読み替える(§7.6)。

**挙動互換(ユーザー体験の勘所)**

- readMode 0(右→左見開き)が既定。見開き合成は「後のページが左」(RTL)/singleSetting=740 の**縦横比**判定(ポイント単位。§4.2)。
- loopCheck 4 値の意味、特に **1 と 2 の差は後方(前の本へ戻る)時のみ**: 2 は必ず末尾から開き GoToLastPage 復元をバイパスする(§4.3.4)。
- GoToLastPage 復元フロー(0=確認/1=自動/2=無効。保存 page==0 は「復帰なし」と不可分。§7.3)。
- モード別バインディングの解決順とフォールバック(「ノーマルモードが基本、モード固有が優先」)。マウスクリックだけモード対応が異なる非対称(§5.3)は**統一するなら仕様変更として明記**。
- switchAction の入替ペア表と対象外アクション(原寸/Finder/ゴミ箱は入替えない。§5.4)。
- pageMover と 0-9 キーの競合解決(pageMover 表示中のみ数字を消費、それ以外は Go to %。§5.8)。
- ページ送りトリガの微妙な仕様: scrollTo の戻り値(純垂直移動での端到達のみ YES)、クリック 1 秒超の長押しキャンセル、ドラッグジェスチャ ±30px、cursorMoved の X/Y 入替(§5.9, CustomImageView.m:179)。
- 疑似フルスクリーンの UX: 上端ホバーでメニューバー出現、カーソル 3 秒自動隠し、hidesOnDeactivate(アプリ非アクティブで隠れる=esc 文化と対)(§3.3)。ネイティブ全画面へ移行しても**この 3 点は再現**。
- 単一画像ファイルを開くと親フォルダを本として開き該当ページへジャンプ(§2.4)。
- 同フォルダメニュー+次/前の本(名前順・端でラップ・移動追従ダイアログ)(§4.1.4, §4.3.4)。
- ページバー/ページ番号のカスタマイズ体系(4 隅位置+マージン+色+フォント+自動隠し+ホバーバブル+クリックジャンプ)(§3.4)。
- Finder 互換自然順ソート(finderCompareS の意味論=localizedStandardCompare: 相当: 全角半角・大小・合成非区別、数字は数値比較)と、書庫ファイル名エンコーディング自動判定(UniversalDetector 相当)(§4.4.3, §4.17)。
- Cancel で全ロールバックする設定ウインドウのトランザクション挙動(即時反映化するなら**仕様変更として明記**。§6.3)。
- しおりは RememberBookSettings=NO でも保存される(§7.1)。
- エラー黙殺方針(壊れ画像=broken.png、空ブック=empty.png、ダイアログなし)は現仕様(§4.17)。改善する場合も「ページ数を保ったまま壊れページを表示する」性質は維持が無難。
- キー/マウスの既定バインディング表(§5.7)と設定画面のアクション表示順(NSDictionary_Adding のハードコード順序配列)。

### 13.3 「バグを含めて再現するか」の明示判断リスト

§12.1 の ★ 印を含む、仕様と不可分になっているバグの扱い:

| 項目 | 推奨 |
|---|---|
| getMouseAction case 5 フォールスルー(#1) | **修正**(skip のみ実行)。既定バインディングに action 5 は無いため影響は限定的 |
| マウス 28/29 の UI ラベル左右逆(#2) | **修正**し、旧設定読込時に action を読み替える(またはラベルだけ直す)。どちらにせよ表で明記 |
| マウス版スライドショーが停止できない(#22) | **修正**(キー版と同じトグルへ) |
| ソート変更で常に先頭ページへ飛ぶ/しおり・最終ページの再マッピングなし(§4.4.2) | 現仕様として**維持**が安全(再マッピングは新機能扱い)。sortMode=1 の本ごと保存が復元を無意味化する点はユーザー向けに注記 |
| しおり編集シートの Cancel 無効(#28) | **修正**(コピー編集に統一)を推奨。仕様変更として記録 |
| goToPar 上限なし(#8)/loopCheck 1・2 の前方同一(§4.3.4) | 現仕様として**維持**(パーセントジャンプ 9=90% と巻末ループの体感に関わる) |
| 数字キーの修飾無視(pageMover 中は control+5 も 5。§5.8) | 維持で問題なし |

### 13.4 アーキテクチャ置換の推奨対応表

| 旧実装 | 置換先 | 移植時の注意 |
|---|---|---|
| NSLock 1 本+ビジーウェイト+threadStop/threadCount+使い捨て detach スレッド(§4.6) | 直列キュー/Swift Concurrency+キャンセルトークン | 「大ジャンプ前に先読みを中断して完了を待つ」「表示は先読み結果を待つ」という**順序保証**だけを移植する。恒久デッドロック経路(§12.2 #7)は設計で消す |
| ページ/合成/サムネイルの手書き LRU 配列(容量 +4/+2 の暗黙値。§4.5.1) | NSCache 等 | 実容量が「設定値+4/+2」である点はユーザー可視でないため正規化してよい |
| サムネイルの 0.001 秒 performSelector 連鎖+doCount/stop(§4.8) | NSCollectionView+非同期ロード | 充填順(右→左読みで右端列から)と mangaMode 合成は仕様として維持 |
| validateMenuItem / contextAction のローカライズ済み文字列比較(§8.3) | tag/セレクタ方式 | カーソル左右による動的リネーム(Next↔Previous 等)は仕様として維持 |
| NSArchiver 化した NSColor/NSFont | NSSecureCoding ないし成分値の辞書保存 | 旧データの一度だけの読み替え移行を用意(§13.5) |
| CALayer.filters への allValues 適用(順序不定。§4.11) | CIFilterKeys 順の適用+KVO 解除 | 「フィルタはビュー全体にかかる」現挙動を画像のみに変えるなら仕様変更として明記 |
| COPDFImageRep の全ページ共有 rep+setCurrentPage(§4.14) | PDFKit/CGPDF でページ毎独立レンダリング | スレッド安全化。白背景・SourceOver 強制・ポイント原寸の描画特性は維持 |
| 書庫の毎回全量メモリ展開(キャッシュなし。§2.4) | 展開キャッシュ/先読み戦略 | solid rar の逐次展開特性(ランダムアクセスが遅い)を前提に設計 |
| mkdtemp 一時展開の dealloc 頼み掃除(§4.17) | 起動時の残骸掃除+確実な後始末 | 現状は ⌘Q・クラッシュで残る(OS の /var/folders 清掃頼み) |
| 拡張子/OSType ベースの CFBundleDocumentTypes 65 エントリ(§2.3) | UTImportedTypeDeclarations | cbz/cbr の二重宣言・Split File/RAR の拡張子重複を整理。対応拡張子集合は維持 |
| コード署名なし・CFBundleShortVersionString なし・INFOPLIST_FILE 小文字(§11.1) | 署名/notarization・両バージョンキー整備・ケース修正 | defaults ドメイン jp.coo.cooViewer の引き継ぎ(または移行)方針を決める |
| XADMaster の ShellScript 再帰ビルド(毎回 clean。§11.2) | ワークスペース参照/XCFramework/SwiftPM | XADMaster↔UniversalDetector の兄弟配置前提も解消 |
| パスワード欄が通常 NSTextField(平文。§3.1) | NSSecureTextField | 併せてパスワードエンコーディングの明示選択(§12.1 #32)を検討 |

### 13.5 旧設定データの移行マッピング

| 旧形式 | 新形式への移行 |
|---|---|
| alias(AliasHandle の NSData) | 初回起動時に pathFromAliasData 相当(temppath フォールバック込み)で解決し、NSURL bookmarkData へ一括変換。解決不能エントリは「パス文字列のみ」で保持するか破棄するかを決める |
| ViewBackGroundColor / TextFont / PageBar* 等の NSArchiver データ | NSUnarchiver 相当で一度だけ読み(失敗時は既定色/フォント表 §6.1 を適用)、新形式で再保存 |
| KeyArray 系 6 配列 | スキーマは維持可能(plist 互換)。型付きデコーダを書き、modifier=100(AppleRemote)エントリの扱い(§13.1)と mouse 28/29 の読み替え(§13.3)をここで実施 |
| SkipPage | value 未設定エントリへの注入(0→10)を移行時に一度だけ実施し、キーを削除 |
| Version | 新実装のスキーマバージョンへ読み替え。versionCompare の辞書式比較は捨て、初回移行判定のみに使用 |
| AllBookmarkSplitPotision ほかウインドウフレーム系 | 引き継がなくても実害なし(初回だけ位置がリセット) |
| BookSettings/RecentItems/LastPages | スキーマ(§7.1-7.3)を維持するなら alias 差し替えのみで互換。キー基数(0/1 始まり)を絶対に変えない |

---

## 14. ライセンスと表記義務

### 14.1 コンポーネント別ライセンス一覧

| コンポーネント | ライセンス | 根拠ファイル | 表記/義務 |
|---|---|---|---|
| cooViewer 本体 | MIT スタイル(「Created by coo under a MIT-style license. Copyright (c) 2005- coo.」) | Licence.txt:1-21(UTF-16) | ライセンス文の同梱。著作権表記 "©coo, 2005"(InfoPlist.strings の NSHumanReadableCopyright) |
| XADMaster(サブモジュール、plife18 フォーク) | **LGPL(版に食い違いあり)**: サブモジュールの XADMaster/README.md は LGPL 2.1 と記載する一方、リポジトリ同梱の Licence_xad.txt は **GNU LGPL v3 全文**+冒頭に「Copyright (C) 1998 and later by Dirk Stöcker / libxad extensions Copyright (C) 2006 and later by Dag Ågren / http://sourceforge.net/projects/libxad/」。**両論併記・要実機確認**(サブモジュール内の実際の LICENSE 原本を確認して新実装の表記を確定すること) | Licence_xad.txt:1-171, XADMaster/README.md:1-33 | LGPL 遵守: ライセンス文の同梱、著作権者表記、**利用者がライブラリを差し替え可能な形態**(現行は動的リンクの埋め込み .framework で充足)の維持 |
| UniversalDetector(サブモジュール、plife18 フォーク) | LGPL 2.1(Mozilla universalchardet 移植の Objective-C ラッパ) | UniversalDetector/README.md:1-13 | 同上(XADMaster 経由の間接依存でも .framework として同梱される) |
| Remote Control Wrapper(RemoteControl / HIDRemoteControlDevice / AppleRemote / KeyspanFrontRowControl / MultiClickRemoteBehavior / GlobalKeyboardDevice) | MIT(Copyright (c) 2006-2009 martinkahr.com) | Licence_RemoteControlWrapper.txt:1-21 | ライセンス文と著作権表記の同梱。**§13.1 に従いスタックを削除する場合、この義務ごと消滅する** |

> **確認済み(2026-08-07)**: サブモジュール実体の `XADMaster/LICENSE`・`UniversalDetector/LICENSE` はいずれも **GNU LGPL 2.1 全文**であることを確認した。リポジトリ同梱の `Licence_xad.txt`(LGPL v3 全文)の方が古い/不正確であり、新実装のライセンス表記は **LGPL 2.1** を正とする。

### 14.2 About パネル表記(Credits.rtf)

`orderFrontStandardAboutPanel:` が表示する Credits.rtf(Credits.rtf:1-17)の内容:

- 「using: XAD library system」+ Dirk Stöcker / Dag Ågren の著作権表記 + libxad の URL
- 「Remote Control Wrapper Copyright (c) 2006-2009 martinkahr.com」+ http://www.martinkahr.com/source-code/

XADMaster を使い続ける限り前者の表記は**維持必須**。Remote Control Wrapper の行は同スタックを削除するなら除去してよい。About パネルの表示は InfoPlist.strings(CFBundleName="cooViewer" / NSHumanReadableCopyright="©coo, 2005")と組で構成される(§10.1)。

### 14.3 その他のクレジット(README 由来)

| クレジット | 内容 | 根拠 |
|---|---|---|
| 書類アイコン | 「デフォルトの書類アイコンは新・mac板…Part4 の 971 さんに作成していただきました」 | README.md:71 |
| nib→xib 変換 | kanjitalk755 氏への謝辞 | README.md(fork 元 README 部分) |
| 現フォーク | plife18: サブモジュール化・Monterey/Apple Silicon 対応・RAR5 対応 | README.md:1-30 |
| 旧公式サイト | docs/(© 2005- coo. All rights reserved.、連絡先 coo.ona.jp@gmail.com) | docs/index.html:1-142 |
| 謝辞(コミュニティ) | docs/other.html の表示部は 2ch スレッドへの謝辞のみ | docs/other.html |

### 14.4 新実装での注意点

1. **Licence*.txt 3 種は現行ビルドで Resources フェーズに含まれず、アプリバンドルに入っていない**(リポジトリ同梱のみ。§11.4)。LGPL 遵守の観点から、新実装ではライセンス文をバンドル内(または About からの参照)に同梱することを推奨。
2. LGPL ライブラリ(XADMaster/UniversalDetector)は**動的リンク+差し替え可能な形**での同梱(現行の埋め込み .framework 方式)を維持するのが安全。静的リンク化する場合は LGPL の追加条件(オブジェクトファイル提供等)を検討する必要がある。
3. XADMaster の LGPL 版数の食い違い(§14.1)は、リライト時にサブモジュール内の LICENSE 原本を確認して表記を確定すること(**要実機確認**)。
4. defaults ドメイン `jp.coo.cooViewer` は README がアンインストール手順(`~/Library/Preferences/jp.coo.cooViewer.plist` の削除)として公表している識別子であり、変更する場合は README/移行手順の更新まで含めて行う。
5. アイコン(icon.icns / coo_*.icns)を流用する場合、§14.3 の書類アイコン作者クレジットを README 等に維持する。

---

*本書は cooViewer f572957(modernize/macos26)の静的コードリーディングに基づく。動的挙動(要実機確認と記した箇所)は、リライト実装時に旧アプリまたは新実装上で検証すること。*

<!-- END OF DOCUMENT -->
