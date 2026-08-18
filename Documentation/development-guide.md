# cooViewer 開発ガイド

新しくこのリポジトリを触る人向けの実務ガイド。**設計の判断と経緯は
[architecture.md](architecture.md)(設計書)**、**挙動の仕様は
[legacy-app-analysis.md](legacy-app-analysis.md)(仕様書)**にあり、
本書はビルド・検証・リリースの手順と、ハマりどころをまとめる。

対象: macOS 26 (Tahoe) 以降 / Apple Silicon 専用。作業ブランチは
`modernize/macos26`、リリースは `master`。

## 1. セットアップとビルド

```sh
git submodule update --init --recursive   # XADMaster / UniversalDetector が必須
xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug build
xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug test
```

- `xcode-select` がコマンドラインツールを指している環境では、各コマンドに
  `DEVELOPER_DIR=/Applications/Xcode.app` を前置する。
- Run Script フェーズが XADMaster/UniversalDetector を `Frameworks/` に
  ビルドする(成果物があればスキップ)。サブモジュール更新後は
  `rm -rf Frameworks` で作り直しを強制し、その後
  `Scripts/sign-sparkle-nested.sh` を再実行する(Sparkle の再取得時)。

### プロジェクトファイルの約束

- pbxproj は**手書き**(objectVersion 77、filesystem-synchronized groups)。
  `CooViewer/`・`CooViewerTests/` 配下に置いたファイルは自動で
  ターゲットに入る。**ファイル単位のエントリを pbxproj に足さない**。
- ターゲットは **arm64 固定**(プロジェクト設定 `ARCHS = arm64`)。
  Xcode の Signing 画面が `ARCHS = $(ARCHS_STANDARD)` を勝手に注入することが
  ある(x86_64 の XADMaster リンクエラーになる)。見つけたら削除する。
- `Localizable.xcstrings` は Xcode の生成形式を保ったまま**テキストブロックの
  挿入だけ**で編集する(全体の再シリアライズはしない)。キー追加時は
  4 段インデント・`" : "` 区切りの既存書式に合わせる。

## 2. 動作検証(スナップショット CLI)

画面収録の権限なしで実描画を確認できる隠し引数がある(AppDelegate.swift の
`handleDebugArguments`)。Debug ビルドの実行ファイルを直接起動して使う:

```sh
build/Debug/cooViewer.app/Contents/MacOS/cooViewer \
  --open <本のパス> --at-page 3 --snapshot out.png
```

| 引数 | 内容 |
|---|---|
| `--open <path>` | 指定の本を開く(`--at-page <1 始まり>` で開始ページ指定) |
| `--snapshot <png>` | 2 秒後に contentView を PNG 出力して終了 |
| `--show-thumbnails` | サムネイルオーバーレイを開いてから撮る |
| `--show-bookmark-editor` | しおり編集をウインドウ表示(シートは撮れないため) |
| `--show-file-info` | ファイル情報パネルを開く(`--snapshot` はパネルを撮る) |
| `--show-opening-progress` | オープン進捗 HUD を固定内容で表示 |
| `--show-gesture-hud <left\|right\|up\|down>` | ドラッグジェスチャの方向 HUD を強調状態で表示(割当名は実際のバインディングを解決。未割当なら灰色) |
| `--zoom <倍率>` | 連続ピンチズームを中心基点で指定倍率にして撮る(1.0=下限。パン/描画確認用) |
| `--show-activity` | アクティビティ窓を開いて撮る(`--snapshot` は ImageRenderer で内容を描画。ScrollView は headless の cacheDisplay で写らないため) |
| `--show-password-dialog <png>` | パスワード入力欄+保存チェックボックスのアクセサリを撮る(はみ出し確認用) |
| `--then-next-book` / `--then-previous-book` | 表示後に次/前の本へ移動(複数回可) |
| `--then-next-page` | 表示後にページ送りする(めくり効果の完了後状態の確認等) |
| `--then-open <path>` | 表示後に別の本へ切り替える |
| `--then-toggle-cover-single` | 表示後に「表紙を単ページで表示」を切り替える |
| `--snapshot-settings <png>` | 設定ウインドウを撮って終了 |
| `-SettingsSelectedTab <n>` | 設定ウインドウの表示ペイン(SettingsPane.rawValue) |
| `-SettingsSearchText <語>` | 設定検索の初期値を注入(検索 UI の検証用) |
| `-キー名 <値>` | 任意の defaults を引数ドメインで上書き(例 `-SpreadCoverSingle 1`) |

パスワードマネージャーの検証: テスト・`--snapshot` 実行では Keychain に触れない(保管庫は「利用できません」になる)。実際に保存・自動解錠を検証するときは、**Debug ビルド限定**の環境変数 `COOVIEWER_TEST_VAULT_KEY=<hex64桁>` と `COOVIEWER_TEST_VAULT_DIR=<一時ディレクトリ>`(必ず両方セットで指定)により使い捨ての鍵と保存先を注入して起動する(開発機の Keychain とプロンプトを汚さない。Release は環境変数を受け付けない)。

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

## 3. テスト

- ロジック(ソート・見開き判定・バインディング・レイアウト・永続化・検索
  など)には必ず CooViewerTests のユニットテストを付ける(設計書 §7.6)。
- テスト実行は XCTest ホストとしてアプリを起動するが、`AutomatedRun.isXCTest`
  ガードにより「前回の本を開く」等でユーザーの実データに触れない。
- テスト出力に CGImageSource のエラーが混ざるのは壊れ画像の意図的テスト。

## 4. リリース手順(2.0b14 まで検証済み)

1. pbxproj の `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` を bump(各 4 箇所)。
2. ブランチをコミット・push → `master` へ `git merge --no-ff`。
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
| Xcode コンソールに `mdb_txn_commit error: MDB_MAP_FULL` | LMDB(メモリマップ DB)がマップ上限に達したという macOS 側サブシステム(Siri/知識・Spotlight ドネーション・AppIntents 系など)のノイズ。**cooViewer 本体も同梱フレームワーク(Sparkle/UniversalDetector/XADMaster)も LMDB を一切使わない**(2026-08 確認: 実行バイナリ・フレームワーク・リンク dylib に MDB 文字列ゼロ)ため、アプリの動作・保存データへの影響なし。上の linkd/appintents と同じ ad-hoc Debug ビルドのシステムノイズで、OS が自動で圧縮・再構成する。beads とも無関係(bd は Dolt=noms 方式で LMDB 非使用)。気になればコンソールで `MDB` を除外フィルタ |
| `ReadPhotoshopImageResource: ERROR: Corrupt 8BIM data` で Xcode 実行が止まる | 開いた画像の埋め込み Photoshop メタデータ(APP13 の 8BIM リソースブロック)が壊れているときに **ImageIO(システム)**が出すログ。8BIM/Photoshop 参照は cooViewer のコードにもフレームワークにも無く、デコード経路は guard/throws で壊れたメタデータを無視して**画素は正常に復号**する(2026-08 確認: 壊れた 8BIM を仕込んだ JPEG を開いても exit 0・正常な描画・クラッシュ痕跡なし)。アプリはクラッシュしないので「実行が止まった」のは**デバッガ側の一時停止**——ImageIO がメタデータ解析中に内部で raise→catch する例外を Xcode の「All Exceptions / Objective-C Exceptions」ブレークポイントが拾っているのが典型。対処: ▶ Continue で再開できる。恒久的には Breakpoint Navigator(⌘8)の All Exceptions ブレークポイントを削除/無効化するか、例外種別を C++ のみに絞る(ImageIO のは Objective-C なので止まらなくなる)。※もし例外ブレークポイントではなく本当のクラッシュスタックで止まっているなら、その停止箇所(コールスタック)を控えて別途調査 |
| CodeSign 失敗 / 起動が古いバイナリ / 保存状態が勝手に変わる | このプロジェクトは **legacy build location**(`BuildLocationStyle = UseTargetSettings`、成果物は DerivedData でなくプロジェクト直下 `build/Debug/cooViewer.app`)。**エージェントの `xcodebuild`/スナップショットと手元の Xcode ▶ Run は同じ `build/Debug` を書き換え・再署名する**ため同時に走らせると衝突する(実行中プロセスが .app を掴んで CodeSign が失敗、半分書きかけのバンドルを起動、等)。さらに両者は同じ bundle id `jp.coo.cooViewer` で UserDefaults・BookStates・キャッシュ・Keychain を共有し、**後勝ちでウインドウ位置や最終ページを上書き**し合う。回避: ビルド/実行を時間的にすみ分ける(エージェント作業中は Run を止める・Run 中はエージェントのビルドを控える)、作業前後に残プロセスを `pkill -f "cooViewer/build/Debug"`。完全分離が要るなら bundle id を変えたクローン(ウインドウ位置調査の隔離手法)を使う。※ソース編集は「すでに起動中」のプロセスには影響しないが、次に Run するとその時点の最新ソースから再ビルドされる(編集途中の中途半端な状態でビルドし得る) |
| XADMaster が undefined symbol | ターゲットに x86_64 が混入。`ARCHS = arm64` を確認 |
| 公証が Invalid | Sparkle 内部の再署名漏れ(sign-sparkle-nested.sh)か、素の Release ビルド |
| 自動更新が来ない | appcast.xml の `length=` 不一致・資産名が `cooViewer-<ver>.zip` でない |
| xcstrings が巨大 diff | 再シリアライズしてしまった。テキストブロック挿入だけに戻す |
| 設定変更が反映されない | defaults キー名の相違か、applySettings の反映点が未実装 |
| 検証実行後に挙動が変 | 引数ドメインの `-キー 値` 上書きが persistent に混ざった可能性。該当キーを確認 |
| 見開きの区切りが動かない | ペア判定は現在位置から局所的(仕様書 §4.2)。設定切替時は Book.reanchorToLeadingPartition を通す |
