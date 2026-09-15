# XADMaster エンジン撤去(PR 1)の実装・検証記録

日付: 2026-09-15。対象: `feat/xad-removal-1`、起点 `bd0af84`。
対応 issue: `cooViewer-6lrc.5` / `cooViewer-6lrc.6`。

## 変更と設計判断

- `ArchiveSource` は KaitoKit のみを使う。XADMaster エンジン、選択値、one-shot フォールバックを撤去した。
- URL 入力の mmap データを open できなかった場合(nil / throw)に限り、同じエンジンの file 入口を一度試す。列挙は再試行の catch の外に置く。file 成功時は `sourceData` を保持せず、後続の展開係も file 入口を使う。
- メモリ専用入力は実ファイルを持たないため、file 入口で再試行しない。ネスト書庫・EPUB・PDF の振り分けや平文の扱いは維持した。
- `ArchiveEngineDiagnostics` は `mmapRetryCount` と `lastError` をロックで保持する。再試行は info ログへ、終端の open・列挙失敗は回数を増やさず最後のエラーと error ログへ記録する。
- `requireCompleteNames` は両入口とも false。名前 nil のエントリだけを warning ログ付きで除外し、残りを表示する。負の件数などの列挙失敗は `BookSourceError.unreadable` にする。
- 分割 ZIP の `.z01` 兄弟がある場合の mmap 除外を維持した。KaitoKit の兄弟探索は file 入口でのみ動く。
- ゴールデン JSON と provenance のフィールドは固定資産として維持した。採取テスト・provenance 生成・JSON 出力ヘルパーを削除し、読み取り専用の `Decodable` にした。
- 仕様参照は architecture §2.4、development-guide §2・§2.1・§3.6 に反映した。`CLAUDE.md` の実質変更は規約に従って `AGENTS.md` にも要約した。

## 互換方針

| 対象 | 動作 |
|---|---|
| `ArchiveEngine` キー | 削除・改名しない。旧 `"xadmaster"` と未知値は getter で `.kaitokit` に写像するが、保存文字列を書き戻さない |
| `--engine <name>` | `ArchiveEngineKind(rawValue:)` で解決する。`kaitokit` はプロセス内だけに適用し、旧名・未知名は warning を出して無視する |
| 設定 UI | エンジン Picker、AppStorage、Binding と対応する検索語を撤去する |
| 状態表示 | 使用中のエンジン、mmap→file 再試行回数、最後のエラーを表示する |
| `--audit-engines` | 既定・有効値とも `kaitokit` のみ。旧名を指定すると「この版では KaitoKit のみ」のエラーと終了コード 1 |
| 監査 TSV | 既存の 11 列を維持し、`match` 列とエンジン間比較の集計を撤去する。比較は変更していない `Scripts/audit-compare.py` へ渡す 2 つの TSV で行う |

## sandbox 内での検証

### ビルドと XCTest

`/Applications/Xcode.app` の Apple Swift 6.4、Swift 6 strict concurrency で確認した。
本体と全テストターゲットのコンパイル・リンクに成功した。成功時のコマンドは次のとおり。

```sh
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild \
  -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug \
  -derivedDataPath .build/task-r1/DerivedData \
  EXCLUDED_SOURCE_FILE_NAMES=AppIcon.icon \
  'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox' build-for-testing

# 同じ引数の build も BUILD SUCCEEDED
```

通常の build には以下の環境上の制約があった。回避は検証コマンドと生成物だけに限定し、pbxproj・ビルドスクリプトを変更していない。

- 既定の `~/Library/Developer/Xcode/DerivedData` は書き込み不可。worktree 内へ出力した。
- コピー済み framework より新規 worktree のソース日時が新しく、Run Script が再ビルドしようとした。提供された生成物の日時(XADMaster / Washi バイナリ、KaitoKit スタンプ)を更新し、既存 framework を使用した。バイナリ内容は変更していない。
- Icon Studio の書き出しが終了コード 255 で失敗したため、検証時だけ `AppIcon.icon` を除外した。
- Swift マクロの子 sandbox 起動が `sandbox_apply: Operation not permitted` で失敗したため、検証時だけコンパイラに `-disable-sandbox` を渡した。外側の実行 sandbox は維持される。
- 通常の `xcodebuild test` は `com.apple.testmanagerd.control` の `Sandbox restriction` で、テスト開始前に終了コード 133。全テストの成功は未確認。

補助検証として、ビルドしたテストバンドルと同じ `cooViewer.debug.dylib` を `xctest` から直接ロードした。

| 直接実行したテスト群 | 結果 |
|---|---|
| `ArchiveEngineTests` | 11 件中 10 件成功。固定ゴールデン、ZipCrypto、nil / throw の再試行、両入口失敗、再試行後の展開係、列挙失敗、名前欠落、既定エンジンの各検証は成功 |
| `ArchiveAuditTests` | 9 件成功、0 失敗 |
| `SettingsStoreAdvancedTests` | 16 件成功、0 失敗。旧保存値の非書き戻しとプロセス内上書きも確認 |

`ArchiveEngineTests` の既存 `testKaitoKitSolidGroupsDriveParallelMode` だけは 2 assertion が失敗した。
独立プローブで `UTType(filenameExtension: "png")` が動的な未宣言型になり、
`UTType.png.conforms(to: .image)` も false になることを確認した。この環境では PNG をページとして
列挙できず、並列粒度が serial になる。エンジンのゴールデンに含まれる solidGroup 自体は一致した。
型判定や既存テストの期待値は変更せず、通常ホストでの再検証を残した。
新規の open 制御テストは型 DB への依存を避けるため、直接認識される `.avifs` 拡張子に PNG 内容を入れる
フィクスチャを使う(画像デコーダは内容で形式を判別)。既存の固定ゴールデンは変更していない。

ログと直接実行用スクリプトは `.build/task-r1/` に保存した。
主なログ: `commit-1-compile-retry.log`、`commit-2-compile-final.log`、`final-build.log`、
`commit-2-tests.log`、`final-direct-*.log`、`type-probe.log`。

### 実書庫の監査 CLI

同じ 2 枚の PNG(256×384)を通常 CBZ、7z、RAR5、分割 ZIP(`.z01`～`.z09` + `.zip`)へ格納した。
作成には Python zipfile、7zz、rar、`zip -0 -s 64k` を使用した。

| 形式 | 入口 | open / 列挙 / 内容 SHA-256 |
|---|---|---|
| CBZ | data | 成功 |
| 7z | data | 成功 |
| RAR5 | file | 成功 |
| 分割 ZIP | file | 成功 |

4 書庫・8 エントリの名前と SHA-256 が元画像と一致し、各書庫の集約 digest も一致した。
監査結果は KaitoKit の 1 行ずつで、`match` のない 11 列を確認した。
壊れた ZIP を加えた実行は `open-failed` と終了コード 1、`--audit-engines xadmaster` も所定のエラーと終了コード 1。
コーパス、TSV、元画像の digest、生成ログは `.build/task-r1/` に残した。

### 静的確認

- `import XADMaster` / `import UniversalDetector` / `XADMasterEngine` / `.xadmaster` は本体・テストとも 0 件。
- `fallbackCount` / `recordFallback` / `noteFallback` と削除対象のローカライズキー・設定検索語は 0 件。
- 広い名称検索で残るのは、保持を指定された Credits.rtf、歴史的コメント、固定資産のエラーメッセージ、provenance と旧値互換テストの文字列。旧値をテストするための `"xadmaster"` は意図的に残した。
- `Localizable.xcstrings` は JSON として検証し、再試行回数の ja 訳を追加した。
- pbxproj、submodule、ビルドスクリプト、CI、Credits.rtf、LGPL-2.1.txt、ゴールデン JSON に差分なし。
- `git diff --check` 成功。コミット・push は実施していない。

## 未検証範囲と既知の制約

通常 CBZ のスナップショット CLI は sandbox 内で SIGABRT により終了し、PNG を生成できなかった。
通常ホストでの全 XCTest、4 形式のスナップショット、壊れた書庫の黒画面、`--engine xadmaster` と
引数ドメイン `-ArchiveEngine xadmaster` の起動・ファイル情報表示は Fable が sandbox 外で確認する。
そのための実行例は `.build/task-r1/verify-outside-sandbox.sh` に保存した。
この記録の実書庫確認は監査 CLI によるもので、画面表示の確認とは区別する。

監査は単一エンジンであり、アプリの mmap→file 再試行と名前 nil の除外を適用しない。
framework の link / Embed / Run Script、submodule、クレジット・ライセンス資産、CI の撤去は PR 2 の範囲。

Beads は `bd show cooViewer-6lrc.5` / `.6` の時点で
`embeddeddolt: ... openat LOCK: operation not permitted` となり、issue 状態を参照・更新できなかった。
共有 DB をコピー・変更する回避は行っていない。

## コミット分割

コミットは未作成。日本語メッセージと指定トレーラーは `.build/task-r1/commit-1.txt` / `commit-2.txt` に保存する。
同一ファイルに両段階の変更があるため、`commit-1.patch` と `commit-2.patch` を起点 `bd0af84` へ順に適用できる形で保存する。
`.build/task-r1/` は引き継ぎ用の生成物であり、コミット対象に含めない。

### コミット 1(cooViewer-6lrc.5)

- `CooViewer/Core/Source/ArchiveEngine.swift`
- `CooViewer/Core/Source/ArchiveSource.swift`
- `CooViewerTests/ArchiveEngineTests.swift`

### コミット 2(cooViewer-6lrc.6)

- 規約・文書: `AGENTS.md`、`CLAUDE.md`、`Documentation/architecture.md`、`Documentation/development-guide.md`、本検証記録
- アプリ: `CooViewer/App/AppDelegate.swift`、`CooViewer/App/ArchiveAuditCommand.swift`
- 書庫・監査: `CooViewer/Core/Source/ArchiveEngine.swift`、`ArchiveSource.swift`、`BookSource.swift`、`FolderSource.swift`、`NestedFolderSource.swift`、`CooViewer/Core/SupportedTypes.swift`、`CooViewer/Core/Audit/ArchiveAudit.swift`
- 設定・文字列: `CooViewer/Persistence/SettingsStore.swift`、`CooViewer/UI/Settings/SettingsView.swift`、`CooViewer/Resources/Localizable.xcstrings`
- テスト(`CooViewerTests/`): `ArchiveEngineTests.swift`、`ArchiveAuditTests.swift`、`ArchiveSourceTests.swift`、`EngineGolden.swift`、`NestedArchiveSourceTests.swift`、`SettingsStoreAdvancedTests.swift`、`TestFixtures.swift`、`ThumbnailCacheTests.swift`
