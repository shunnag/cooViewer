# cooViewer 開発ガイド

新しくこのリポジトリを触る人向けの実務ガイド。**設計の判断と経緯は
[architecture.md](architecture.md)(設計書)**、**挙動の仕様は
[legacy-app-analysis.md](legacy-app-analysis.md)(仕様書)**にあり、
本書はビルド・検証・リリースの手順と、ハマりどころをまとめる。

対象: macOS 26 (Tahoe) 以降 / Apple Silicon 専用。作業ブランチは
`modernize/macos26`、リリースは `master`。

## 1. セットアップとビルド

サブモジュールは不要。通常の clone と KaitoKit / Washi の兄弟チェックアウトでビルドする。

```sh
git clone https://github.com/shunnag/cooViewer.git
git clone https://github.com/shunnag/KaitoKit.git
git clone https://github.com/shunnag/Washi.git
cd cooViewer
xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug build
xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug test
```

- `xcode-select` がコマンドラインツールを指している環境では、各コマンドに
  `DEVELOPER_DIR=/Applications/Xcode.app` を前置する。
- Run Script フェーズは KaitoKit / Washi を兄弟チェックアウトから `Frameworks/` に
  ビルドし、**Fetch Sparkle** が `Scripts/fetch-sparkle.sh` で Sparkle を自動取得する
  (バージョン・SHA-256 固定、スクリプト単独で `Frameworks/` も作成する)。
  全て作り直す場合は `rm -rf Frameworks` の後にビルドし、Release 前には
  `Scripts/sign-sparkle-nested.sh` を再実行する(Sparkle の再取得時)。
- 既存 checkout の旧生成物は次で片付ける(新規 clone では不要):
  `rm -rf Frameworks/XADMaster.framework Frameworks/UniversalDetector.framework Frameworks/.buildflags`。
  旧版のビルド済みアプリへの残留を避けるため、PR 2 の同梱確認には新規ビルドを使う。
- **KaitoKit** は兄弟チェックアウト `../KaitoKit` が必須。`KAITOKIT_SOURCE_DIR` で
  Package.swift のあるディレクトリを指定できる。再生成の詳細は §3.6 を参照。
- **Washi(EPUB 3 ツールキット)**は兄弟チェックアウト `../Washi` の独立 SwiftPM
  リポジトリ(https://github.com/shunnag/Washi、MIT)で、`WASHI_SOURCE_DIR` に
  Package.swift のあるディレクトリを指定して上書きできる。
  チェックアウトは**必須**で、無いとビルドは失敗する。
  Run Script フェーズ(`Scripts/build-washi-framework.sh`)が
  `Frameworks/Washi.framework` を組み立てて埋め込む(SwiftPM 参照でないのは
  Xcode が legacy build location とパッケージ参照を併用できないため)。
  **Washi のソースを変更したら `rm -rf Frameworks/Washi.framework`** で
  再ビルドを強制する。パッケージ単体のテストは `cd ../Washi && swift test`。
  **注意(実害あり)**: まれにアプリへの**埋め込みコピーがスキップ**され、
  `build/Debug/cooViewer.app/Contents/Frameworks/Washi.framework` が旧版の
  まま残ることがある(Frameworks/ 側だけ新しくなる)。挙動が変わらない
  ときは埋め込み側も `rm -rf` してからビルドし直す。確認は
  `strings <app 内の Washi> | grep <新シンボルや文字列>`。
- **Washi と複数バージョンの Xcode**: バイナリ `.swiftmodule` はコンパイラの
  バージョンに固定されるため、フレームワークには library evolution の
  **`.swiftinterface` を同梱**している(別バージョンの Xcode/CLI はこれへ
  フォールバックして import できる)。スクリプトは Swift バージョンと
  ソースディレクトリをスタンプし、ツールチェーンやチェックアウトが変わると
  自動で作り直す。
  「Module compiled with Swift X cannot be imported by Y」が出たら
  `rm -rf Frameworks/Washi.framework` してビルドし直せば確実に直る。
  なお SwiftPM の出力レイアウトはバージョンで異なる(6.3 系:
  `Modules/` 平置き、6.4 の swiftbuild: トリプル別ディレクトリ+
  interface は Intermediates 配下)——スクリプトは両対応済み。

### プロジェクトファイルの約束

- pbxproj は**手書き**(objectVersion 77、filesystem-synchronized groups)。
  `CooViewer/`・`CooViewerTests/` 配下に置いたファイルは自動で
  ターゲットに入る。**ファイル単位のエントリを pbxproj に足さない**。
- ターゲットは **arm64 固定**(プロジェクト設定 `ARCHS = arm64`)。
  Xcode の Signing 画面が `ARCHS = $(ARCHS_STANDARD)` を勝手に注入することが
  ある(x86_64 と KaitoKit / Washi framework のアーキテクチャ不一致でリンクエラーになる)。見つけたら削除する。
- `Localizable.xcstrings` は Xcode の生成形式を保ったまま**テキストブロックの
  挿入だけ**で編集する(全体の再シリアライズはしない)。キー追加時は
  4 段インデント・`" : "` 区切りの既存書式に合わせる。

## 2. 動作検証(スナップショット・監査 CLI)

画面収録の権限なしで実描画を確認できる隠し引数がある(AppDelegate.swift の
`handleDebugArguments`)。Debug ビルドの実行ファイルを直接起動して使う:

```sh
build/Debug/cooViewer.app/Contents/MacOS/cooViewer \
  --open <本のパス> --at-page 3 --snapshot out.png
```

| 引数 | 内容 |
|---|---|
| `--open <path>` | 指定の本を開く(`--at-page <1 始まり>` で開始ページ指定。リフロー EPUB では spine 項目の指定になる) |
| `--engine <name>` | スクリプト互換のため受理する。`kaitokit` はこの起動だけに適用し、旧 `xadmaster` を含む未知値は os_log の warning を出して無視する。defaults の設定値は変更しない |
| `--audit-archives <folder>` | フォルダ以下の書庫を GUI なしで直列監査し、TSV を stdout へ出す。全件成功なら終了コード 0、失敗があれば 1 |
| `--audit-output <tsv>` | 書庫ごとの KaitoKit 監査結果を指定ファイルへ保存 |
| `--audit-entries <tsv>` | エントリ単位の名前・サイズ・SHA-256 を別 TSV へ保存 |
| `--audit-engines kaitokit` | 監査エンジンは既定・指定とも `kaitokit` のみ。旧 `xadmaster` を指定すると「この版では KaitoKit のみ」のエラー。`--engine` とは独立 |
| `--audit-hash` | 非暗号化書庫の内容 SHA-256 も計算。省略時は open・列挙・名前のみ監査 |
| `--audit-progress <N>` | stderr へ進捗を出す書庫数の間隔(正の整数、既定 20)。開始・最終件も表示 |
| `--snapshot <png>` | `--then` の完了と表示整定を待ち、さらに 2 秒後に contentView を PNG 出力して終了 |
| `--show-thumbnails` | サムネイルオーバーレイを開いて撮る(EPUB モードでは census 一致の画面単位一覧。生成は逐次なのでセルが埋まるまで `--then-goto-percent` 等でステップを足して撮影を遅らせる)。行列はウインドウサイズとセルサイズから自動算出されるため、`-ThumbnailCellSize <pt>`(80–400)の注入でズーム水準を変えて撮れる |
| `--show-bookmark-editor` | しおり編集をウインドウ表示(シートは撮れないため) |
| `--show-file-info` | ファイル情報パネルを開く(`--snapshot` はパネルを撮る) |
| `--show-opening-progress` | オープン進捗 HUD を固定内容で表示 |
| `--show-gesture-hud <left\|right\|up\|down>` | ドラッグジェスチャの方向 HUD を強調状態で表示(割当名は実際のバインディングを解決。未割当なら灰色) |
| `--zoom <倍率>` | 連続ピンチズームを中心基点で指定倍率にして撮る(1.0=下限。パン/描画確認用) |
| `--show-activity` | アクティビティ窓を開いて撮る(`--snapshot` は ImageRenderer で内容を描画。ScrollView は headless の cacheDisplay で写らないため) |
| `--show-password-dialog <png>` | パスワード入力欄+保存チェックボックスのアクセサリを撮る(はみ出し確認用) |
| `--then-next-book` / `--then-previous-book` | 表示後に次/前の本へ移動(複数回可) |
| `--then-next-page` | 表示後にページ送りする(めくり効果の完了後状態の確認等)。リフロー EPUB リーダーが開いていればそちらを送る(複数回可) |
| `--then-goto-percent <n>` | 表示後に比率ジャンプ(数字キー 0-9 の goToPercent 経路の検証。**EPUB モード中のみ**動作) |
| `--then-show-thumbnails` | サムネイル一覧をトグル(EPUB 入場後に開く順序制御用) |
| `--then-rapid-thumbnails <N>` | サムネイル一覧を約 70ms 間隔で N 回トグル(t キー連打の再現。奇数なら開いた状態で終わる。`0` はトグルせず、1 秒の最低間隔と表示整定待ちの後に撮影を 2 秒延ばす)。撮影は連打の所要時間ぶん自動で遅延する |
| `--dump-thumbnail-stats` | 撮影時に ThumbnailCache の内部状態(メモリ/生成中/失敗記録/生成ゲート)と本の保護コンテンツ判定を stdout へ出力(欠けセルの原因判別用) |
| `--then-show-bubble <0-1>` | ページバーのホバーバブルを指定比率位置に表示(マウスホバーは CLI から再現できないため。EPUB では census 完了後に出すこと) |
| `--then-play-narration` | 音声メディアオーバーレイ(SMIL)の再生をトグル(EPUB でオーバーレイを持つ項目のとき。読み上げ中テキストの active-class ハイライトの検証用。2 回で一時停止になる) |
| `--then-open <path>` | 表示後に別の本へ切り替える |
| `--then-toggle-cover-single` | 表示後に「表紙を単ページで表示」を切り替える |
| `--snapshot-settings <png>` | 設定ウインドウを撮って終了 |
| `-SettingsSelectedTab <n>` | 設定ウインドウの表示ペイン(SettingsPane.rawValue) |
| `-SettingsSearchText <語>` | 設定検索の初期値を注入(検索 UI の検証用) |
| `--appearance <dark\|light>` | 外観を強制(EPUB のテーマ追従などダークモード検証用) |
| `--dump-first-responder <txt>` | 3 秒後に first responder の型名を書き出して終了(EPUB⇔画像本のフォーカス復帰検証) |
| `-キー名 <値>` | 任意の defaults を引数ドメインで上書き(例 `-SpreadCoverSingle 1`) |

`--then-*` はコマンドライン順に、1 秒の最低間隔を置き、表示整定(オープンフローと
EPUB 入場の完了)を待ってから逐次実行される。各整定待ちは約 12 秒でタイムアウトする。
`--snapshot` は全ステップの完了を待ち、キャプチャ前にも表示整定を確認するため、
`--at-page` で合本内の代理ページへ直接着地する場合も、次のようなチェーンも決定的に
検証できる。組合せ例: コレクション内 EPUB の巻末超え復帰の検証は
`--open <フォルダ> --then-next-page --then-next-page --then-goto-percent 100 --then-next-page`
(送りで代理ページへ→自動入場→EPUB 内 100%→巻末超えで合本の次エントリへ)。

書庫は KaitoKit のみで開く。「書庫エンジンの状態…」には使用中のエンジン、
mmap→file 再試行の累積回数、最後のエラーを表示する。旧引数の互換確認は同じ本・
ページ・ウインドウ条件で行う。保存設定の互換は引数ドメインで試し、実 defaults を書き換えない。

```sh
build/Debug/cooViewer.app/Contents/MacOS/cooViewer \
  --engine xadmaster --open sample.cbz --at-page 3 --show-file-info --snapshot /tmp/engine-compat.png
build/Debug/cooViewer.app/Contents/MacOS/cooViewer \
  -ArchiveEngine xadmaster --open sample.cbz --at-page 3 --show-file-info --snapshot /tmp/defaults-compat.png
```

パスワードマネージャーの検証: テスト・`--snapshot` 実行では Keychain に触れない(保管庫は「利用できません」になる)。実際に保存・自動解錠を検証するときは、**Debug ビルド限定**の環境変数 `COOVIEWER_TEST_VAULT_KEY=<hex64桁>` と `COOVIEWER_TEST_VAULT_DIR=<一時ディレクトリ>`(必ず両方セットで指定)により使い捨ての鍵と保存先を注入して起動する(開発機の Keychain とプロンプトを汚さない。Release は環境変数を受け付けない)。

復号できない保管庫の復旧導線は、注入鍵と壊れた `vault.enc` で決定的に検証できる:

```sh
DIR=$(mktemp -d); printf garbage > "$DIR/vault.enc"
COOVIEWER_TEST_VAULT_KEY=$(openssl rand -hex 32) COOVIEWER_TEST_VAULT_DIR="$DIR" \
  build/Debug/cooViewer.app/Contents/MacOS/cooViewer --snapshot-settings /tmp/vault.png -SettingsSelectedTab 5
```

「保存済みパスワード: 利用できません」と、有効な「リセット」ボタンが表示されることを確認する。

環境変数:

- `COOVIEWER_UI_TEST_CANCEL_PASSWORD=1` — パスワードダイアログを出さず
  キャンセル扱いにする(モーダルでハングさせないため)。
- `RETRO_SAMPLE_DIR=<dir>` — レトロデコーダのゴールデン比較テストを有効化。

**注意**: スナップショット実行は通常起動と同じく実ユーザーの defaults・
本の状態(ウインドウ枠、最終ページ、履歴)へ書き込む。検証で値を汚したら
元に戻すこと。ヘッドレス描画には限界があり、サイドバーの選択行ラベルや
NSSegmentedControl は写らないことがある(実表示では問題ない)。

サンプル本が要るときは、縦長 PNG を数枚入れたフォルダを作ればよい
(git 履歴の `makepages.swift` 参照)。

EPUB の検証: `--open x.epub --snapshot` はリフローなら EPUB 表示モードを
WKWebView の takeSnapshot 合成で、固定レイアウトなら通常の contentView で撮る
(layer.render に WKWebView は写らないため撮り分けている)。サンプル EPUB
(縦組み小説=ルビ・圏点・縦中横入り/電書協風 FXL 漫画)の生成:

```sh
swift Scripts/make-sample-pages.swift /tmp/pages 6          # 番号入りページ画像
python3 Scripts/make-sample-epub.py /tmp /tmp/pages          # 2 冊の .epub を出力
python3 Scripts/make-jp-epub-fixtures.py /tmp/washi-fixtures # 日本語 EPUB の検証セット
```

### 2.1 実コレクションの監査手順

`--audit-archives` は手元の書庫を外部へ送らず、KaitoKit 単独で開けるか、
名前と内容の SHA-256 を記録する。通常のアプリ起動より先に実行し、
ウインドウ・復元・履歴移行/書き込み・キャッシュ掃除・Sparkle・パスワード保管庫を起動しない。
パーサー設定はアプリと共通。監査は単一エンジンで、KaitoKit を直接開く。
アプリと異なり mmap→file 再試行は行わず、選んだ入口の失敗をそのまま記録する。
名前 nil も監査では列挙失敗にする(アプリはそのエントリだけを除外する)。
別バージョンの結果との比較には 2 つの TSV と `Scripts/audit-compare.py` を使う。

```sh
APP=build/Debug/cooViewer.app/Contents/MacOS/cooViewer
"$APP" --audit-archives "$HOME/Comics" --audit-hash \
  --audit-output /tmp/audit.tsv --audit-entries /tmp/audit-entries.tsv
echo $?

# 別バージョン・別マシンでの KaitoKit 単独監査にも使える
"$APP" --audit-archives "$HOME/Comics" --audit-engines kaitokit \
  --audit-hash --audit-output /tmp/kaitokit-new.tsv
python3 Scripts/audit-compare.py /tmp/kaitokit-old.tsv /tmp/kaitokit-new.tsv

# 旧版で採取した両エンジン入りの TSV では比較対象を指定する
python3 Scripts/audit-compare.py old.tsv new.tsv --engine kaitokit
```

監査対象は `SupportedTypes.isArchive` に該当する通常ファイルで、ルート以下を再帰する。
隠し項目・パッケージ内・シンボリックリンク・続き巻(`.z01` / `.r00` / `.002` 等)を除外し、
先頭巻 `.001` は含める。UTF-8 パス順で処理し、書庫内はエンジンの列挙順を保つ。
読み取れないフォルダがあれば未走査範囲を成功扱いせず、stderr にエラーを出して終了コード 1 にする。

**監査 TSV の読み方**(ヘッダー付き、1 行 = 書庫、エンジンは KaitoKit のみ):

| 列 | 意味 |
|---|---|
| `path` / `engine` | 監査ルートからの相対パス / `kaitokit` |
| `entrypoint` | `data` は `ArchiveSource.shouldMemoryMap` に従う `.mappedIfSafe` 読み込み、`file` はファイル入口。ネットワーク・リムーバブル・RAR・`.z01` の兄弟がある ZIP 等は `file` |
| `status` | `ok` / `open-failed`(例外・nil・ファイル読み取り失敗) / `enumeration-failed`(負の件数・名前 nil・列挙例外) / `entry-unreadable`(内容 nil・展開例外)。失敗後も次の書庫を処理する |
| `entries` / `files` | エンジンが返した件数(取得不能なら空欄) / 列挙できた非ディレクトリ件数。列挙失敗時の `files` は途中までの件数 |
| `encrypted` | 書庫または一つでもエントリが暗号化されていれば `true`。暗号化書庫は open と列挙だけを確認し、混在書庫でも内容は読まない |
| `elapsed_ms` | 当該エンジンでの読み込み・列挙・ハッシュ計算の経過ミリ秒 |
| `names_sha256` | 全 entry の比較名を LF で連結(末尾 LF なし)した UTF-8 バイトの SHA-256。**ディレクトリと判定された名前だけ末尾の `/` と `\` を全て除く**。旧版の監査結果との互換を維持するため(cooViewer-vwey.8)。他の名前は変更しない |
| `contents_sha256` | `--audit-hash` 時、各 entry の小文字16進 SHA-256 文字列を列挙順に区切りなしで連結し、その UTF-8 バイトを SHA-256 にした値。ディレクトリは空データの digest を使う。`kaito sha` / `xadsha` の `total` と同じ定義 |
| `error` | 失敗の理由。内容を読めない場合は該当 entry の 0 始まり index も含む |

ハッシュ未指定・暗号化・open/列挙失敗による未計算は空欄。
内容読み取り失敗は該当 entry と `contents_sha256` を `unreadable` にする
(欠落した digest を空データとして補わない)。空書庫の二つのハッシュは空データの SHA-256。
`match` 列は撤去済み。壊れた書庫の `open-failed` は終了コード 1 になる。
暗号化書庫の `ok` は内容の同値性を確認した意味ではない。

entry TSV は `path, engine, index, name, size, sha256` のタブ区切り。
`name` は正規化前のエンジンの保存名、`size` はサイズ不明なら空欄。
内容が読める書庫では `sha256` を `kaito sha <archive>` の同じ index と照合できる。
両 TSV とも UTF-8・LF、セル内の `\` / タブ / LF / CR はそれぞれ
`\\` / `\t` / `\n` / `\r` に可逆エスケープする(引用符による CSV quoting は使わない)。
ファイル出力は同じディレクトリの一時ファイルへ書き、完了時に置き換える。
stdout 指定は書庫ごとに逐次出力する。

stderr には開始時・20 書庫ごと・最後に進捗を出す(`--audit-progress 1` なら毎書庫)。
最後の集計は `total`(書庫数)と `failed`(失敗した書庫数)。
2 エンジンの比較集計(`kaitokit_only_failed` 等)は撤去済み。
内容を読むため、大きな書庫一つの処理には時間がかかる。

`audit-compare.py` は `path` で突合し、追加・削除と `status` / `names_sha256` /
`contents_sha256` の差を列挙する。終了コードは同一 0、差あり 1、入力不正 2。
旧版の両エンジン入り TSV を `--engine` なしで渡して path が重複した場合はエラーにする。

**差分が出たときに送ってほしい情報**: 比較した 2 つの TSV の該当行、必要なら該当 entry 行、
`kaito list --raw <該当書庫>` の出力、cooViewer / KaitoKit のバージョン、macOS のバージョン、
ローカル/ネットワーク等の配置条件。書庫本体は不要。共有前にパスやファイル名の非公開情報を確認する。
コアの記録は `Codable` 値型なので、別の検証ツールからも利用できる。

## 3. テスト

- ロジック(ソート・見開き判定・バインディング・レイアウト・永続化・検索
  など)には必ず CooViewerTests のユニットテストを付ける(設計書 §7.6)。
- テスト実行は XCTest ホストとしてアプリを起動するが、`AutomatedRun.isXCTest`
  ガードにより「前回の本を開く」等でユーザーの実データに触れない。
- テスト出力に CGImageSource のエラーが混ざるのは壊れ画像の意図的テスト。

## 3.2 書庫コーパスと計測(Scripts/bench/)

`Scripts/bench/` にはエンジンに依存しない画像・書庫・破損入力の生成器、CRC/inflate の
マイクロベンチ、LZMA2 ヘッダ調査、cold/warm 計測ラッパーを残す。
使い方と前提ツールは [Scripts/bench/README.md](../Scripts/bench/README.md) を参照。
性能は同じ入力・同じ条件の交互実行で測り、内容の SHA-256 も比較する。

削除したオラクル・旧エンジンのベンチ・専用集計・生データの移設先は
[cooViewer-bench](https://github.com/shunnag/cooViewer-bench)。
通常の clone には含めず、git 履歴 **8b726c1** の `Scripts/bench/` にも残している。

## 3.5 Washi の組み込み

Washi は cooViewer と同じ親ディレクトリに置く独立 SwiftPM リポジトリ
(https://github.com/shunnag/Washi、MIT)で、サブモジュールではない。既定では
`../Washi` を使い、別の配置を試す場合は `WASHI_SOURCE_DIR` に Package.swift の
あるディレクトリを指定する。相対パスは cooViewer リポジトリを基準に解決する。
チェックアウトは**必須**で、無いとビルドは失敗する。

`Scripts/build-washi-framework.sh` が `Frameworks/Washi.framework` を組み立て、
通常は CooViewer.xcodeproj の Run Script フェーズから自動実行される。
開発は Washi リポジトリ側で行い、単体テストは cooViewer のルートから
`cd ../Washi && swift test` で実行する。ソース更新後は cooViewer 側の
`rm -rf Frameworks/Washi.framework` で再ビルドを強制する。

Washi のリリースは Washi リポジトリで行う。CHANGELOG.md の
`## [X.Y.Z] - YYYY-MM-DD` 見出しを確定させ、変更をコミットしてから次を実行する。
SwiftPM は semver タグで解決する。

```sh
cd ../Washi
git tag X.Y.Z && git push origin main X.Y.Z
```

cooViewer の **Release ビルド前には `../Washi` が push 済みのタグの状態であること**
(`WASHI_SOURCE_DIR` 指定時も参照先で同様)。cooViewer 側の履歴には Washi の版が
記録されないため、配布する実装を公開済みのタグで特定できる状態にしておく。

## 3.6 KaitoKit の組み込み

エンジン契約のゴールデンは `CooViewerTests/Fixtures/engine-golden.json` に保存し、
KaitoKit の file/data 両入口の列挙値・内容 SHA-256・solidGroup・暗号化挙動を照合する。
**旧エンジン撤去済みのため再採取不可。ゴールデンは固定資産。**
採取用テストと provenance 生成処理は撤去した。保存済み JSON とその出自を維持し、
KaitoKit の実装変更に合わせて期待値を作り直さない。JSON がない場合は既存の固定資産を復元する。

KaitoKit は cooViewer と同じ親ディレクトリに置く独立 SwiftPM リポジトリ
(https://github.com/shunnag/KaitoKit、MIT)で、サブモジュールではない。既定では
`../KaitoKit` を使い、別の配置を試す場合は `KAITOKIT_SOURCE_DIR` に Package.swift の
あるディレクトリを指定する。

**書庫エンジンは KaitoKit 単独である。** 旧エンジンと自動フォールバックは
撤去済み。PR 2 で旧 framework のビルド・リンク・同梱、submodule とライセンス資産も
撤去した。設定のエンジン Picker も撤去した。
`ArchiveEngine` キーは保持し、旧 `"xadmaster"` 等の未知値は KaitoKit に写像する。
保存値は書き戻さず、旧版に戻した場合の選択を残す。`--engine` の扱いは §2 を参照。

ローカル書庫の mmap データを解析できない場合は、KaitoKit の file 入口で一度再試行し、
回数と理由を診断・os_log の info に記録する。列挙失敗は再試行せず unreadable。
名前 nil のエントリはログ付きで除外し、残りのページを表示する。分割 ZIP の `.z01` 兄弟が
ある場合や RAR は mmap せず、兄弟探索が働く file 入口を使う。

ファイル名の文字コード判定は KaitoKit 自身の `EncodingPolicy.automatic`
(既定 `likelyLanguage: "ja"`、2026-09-15 の KaitoKit PR #24 で 39 言語・54 legacy
候補)で行い、cooViewer は `KaitoArchiveDelegate` の名前判定フックを実装しない。
判定精度の測定値と残差は KaitoKit の
`Documentation/verification/2026-09-14-name-encoding-languages.md` を参照。

KaitoKit は StuffIt にも対応する(classic/5/X、`.sea`、MacBinary/AppleSingle/BinHex の
透過 unwrap、`.exe` SFX)。StuffIt X の JPEG(method 7)・StuffIt 7 Mac の
`.sitx`・wrapper 内側・暗号化 SITX も KaitoKit で処理する。
cooViewer の拡張子判定には `.sit` に加えて `.sitx`・`.sea`・`.hqx` を含める
(仕様書 §2.1 の archiveTypes、設計書 §2.4)。`.bin` は汎用拡張子のため宣言しない。
現在のドロップ／`--open` は `BookSourceFactory.make` の拡張子判定を通るため、
未宣言の `.bin`・`.exe` はエンジンの内容判定に到達せず `unsupportedFormat` になる。
この拡張子の振り分けは PR 1 でも維持する。

`Scripts/build-kaitokit-framework.sh` はソース・Package.swift・ビルドスクリプトの
mtime と Swift コンパイラのスタンプを調べ、更新時だけ KaitoKit 側の
`Scripts/build-framework.sh` を呼ぶ。KaitoKit 側が生成する arm64/x86_64 の
ユニバーサルフレームワークを `Frameworks/KaitoKit.framework` へ複製し、通常は
CooViewer.xcodeproj の Run Script フェーズから自動実行される。配置を明示して
単独で組み立てる場合は次のとおり:

```sh
KAITOKIT_SOURCE_DIR=/path/to/KaitoKit Scripts/build-kaitokit-framework.sh
```

フレームワークには `KaitoKit` と `KaitoKitCompat` の両モジュールが
`Modules/` 以下に入る。`KaitoKitCompat` の interface が `KaitoKit` を import
するため、利用側には通常の framework search path に加えて次の include path
(`-I` 相当)が必要になる。これはアプリ・テストが継承するプロジェクト設定にあり、
テストターゲットも KaitoKit.framework を明示的にリンクしている。

```text
$(SRCROOT)/Frameworks/KaitoKit.framework/Modules
```

兄弟チェックアウトを更新するときは KaitoKit 側で fast-forward し、cooViewer 側の
コピーを削除してから通常のビルドを行う。削除対象はこのリポジトリの
`Frameworks/KaitoKit.framework` であり、兄弟チェックアウトのソースではない。

```sh
git -C ../KaitoKit pull --ff-only
rm -rf Frameworks/KaitoKit.framework
```

StuffIt 統合時(2026-09-13)の旧エンジンとの比較記録は
[PR 2 検証記録の付録](verification/2026-09-15-xadmaster-framework-removal.md#付録-stuffit-統合時の検証記録)へ移した。

## 4. リリース手順(2.0b14 まで検証済み)

1. pbxproj の `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` を bump(各 4 箇所)。
2. ブランチをコミット・push → `master` 向けの PR をマージ。
3. `./Scripts/sign-sparkle-nested.sh`(Sparkle 内部の実行体を Developer ID +
   timestamp + hardened runtime で再署名。これを飛ばすと**公証が Invalid**)。
4. Release ビルド:
   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app xcodebuild -configuration Release build \
     CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp"
   ```
   素の Release ビルドは公証に落ちる(get-task-allow が残る+タイムスタンプ無し)。
5. `ditto -c -k --keepParent cooViewer.app out.zip` →
   `xcrun notarytool submit out.zip --keychain-profile cooviewer --wait` →
   `xcrun stapler staple cooViewer.app` → **ステープル済みアプリを再 zip**
   (資産名は `cooViewer-<version>.zip` 固定。appcast の URL が名前から決まる)。
6. `spctl -a -vv cooViewer.app` が "Notarized Developer ID" であることを確認。
7. `vX.YbN` タグを master に打って push、`gh release create`(ベータは
   `--prerelease`)。リリースノートには 1.x へ戻す場合のデータ消去手順
   (日英併記)を必ず含める。
8. `Scripts/make-appcast.sh <stapled-zip> <version> <build>` で appcast.xml に
   `<item>` を追加(EdDSA 署名はログインキーチェーンの鍵)→ master へ
   コミット・push → フィードの `length=` が実ファイルサイズと一致するか確認。
9. `master` を `modernize/macos26` へマージバックする。

**開発機での禁止事項**: `defaults delete jp.coo.cooViewer BookStateStoreVersion`
と `BookStates/` の削除の組み合わせ(移行の再実行)は、開発機の実読書データを
壊すので絶対に行わない。移行テストは一時ディレクトリ+専用 defaults suite で行う。

### ML モデル資産(models-1 リリース)

補間(描画品質)の ML モデルは**すべて**アプリ本体とは別の GitHub リリース
**`models-1`**(タグ)に資産として置き、アプリが同意後にダウンロードする
(URL と SHA-256 は `MLSuperResolver.swift` / `MLNoiseReducer.swift` に
ピン留め。外部リポジトリの構成変更・消失に影響されない自前配信)。

- 再変換する場合: `Scripts/convert-realesrgan.py` を使う。
  Python 3.12 の venv に `torch` と `coremltools` を入れ、公式チェックポイント
  `RealESRGAN_x4plus_anime_6B.pth`(xinntao/Real-ESRGAN v0.2.2.4、BSD-3-Clause)を
  渡すと単一ファイルの .mlmodel(fp16、入力 256 → 出力 1024)を出力し、
  PyTorch とのパリティ(最大絶対誤差)も表示する。
  **Python 3.14 は不可**(coremltools のバイナリ拡張が無い)。
- モデルを差し替えたら: 新しいタグ(models-2 など)で `gh release create` →
  `MLSuperResolver.swift` の URL と SHA-256 を更新。既存タグの資産を
  上書きしない(過去バージョンのアプリが SHA 不一致で壊れるため)。
- waifu2x(超高)のモデルも同じ models-1 リリースから自前配信する
  (imxieyi/waifu2x-mac(MIT)からの無改変再配布。MIT の条件である
  著作権表示・ライセンス全文はリリース資産 `LICENSES-models.txt` に同梱。
  モデル資産を追加・更新したらこのファイルも必ず更新すること)。

## 5. ハマりどころ早見表

| 症状 | 原因と対処 |
|---|---|
| SR 結果にタイル境界の帯・線 | GAN は平坦部のトーンがタイル毎に Δ1-2 階調揺れる。マージン捨てだけでは不十分で、フェザー合成+Bayer ディザ(MLSuperResolver.writeTile)を外さないこと |
| Xcode コンソールに linkd / appintents のエラー | `Unable to get synchronousRemoteObjectProxy … com.apple.linkd.autoShortcut` 等は AppKit の App Intents 自動登録が **ad-hoc 署名の Debug ビルド**で弾かれる macOS 側のノイズ(XCTest 実行にも出る)。アプリのコードとは無関係で、Developer ID 署名の Release ビルドでは出ない(2026-08 監査: Release はエラー級・fault 級ともゼロ、stdout/stderr もゼロを確認)。アプリ自身のログは MediaSpeedProbe の Logger.info(ボリューム毎 1 回)のみ、という状態を保つ |
| Xcode コンソールに `mdb_txn_commit error: MDB_MAP_FULL` | LMDB(メモリマップ DB)がマップ上限に達したという macOS 側サブシステム(Siri/知識・Spotlight ドネーション・AppIntents 系など)のノイズ。**2026-08 の検証時点で cooViewer 本体・当時の同梱フレームワークは LMDB を一切使っていなかった**(2026-08 確認: 実行バイナリ・フレームワーク・リンク dylib に MDB 文字列ゼロ)ため、アプリの動作・保存データへの影響なし。上の linkd/appintents と同じ ad-hoc Debug ビルドのシステムノイズで、OS が自動で圧縮・再構成する。beads とも無関係(bd は Dolt=noms 方式で LMDB 非使用)。気になればコンソールで `MDB` を除外フィルタ |
| `ReadPhotoshopImageResource: ERROR: Corrupt 8BIM data` で Xcode 実行が止まる | 開いた画像の埋め込み Photoshop メタデータ(APP13 の 8BIM リソースブロック)が壊れているときに **ImageIO(システム)**が出すログ。8BIM/Photoshop 参照は cooViewer のコードにもフレームワークにも無く、デコード経路は guard/throws で壊れたメタデータを無視して**画素は正常に復号**する(2026-08 確認: 壊れた 8BIM を仕込んだ JPEG を開いても exit 0・正常な描画・クラッシュ痕跡なし)。アプリはクラッシュしないので「実行が止まった」のは**デバッガ側の一時停止**——ImageIO がメタデータ解析中に内部で raise→catch する例外を Xcode の「All Exceptions / Objective-C Exceptions」ブレークポイントが拾っているのが典型。対処: ▶ Continue で再開できる。恒久的には Breakpoint Navigator(⌘8)の All Exceptions ブレークポイントを削除/無効化するか、例外種別を C++ のみに絞る(ImageIO のは Objective-C なので止まらなくなる)。※もし例外ブレークポイントではなく本当のクラッシュスタックで止まっているなら、その停止箇所(コールスタック)を控えて別途調査 |
| CodeSign 失敗 / 起動が古いバイナリ / 保存状態が勝手に変わる | このプロジェクトは **legacy build location**(`BuildLocationStyle = UseTargetSettings`、成果物は DerivedData でなくプロジェクト直下 `build/Debug/cooViewer.app`)。**エージェントの `xcodebuild`/スナップショットと手元の Xcode ▶ Run は同じ `build/Debug` を書き換え・再署名する**ため同時に走らせると衝突する(実行中プロセスが .app を掴んで CodeSign が失敗、半分書きかけのバンドルを起動、等)。さらに両者は同じ bundle id `jp.coo.cooViewer` で UserDefaults・BookStates・キャッシュ・Keychain を共有し、**後勝ちでウインドウ位置や最終ページを上書き**し合う。回避: ビルド/実行を時間的にすみ分ける(エージェント作業中は Run を止める・Run 中はエージェントのビルドを控える)、作業前後に残プロセスを `pkill -f "cooViewer/build/Debug"`。完全分離が要るなら bundle id を変えたクローン(ウインドウ位置調査の隔離手法)を使う。※ソース編集は「すでに起動中」のプロセスには影響しないが、次に Run するとその時点の最新ソースから再ビルドされる(編集途中の中途半端な状態でビルドし得る) |
| KaitoKit / Washi framework のリンクエラー | ターゲットに x86_64 が混入。`ARCHS = arm64` を確認 |
| 公証が Invalid | Sparkle 内部の再署名漏れ(sign-sparkle-nested.sh)か、素の Release ビルド |
| 自動更新が来ない | appcast.xml の `length=` 不一致・資産名が `cooViewer-<ver>.zip` でない |
| xcstrings が巨大 diff | 再シリアライズしてしまった。テキストブロック挿入だけに戻す |
| 設定変更が反映されない | defaults キー名の相違か、applySettings の反映点が未実装 |
| 検証実行後に挙動が変 | 引数ドメインの `-キー 値` 上書きが persistent に混ざった可能性。該当キーを確認 |
| 見開きの区切りが動かない | ペア判定は現在位置から局所的(仕様書 §4.2)。設定切替時は Book.reanchorToLeadingPartition を通す |
