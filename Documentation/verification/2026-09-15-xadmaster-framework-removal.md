# XADMaster / UniversalDetector のビルド・同梱資産撤去(PR 2)

- 対象: Task R2、bd `cooViewer-6lrc.7` / `cooViewer-6lrc.8`
- 起点: `8b726c18dcd25a39056d4b3103933142b3ebcd83`、作業ブランチ `feat/xad-removal-2`
- 方針 D1(b): 通常の clone に旧エンジンを含めない。旧オラクル群は履歴に残し、
  bd `cooViewer-6lrc.9` で別リポジトリへ移設する。
- 本記録は sandbox 内の実装・検証結果。コミット・push はしていない。
  gitlink を含む削除差分は作業ツリーにあるが、共有 index の更新と実アプリ検証は未完了。

## 削除・変更一覧

### 削除

- `.gitmodules`(2 エントリ全て)、`XADMaster` / `UniversalDetector`(mode 160000 の gitlink 削除差分)
- `Scripts/build-frameworks.sh`
- `CooViewer/Resources/LGPL-2.1.txt`
- `Scripts/bench/` の 13 ファイル(下表)。`bitreader-diff/` と `results-2026-08-27/` は全ファイルを撤去

### 変更

- `CooViewer.xcodeproj/project.pbxproj`: 旧 framework の参照とリンク・Embed を撤去、Sparkle の取得フェーズへ変更
- `Scripts/fetch-sparkle.sh` / `Scripts/build-washi-framework.sh`: 呼び出し経路・方式のコメントのみ変更
- `CooViewer/Resources/Credits.rtf`: 旧ライブラリの 4 ブロックを削除
- `.github/workflows/ci.yml`: recursive submodule checkout と旧 framework 名を削除
- `.gitignore`: 旧 framework 単独の ignore を削除、ローカル検証・コミットメッセージ保存先の `.build/` を追加
- `Scripts/bench/README.md` / `coldopen.sh` / `purge-cold.sh` / `microbench.c`: 残存ツールの説明、計測コマンドの引数化、汎用 CRC のコメント
- `CLAUDE.md` / `AGENTS.md` / `README.md` / `Documentation/architecture.md` / `Documentation/development-guide.md`: 現行ビルドと第三者表記、過去形の謝辞、履歴・移設先、旧生成物の掃除方法
- `CooViewerTests/EngineGolden.swift` / `ArchiveEngineTests.swift`: 旧エンジン名をコメント・固定資産欠落時の診断文で一般化。テストロジック・provenance のフィールド名は不変
- 本記録を新規追加。開発ガイド内の 2026-09-13 StuffIt 検証記録は、当時の比較を失わないよう付録へ無改変で移動

`legacy/Licence_xad.txt` は旧版の参照資料として維持。
`engine-golden.json` と既存の検証記録は更新しない。
`MARKETING_VERSION = 2.0b36` / `CURRENT_PROJECT_VERSION = 2036` は各 4 箇所とも不変。

## pbxproj と Run Script

手書きの objectVersion 77 を保ち、再シリアライズしない。
削除したオブジェクトは次の 6 個(ID の新設・再利用なし):

| ID | 旧用途 |
|---|---|
| `C0000000000000000000000B` | XADMaster.framework の PBXFileReference |
| `C0000000000000000000000C` | UniversalDetector.framework の PBXFileReference |
| `C0000000000000000000000D` | XADMaster.framework の Frameworks PBXBuildFile |
| `C0000000000000000000000E` | UniversalDetector.framework の Frameworks PBXBuildFile |
| `C0000000000000000000000F` | XADMaster.framework の Embed Frameworks PBXBuildFile |
| `C00000000000000000000010` | UniversalDetector.framework の Embed Frameworks PBXBuildFile |

Frameworks グループ、アプリの Frameworks / Embed Frameworks フェーズからも各 2 参照を除去。
旧 `Build XADMaster frameworks` フェーズ(`C00000000000000000000015`)は **Fetch Sparkle** に改名し、
次の出力・呼び出しだけを持つ。フェーズの順序は維持した。

```text
outputPaths = $(PROJECT_DIR)/Frameworks/Sparkle.framework/Versions/B/Sparkle
shellScript = exec "${PROJECT_DIR}/Scripts/fetch-sparkle.sh"
```

`fetch-sparkle.sh` は既に展開後の `mkdir -p "$FW_DIR" "$DIST_DIR"` を持ち、
単独で `Frameworks/` を作成できる。バージョン 2.9.5、SHA-256 照合、配置、
既存成果物を使う条件は変更していない。既存 Sparkle を置いた単独呼び出しは成功した。
新規ダウンロードの実行確認は sandbox 外へ引き継ぐ。

KaitoKit / Washi の Run Script オブジェクトは完全に不変。
全 buildSettings(ARCHS、署名、バージョン等)、残存 framework のリンク・Embed 設定も不変。
`Scripts/sign-sparkle-nested.sh` / `make-appcast.sh` / `build-kaitokit-framework.sh` は無変更。
Resources は filesystem-synchronized group なので、ライセンス文書の個別 PBX 参照はなく、
実ファイル削除でバンドル対象から外れる。

## Credits

RTF の既存構造を保ち、次のブロックを削除した。

- `XAD library system`(libxad の著作権表示・リンク)
- `XADMaster`(著作権表示・LGPL・改変ソースのリンク)
- `UniversalDetector`(著作権表示・ライセンス・改変ソースのリンク)
- `The GNU LGPL 2.1 license text is bundled…` の案内

libxad のクレジットを削除する理由は、旧 framework 撤去後の 2.0 が libxad 由来コードを含まないため。
KaitoKit / Sparkle / ML モデルのブロックは保持し、`KaitoKit-LICENSE.txt` も維持した。
`textutil -convert txt -stdout` で変換でき、削除ブロック以外のテキストが変更前と完全一致することを確認した。
About パネルでの実描画は未確認。

## bench の判定表

`rg` で import / include / 呼び出し / submodule パスを検索し、ソース・利用側・旧 README を読んで判定した。
「単独でコンパイルできる」だけでなく、測定対象が旧エンジン内部かどうかも区別した。

| 対象(`Scripts/bench/` 以下) | 判定 | 根拠 |
|---|---|---|
| `xadsha.swift` | 削除 | `import XADMaster` / `XADArchive`。各エントリ SHA-256 の黒箱オラクル |
| `xadbench.m` | 削除 | `XADMaster/XADArchive.h` を import し、open / 展開 / solidGroup の性能を測る |
| `xadbench-swift.swift` | 削除 | `import XADMaster`。NSData→Data ブリッジを含む展開計測 |
| `build-variant.sh` | 削除 | `XADMaster/XADMaster.xcodeproj` をビルドし、旧ハーネスを配置 |
| `run-variant.sh` | 削除 | `xadbench` / `xadbench-swift` の固定スイートを実行 |
| `bitreader-diff/README.md`, `bitdiff.c` | 削除 | 自己完結した C でも `CSInputBuffer.[hm]` の内部ビット操作の参照移植・候補実装を比較する専用資産 |
| `zip-open-ceiling.patch` | 削除 | `XADZipParser.[hm]` に適用する性能上限測定専用パッチ |
| `results-2026-08-27/clean-ab.tsv`, `experiments.tsv` | 削除 | 旧ハーネスの baseline / variant 生データ |
| `summarize.py` | 削除 | Python 単体だが、旧 `run-variant.sh` の variant・時刻・JSON という TSV を読み、`rep_ms` / `sha256` と baseline 比を集計する専用処理。残存ツールにこの出力の生成者はない |
| `strbench.m` | 削除 | `XADString.h` / `escapedASCIIStringForBytes` を直接測定 |
| `strtest.m` | 削除 | `XADString` のエスケープ文字列・データ API を旧実装と比較 |
| `microbench.c` | 維持(コメント変更) | CRC テーブル生成・スライス演算をファイル内に持ち、ARM CRC / Apple zlib / libcompression / libdeflate と比較。旧 framework の import・リンク・内部 API 呼び出しはない。旧コメントの「模した実装」は比較方式を指し、現在の測定対象はこの独立実装 |
| `lzma2walk.c` | 維持(無変更) | stdio / stdlib / stdint のみ。LZMA2 ヘッダを直接読み、辞書リセット位置を調べる。旧エンジンの呼び出しなし |
| `make-archives.sh` | 維持(無変更) | zip / 7zz / rar / LHa / sips と画像生成器でコーパスを作る |
| `makecorpus.swift` | 維持(無変更) | Foundation / CoreGraphics / ImageIO / UniformTypeIdentifiers のみで画像生成 |
| `makesjiszip.py` | 維持(無変更) | Python 標準 zipfile / struct 等で cp932 名 ZIP を生成・検査 |
| `makemutants.py` | 維持(無変更) | Python 標準ライブラリで生バイトの切詰め・ビット反転 |
| `coldopen.sh` | 維持(呼び出しを引数化) | 元は `variants/<name>/MacOS/xadbench` に依存。disk-image と任意のコマンド・引数を受け取り、detach/attach 後に cold / warm 実行する形へ変更 |
| `purge-cold.sh` | 維持(呼び出しを引数化) | 元は lha / cdmem 変種の `xadbench` と専用 JSON に依存。`sudo -n purge` 後に任意のコマンドを呼ぶ形へ変更し、実行権限も付与 |
| `README.md` | 書換え | 残存ツールの前提・引数・利用例、旧群の履歴と移設予定を記載 |

cold 計測の 2 本は仕様で維持対象とされたが、実際には旧実行体に依存していた。
コメント変更だけでは使用不能になるため、固定パスと専用 JSON 解析を除去した。
計測対象の stdout をそのまま出し、`time -p` を stderr に出す。失敗の終了コードを維持し、
認証は非対話(`sudo -n`)で待たない。対象コマンドを root で実行する必要はない。

## 検証結果

| 検証 | 結果・限界 |
|---|---|
| `git diff --check` | 成功 |
| `plutil -lint CooViewer.xcodeproj/project.pbxproj` | 成功 |
| pbxproj の変更前後を JSON として意味比較 | 6 オブジェクト削除、3 リストの参照削除、Fetch Sparkle の 3 フィールド変更だけ。ID 重複・未解決参照なし |
| `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild -project CooViewer.xcodeproj -list` | exit 0。cooViewer / CooViewerTests、Debug / Release、cooViewer scheme を認識。CoreSimulator / ログ保存先の sandbox 警告あり |
| 同環境の `xcodebuild … -scheme cooViewer -configuration Debug build` | exit 65。DerivedData の workspace arena を作成できず、コンパイル前に停止(下記) |
| `textutil -convert txt -stdout CooViewer/Resources/Credits.rtf` | 成功。削除対象以外のテキストは変更前と完全一致 |
| `Scripts/fetch-sparkle.sh` | 単独実行 exit 0、`Sparkle 2.9.5 is up to date.`。既存成果物での経路のみ実行 |
| shell / Python 構文 | 残存 bench の各 shell、fetch-sparkle / build-washi を `zsh -n` で個別確認。Python 2 本も構文確認 |
| 計測ラッパー | 8 ケース成功。引数不足、空白・引用符・日本語を含む引数、失敗終了コード、cold 失敗時の warm 中止、mount / purge 失敗時の中止。hdiutil / sudo はスタブで、実マウント・purge は未実行 |
| `microbench.c` | clang で独立ビルド成功。solid.7z の PNG+パディングを 7zz で取り出した 33,104 bytes を使い、CRC 一致 / inflate 往復一致。JPEG/TIFF の性能評価ではない |
| `lzma2walk.c` | clang で独立ビルド成功。solid.7z を `STREAM END` まで解析(1 非圧縮チャンク、出力 33,104 bytes) |
| `makesjiszip.py` / `makemutants.py` | 小入力 3 件で全ヘッダ cp932 名・UTF-8 flag OFF と ZIP CRC を確認。32 mutants を生成 |
| 全 XCTest、クリーンビルド、bundle / otool、snapshot CLI、About 描画 | ビルドが停止したため未実行。Fable 側で検証する |
| 全コーパス生成・実 cold 性能測定 | 未実行。変更していない生成器の全量実行・性能比較は本作業では行わない |

ビルド停止のエラー:

```text
Couldn't create workspace arena folder '/Users/nagash/Library/Developer/Xcode/DerivedData/CooViewer-dvubogdggoakmebpzhicvpbjbttz':
You don’t have permission to save the file … in the folder “DerivedData”.
** BUILD FAILED **
```

ローカルログ・変換結果は `.build/task-r2/` の `xcodebuild-list.log` / `xcodebuild-build.log` /
`static-verification.txt` / `bench-smoke.log` / `credits-before.txt` / `credits-after.txt` に保存した。

### 参照検索の扱い

現行の本体・テスト・ビルド設定・CI・Scripts には `XADMaster` / `UniversalDetector` / `LGPL` の
使用参照がない。固定ゴールデンの provenance フィールド名と値は変更していない。
README の謝辞、設計書の旧構成・変更履歴、検証記録、旧版の挙動仕様書
`Documentation/legacy-app-analysis.md` は歴史資料として維持する。

仕様で明記された開発ガイド §1 の旧生成物掃除コマンドにも旧 framework 名が残る。
従って、指定の単純な再帰 grep は歴史資料・この掃除コマンド・git 外の検証ログ等にも
一致し、文字通りの 0 件にはならない。使用参照の撤去と、保持必須の記録を区別して確認した。
指定 grep の実行結果は `reference-scan.txt` に保存し、stderr は 0 行だった。
生成ログを除く一致先は、README、architecture、development-guide の掃除手順、
既存と今回の検証記録、legacy-app-analysis のみ。現行ソース・設定を対象にした照合は 0 件。

## submodule と sandbox の引き継ぎ

この worktree の submodule は未初期化で、2 パスは空ディレクトリだった。
`git rm -- .gitmodules XADMaster UniversalDetector` を試したが、次のエラーで共有 index を更新できなかった。

```text
fatal: Unable to create '/Users/nagash/Github/cooViewer/.git/worktrees/coo-pr2/index.lock': Operation not permitted
```

`.gitmodules` と空ディレクトリは作業ツリーから削除し、`git diff --summary` でも
`delete mode 160000 UniversalDetector` / `XADMaster` を確認した。
未ステージなので `git ls-files XADMaster UniversalDetector .gitmodules` はまだ 3 件を返す。
Fable 側で次を実行すれば削除を index に反映できる(この作業ではコミットしない)。

```sh
git rm -- .gitmodules XADMaster UniversalDetector
git ls-files XADMaster UniversalDetector .gitmodules
```

未初期化の今回は deinit は不要。初期化済み checkout で同じ撤去を行う場合は、
未保存の submodule 変更がないことを確認し、`.gitmodules` を削除する**前**に
`git submodule deinit -f -- XADMaster UniversalDetector` → `git rm` の順に行う。
共有 `.git/modules` は他 worktree でも使う可能性があるので、本作業から削除していない。

Beads も `bd show cooViewer-6lrc.7` が次のエラーで停止したため、.7 / .8 の claim / close は未実施。
DB の迂回コピーや JSONL の編集はしていない。Fable 側で最終検証とともに状態を更新する。

```text
Error: failed to open database: embeddeddolt: init schema: embeddeddolt: open db:
failed to load database "cooViewer": openat LOCK: operation not permitted
```

## 残る検証・作業

- Fable 側: submodule 削除をステージした差分から、新規 worktree / 通常 clone で
  `rm -rf Frameworks` → Debug build / 全 XCTest。KaitoKit / Washi のソース配置を用意し、Sparkle の取得経路も確認する。
- 新規アプリの `Contents/Frameworks` と `otool -L` に旧 2 framework がないこと、
  `Contents/Resources/LGPL-2.1.txt` がないことを確認する。
- Credits の About 表示、snapshot CLI で CBZ / 7z / 分割 ZIP を確認する。
- bd `cooViewer-6lrc.9`: 履歴 `8b726c1` のオラクル・ベンチ群を別リポジトリへ移設する。
- リリース **2.0b37**: Sparkle 内部署名、Release 署名・公証・staple を確認する。バージョン更新はリリース作業で行う。
- 日本語のコミットメッセージは `.build/task-r2/commit-message.txt` に保存。指定のトレーラー 2 行を末尾に保持する。

## 付録: StuffIt 統合時の検証記録

以下は開発ガイドにあった **2026-09-13 時点**の記録であり、PR 2 の実行結果ではない。
当時のフォールバックや旧 `--engine` の挙動も含めて、原文を保持する。

**StuffIt 統合の検証記録(2026-09-13、cooViewer-40b6)**

KaitoKit main(slice 1〜8、`../KaitoKit`)から `rm -rf Frameworks/KaitoKit.framework` の上で
通常の Debug ビルドを行い(Run Script が再生成)、`nm Frameworks/KaitoKit.framework/Versions/Current/KaitoKit | grep -c StuffIt`
が 1,764。`xcodebuild … test` は全件成功。

スナップショット CLI(`--engine kaitokit --open <書庫> --snapshot <png>`)で次の 4 本を開き、PNG を確認した
(fixture は git 管理外の `inbox/stuffit-fixtures/`。前 3 本は CC0 の ssokolow/stuffit-test-files、
`jp-pages.sit` は `Scripts/make-sample-pages.swift` の 5 ページを Shift_JIS 名で classic StuffIt に詰めたもの):

| 入力 | 結果 |
|---|---|
| `testfile.stuffit651_dlx.mac9.sit`(classic method 13) | 1/2 (testfile.jpg) が表示 |
| `testfile.stuffit_deluxe_2010.win.sitx`(StuffIt X、JPEG method 7) | 1/2 (sources/testfile.jpg) が表示。**同じ書庫を `--engine xadmaster` で開くと「このページを読み込めませんでした。」**(XADMaster は method 7 を復号できない) |
| `testfile.stuffit7_dlx.mac9.sitx.hqx`(BinHex の中の StuffIt X) | 1/2 (testfile.jpg) が表示 |
| `jp-pages.sit`(日本語名、フォルダ 1 段、1 ページ目に resource fork) | 1/5 (第１巻/ページ01.png) が表示 |

`.sitx` と `.hqx` の 2 本は、XADMaster が出せない内容(method 7 の JPEG、BinHex の内側)が表示されたことで
KaitoKit で開いたと確定する。classic の 2 本は `kaito` CLI で開けるためフォールバック条件に当たらないが、
XADMaster でも同じ画面になるので画面からは区別できない(os_log の `.error` は `log show` で採れなかった)。

暗号化 catalog の StuffIt X(`testfile.stuffit_deluxe_2009.win.password.des.sitx`)と RAR5 `-hp` は、両エンジンとも
パスワードを求めずに黒画面のまま終了する(`KaitoArchive(file:)` が `passwordRequired` を nil に潰し、
XADMaster 側も delegate なしでは開けない)。StuffIt 由来ではない既存の欠陥として cooViewer-p2r1 に記録した。
entry だけ暗号化された書庫(2010 AES 等)はプロンプトが出る。

`.bin` / `.exe` は拡張子を宣言しないため、ドロップ／`--open` では `BookSourceFactory.make` の拡張子判定で
`unsupportedFormat` になる(KaitoKit 自体は内容判定で開ける)。この振り分けと `ArchiveSource` のフォールバック経路は
本対応では変更していない(フォールバック撤去は cooViewer-6lrc)。

