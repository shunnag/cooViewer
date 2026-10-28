# AppleDouble の open 時検査を省く変更（cooViewer-y9eq.1）

主書庫・展開係・監査の共通 ReaderOptions を `.expose` にした。画像の表示一覧は名前で
従来どおり除外し、エントリ番号の変更に備えて画像キャッシュの名前空間を更新した。
BookStates のスキーマ・保存キー・復元規則は変更していない（設計書 §5、§7.2）。
bd と git の書き込み操作、pbxproj の編集、兄弟リポジトリのソース編集は行っていない。

**ReaderOptions の全生成箇所**

`rg -n 'ReaderOptions\(' --glob '*.swift' .` で確認した生成箇所は次の3箇所。

| 箇所 | 変更 |
|---|---|
| `CooViewer/Core/Source/ArchiveEngine.swift:131` | `ArchiveDecodeBudget.readerOptions` に `appleDoublePolicy: .expose` を追加 |
| `Scripts/diagnostics/FileAccessPerformanceProbe.swift:11` | 診断用のオプションにも `.expose` を指定 |
| `Scripts/diagnostics/ArchiveReaderFDProbe.swift:21` | 省略されていたオプションを明示生成し、data/file 両入口へ渡す |

アプリ側の `KaitoKitEngine.options`（`ArchiveEngine.swift:177`）は最初の生成箇所を必ず使う。
役割による変更は復号予算だけで、副ファイル方針は全役割で同じ。

| 経路 | 共通オプションへの経路 |
|---|---|
| 主書庫の file/data | `ArchiveSource.swift:556` / `:572` → `ArchiveEngineFactory.live`（`ArchiveEngine.swift:384`）→ `KaitoKitEngine.open`（`:218` / `:222`） |
| 独立した展開係の file/data | `ArchiveSource.swift:1904` / `:1917` → 同じ factory（役割は `.extractor`） |
| ネストの子 | `ArchiveSource.swift:899` / `:908` の子 ArchiveSource に同じ factory を渡す |
| パスワード検証 | `ArchiveSource.swift:1393` / `:1401` の既存主書庫を使い、新規オプションを作らない |
| スプール専用の再開 | `ArchiveSource.swift:1580` → `ArchiveEngine.swift:344`。KaitoKit の `ArchiveReader.swift:298` は元の options を複製する |
| Quick Open の安全な再試行 | `ArchiveEngine.swift:279` の `safeOptions = options` から Quick Open とパスワードだけを変更する |
| 監査 CLI | `Core/Audit/ArchiveAudit.swift:206` / `:207` → 同じ factory、`.primary` |

テストで旧 `.merge` を作る比較用 factory は `ArchiveAppleDoubleTests.swift:44`。
製品コードに別の ReaderOptions 生成箇所はない。

**番号と保存・キャッシュの確認**

KaitoKit の `../KaitoKit/Sources/KaitoKit/Formats/AppleDouble/AppleDoubleReader.swift:63` は
`.expose` なら内側の reader をそのまま返す。旧 `.merge` は同ファイル `:125` 以降で
確認済み sidecar を除去し、resource fork があれば追加し、`:147` 以降で番号を振り直す。
cooViewer の `ArchiveSource.swift:629` はこの番号を `PageEntry.id` に使うため ID は変わる。
追加 fixture では画像の ID が `[0, 2, 4]` → `[2, 4, 8]` になり、名前・順序・内容は同じ。

| 保存・キャッシュ | 参照箇所と結論 |
|---|---|
| ディスクサムネイル | `Core/Source/FolderSource.swift:97` が説明する通り ID がキー。実装は `Core/Cache/ThumbnailCache.swift:168`、`:192` の `<bookKey>/<id>@<解像度>.heic`。旧 `Book.makeCacheKey` は ID を含まず、書庫ファイルと表示パス一覧が同じだと旧画像が別ページに当たり得た。`Core/Book/Book.swift:175` の `pages-v2` と `:186` の ID・パス対応で失効させた。順序非依存を保ち、同長パス間の ID 交換が加算で相殺されないよう `:194` で混ぜる |
| 超解像のディスクキャッシュ | `UI/Reader/ReaderWindowController.swift:1715`、`:2525`、`:2794` と `UI/Reader/LoupeController.swift:200` は同じ `book.cacheKey` と ID を使う。`Core/Rendering/ImageResampler.swift:336` の超解像キー、`MLSuperResolver.swift:337` のディスクファイル名まで共通キーを継承するため、同じ修正で失効する。別の移行は不要 |
| EPUB・合本専用のサムネイル | `UI/Thumbnails/EPUBThumbnailCacheKey.swift:27` と `UI/Reader/ReaderWindowController+Thumbnails.swift:324` は専用キー。後者の `col:` キーは Book.cacheKey を使わないが、`UI/Thumbnails/CollectionThumbnailPlan.swift:61` は表示セルの `entries.count` から ID を付け直す。前者も EPUB の画面順。どちらも書庫の生エントリ番号を使わず、今回の変更で画面・セル順が変わらないため失効は不要 |
| しおり・最終ページ | `Persistence/BookStateRecord.swift:13`、`:54`、`:66` は表示ページ配列の位置とパスを保存する。保存元は `UI/Reader/ReaderWindowController+Library.swift:27`、`:40`、`:43`。`BookHistoryStore.swift:62` は `pathInBook` があれば照合し直し、なければ保存位置を返す。`:396` と `:595` は書庫のエントリ番号ではなくこの表示位置。`:605`、`:618` から UI の `ReaderWindowController+Library.swift:104`、`:130` へ復元する。表示順・パスが同じなので、パス有りも番号のみの旧 v2 データも同じページへ戻る。スキーマ・canonical path の SHA-256 ファイル名（`BookHistoryStore.swift:86`）は維持 |
| 見開き指定・ComicInfo | 見開き指定も表示ページ位置。`Book.swift:242` の ComicInfo 章指定も表示一覧の位置で、`:209` のメタデータ保持は Book 内だけ。`ArchiveSource.swift:620` で控える XML のエントリ番号は open ごとに取り直す |
| スプール | `ArchiveSource.swift:1504` が `<pid>-<UUID>` の専用ディレクトリを毎回作り、`:1882` はそのインスタンスの `spooledIDs` とディレクトリだけを読む。旧ディレクトリの数字ファイルは別インスタンスから再利用しない。ネストの一時領域も `:999` の UUID。ディスク上の旧番号を再利用する経路はない |
| 復号状態・元データ | `Core/Source/ArchiveDecodedStateCache.swift:28`、`:39` はプロセス内の所有者 `ObjectIdentifier` で管理。`ArchiveSource.swift:162`、`:961` の ID 別元データもソース actor 内のみ。各 reader の索引と方針は開いた時点で固定され、別版・別インスタンスの番号と混ざらない |
| デコード画像・寸法・進行中タスク | `Core/Cache/PageCache.swift:12` は Book 単独所有のメモリ。`Book.swift:291`、`:361` も Book 内の ID 索引。グローバルな `ImageResampler` とサムネイル表示は版付き `bookKey` を使う |
| ページ数・census | 普通の書庫は `Book.swift:202` の `entries.count` を計算し直し、番号に依存する永続ページ数キャッシュはない。永続 census はリフロー EPUB 用で、`BookStateRecord.swift:165` の版面キー・spine ごとの枚数・releaseIdentifier（`BookHistoryStore.swift:542`、`:551`）。書庫エントリ ID は保存しない。合本のメモリ対応表は `Core/Book/CollectionPageMap.swift:30`、`:42` と `UI/Reader/CollectionPageMapState.swift:34`、`:41`、`:60` が現在の PageEntry 列を保持・照合する |
| Quick Open の不信任キー | `Core/Source/ArchiveQuickOpenPolicy.swift:7` の canonical path と BookFileIdentity（サイズ・mtime）だけ。`:18` の集合はプロセス内のみで、ページ番号を持たない。変更不要 |
| ネストの保存パスワードキー | `ArchiveSource.swift:846` の親キー＋書庫内パス。番号付き一時展開ファイル名を保存キーには使わないため変更不要 |

キャッシュの版更新はフォルダ・PDF を含む全書種の Book.cacheKey に適用され、このキーを
使う既存のサムネイル・超解像は一度再生成する。旧キャッシュの強制削除はせず、既存の期限・容量管理で回収する。
保存済みのユーザーデータは変更しない。

**resource fork と Finder 情報**

`ArchiveEngine.swift:244` 以降で使う情報は名前・内容・サイズ・directory/encrypted・solid group。
Finder 情報、xattr、resource fork の関連付けや formatSpecific は参照していない。
旧 `.merge` が作る `..namedfork/rsrc` は画像拡張子に当たらずページにならない
（`Core/SupportedTypes.swift:132`）。`.expose` の sidecar は `ArchiveSource.swift:616` の
ドット始まり／`__MACOSX` 除外でページにもネスト候補にもならない。
Finder 情報・resource fork を消費する製品機能への変更はない。

監査は元々全エントリを列挙するため、TSV の件数・番号・名前・ハッシュは sidecar を露出した
一覧に変わる。これは表示ページ一覧とは別の診断出力。`includeHashes` を指定した監査は
要求どおり sidecar も内容ハッシュのため読むが、open 自体ではそのデータを検査しない。

**XCTest**

`CooViewerTests/ArchiveAppleDoubleTests.swift` に追加した6件：

| 行 | 確認すること |
|---|---|
| `:56` | ditto 形式の AppleDouble ヘッダ（Finder 情報＋非空／空 resource fork）、直下の `._*` と `__MACOSX` の木を手組み ZIP に格納。旧 `.merge` と新 `.expose` の ArchiveSource で可視パス・名前・順序を比較し、具体的な ID 変更と幅マーカーによる内容を確認。cbz の mmap と cbr 名の file、独立した展開係の両経路 |
| `:79` | 同じ fixture を入れたネスト書庫でもパス・順序・内容が同じ。空き容量は既存 TaskLocal の注入点で固定 |
| `:105` | 旧一覧から v2 JSON にしおり・最終ページを保存し、新ストアで再読込して新一覧へ復元。パス付き／番号だけの両方を確認 |
| `:140` | 旧キーのディスク画像を置き、同じ ID が別ページを指す衝突を再現。旧キーなら誤った幅5の画像に当たること、新キーなら正しい表紙の幅4へ戻ることを確認。旧式のキーは変更前の式から得た固定値 |
| `:196` | 同じ長さのページ名同士で ID を交換してもキーが変わること。別テストでエントリ列の反転ではキーが変わらないことも確認 |
| `:208` | 公開 ByteSource 差し込み API で全 read 範囲を記録。先頭・末尾の形式検査範囲から離した sidecar payload に `.primary` / `.extractor` の open が触れないこと。同じ観測点で `.merge` が触れることも確認 |

画像判定をシステム UTI サービスに依存させない既存テストの `.avifs` パターンを用い、
内容は PNG のマジックで復号する。旧サムネイルも PNG バイトを `.heic` のキャッシュパスへ
直接置く（読取はマジック判定）。HEIC 符号器自体は今回のテスト対象に含めない。
`ArchiveDecodeBudgetTests.swift:80` に、両役割の `.expose` 固定のアサーションも追加した。

**検証コマンドと実際の結果**

以下はすべてこの作業ツリーで実行。ログは `/tmp/cooviewer-appledouble-*.log`。
通常のテストホストによる全スイートはオーケストレーター側で実行する。

1. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug -jobs 4 build > /tmp/cooviewer-appledouble-build.log 2>&1`
   → **exit 65**。既定の `~/Library/Developer/Xcode/DerivedData` に書けずビルド準備失敗。
2. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug -jobs 4 -derivedDataPath /tmp/cooviewer-appledouble-derived build > /tmp/cooviewer-appledouble-build-local.log 2>&1`
   → **exit 65**。Build Washi framework が兄弟の `Washi/.build/out/.../manifest.json` へ書けず失敗。
3. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer GIT_OPTIONAL_LOCKS=0 xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug -jobs 4 -derivedDataPath /tmp/cooviewer-appledouble-derived -only-testing:cooViewerTests/ArchiveAppleDoubleTests -only-testing:cooViewerTests/ArchiveDecodeBudgetTests -only-testing:cooViewerTests/BookCacheKeyTests test > /tmp/cooviewer-appledouble-test.log 2>&1`
   → **exit 70**。こちらの target 名の大小文字指定ミス。直後の4で修正した。
4. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer GIT_OPTIONAL_LOCKS=0 xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug -jobs 4 -derivedDataPath /tmp/cooviewer-appledouble-derived -only-testing:CooViewerTests/ArchiveAppleDoubleTests -only-testing:CooViewerTests/ArchiveDecodeBudgetTests -only-testing:CooViewerTests/BookCacheKeyTests test > /tmp/cooviewer-appledouble-test-targeted.log 2>&1`
   → **exit 133**。同じ Washi 書込エラー後に Xcode が停止。XCTest には到達しなかった。
5. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 -module-name AppleDoubleTestsProbe -module-cache-path /tmp/cooviewer-appledouble-module-cache -I build/Debug -F Frameworks -I Frameworks/Washi.framework/Modules -I Frameworks/KaitoKit.framework/Modules -I /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks CooViewerTests/ArchiveAppleDoubleTests.swift CooViewerTests/ArchiveDecodeBudgetTests.swift CooViewerTests/TestFixtures.swift > /tmp/cooviewer-appledouble-typecheck-tests.log 2>&1`
   → **exit 0**。初期追加テストを既存モジュールに対して型検査。マクロの sandbox 警告あり。
6. `/bin/zsh /tmp/cooviewer-appledouble-probe/build-library.sh > /tmp/cooviewer-appledouble-library-final.log 2>&1`
   → **exit 0、診断なし**。既存の framework を使い、製品の Swift 全140ファイル（main.swift を除き生成 asset 定義を含む）と監査の Objective-C を、Swift 6 strict concurrency で実際にコンパイル・リンクした。古いアプリ dylib はリンクしていない。
7. `/bin/zsh /tmp/cooviewer-appledouble-probe/build-tests.sh > /tmp/cooviewer-appledouble-compile-tests-final.log 2>&1`
   → **exit 0、診断なし**。最終版の追加 XCTest と復号予算テストを新しいライブラリへリンク。既存 BookCacheKeyTests も原文のクラスを抜き出してコンパイルしたが、独立 runner での実行対象は追加6件＋復号予算7件。
8. `mkdir -p /tmp/cooviewer-appledouble-probe/home`、`CFFIXED_USER_HOME=/tmp/cooviewer-appledouble-probe/home /tmp/cooviewer-appledouble-probe/tests > /tmp/cooviewer-appledouble-run-tests-verified.log 2>&1`
   → **ともに exit 0**。**13 tests、0 failures**。実ユーザーの BookStates を使わず一時ストアで実行。
9. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -typecheck -parse-as-library -swift-version 6 -strict-concurrency=complete -module-cache-path /tmp/cooviewer-appledouble-module-cache -F Frameworks -I Frameworks/KaitoKit.framework/Modules Scripts/diagnostics/ArchiveReaderFDProbe.swift > /tmp/cooviewer-appledouble-typecheck-fd.log 2>&1`
   → **exit 0、診断なし**。
10. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -typecheck -parse-as-library -swift-version 6 -strict-concurrency=complete -D CURRENT -module-cache-path /tmp/cooviewer-appledouble-module-cache -F Frameworks -I Frameworks/KaitoKit.framework/Modules Scripts/diagnostics/FileAccessPerformanceProbe.swift > /tmp/cooviewer-appledouble-typecheck-perf.log 2>&1`
    → **exit 0、診断なし**。
11. `git --no-optional-locks diff --check` → **exit 0**。
    `git --no-optional-locks status --short` と `git --no-optional-locks diff --stat` で変更範囲を確認。
    `rg -n 'ReaderOptions\(' --glob '*.swift' .` で上記3生成箇所を再確認。

独立ビルドの準備中の失敗も記録する：最初は swiftc へ `-filelist` を渡して **exit 1**。
応答ファイル `@sources.txt` に修正後、明示的な `-framework Washi` 等が欠けたリンクも
**exit 1**。framework 指定後は **exit 0**、Objective-C の deployment target 警告を直した
最終版が上記6。初回テストコンパイルは存在しない `CooViewerTests/AssemblyTestGate.swift`
を指定して **exit 1**、必要な BookCacheKeyTests クラスだけを原文から切り出して解消した。
初回 runner は UTI が `.png` を画像と認識できず一覧が空となり **exit 133**。
その後の実行は HEIC 書込とネスト用空き容量取得の環境依存で **exit 1（2 failures）**。
既存の注入点と上記 fixture へ修正後、上記8の13件が通った。

UTI の切り分けコマンドは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -module-cache-path /tmp/cooviewer-appledouble-module-cache /tmp/cooviewer-appledouble-probe/uti.swift -o /tmp/cooviewer-appledouble-probe/uti` と
`/tmp/cooviewer-appledouble-probe/uti`（ともに **exit 0**）。`UTType(filenameExtension: "png")` は
dynamic 型、`UTType.png.conforms(to: .image)` は false だった。製品の画像判定は変更していない。

直接ビルドのスクリプトは `/tmp/cooviewer-appledouble-probe/` に残す。
`sources.txt` は `CooViewer/**/*.swift` から `App/main.swift` を除いた絶対パスと
`build/CooViewer.build/Debug/cooViewer.build/DerivedSources/GeneratedAssetSymbols.swift` の一覧。
ライブラリの主要コマンドは次の通り（上記6で実行済み）。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun clang -target arm64-apple-macos26.0 -fobjc-arc -fblocks -c CooViewer/Core/Audit/ArchiveAuditException.m -o /tmp/cooviewer-appledouble-probe/ArchiveAuditException.o
xcrun swiftc -emit-library -emit-module -enable-testing -parse-as-library -Onone -j 4 -swift-version 6 -strict-concurrency=complete -Xfrontend -disable-sandbox -D DEBUG -target arm64-apple-macos26.0 -module-name cooViewer -module-cache-path /tmp/cooviewer-appledouble-module-cache -F Frameworks -framework Washi -framework KaitoKit -framework Sparkle -I Frameworks/Washi.framework/Modules -I Frameworks/KaitoKit.framework/Modules @/tmp/cooviewer-appledouble-probe/sources.txt /tmp/cooviewer-appledouble-probe/ArchiveAuditException.o -emit-module-path /tmp/cooviewer-appledouble-probe/cooViewer.swiftmodule -o /tmp/cooviewer-appledouble-probe/libcooViewer.dylib
```

未確認なのは通常の xcodebuild による app bundle のビルド完了と XCTest ホストでの実行、
オーケストレーターが担当する全スイート、実 NAS での pread 数・速度、実 HEIC 符号化。
ByteSource の read 範囲検証は実行できたので省略していない。利用者提示の
812→5 pread という計測値の再測定は行っていない。
