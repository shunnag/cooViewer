# セキュリティ・堅牢性監査の検証（2026-10-26）

`Documentation/2026-10-26-audit-instructions.md` の指示書に沿って実施した。HEAD は `d0183b6`（2.0b49）。
`../KaitoKit` は branch `fix/security-audit-2026-10-26`（検査開始時 `32205fc`、検査中に 0.17.0 候補の修正が入った。第 6 節）。
`Frameworks/.KaitoKit-framework-stamp` は Swift 版・絶対 path・arch・内容 fingerprint だけで**commit を含まない**
（指示書 §3 の指摘どおり。4.8-F1 で対応）。

**体制**: 10 領域に 1 エージェントずつ（読解と read-only コマンドのみ。ビルド・計測・GUI 駆動・commit は禁止）、
確認された所見ごとに敵対的反証 2 観点で合計 78 エージェント。所見 96 件のうち 41 件が反証を通過し、55 件を退けた。
実測は orchestrator が逐次実行した。

## 1. 判定表（重大度 中以上と、方針に関わるもの）

| ID | 主張 | 判定 | 実リスク | 重大度 | 対応 |
|---|---|---|---|---|---|
| CV41-1 | ネスト子の自動 password 試行に上限が無く、1 冊あたりの鍵導出総量が無制限 | **正しい**（反証 2/2 で生存） | `NestedUnlocker.performUnlock` の vault + `knownPasswords` ループが `promptingDisabled` 判定より**前**にあり、`build()` 中に child ごとに自動で走る。利用者が 1 回 password を通すと以後**操作ゼロ**で `K × (1+N)` 回の導出。失敗した child は §4.17 の方針で無言で除外され、`AssemblyPreparation` の 10 秒 cutoff は「除外」には張られない（`AssemblyRetry.swift:345-352`、`:434-441`） | 中 | **修正**（自動試行の連続全敗に上限） |
| 4.2-F1 / C46-5 | ネスト子の平文 temp 書き出しに空き容量判定も累計上限も無い | **正しい**（反証 2/2 で生存） | `writeNestedTemp`（`ArchiveSource.swift:980-991`）は無条件に書く。1 件 ≤ 1 GiB、件数は 1M 打ち切りまで。**書き込みは子を開く前**なので壊れた child でもディスクを食い、失敗時の unlink が無い。同じプロジェクトの他 2 つの temp 書き手には予算がある | 中 | **修正** |
| 4.2-F2 | `build()` に候補件数・時間の予算が無く、窓を閉じても取り消されない | **正しい**（反証 2/2 で生存） | 60〜100 万件まで直列処理。`openBook` の Task を controller が保持していない | 中 | **修正** |
| F1（画像） | MAG の 64 Mi guard が packed index の byte 数なので 16 色 × doubleHeight の 4 倍が抜ける | **正しい**（反証 2/2 で生存） | **48 byte の MAG で `renderRGB` が 1 GiB（65536×4096 RGBX）を確保**。retro 経路は `maxPixelSize` を受け取らず、縮小は decode の後（`ImageDecoding.swift:105-107`） | 中 | **修正** |
| 4.4-F7 | ComicInfo.xml の各欄が長さ上限なしで表示され、⌘I が全文の高さを MainActor で測る | **正しい**（反証 2/2 で生存） | メインスレッドの固着。入力は 16 MiB まで来る | 中 | **修正** |
| C46-6 | decoded-state の追い出しと spool 開始が reader を reopen するので、ページ送りで鍵導出予算が何度でも全額復活する | 正しい（反証で低へ） | KaitoKit 側では 1 冊あたりの総量を縛れない。1 回あたりは有限（`reader × password` ごとに cyclesPower 24 で 16 導出 / 19 で 512） | 低 | 文書化（KaitoKit のリリース判定へ渡した） |
| CV41-2 | 旧既定 `4 × 2^24` では、`knownPasswords` が 2 件以上あると正しい password を 3 回目に入れた利用者が偽「パスワードが違います」で弾かれる | 正しい | nested とコレクションで到達する | 低（解消済み） | **KaitoKit 側の修正で解消**（第 6 節。cooViewer 側の変更は不要） |
| CV41-3 | `classifyProbeFailure` が `KaitoError.limitExceeded` を `.rejected`（= password が違う）に分類する | **正しい**（反証 2/2 で生存） | 利用者に嘘の文言が出る。`ArchiveEngine.swift:465-469`。挙動は `CooViewerTests/PasswordCheckTests.swift` で固定されている | 低 | **修正** |
| CV41-5 | 出荷済み 2.0b49 に 225 byte の敵対的 `.sitx` を渡すと固まる | **部分的（未実証）** | 既存 fixture（catalog 暗号）では固まらない（`passwordRequired` で open 失敗）。固まるのは stream 暗号の変種で、その fixture は存在しない。**一方 7z 経路は v0.16.0 に entry 予算が無いので固まり、vault / 既知 password の自動投入で操作ゼロで到達する** | 中（0.17.0 で解消） | 記録（リリース優先度の根拠） |
| SPK-1 | appcast.xml は enclosure 以外が署名されず、master に書ける攻撃者が更新 metadata を注入できる | **正しい**（反証 2/2 で生存） | **master に branch protection は無い**（`gh api .../branches/master/protection` → `Branch not protected` 404、`rulesets` → `[]`）。注入できるのは metadata と release notes の参照先で、**任意コードの配布はできない**（enclosure は EdDSA 署名） | 中 | **利用者の裁定**（第 4 節） |
| SPK-5 | release notes の表示経路で攻撃者の HTML / JS が実行される | 部分的 | feed が署名されていれば Sparkle は外部参照を禁止する。未署名のままなら `releaseNotesLink` を任意の https URL にできる | 低 | SPK-1 と同じ裁定 |
| SPK-3 | **古い署名済み zip を高い版に見せかけて downgrade を誘導できる** | **到達不能（反証）** | Sparkle 自身が防ぐ。`Autoupdate/SUPlainInstaller.m:323-343` の `performInitialInstallation` が「Prevent malicious downgrades」として**展開後の実物の bundle** の `CFBundleVersion` を host の版と比較する | — | — |
| SPK-4 | 公開鍵が実鍵と不一致で更新が効かない | **誤り** | 2.0b49 / 2.0b25 / 2.0b2 の 3 版を download し、長さ一致と Ed25519 署名の検証成功を独立に確認（第 2.1 節） | — | — |
| SPK-7 | `make-appcast.sh` は zip と appcast の版表示の一致を保証している | **誤り** | 版は argv を文字列として埋めるだけで照合しない。ただし SPK-3 の installer 検査があるため実害は metadata に限られる | 低 | 文書化 |
| 4.8-F1 / 4.8-F7 | 出荷物から同梱した KaitoKit / Washi の版が判らない（framework は 0.1.0 / 1.0.0 を名乗る） | 正しい | 補償策は release commit message の手書きで、直近 2 リリースで守られていない | 低 | **修正**（Info.plist に revision を刻む） |
| 4.8-F4 | ci.yml に `permissions:` block が無い | 部分的 | 実効権限は repository 設定の read で git に残らない | 低 | **修正**（宣言を追加） |
| 4.9-B | sandbox 無しは記録された意図的判断ではない | 部分的（反証で低へ） | 判断の記録自体が成果物 | 低 | 文書化 |
| 4.10-D / E / G | オフスクリーン webview に外部遮断の `WKContentRuleList` が無い / 画面リーダーでは rule list の追加が初回 load より後 / autoplay 対策が無い | 正しい | **実装は `../Washi` 側**。cooViewer では直せない | 低 | 文書化（Washi 側の修正案を記録） |
| 4.10-C / J / K | EPUB の資源が外部ネットワークに出られる / コンテナ外のローカルファイルを読める / CSP の付かない応答がある | **誤り** | CSP は 7 directive で subresource を全方向塞ぎ、遷移は `washi-epub` 以外を拒否。`FolderContainerReader.read` は `isSafeContainerRelativePath` で検査。応答はすべて `EPUBSchemeHandler.reply` を通る | — | — |
| 4.2-F4 | `enumerateEntries` が init 内で同期実行されるので開く操作でメインスレッドが固まる | **誤り** | `ArchiveSource.init` の呼出は 2 箇所で、どちらも非 MainActor 文脈 | — | — |
| CV41-4 | password を入れずに本を開くだけで鍵導出が走る | **到達不能** | cooViewer は `ReaderOptions.passwordProvider` を設定しない。自動導出は vault / `knownPasswords` 経路のみ（CV41-1 が本体） | — | — |
| C46-2 / C46-3 / C46-4 | decoded-state の解放条件を永久に満たさなくできる / 2,000 冊で EMFILE に再到達する / 先読みで次々と本が開く | **誤り / 到達不能** | 3 条件はすべて有界経路で戻る。安全ローカルの zip/7z は mmap 入口で FD を持たず、file 入口は `.bounded`。`preparedNextBook` は単一 optional | — | — |
| F3 / F4 / F5 / F11 | 自前 parser の境界検査漏れ（MAG header / displayPixelCap を nil にできる / `Book.swift:346` の cap 無し decode / MAKI・Pi・PIC・P4 の抜け） | **誤り / 到達不能** | `parseMagHeader` は `d.count > 40`・`base + 32 <= d.count`・範囲検査を持つ。`displayPixelCap` の設定は範囲 clamp 付き。`fullResolutionImage` の呼出は存在しない | — | — |
| TMP45-1 / TMP45-2 / TMP45-7 | 平文で spool を始めた本が後から sensitive になる / sweeper が生きた spool を消す / temp 名に `..` を入れられる | **誤り / 到達不能** | `spoolEncrypted` は `isEncrypted() \|\| password != nil \|\| contentIsSensitive` で決まる。掃除対象の名前は 3 種すべて先頭が pid。`lastPathComponent` が区切りを落とす | — | — |
| 4.9-G / 4.9-H / 4.9-I | `ENABLE_USER_SCRIPT_SANDBOXING = NO` が App Sandbox 無効の証拠 / Debug に TSan dylib が同梱 / entitlement が空で機能が壊れる | **誤り / 到達不能** | 前者はビルド時の run-script sandbox。TSan dylib は Debug の残骸で Release には無い。JS は別 process で走るので `cs.allow-jit` は不要 | — | — |

低重大度で修正するもの（反証を通過）: 4.4-F1 / F6 / F10（警告文・password ダイアログ・読めない巻の marker への**行注入**）、
4.4-F3（ネスト temp 名の長さで ENAMETOOLONG）、4.4-F8（ComicInfo の章件数に上限が無く PDF 側と非対称）、
4.4-F12（log の `privacy: .public` に絶対 path と entry path が乗る）、F2（HDR gain-map の検査順）、
F9（retro decode の入力全量複写）。

## 2. 実証した事実

### 2.1 Sparkle の鍵一致と署名（keychain に触らずに検証）

`Info.plist:8` の feed は `https://raw.githubusercontent.com/shunnag/cooViewer/master/appcast.xml`、
`:10` の `SUPublicEDKey` は `Uv/vfCACTENgdAolafjMCY9fDZO6VOex/GM1sa5vCks=`。appcast の 48 item すべてに
`length` と `sparkle:edSignature` がある。3 版を download して独立に検証した（検証器は CryptoKit の
`Curve25519.Signing.PublicKey.isValidSignature` だけを使う 20 行の swift script。`generate_keys` は
login keychain の dialog が出るため**実行していない**）。

```
== 2.0b49: declared=9032973 actual=9032973   SIGNATURE VALID
== 2.0b25: declared=6679951 actual=6679951   SIGNATURE VALID
== 2.0b2:  declared=4193436 actual=4193436   SIGNATURE VALID
```

公開鍵と実際の署名鍵は対応している。**downgrade は Sparkle 自身が防ぐ**（SPK-3。installer が展開後の
実物の bundle 版を host と比較する）。したがって master に書ける攻撃者ができるのは metadata と
release notes の参照先の操作で、**任意コードの配布と downgrade はできない**。

### 2.2 KaitoKit 0.17.0 候補の予算の挙動（orchestrator が release build で実測）

| 条件 | 結果 |
|---|---|
| cyclesPower 19・salt が folder ごとに異なる 600 folder・同一 password | **entry 512 でちょうど打ち止め**（`16×2^24 / 2^19 = 512`）= 予算は entry をまたいで積算される |
| 使い切った後に**同じ** password を再設定 | 戻らない（`limitExceeded` のまま） |
| 使い切った後に**別** password を設定 | 戻る（読取成功） |
| cyclesPower 24・同一 reader に毎回違う password ×8 | 8/8 成功（旧既定では 5 回目で失敗した） |

### 2.3 1 冊で開く reader の数（CV41-1 の実効倍率）

`Σ_{ArchiveSource} (1 + E + S + D)`、`E ≤ 6`（`ArchiveSource.swift:265-270` の extractor pool）、
`S` = spool 開始回数（`:1542`）、`D` = decoded-state 解放回数（`:1736`、`:1907` → `ArchiveEngine.swift:356-363` の `reopen()`）。
`ArchiveSource` の数は `1 + K₁ + Σ K₂`（K は攻撃者が選ぶ。深さは `:632` の 2 階層、個数の縛りは `:622` の 1M と
`:957` の 2 GiB/child だけ）。nest 無しの単一書庫でも 16 core 機で最低 8 個、nest ありは ×(1+K)。

## 3. 修正（本記録の時点。commit はしていない）

1. **CV41-1**: `NestedUnlocker` に自動試行（vault + `knownPasswords`）の連続全敗回数の上限を持たせ、
   超えたら以後の child では自動試行をやめる。全巻が同じ password の正規コレクションは「連続全敗」にならない。
2. **4.2-F1 / C46-5**: `writeNestedTemp` の前に空き容量判定（既存の `SpacePolicy` 相当。純関数として
   テストから注入可能な形）と本ごとの累計上限を入れ、child の open が失敗したら temp を unlink する。
3. **4.2-F2**: ネスト候補の件数に上限（1,024）を入れ、切り捨てた分を既存の `excludedCount` に加算して
   「欠落冊数を明記する」UI に乗せる。`openBook` の Task を `windowWillClose` で cancel する。
4. **F1 / F9（画像）**: `renderRGB` に出力 byte 数の上限（256 MiB）を、`decode` に入力サイズの上限（64 MiB）を足す。
   F6（原寸表示・ルーペの保持）も同時に解消する。
5. **F2（画像）**: HDR gain-map 分岐の前に宣言寸法を見て、8192 超なら full HDR decode を飛ばす。
6. **4.4-F7**: ComicInfo の値を 2,000 文字で切り、`FileInfoView` に `lineLimit` を入れる。
7. **4.4-F1 / F6 / F10**: `EntryNameFormatter.forDisplay(_:)` を 1 つ作り、警告文・password ダイアログ・
   読めない巻の marker で使う（改行と行区切りを空白へ畳み、長さを切る）。**bidi の処理は入れない**（第 5 節）。
8. **4.4-F3**: ネスト temp 名の最終成分を 200 文字で切る。
9. **4.4-F8**: `chapterMarks` を 5,000 件で打ち切る（PDF 側 `ComicInfo+PDF.swift:34` と同じ上限）。
10. **4.4-F12**: path を含む log の `privacy: .public` を外す（engine 名は `.public` のまま）。
11. **CV41-3**: `limitExceeded` を「password が違う」に分類しないよう `classifyProbeFailure` を直し、
    `PasswordCheckTests` の期待値を新しい意味に合わせる（`truncated` / `checksumMismatch` を `.rejected` に
    留める既存の判断には触らない）。
12. **4.8-F1 / F7**: `Scripts/build-kaitokit-framework.sh` と `build-washi-framework.sh` で
    `git describe --tags --always --dirty` を framework の Info.plist に刻む（stamp の最終行は fingerprint のまま保つ）。
13. **4.8-F4**: `ci.yml` に top-level の `permissions: contents: read` を足す。

いずれも**修正前に失敗する**回帰テストを添えた（5・8・10・12・13 を除く）。

## 4. 利用者の裁定が必要なもの

1. **master の branch protection が無い**（SPK-1 の前提として実測で確認）。appcast.xml は master へ直接 push される
   運用なので、repo に書ける者が更新 feed を書き換えられる。**任意コードの配布と downgrade は Sparkle が防ぐ**が、
   release notes の参照先（SPK-5）と `minimumSystemVersion` などの metadata は操作できる。
   選択肢: (a) master に branch protection / ruleset を設定する（GitHub の設定だけで済む。推奨）、
   (b) Sparkle 2.10 の feed 署名を使う（`Scripts/make-appcast.sh` に `sign_update appcast.xml` を足す。
   login keychain の秘密鍵を使うのでリリース手順が変わる）、(c) 現状維持。
   **この検査では appcast.xml と master に触っていない。**
2. **Sparkle 2.10.0 → 2.10.1** の pin 更新（`Scripts/fetch-sparkle.sh:10-11`）。script が SHA-256 を検証するので
   間違えればビルドが止まる（安全側）。リリース作業の一部として行うのが自然。
3. **GitHub Actions の SHA pin**（KaitoKit の T2 と同じ 1 つの決定。3 プロジェクトで揃える）。

## 5. 文書化した事実（コード変更なし）

`Documentation/architecture.md` と `Documentation/development-guide.md` に記録した。

- KaitoKit 0.17.0 候補の鍵導出予算は **reader と password の組ごと**で、`reopen()` / `open()` は満額で始まる。
  cooViewer は 1 冊で reader を複数持ち、decoded-state の追い出しとページ送りで何度でも満額に戻るので、
  **1 冊あたりの総鍵導出量は KaitoKit 側では縛れない**（C46-6）。1 回あたりは有限。
- サイズを宣言しない entry では 2 GiB guard（`:1086-1092`、`:914-919`）が迂回され、最終的な上限は KaitoKit の
  `maxInMemorySize`（既定 1 GiB）になる（4.2-F3）。
- 機微な親の下では全ネスト子の展開済みバイトが本の寿命まで常駐し、常駐総量に上限が無い（4.2-F8。修正 2 で緩和）。
- `architecture.md:129` の「終了時削除 + 起動時掃除」は実際と違う（source 解放時に削除 + 起動時掃除）。
- sandbox 無しの代償: 信頼できない byte が ImageIO/AppKit・自前 retro parser・WebKit の 3 系統に in-process で届く（4.9-B）。
- **オフスクリーンの webview には外部ネットワーク遮断の `WKContentRuleList` が無く**、画面リーダーでも
  rule list の追加が初回 load より後になる競合窓がある。実装は `../Washi` 側なので cooViewer では直さない（4.10-D / E / G）。
- 書庫由来の名前の **bidi 制御文字（U+202A-202E / U+2066-2069）は加工していない**（修正 7 は改行と長さだけ）。
  cooViewer には entry を実行・起動する経路が無いので実害は表示の偽装に限られる。`EPUBTitleFormatter` が
  EPUB 題名にだけ isolate を足している非対称も記録した（4.4-F4 / F5 / F9）。
- `make-appcast.sh` は zip と appcast の版表示を照合しない（SPK-7）。

## 6. KaitoKit 0.17.0 の 4 変更に対する影響（必須の横断チェック）

| 変更 | 影響 | 根拠 |
|---|---|---|
| `maxSevenZipEntryKDFWork`（既定 `16 × 2^24`、reader × password 単位） | **影響あり** | 旧既定 `4 × 2^24` では nested / コレクションで `knownPasswords` が 2 件以上あると正規利用者が 3 回目で弾かれた（CV41-2）。新しい既定と意味論で解消。多重化（CV41-1）は host 側で縛る |
| `maxStuffItXKDFWork`（既定 `2^22`） | **影響あり** | `.sitx` / `.sit` / `.sea` / `.hqx` が対応形式。v0.16.0 には予算が無い |
| `ExtractionOptions.preserveSetUserIDBits` | **無関係** | `ExtractionOptions` / `preserveSetUserID` / `resourceFork` が grep で 0 件。KaitoKit の展開器を使わず memory へ stream して自前の temp を自前の mode で書く |
| resource fork entry の metadata | **無関係** | 同上 |

依存の形: `Frameworks/` は gitignore され、`Scripts/build-kaitokit-framework.sh` がビルド時に
`${KAITOKIT_SOURCE_DIR:-../KaitoKit}` から再ビルドする。**版の pin は無い**（修正 12 で revision を刻む）。

## 7. 検査の限界

- エージェントはビルド・計測・GUI 駆動を禁止されていたので、所見は「コード読解で確定」か「要実測」である。
  実測したのは第 2 節（orchestrator が実行）と、エージェントが read-only で行った `gh api` / `plutil` / `strings` / `openssl`。
- **GUI では駆動していない。** ⌘I の固着（4.4-F7）、警告文の行注入の実描画（4.4-F1 / F6 / F10）、
  48 byte の MAG での 1 GiB 確保（F1）は、いずれも unit test か算術で固定した。
- **出荷済み 2.0b49 が敵対的 `.sitx` で固まるかは未実証**（CV41-5）。既存の 225 byte fixture（catalog 暗号）では
  `passwordRequired` で open が失敗して固まらない。固まるのは stream 暗号の変種で、その fixture を作っていない。
  7z 経路（v0.16.0 に entry 予算が無い）は固まることが KaitoKit 側の実測で確定している。
- `../Washi` の webview 設定（4.10）は読んだが修正していない。Washi 側の検査は本検査の範囲外。
- xcodebuild の全 suite は orchestrator が実行した（結果は本記録の末尾に追記する）。

## 8. 追記（2026-10-28、後続作業）

### 8.1 監査時の全 suite の結果

監査時の全 suite の結果は本記録に追記されていなかった。数字は eceac38 の commit message と、2.0b51 の 9ec1db2 に
「1,241 tests / 2 skipped / 0 failures」として残っている（KaitoKit v0.17.0 / Washi 1.25.0）。
本節はその再掲であり、監査時の実行を本記録で新たに証明するものではない。

### 8.2 CV41-5 の実測（第 7 節の未実証を解消）

M4 Max で、KaitoKit **v0.16.0**（2.0b49 が同梱した版。2.0b49 の release notes で確認）の一時 worktree に、
0.17.0 の `StuffItXKDFWorkTests` と同じ形の書庫を作る試験を足し、release build（`-enable-testing`）で
別 thread の処理を 120 s 待った。

| 書庫 | 大きさ | 操作 | v0.16.0 |
|---|---|---|---|
| entry 鍵の変種（algorithm 64 段 × 1,024） | 215 byte | password 付きで open し、entry を read | 120 s で**戻らない** |
| catalog 暗号の変種（鍵長 65,536） | 192 byte | password 付きで open | 120 s で**戻らない** |

v0.16.0 には StuffIt X の鍵導出予算も、導出中の取消し検査も無いので、CPU を占有したまま戻らない。
v0.17.0 では、同じ形が `limitExceeded("StuffIt X KDF work")` で導出前に拒否される
（`testMaximumAcceptedKeyLengthIsRejectedBeforeDerivation` / `testMaximumEntryKeyListsWithoutDerivingAndFailsOnRead`）。
2.0b49 で到達するには password が必要で、入れ子の既知 password・vault・利用者の入力のどれでも届く。
結論として、**2.0b49 は stream 暗号の変種の `.sitx` で固まる**。2.0b50 以降（KaitoKit v0.17.0）では解消している。

### 8.3 4.2-F3 の再評価

サイズを宣言しない entry は 2 GiB の guard（`exceedsPerPageDecodeLimit`）を通る。ただしページの展開も入れ子の読み出しも
`ArchiveEngine.readContents` → `readAll` を通り、`readAll` はサイズ不明でも累計が `maxInMemorySize`（既定 1 GiB）を
超えた時点で `limitExceeded` を投げる（`ArchiveEngine.swift` の `readAll`）。2 GiB guard より厳しい上限が既にかかって
いるので、変更は不要と判断した（cooViewer-hzvo）。

### 8.4 文書化だけで終えた項目の後続

| 項目 | 対応 | bead |
|---|---|---|
| §4-1 branch protection | 利用者が 5 repo に ruleset を設定した（cooViewer は削除と non-fast-forward の禁止、PR 必須、CI 2 job 必須） | cooViewer-8iq0 |
| 4.4-F4 / F5 / F9 bidi | `EntryNameFormatter` が U+202A–202E / U+2066–2069 を除き、強い RTL を含む名前を FSI/PDI で囲む | cooViewer-sq2t |
| SPK-7 | `make-appcast.sh` が zip の名前と、zip 内のアプリの版・build 番号を照合する | cooViewer-il5y |
| 4.8-F7 の残り | 両 framework の `CFBundleShortVersionString` を最近傍タグから導出する | cooViewer-vz3k |
| 版の pin（第 6 節） | CI が KaitoKit / Washi を `KAITOKIT_REF` / `WASHI_REF` の版で取得する。ローカルと共有する単一の正はまだ無い | cooViewer-cjr9 |
| 4.10-D / E | Washi 側で、画面上と画面外の webview の初回 navigation より前に rule list を登録する修正を用意した（Washi-rmg、未取り込み） | Washi-rmg |
| C46-6 | 受け入れたまま。KaitoKit の `reopen()` が導出済み鍵を引き継ぐ案を記録した | cooViewer-44e8 |

### 8.5 後続修正の検証

branch `fix/audit-followups-2026-10-28` で、Debug の xcodebuild の全 suite を orchestrator が実行した:
**1,255 tests / 2 skipped / 0 failures**（KaitoKit v0.17.0 / Washi 1.25.0）。追加した試験 15 件はすべて実行され、成功した。
