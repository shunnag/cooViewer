# 大量書庫閲覧時の Core Image クラッシュ調査・修正

2.0b46 のクラッシュ直前にファイル記述子の枯渇が起きていた。記述子を使い切った後に初めて Core Image を初期化すると、標準 Metal ライブラリの読み込みに失敗し、元報告と同じ関数の +1136、同じ NULL＋0x28 へのアクセスで SIGSEGV になる。業務ファイルを使わない合成画像でこの経路を再現した。

合本が書庫を全冊開いたまま保持する構造から記述子の枯渇と正常ページの欠落も再現でき、アプリ側の無制限な保持と、Core Image 内部の初期化失敗処理の連鎖を確認した。同じ資源不足から MetalFX の別の例外も再現した。クラッシュ時の全実行状態が保存されているわけではないが、元報告の同一プロセスの EMFILE と、再現の例外・ライブラリ UUID・関数・オフセット・障害アドレスが一致する。

初期調査は実装を変更せず、合成画像・合成 ZIP・OS 同梱色プロファイルで行った。その後、cooViewer・KaitoKit・KaitoFinder・Washi・GyoshukuKitへ以下の修正を実装した。業務ファイルは使用していない。記録には実ファイル名・実フォルダパスを含めず、ローカルのシステムログからは時刻と件数だけを採り、調査用の生ログコピーは削除した。

## 対象と検証環境

- macOS 27.2、26B118、Apple M4 Max、Swift 6.4、最適化プローブは `-O`。
- 修正前の比較基準は `fe9f8d2`。`v2.0b46` との差分は appcast のみ。
- インストール済みアプリの UUID は報告と一致する `985EB3AF-6ED5-36E9-ADC9-8C74A5BACDE6`。
- 修正前の KaitoKit のインストール済み・検証用 framework とも、報告と同じ UUID `C3211A88-E359-35B8-9E59-605509A50F1F`。
- `launchctl limit maxfiles` は soft 256、hard unlimited。クラッシュレポートには当該プロセス自身の limit はないが、アプリに上限変更処理はない。再現試験は独立プロセスまたは専用テストホスト内の soft limit のみを 256 にした。
- アプリのビルド先・テストホームは一時領域に分離。XCTest は `EnvironmentVariables.CFFIXED_USER_HOME` をテストターゲットへ指定し、同時テストを無効にした。

## クラッシュ時の確定事項

| 時刻 | 同一プロセスでの出来事 |
|---|---|
| 11:32:15.1336 | アプリ起動 |
| 11:33:08.965 | `Too many open files`、errno 24 を記録 |
| 11:33:08.968 以降 | SQLite・ネットワーク設定など複数系統のファイルオープンが同じ理由で失敗 |
| 11:33:48.995〜48.996 | Core Image の非公開メッセージ6件。内容は `<private>` で原因の特定には使えない |
| 11:33:50.5931 | CI 内部キューで NULL 近傍 `0x28` への書き込みにより SIGSEGV |

該当時間帯には書庫 open 失敗564件、明示的な `Too many open files` メッセージ9件があった。564件全部が EMFILE だったとは断定できない。書庫 open の実装が詳細エラーを消しており、破損・非対応・資源不足が同じメッセージになるためである。

Thread 11 は [LanczosDownscaler.swift](../../CooViewer/Core/Rendering/LanczosDownscaler.swift) の `CIContext.render` でシェーダー生成完了を待っていた。Thread 3・14・17 は CI 内部のコンパイルキュー。Thread 7・9・12・15 は書庫スプールを実行中だった。スプールは **4本**であり、CI のキュー3本と混同しない。

`KaitoKit` の `pread` が他スレッドに存在することだけでは書庫デコーダのメモリ破壊を示さない。同様に VM の大きな Guard 領域は実 RAM 消費ではなく、今回のレポートはメモリ不足の証明にはならない。

## 元報告と同じ Core Image クラッシュの再現

現行 Lanczos を独立プローブへ `-O` でリンクした。2048×1536 の単色 sRGB 画像をメモリに作り、プローブ自身の soft limit を256にし、`/dev/null` を open して EMFILE になるまで記述子を消費する。**他の描画器からも CIContext を先行生成しない**状態で初めて `LanczosDownscaler` を作り、978×341へ縮小した。

Core Image は `ci_stdlib`、`ci_filters`、`ci_raw` および stitchable 版の Metal ライブラリを読み込めないと記録し、その直後に SIGSEGV となった。

| 照合項目 | 元報告 | 合成画像の再現 |
|---|---|---|
| 例外 | EXC_BAD_ACCESS / SIGSEGV | 同じ |
| 障害アドレス | 0x28 | 同じ |
| 関数 | CI::ProgramNode::create_program_and_arguments の block | 同じ |
| 関数内オフセット | +1136 | 同じ |
| CoreImage imageOffset | 3211776 | 同じ |
| CoreImage UUID | f87ba1ec-adf3-31c4-b443-b67a9ba9d2f8 | 同じ |
| x8 | 0 | 同じ |
| 内部キュー | CI::MainProgramArgsQ-3 | CI::MainProgramArgsQ-2 |

内部キューの番号以外は一致し、別プロセス・別の一時ホームでも同じ例外を2回再現した。同じ条件で16個の記述子を閉じて余裕を戻してから CIContext を生成すると、縮小は正常完了し、中央画素は RGBA 204, 51, 26, 255 だった。元の業務画像や壊れた書庫がなくても、資源不足だけで同じクラッシュを起こせる。匿名化した照合値は [再現証拠 JSON](2026-10-20-coreimage-resource-evidence.json) に保持する。

先行試験の `late` 条件では、Lanczos 自体は遅延生成していても MetalFX のコンストラクタが先に CIContext を作っており、再現を隠していた。この先行初期化も取り除いてから同一例外が再現した。単に「CIContext は actor 内だから安全」「通常の縮小が数千回通る」という検査ではこの条件を見落とす。

## 合本の保持数と正常なページの欠落

[NestedFolderSource.swift](../../CooViewer/Core/Source/NestedFolderSource.swift) は構築時の並列数を4に制限する一方、完了した子を `prepared`、その後 `children` にすべて強参照する。未表示の書庫も閉じないため、file 入口で開いた reader の FD 使用量は冊数に比例する。

出荷版 KaitoKit の直接試験では、初期 FD 3から ZIP reader を252個保持すると FD 255となり、次の `ArchiveReader.open(url:)` は `KaitoError.io(24)` で失敗した。親ディレクトリを一時的に開く必要もあるため、最後の1個が空いていても次の reader を開けない。全 reader を解放すると FD 3へ戻った。Data 入口では500 reader を保持しても FD 3のままだった。

実際の `NestedFolderSource` でも、各 ZIP に JPEG 1枚、画像から作った1ページ PDF、指示メモを入れた正常な300冊で比較した。メモはページ数に含まれず、期待値は600ページである。

| 経路 | 初期 FD | 保持中 FD | ページ数 | 資源回復後の再照会 |
|---|---:|---:|---:|---:|
| 安全なローカル mmap、通常 factory | 6 | 7 | 600 / 600 | 600 |
| file 入口へ誘導した factory | 7 | 255 | 491 / 600 | 491 |

file 入口の試験は、ローカル合成 ZIP に対する `openData` を nil にし、既存の mmap→file 再試行を通している。NAS・外付けに実アクセスする試験ではない。JPEG 試験より前の PNG 版でも489・490ページへの欠落を確認した。並行順序により、外側画像だけ取り込まれた子が生じることもあるため、欠落後の正確なページ数は一定ではない。

ソースを解放すると弱参照は nil になり、FD は9まで低下した。直接 reader 試験は初期値まで戻っており、中心問題は全冊の無制限な常駐保持である。XCTest 内の差分2 FDの用途は特定していない。

欠落が固定される経路は次のとおり。

1. [ArchiveEngine.swift](../../CooViewer/Core/Source/ArchiveEngine.swift) の `KaitoKitEngine.init(file:)` が `try? ArchiveReader.open` で EMFILE を nil にする。
2. `ArchiveSource` は汎用の unreadable にし、`NestedFolderSource.prepareChild` の `try?` がその子を除外する。
3. `buildTask` は欠けたページ列を成功結果として保持する。FD の余裕を戻して `entries()` を再度呼んでも再構築されない。

正常な図面を画面上から欠落させる問題であり、元ファイルを削除する現象ではない。並列幅を4から1に下げても全冊保持は変わらず、上限の引き上げだけでも冊数に比例する問題は残る。

## MetalFX の関連クラッシュ

現行 [MetalFXUpscaler.swift](../../CooViewer/Core/Rendering/MetalFXUpscaler.swift) を独立プローブへそのままリンクし、合成 sRGB 画像 2048×1536 を2500×2000へ拡大した。

| 条件 | 結果 |
|---|---|
| プローブ内で FD を256上限まで消費、空き0 | `makeSpatialScaler` 内で `NSURL initFileURLWithPath:nil`、`NSInvalidArgumentException`、SIGABRT、exit 134 |
| 同じ枯渇状態から FD を16個閉じて空きを戻す | 正常完了。中央画素 RGBA = 204, 51, 26, 255 |

これは元報告の CI SIGSEGV と別の再現済みクラッシュである。`makeSpatialScaler` の optional を検査するコードや Swift の `try?` では、内部の Objective-C 例外を回復できない。資源の余裕を確保し、新規 GPU 処理を始める前に枯渇状態を避ける必要がある。

## 画像処理の類似経路

| 対象 | 調査結果 | 元報告との関係 |
|---|---|---|
| Lanczos の並行実行 | 本番では `ImageResampler` actor 内の同期処理。フィルタは呼び出しごとに新規生成。共有 mutable CIFilter の競合は確認できない | CI 内部キューが複数あることはアプリ側競合の証拠にならない |
| CI 入出力の寿命 | 入力は CIImage グラフに保持、出力は同期 render 後に CGDataProvider へ所有権移譲。解放コールバックと失敗時の解放を確認 | この経路の use-after-free・二重解放は未発見 |
| 通常寸法と極端な縦横比 | sRGB・Display P3・グレー、12形状、50倍率、等方・異方の計3600要求がプロセス終了なしで完走。等倍での nil も検査に含む | 特定の通常倍率だけで落ちる再現は得られない |
| FD 枯渇時の Lanczos | CIContext先行生成ありの sRGB・CMYK・OS同梱 ROMM RGB ICC は完走。先行生成を完全に避けると元と同じ SIGSEGV | 初期化順が再現の分岐点 |
| FD 枯渇時のノイズ低減 | CIContext先行生成ありでは完走。先行生成なしでは Lanczos と同じ +1136 / 0x28 / UUID で SIGSEGV | 同じ初期化失敗がノイズ低減にも及ぶ |
| CI 描画の失敗処理 | Lanczos・NoiseReducer・MetalFX の3経路で Void の `render(toBitmap:)` を使い、未初期化バッファへ描画後、成否を確認せず CGImage にする | 失敗時に無描画のバッファを返す危険があるが、その実被害は未再現 |
| Metal コマンドの失敗処理 | `encodePass` が `waitUntilCompleted()` の後に `.status` / `.error` を確認しない | 失敗したテクスチャを後段へ渡す可能性。失敗注入は未実施 |
| 不正な寸法 | Lanczos に NaN、MetalFX に Infinity を渡すと `Int` 変換で SIGTRAP、各 exit 133 | 元の SIGSEGV とは別。通常 UI からの到達経路は未確認 |
| リサンプル入口 | `ImageResampler.resample` と `cached` にも、guard より前の同型の無検証 `Int` 変換がある | 呼び出し前に有限性・範囲を保証する必要がある |

3600要求の試験は主として寸法と生存の検査であり、全画像の画素一致や全 ICC プロファイルを網羅する試験ではない。8bit CGContext を作れない extended-linear RGB 条件はスキップした。通常の色・向き・透明度は既存の描画テストでも確認している。

Apple は CIContext と CIImage を共有可能とし、mutable CIFilter はスレッド間共有を避けるよう説明している。[Core Image Programming Guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_objects/ci_objects.html)

描画の開始・完了エラーの扱いには `CIRenderDestination` と throwing の `CIRenderTask.waitUntilCompleted()` を検討できる。ただし、内部 SIGSEGV や NSException を Swift のエラーとして捕捉できるという意味ではない。[CIRenderTask](https://developer.apple.com/documentation/coreimage/cirendertask)

## GPU長辺上限による追加のクラッシュ

最終の寸法監査で、M4 Max上の16,384×2画素の入力を32,768×4画素へ拡大すると、512 KiBの小さな出力にもかかわらず、MetalFX内のtexture descriptor検証でSIGABRT（終了134）になることを再現した。NaNや総byte数の検査では防げない別の境界である。

入力・出力双方の長辺を、GPU familyに対応する上限でtexture loader／scaler生成前に検査する。Apple10は32,768、それ以外の対応するMacの経路は16,384を使い、対応外形状はCGへ戻してキャッシュを許す。上限の根拠は[Apple Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)の2D texture寸法表（2026-05-21版）。修正後は同じプローブが終了0でnilを返した。CPU代替のサイズと同一キーの再利用、入力・出力の縦横両方の超過は回帰テストで確認した（`cooViewer-qr73.11`）。

## CMYK・グレースケール入力の描画失敗

図面のスキャンに多い非RGB入力も確認した。CMYK入力では、FDに64本の余裕があっても解放後でもMetalFXがnilを返した。RGBへ正規化してからtextureへ渡している一方、CIImageと出力に元のCMYK色空間を指定していた。これを正規化後のRGB色空間へ直し、同じ合成入力で2500×2000のGPU描画に成功した。Grayも合わせてCoreGraphicsのRGB変換結果との色差を検査した（`cooViewer-qr73.12`）。

この件の修正前プローブは、回復後のnon-nilを要求する診断自身のassertionで停止した。アプリ本体がCMYK入力で同じクラッシュを起こしたという証拠ではない。アプリではCPU代替へ落ちるが、一時失敗扱いでその結果をキャッシュせず再計算し続ける性能上の問題だった。

## 修正前の書庫処理で横展開した確認

- [ArchiveSource.swift](../../CooViewer/Core/Source/ArchiveSource.swift) の `children` もネストした子をすべて保持し、子の open 失敗をスキップして構築結果を固定する。同じ問題がフォルダ合本以外にも及ぶ構造を確認した。大量のネスト子による独立した FD 枯渇再現は行っていない。
- 展開係は各書庫最大6個まで追加の reader を開く。上限は書庫単位であり、アプリ全体の FD 上限ではない。
- `NestedFolderSource.beginBackgroundPreparation` は全書庫のスプールを開始する。総スプールバイトは子の数で割るが、実行並列数・作業メモリには全体 gate がない。元報告でも4本が実行中だった。これによる全体メモリ枯渇は今回再現していない。
- サムネイル生成には全体の4並列 gate があるが、既に保持済みの書庫 reader は解放しない。先読み・ページキャッシュのメモリ予算も FD の余裕を管理しない。
- KaitoKit `FileByteSource` の通常破棄・初期化失敗時の close を確認し、直接 reader の解放試験も通った。file 入口の利用自体を誤りとしたり、ネットワークの書庫を無条件で mmap に変えたりする対処は不適切。

## 実装した修正

Beads の親は `cooViewer-qr73`。業務ファイル・実フォルダの開示は不要で、検証に使用していない。

| 対象 | 修正と性能上の判断 |
|---|---|
| KaitoKit | `ReaderOptions.fileAccessPolicy = .bounded` を追加。未使用の入力 FD をプロセス共通 LRU の最大64枠・soft limitの1/4（最低1枠）で保持する。解析情報やsolid状態をFDの追い出しだけで捨てない。再open時はdevice/inode/種類/サイズ/更新時刻を検証し、差替や変更はESTALEで拒否する。使用中FDをpinし、open/fstat/pread/closeは全体ロック外。全枠使用中は待ち続けずI/Oエラーを返す。従来の公開initializerとdefault `.persistent` のunlink/rename後の読込契約は維持した |
| cooViewer・KaitoFinder | 通常の書庫読込でbounded方針を選ぶ。KaitoFinderの編集用GyoshukuKit snapshotは別の所有FDを使う契約を保つ |
| cooViewer合本 | open/内容読込/一時書出しのI/Oと取消を保持して伝え、部分的な合本を成功キャッシュに固定しない。同じソースで失敗後に再構築でき、旧世代の失敗が新しい構築を消さない |
| cooViewer描画 | 初期化・描画前に16 FDの空きを確認。主因のFD予算と組み合わせる安全弁であり、確認単独で他のopenとの競合を防ぐ保証ではない。CIRenderDestinationの開始と完了を検査し、Metal command bufferの完了状態も確認する。バッファをゼロ初期化し、描画完了まで所有者を保持、成功後にCGDataProviderへ所有権を渡す |
| cooViewerキャッシュ | 非有限・変換不能・桁溢れ・過大な出力を確保前に拒否。一時的なノイズ低減失敗で原画を「処理済み」として保存せず、一時MetalFX失敗のCG代替も回復後に再計算する。nilだった描画器も次回に再初期化する。恒久的な対応外GPUの代替はキャッシュできる |
| cooViewer復号資源 | 全体の実行中スプールは4冊まで。完了時は主readerの復号状態を破棄し、全ページがスプール済みなら待機中の展開係も解放する。スプール対象外の本も、最近使った1〜16冊にだけアイドル復号状態を保持する（8 GiBごとに1冊、上限16）。使用中の係・構築中・実行中スプールは追い出さない。解析済みページ一覧は維持する。展開係の一時I/O失敗で増設を恒久停止しない |
| Washi | CGContext.dataの走査までcontextを保持。スナップショット寸法をWebKit/Int変換/割当前に検証し、画面合成とFXLの出力予算を256 MiB以内へ制限する。展開済みEPUBのOS I/O失敗をresourceNotFoundへ変換せず、mimetype・encryption・nav・NCX・display-optionsのI/O失敗を空値として固定しない。欠落・破損した任意メタデータへの既存の寛容性は保つ |
| GyoshukuKit | 7zの再圧縮・暗号化変換folderごとのunlink済みscratchを、worksetあたり各1本の共有scratchとfolderごとの範囲へ変更。出力範囲と統計はfolder別に保ち、共有ファイルのコピー時間は重複計上しない。出力・snapshotの所有権やunlink後のFD保持は保つ |

復号資源の制限は冊数・並列数に対する制限であり、全codecの辞書・作業領域を合算した厳密なbyte上限ではない。各readerの既存ReadLimitsと復号予算も引き続き適用する。通常のファイル読込をmmapへ強制したり、プロセスのFD上限を引き上げる対処にはしていない。

## 修正後の再現・回復確認

- JPEG 1枚・スキャン相当の1ページPDF・指示メモを入れた300冊で、file経路も600/600ページとなり、再照会のIDとページ数も保たれた。初期7 FD、保持中71 FD。単独実行の解放後7、全体テスト内の解放後11で、ソースの弱参照はnil。全体実行の差分4の用途は特定していない。
- cold CI縮小・coldノイズ低減・MetalFXを残りFD 0で実行しても終了0でnilを返す。FDを解放すると同じプロセスで978×341、2048×1536、2500×2000の描画に回復する。残り32 FDの各対照は実描画まで成功した。
- NaN縮小・Infinity拡大も終了0。CPU代替を含むキャッシュの失敗→回復を別途障害注入で検証した。
- 通常の縮小1,800要求、縦横別倍率の縮小1,800要求、ノイズ低減36要求が成功。sRGB・Display P3・Gray、極端な縦横比、小画像を含む。作成できない8bit extended-linear RGB CGContextは従来どおり除外し、全ICCの網羅は主張しない。
- KaitoKitは400 reader保持、分割ZIP/7z/RARの解放後再読込、差替拒否、並列readと追い出し、低速open/closeが他のreaderを塞がないことを確認した。最終FD・分割巻92テストはAddress Sanitizer付きでも成功。
- Washiの300冊保持はFD増加2以下。実FD枯渇と6種類のメタデータI/O障害から、明示失敗と再openによる回復を確認した。

全体試験の結果と性能値は末尾に記録する。

## 実アプリでの修正前後 A/B

テストホスト(Mac mini M4、macOS 27.2、Xcode 27.0、ヘッドレス)で、修正前 `fe9f8d2` と修正後の作業ツリーを同じ手順で Debug ビルドし、`--open <フォルダ> … --snapshot` で起動した。プロセスの FD soft limit は GUI アプリの既定と同じ 256、ホームは実行ごとの一時ディレクトリ。データは合成のみで、1600×2400 の上下 2 色 PNG(上半分が本ごとの色、下半分が青)を 20 枚ずつ無圧縮 ZIP にした 400 冊。中身は ZIP のまま拡張子を `.cbr` にした組(mmap の対象外となり、NAS・外付けと同じ file 入口を通る)と、`.zip` の組(ローカルでは mmap 入口)を用意した。FD 数は 0.5 秒ごとの `lsof` の数値 FD 行の最大値。

| 条件 | 修正前 | 修正後 |
|---|---|---|
| `.cbr` 400冊・サムネイル一覧 | 約1秒で終了 139。`ci_stdlib` 等の Metal ライブラリ読込失敗の直後 | 終了 0。8000/8000 ページ、上下の向きも正しい |
| `.cbr` 400冊・本送り/ページ送り25往復(約55秒) | 起動直後に終了 139(再現2回目) | 終了 0、最大 82 FD |
| `.zip` 400冊・同じ送り操作(約55秒) | 終了 0 だが最大 255 FD(上限 256 に到達) | 終了 0、最大 82 FD |

修正前のクラッシュレポートは元報告と一致した: `EXC_BAD_ACCESS`/`SIGSEGV`、`KERN_INVALID_ADDRESS at 0x28`、クラッシュしたスレッドは `CI::MainProgramArgsQ-3` 上の `CI::ProgramNode::create_program_and_arguments` の block。CI の完了を待つ協調スレッドのアプリ側フレームは `LanczosDownscaler.downscale` ← `ImageResampler.computeResample` で、元報告の Thread 11 と同じ経路である。業務ファイルなしで、実アプリでも元の現象を再現し、修正後は同じ操作で FD が 82 本に収まることを確認した。

`.zip` の短時間(撮影まで約2秒)の起動は修正前後とも終了 0。ローカルの mmap 入口ではオープン時点では FD を消費せず、閲覧中のスプール・展開係の増加で上限へ達する。元報告が起動から約1分半後だったことと整合する。

追加の安全弁と回帰テスト:

- MetalFX の向きは独立プローブで新旧とも、1段(≤2倍)・多段(>2倍)、premultipliedLast/First の入力で四象限の色が一致した。既存テストに MetalFX の向きの検査がなかったため `ImageResourceSafetyTests.testMetalFXUpscalingPreservesOrientationAndQuadrantColors` を追加した。
- `MLModelInstaller.ensureModel` は CoreML モデルの読込直前に FD の余裕を確認し、不足時は `.failed` にせず nil を返す。一時不足が恒久失敗と記録されて CI 代替結果がキャッシュへ固定されるのを避ける。
- `PDFDocument(url:)` を 300 個保持しても FD 増加は 1 だった。フォルダ直下の PDF は冊数比例の FD 消費源ではない。

## 再現コードと検証結果

[CoreImageResourceProbe.swift](../../Scripts/diagnostics/CoreImageResourceProbe.swift) は本番の Lanczos・NoiseReducer・MetalFX をそのままリンクする。`ImageResampler` のスタブは CG フォールバックだけを実装し、actor の試験には使用していない。ランナーは一時ホームを指定する。

```sh
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh matrix
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh anisotropic
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-scale 0
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-scale-late 0
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-scale-late 32
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-scale 0 cmyk
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-scale 0 icc-romm
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-noise 0
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-noise-late 0
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-noise-late 32
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-metal 0
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh fd-metal 32
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh invalid-lanczos nan
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh invalid-metalfx inf
zsh Scripts/diagnostics/run-coreimage-resource-probe.sh wide-metalfx
```

`fd-scale-late 0`、`fd-noise-late 0`、`fd-metal 0`、`invalid-*` は修正前にクラッシュした境界の独立プロセス試験。修正後のランナーでは安全な失敗と資源解放後の回復を検査する。上限変更はそのプロセス内だけで、OS や他プロセスの上限は変更しない。

[ArchiveReaderFDProbe.swift](../../Scripts/diagnostics/ArchiveReaderFDProbe.swift) は出荷版 framework をリンクして、同一の合成 ZIP に対する file / Data reader の FD 使用量を比較する。引数は `file <合成ZIP>` または `memory <合成ZIP>`。

[ArchiveResourceInvestigationTests.swift](../../Scripts/diagnostics/ArchiveResourceInvestigationTests.swift) は `CooViewerTests` へ一時配置して実行する統合再現。修正前では file 経路の600ページ検査が意図どおり失敗し、mmap 対照は通った。修正後の通常回帰は `ArchiveResourceTests.swift` に常設した。通常のテスト群には失敗する診断を常設しない。

- Debug の専用 build-for-testing 成功。
- Core Imageの完全遅延初期化で元報告と同一 SIGSEGV を Lanczos で2回、ノイズ低減で1回再現。16 FD の余裕を戻した対照は正常。
- JPEG 統合診断2件は、mmap 対照が成功、file 経路が491/600ページで失敗。
- 通常の既存テスト907件、失敗0、スキップ2。診断テストは除外して1本ずつ実行。
- この箇条書きは修正前の調査結果。修正後のソースはローカル変更で、インストール済みアプリ・版番号・業務ファイルは変更していない。コミット・push・Doltリモート同期は行っていない。

## 修正後の性能測定

M4 Max、macOS 27.2、Swift `-O`。業務ファイルを使わず、64 MiBの生成データ、生成した300冊のZIP、生成した画像を使用。旧実装と修正版を交互に3回実行し、I/Oは各実行7周の先頭1周を除いた中央値を採った。描画は各実行のwarmup 10要求を除いたp50の中央値。旧I/Oは配布済みKaitoKitのdylibを一時領域へコピーして実行（UUID照合済み）、旧描画は変更前ソースを同じフラグでコンパイルした。比較用の公開moduleはソース互換の現行interfaceを使い、旧バイナリ自体は変更していない。

| 処理 | 修正前 | 修正後 |
|---|---:|---:|
| 256 KiB単位の2 GiB読込 | 78.09 ms | 78.80 ms |
| 300冊の一覧open | 41.01 ms | 44.07 ms |
| 300冊を5巡（1,500回）の内容再読込 | 8.94 ms | 43.05 ms |
| Lanczos縮小（2048×1536→978×341） | 2.158 ms | 2.148 ms |
| ノイズ低減（2048×1536） | 1.502 ms | 1.516 ms |
| MetalFX拡大（2048×1536→2500×2000） | 4.550 ms | 4.737 ms |

連続I/Oの増加は約0.9%、一覧openは300冊合計で約3.1 ms。全冊再訪はFD再openのため増え、1回あたりの追加は約22.7 µsとなる。解析情報は維持し、FDを追い出しただけで書庫の一覧解析やsolidの復号をやり直す構造にはしていない。一方、復号状態のLRUから外れた本へ戻ると、必要な復号状態を作り直す。最近の本1〜16冊（8 GiBごとに1冊、128 GiB機では16冊）は状態を保ち、冊数に比例した辞書の常駐を防ぐ判断とした。

復号状態LRUの帳簿更新は50,000回で7.66 µs/回。同じ本の連続使用中の状態解放は0回。描画は成功確認の待ちを含め、MetalFXで約0.19 msの増加だった。I/O/描画測定中は他の回帰テストの負荷もあり、数値はこの環境での目安。実NASのopen遅延は測っていない。OS I/Oを全体ロック外へ出す並列試験を行い、1冊の遅い再open/closeが別の本を塞がないことを確認した。

[性能プローブ](../../Scripts/diagnostics/FileAccessPerformanceProbe.swift)と[画像プローブ](../../Scripts/diagnostics/CoreImageResourceProbe.swift)、[集計可能な測定値](2026-10-20-coreimage-resource-evidence.json)を同梱する。

ページキャッシュの成功時insertと、サムネイル失敗記録の既存の5分TTL・4096件上限も確認した。入力/出力FDを同じ保持方針に一括変更せず、GyoshukuKitのunlink済みscratchと編集用snapshotは引き続き所有FDを保持する。

## 修正後の全体検証

| 対象 | 結果 |
|---|---|
| cooViewer | arm64のRelease構成ビルド成功（署名・インストールを行わないビルド検査）。frameworkを現行の兄弟ソースから作り直したDebug全体試験で927件、失敗0、skip2（MetalFXの向きの回帰テストを含む） |
| KaitoKit | 全体の`swift test`で失敗0、skip51。最終キャッシュ最適化・I/O分類変更後の影響92件はAddress Sanitizer付きで再実行し失敗0 |
| Washi | 全体の`swift test`で846件成功、失敗0 |
| KaitoFinder | Mac mini M4で変更適用後の全体1,787件、失敗0、skip33。単一書庫からの分割Save As（`cooViewer-qr73.13`）は変更前後・両機とも成功し再現しない |
| GyoshukuKit | 全体918件、失敗0、skip49 |

先行したメイン機でのKaitoFinder全体実行中、HFS+の生成テストディスクを作るOSのhdiutilが長時間待機した。既知のテスト子プロセスだけにSIGTERMを送り、その後HFS+での編集・保存・整合性・cleanupの検査は324.224秒で成功した。業務ディスクや他プロセスの操作には触れていない。

## 後続: 合本の読込失敗の扱い(feat/open-failure-ux)

クラッシュ修正で「一時的な読込失敗を黙って欠落させず合本を失敗させる」ようにした結果、
ビープと手動の開き直ししか手段がなかった。利用者の決定(2026-10-20)に基づき 3 段階で改善した(beads `cooViewer-lrj7`)。

| 段階 | 内容 |
|---|---|
| 1 | 子ごとの予算付き自動再試行(0.25/0.75/1.5 秒、ネットワーク系は +1 回、未使用ハンドルを解放してから再試行)。最初の失敗から 10 秒、または保存先に届かなければ即座に打ち切り、残りを「未確認」と数える。全子が最終的に成功した組み立ては必ず成功させる。読めた子は保持し、失敗した子だけを読み直す |
| 2 | 窓内に読めない巻の名前と原因を 1 冊 1 行で示し、「もう一度読み込む」(⌘R)と再マウント・スリープ解除時の 1 回の自動読み直しを用意。本そのものが見つからない場合も同じ表示にする |
| 3 | 利用者が選んだときだけ「読めない巻を除いて開く」。欠けた巻は名前と原因付きの札として並び順に残し、「(欠け N 冊)」を表示。番号だけの保存情報は書き換えも適用もしない |

最終確認(Mac mini M4、soft limit 256、合成データ):

- 修正後の最終ブランチで合成 400 冊を `.cbr` と `.zip` の両方で約 55 秒ずつ操作し、終了 0、最大 82 FD。サムネイル一覧も 8000/8000 ページ。
- 5 冊のうち 1 冊を `chmod 000` にした実フォルダで、窓内に「次の 1 冊を読み込めません: ・A-003.zip — アクセス権がありません」と 2 つのボタンが表示されることを確認した。
- cooViewer 全体試験は 1064 件、失敗 0、skip 2。各段階は 3 観点の独立レビューを繰り返し、指摘が軽微なものだけになるまで修正した。
