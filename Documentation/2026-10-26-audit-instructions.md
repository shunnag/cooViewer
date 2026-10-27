# cooViewer セキュリティ・堅牢性監査の指示書（2026-10-26）

この文書は**検査の手順書**であり、検査結果ではない。結果は
`Documentation/verification/2026-10-26-security-audit.md` に、本プロジェクトの検証記録の形式
（`YYYY-MM-DD-<topic-slug>.md`、必要なら `-evidence.json` を兄弟に置く。`2026-10-20-coreimage-resource-crash.md`
が見本）で書く。

**着手前に `AGENTS.md` と `CLAUDE.md` を読むこと。**本書の指示より、そちらのプロジェクト規約が優先する
（特に filesystem-synchronized groups のため **pbxproj に per-file entry を足してはならない**、
Release の署名・notarization 手順、ビルド方法）。

**この検査は KaitoKit 0.17.0 のリリース判定の前提条件**である。KaitoKit 側（`../KaitoKit`、branch
`fix/security-audit-2026-10-26`）の修正は、KaitoFinder・GyoshukuKit・cooViewer の検査が終わるまでリリースしない。

## 1. 背景: KaitoKit 側で何が見つかったか

外部の AI エージェントによる監査報告（34 指摘）を独立検証（81 エージェント）した結果が
`../KaitoKit/Documentation/verification/2026-10-26-security-audit.md` にある。要点:

- 本物は **鍵導出の CPU 枯渇** 2 件（7z: salt が異なる folder ごとに予算未課金 ≈ 0.42 秒/回で無制限 /
  StuffIt X: 二次で 225 byte の書庫が 425 秒）。**password を渡した時だけ**（誤りでも全額）発生。
- 展開 metadata 2 件、bidi 制御文字による表示偽装、CLI の argv に password。
- 誤り 3 件、既に文書化済みの設計判断が複数、到達不能 2 件。

## 2. 検査の方法（ここが本題）

1. **主張を鵜呑みにしない。** 本書の問いも含め現物で確認する。行番号は HEAD で検証する
   （本書は 2026-10-26 の `d0183b6` / 2.0b49 時点）。
2. **再現できたものだけを「実証済み」と呼ぶ。** 細工ファイルを作り、実際に走らせ、実測と実出力を貼る。
   GUI は headless の Mac mini（`ssh Mac-mini-M4.local` + `gui-run`、`~/.claude/CLAUDE.md` の節）で駆動し、
   停止中の証拠は `screencapture` で残す。
3. **既に守られていないかを先に探す。** このプロジェクトは**防御が厚く、日本語コメントで根拠が書かれている**。
   各領域の「既にある緩和策」と既存の検証記録（特に `2026-10-20-coreimage-resource-crash.md`）を**先に読む**。
   「設計判断として文書化済み」「到達不能」は正しい結論であり成果である。
4. **重大度は「既定設定で誰が引き起こせるか」で決める。** cooViewer は**sandbox 無し**なので、
   どの欠陥も影響が一段重い（第 4.9 節）。一方で、**表示の偽装**は cooViewer では実行経路が無いぶん軽い。
   両方を正しく重みづける。
5. **提案は最小の変更に絞る。** 「文書化だけ」「対応不要」も正当。
6. **過大評価を自分で疑う。** 元の監査は「高」2 件を挙げて両方外した。

## 3. 前提: KaitoKit 0.17.0 候補の変更とこのプロジェクトへの影響

| 変更 | cooViewer への影響 |
|---|---|
| `maxSevenZipEntryKDFWork`（既定 `4 × 2^24` rounds、**reader 単位**） | **影響あり。最重要（第 4.1 節）**。cooViewer は reader を多数開くので予算が多重化する一方、**正規の高 cyclesPower 書庫が開けなくなる回帰**も起こり得る |
| `maxStuffItXKDFWork`（既定 `2^22`） | **影響あり**。`.sitx` / `.sit` / `.sea` / `.hqx` が対応形式（`SupportedTypes.swift:10`）。**現行の 2.0b49 は KaitoKit v0.16.0 ビルドなので、225 byte の敵対的 `.sitx` で固まる可能性がある**（要確認） |
| `ExtractionOptions.preserveSetUserIDBits` | **無関係**。`ExtractionOptions` / `preserveSetUserID` / `resourceFork` は grep で 0 件。cooViewer は KaitoKit の展開器を使わず、memory へ stream して自前の temp を自前の mode で書く |
| resource fork entry の metadata | **無関係**（同上） |

依存の形: **Frameworks/ は gitignore されており、KaitoKit は vendor されていない**。
`Scripts/build-kaitokit-framework.sh` がビルド時に `${KAITOKIT_SOURCE_DIR:-../KaitoKit}` から再ビルドし、
`Sources` などの fingerprint を `Frameworks/.KaitoKit-framework-stamp` と比較する（`:58-74`）。
**版の pin も commit の記録も無い**。検査開始時に `git -C ../KaitoKit log --oneline -1` と現在の stamp を記録せよ。

## 4. 検査領域（優先順）

### 4.1 KDF 予算と password 試行（最優先・両方向）

KaitoKit の予算は **reader 単位**で `reopen()` でも引き継がれない。cooViewer は 1 冊の本に対して
reader を多数開く。**過小（予算の多重化）と過大（正規書庫の拒否）の両方**を見る。

起点: `CooViewer/Core/Source/ArchiveSource.swift:1345-1372`（`checkAndSetPassword`: probe entry を 1 つ選ぶ）、
`:1355`（probe の選び方）、`Core/Source/ArchiveEngine.swift:465-469`（`classifyProbeFailure`:
`CancellationError` と `KaitoError.io` 以外は**すべて `.rejected`**）、`Core/Source/NestedUnlocker.swift:112-190`
（vault → `knownPasswords` 全部 → prompt 最大 3 回。**同じ child reader に対して**）、
`ArchiveSource.swift:265-270`（extractor pool 3〜6）、`:1370`（成功した password を共有 unlocker に broadcast）。

答えるべき問い:
- 1 つの悪意ある書庫で cooViewer が開く reader の数を数える（primary 1 + extractor 最大 6 + spool の reopen +
  `discardDecodedState()` ごとの新規 + nested child ごと ×2 階層 …）。**実効倍率を数値にする。**
- `reopen()` で予算が戻ることにより、KaitoKit の「salt が folder ごとに異なる 7z」への対策は無効化されるか。
  実際に敵対的 7z を作って cooViewer で開き、CPU と wall を測る。
- **回帰の方向**: cyclesPower 24 の正規の暗号化 7z では既定予算で約 4 回しか導出できない。
  `NestedUnlocker.performUnlock` は vault 1 + known N + prompt 3 回の probe を同じ reader に撃つ。
  **正しい password を 4 回目以降に入力した利用者が `limitExceeded` で弾かれないか。**
  弾かれるなら、これは KaitoKit 側の既定値を見直す根拠になる（本書の第 5 節へ）。
- `classifyProbeFailure` は `limitExceeded` を `.rejected`（＝password が違う）に分類してしまうのではないか。
  **利用者に「password が違います」と嘘を表示する**ことになるので、分類の見直しが要るかを決める。
- **現行出荷版の確認**: 2.0b49（KaitoKit v0.16.0 ビルド）に 225 byte の敵対的 `.sitx` を渡すと固まるか。
  固まるなら、0.17.0 への更新は**利用者にとっての修正**であり、リリース判定の優先度が上がる。

再現: `../KaitoKit/Tests/Fixtures/sevenzip-kdf/generate.py` と `.../stuffitx-kdf/generate.py` で細工書庫を作る。
`.sitx` は `../KaitoKit` の検査で使った t65536.sitx（225 byte、425 秒）がそのまま使える。

既にある緩和策（再報告しない）: probe は**暗号化された** entry を優先するので、混在書庫で任意の password が
通ることはない（`:1346-1355`、旧アプリに対する意図的な強化）。probe は 2 GiB の decode 制限内の entry を選ぶ。

### 4.2 本を開く経路と先読みの膨張

開いた瞬間に何が起きるか: 全 entry の一覧 → **nested な書庫 / PDF / EPUB 候補を memory へ全展開** →
ページの background spool。再帰は `nestingDepth < 2`（`ArchiveSource.swift:632`）で止まるが、**深さではなく
幅が無制限**である。

起点: `ArchiveSource.swift:583-641`（`enumerateEntries` は `init` の中で同期実行）、`:354-366`、`:412-424`、
`:706-758`（`build()`）、`:954-961`（`nestedChildData`: 2 GiB guard の後に**全部 memory へ**）、
`:1086-1099`（`perPageDecodeSizeLimit` 2 GiB）、`:1090-1091` と `:917-918`（**サイズ宣言の無い entry では
2 GiB guard を明示的に迂回**）、`:720`（攻撃者の相対 path から URL を組む）。

問い: 1M entry の上限（`:622`）までに nested child をいくつ宣言できるか、各々がいくら払うか。
**11 形式のうち `entryHasSize == false` を返すのはどれか**（そこが guard の穴）。`init` が同期で走る以上、
開く操作でメインスレッドが固まるか（beachball になるか）。`AssemblyPreparation` は `:720` の URL で何をするか
（stat か表示か）。

### 4.3 画像 decode と画素の上限

攻撃者のバイト列は 3 つの decoder に届く: ImageIO/AppKit（OS）、**自前の retro 形式 parser（1,084 行、
raw pointer 出力）**、EPUB の WebKit。

起点: `Core/ImageDecoding.swift:43-98`（`:91-97` は `maxPixelSize == nil` で**無制限 decode**）、
`:51-78`（HDR gain-map）、`:103-138`、`:169-179`（SVG を平文 temp に書いて `NSImage` へ）、
`UI/Reader/ReaderWindowController+Library.swift:670-693`（「原寸で表示」は cap 無し）、`Book.swift:65`、`:346`、
`Core/RetroImageDecoding.swift:232-233`、`:528-529`、`:792-793`、`:999-1000`（4 つの 64 Mpx guard）、
`:240-247`（header 由来の offset から `d[p+1]`、`d[p+2]` を読む）、`:1031-1083`（`renderRGB` の生確保）。

問い: 「原寸で表示」と `Book.swift:346` は cap 無しで decode する。65535×65535 の PNG で何が起きるか。
`Book.displayPixelCap` は `Int?` で、設定から nil（無制限）にできるか。64 Mpx guard の後でも
`renderRGB` は 512 MiB/枚を確保し得る（64 Mpx × 4 byte × doubleHeight）。12 ページ先読みと掛かるとどうなるか。
`parseMagHeader` は `offsetA` / `base` を検証しているか（`:240-247` の読み出しが header 由来の offset である点を
追う）。magic gate は拡張子衝突（`.pic`、`.max`）に対して厳密か。

**ここは自前 parser なので、KaitoKit の parser と同じ厳しさで見る価値がある領域**である。

### 4.4 entry 名の UI 表示とディスク上の名前

cooViewer は bidi / 制御文字の処理を**どこにも持たない**。ただし **entry を open / 起動 / 実行することは無く、
AppleScript も URL scheme も pasteboard 書き込みも save panel も無い**（grep 済み）。
したがって実害は「表示の偽装」に限られ、KaitoFinder より軽い。

起点: `Core/PageEntry.swift:49-54`、`:9-15`（`UnreadableVolumeMarker.message`）、
`UI/Reader/ReaderWindowController.swift:3250`、`Core/PageFileInfo.swift:98-99`、`:134`、
`ArchiveSource.swift:985-986`（temp 名の組み立て）、`:623`、`:633`（**拡張子で経路を決める**）、
`:478`、`:497`（unified log に path と engine の文字列を `privacy: .public` で出す）。

問い: **表示される名前と、判断に使われる名前がずれる箇所はあるか**（`isImageFile` / `isBookFile` は
拡張子で routing する）。NUL / 改行 / U+2028 がラベルを壊す、あるいは警告文に改行を注入できるか。
`:985-986` の `lastPathComponent` + `"<index>-"` 前置で `..` が無害化されることを確認する。
log の `privacy: .public` は、本プロジェクトの方針に照らして妥当か。

既にある緩和策: `EPUBTitleFormatter`（cooViewer-oxr.52）は EPUB 題名の方向制御を ICU の bidi class で
解決済み。**同じ議論を再度持ち出さない**（ただしあれは isolate を**足す**処理で、埋め込まれた
U+202A-202E を**除く**処理ではない点は区別してよい）。

### 4.5 一時ファイルの平文と後片付け

cooViewer は設計上、復号した内容をディスクに書く（spool）。CWE-312 に対する規律が文書化されている。
問いは「その規律が端で破れないか」と「stale sweeper を悪用できないか」。

起点: `ArchiveSource.swift:1464-1466`（`<pid>-<uuid>`）、`:78-83`（`spoolEncrypted` と per-process
`SymmetricKey`）、`Core/Source/ArchiveSpoolWorker.swift:37-56`、`:49-50`、`ArchiveSource.swift:963-991`
（nested の 0o700 / 0o600）、`AppDelegate.swift:113-130`（起動時の sweep）、`ArchiveSource.swift:643-655`
（deinit の detached cleanup）、`:313-322`（`removeStaleSpoolDirectories` が pid を名前から切り出す）。

問い: `spoolEncrypted` は `beginSpooling` の 1 回だけ決まる。**平文で spool を始めた本が、後から
sensitive になる**経路はあるか。sweeper の pid 解析は `<pid>-<uuid>-nested` を正しく扱うか、
**別プロセスの生きた spool を消せるか**。`.atomic` 書き込みは rename 前に umask の mode で存在し、
chmod 0o600 は**後**である（窓があるか）。強制終了で平文が次回起動まで残るのは許容された契約か。

### 4.6 コレクション全体での資源枯渇

**1 つの操作（folder を開く）がほぼすべての上限を「書庫の数」倍する**のがこのプロジェクトの形。
`Documentation/verification/2026-10-20-coreimage-resource-crash.md` に既に 1 度監査された記録がある。**先に読む。**

起点: `Core/Source/NestedFolderSource.swift:11-45`、`ArchiveSource.swift:94`、`:98`、`:45`、`:1903-1913`、
`:265-270`、`ArchiveEngine.swift:186`（`fileAccessPolicy = .bounded`）、`Core/FileDescriptorHeadroom.swift:1-19`。

問い: 掛け算の表を作る（N 書庫 × (primary 1 + extractor 最大 6) × per-reader の decode memory …）。
`prepareNextBookPages`（既定 6）により、前に進むだけで次々と本が開くか。
`ArchiveDecodedStateCache` の解放条件（`!isBuilding && !spoolIsActive && 全 extractor idle`）を
**敵対的な書庫が永久に満たさなくできるか**。2,000 個の小さな書庫で EMFILE に再び到達するか。

### 4.7 Sparkle の更新経路（KaitoKit に対応物が無い最重要領域）

**compromise が全利用者に届く唯一の経路**。payload 自体は EdDSA 署名で守られているが、
**appcast.xml は署名されていない XML** で、master に直接 push されている。

起点: `appcast.xml`、`Info.plist:8`（feed URL）、`:10`（EdDSA 公開鍵）、`Scripts/fetch-sparkle.sh:4-11`
（version + SHA-256 の二重 pin）、`:29-36`、`Scripts/sign-sparkle-nested.sh:14-20`、`:29-43`、
`Scripts/make-appcast.sh:21-28`（**login keychain の EdDSA 秘密鍵**）、`:30`、`:32-41`、`:49-56`。

問い:
- enclosure は署名されるが**その他の要素は署名されない**。master に書ける攻撃者は `sparkle:version`、
  `shortVersionString`、`minimumSystemVersion`、説明文を書き換えられる。**何ができて何ができないか**を
  具体的に列挙する（古い版への誘導＝downgrade は可能か、任意 zip の配布は可能か）。
- master は branch protection されているか（`gh api repos/shunnag/cooViewer/branches/master/protection`）。
  手で push する運用なら、**これが事実上の完全性管理**である。
- `Info.plist:10` の公開鍵が、実際に使っている秘密鍵と対応しているか
  （`Frameworks/Sparkle-dist/bin/generate_keys -p` と突き合わせる）。不一致なら更新が全く効かない。
- 公開済みの 1 件を端から端まで独立検証する（zip を落とし、長さが appcast の宣言と一致し、Ed25519 署名が
  検証できること）。
- Sparkle 2.10.0 は最新か、advisory は無いか（pin の仕組み自体は正しい）。

既にある緩和策（再報告しない）: feed も全 49 item の enclosure も https、公開鍵は bundle に pin。

### 4.8 ビルドと CI の供給連鎖

**cooViewer のビルドは、他の 2 つの repository の default branch から取得した script を実行する**
（CI でも開発機でも、pin 無し）。

起点: `.github/workflows/ci.yml:10-18`（trigger。**`permissions:` block が無い**）、`:29`
（`actions/checkout@v4` は tag pin）、`:31-34`（KaitoKit と Washi を `--branch main` で浅く clone）、
`:14-15`（unpinned が**意図的な上流破壊検知**であるというコメント）、`:41-45`、
`Scripts/build-kaitokit-framework.sh:28-32`（存在と実行可能性しか見ない）、`Scripts/fetch-sparkle.sh`（対照例）。

問い: 兄弟 repository の compromise は cooViewer の CI における任意コード実行か。**開発機でも同じ**
（現在 `../KaitoKit` は audit branch `d2fa536` を指している）。出荷された KaitoKit の版が
**どこにも記録されない**（framework は 0.1.0 を名乗る）。`build-kaitokit-framework.sh` に
`git describe --tags --always --dirty` を Info.plist へ刻むべきか（**トレーサビリティの提案として最有力**）。
`actions/checkout@v4` の tag pin は KaitoKit と同じ運用判断なので、**3 プロジェクトで結論を揃える**。

### 4.9 sandbox・entitlement・hardened runtime（重大度の倍率）

cooViewer は**sandbox 無し・entitlement なし**（`codesign -d --entitlements` が空）。したがって decoder の
欠陥は利用者の home 全体に届く。Release は hardened runtime 有効・Developer ID・notarized／stapled。

問い: sandbox 無しは記録された意図的判断か（NAS や任意の場所の本を開く要件は実在する）。
記録が無ければ、**判断を記録すること自体**が成果物になる。`disable-library-validation` が無いので
3 つの embedded framework は同一 team 署名である必要がある——確認する。
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` を手で渡す運用は、渡し忘れたときに notarization が落ちるだけで
安全側に倒れるか。Debug は ad-hoc 署名で hardened runtime 無効・Release と同じ bundle id を共有する
（`AppDelegate.swift:120-122` の pid sweep がそれに依存）——危険は無いか。

### 4.10 EPUB / WebKit host

nested の固定レイアウト EPUB は `build()` 中に自動で開かれ、WebKit で描画される。
**攻撃者の HTML / CSS / JavaScript が実行される唯一の経路**。
起点: `ArchiveSource.swift:803-807`（256 MiB 超の sensitive FXL は staging せず skip）、
`Core/EPUB/EPUBOffscreenSettings.swift:7-45`、`Core/EPUB/EPUBStagingArea.swift:44`、`:275`、`:338`、
`UI/Reader/ReaderWindowController+EPUB.swift:716`、`:801`、`:927`、`:1383`（key は local event monitor 経由）。
問い: WebKit の設定で JavaScript / リモート読み込み / file URL の扱いはどうなっているか。
EPUB 内の資源が外部ネットワークに出られるか。staging の平文はどこに置かれ、いつ消えるか。

## 5. 必須の横断チェック

1. `git -C ../KaitoKit log --oneline -1` と `Frameworks/.KaitoKit-framework-stamp` を記録する。
2. KaitoKit 0.17.0 の 4 変更それぞれに「影響あり / 無関係（根拠）」を明示する。
3. **4.1 の両方向の結論を数値で出す**:（a）reader の実効倍率、（b）正規の高 cyclesPower 書庫で
   利用者が弾かれるか。(b) が yes なら **KaitoKit 側の既定値かエラー分類を見直す**根拠になるので、
   その旨を記録に明記し、KaitoKit の記録にも反映できる形で書く。
4. 4.7 の公開鍵一致と署名の独立検証を済ませる。

## 6. 成果物の形式

判定表（`ID | 主張 | 判定 | 実リスク | 重大度 | 対応`）、実証済み各件の再現コマンドと実出力、
退けた項目とその根拠、自分の検査の限界（GUI で駆動できなかった経路、計測の揺らぎ）。
修正する場合は、`AGENTS.md` / `CLAUDE.md` のテスト規約に従った回帰テストを添える。

## 7. 禁止事項

- `git commit` / `push` / branch 作成をしない。**appcast.xml と master に触らない。**
- インストールをしない。
- pbxproj に per-file entry を足さない（filesystem-synchronized groups）。
- `../KaitoKit` と `../Washi` を書き換えない。
- repository を汚さない（細工ファイルは `$TMPDIR` 以下）。
- `open -a` でアプリを起動しっぱなしにしない（headless の mini では野良インスタンスが click を奪う）。
- GUI 検査の前に画面を塞ぐものが無いか確認する（`~/.claude/CLAUDE.md` の Mac mini の節）。

## 8. 完了条件（リリース判定）

- 全領域の判定が書かれている。
- 重大度 高 / 中 が残っていない（残るなら修正済みか裁定待ちと明示）。
- 4.1 の (a)(b) と 4.7 の鍵一致に結論が出ている。
- 現行出荷版（2.0b49）が敵対的 `.sitx` / 7z で固まるかの事実が判明している。

## 9. 想定工数と最初の 30 分

全体で 2〜3 日（3 プロジェクト中もっとも大きい）。配分は 4.1 と 4.7 に半分、4.2・4.3・4.6 に 1/3、残りに 1/6。

最初の 30 分: (1) `AGENTS.md` と `CLAUDE.md` を読む。(2) `Documentation/verification/2026-10-20-coreimage-resource-crash.md`
を読む（4.6 の前提）。(3) `git -C ../KaitoKit log --oneline -1` と stamp を記録。
(4) 4.1 の「現行出荷版に敵対的 `.sitx` を渡すと固まるか」を先に決着させる（yes なら全体の優先度が変わる）。
