# 変更履歴

すべての注目すべき変更をこのファイルに記録する。書式は
[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [1.16.0] - 2026-09-06

### 追加
- 内部リンク・目次・検索／ブックマーク位置へのジャンプを最大 50 件保持する
  `EPUBReaderView.canGoBack` / `goBack()` と、利用可否の変更通知を追加した。
  通常のページ送り・位置復元・メディアオーバーレイ移動は履歴へ含めない
  (cooViewer-oxr.31)。
- 内部リンクの EPUB セマンティクス・解決先・アンカー矩形を表す
  `EPUBInternalLink` と遷移前 delegate、同一文書／別文書の脚注本文を取り出す
  `noteContent(for:)` を追加した。`hidesFootnoteAsides` で脚注 aside を本文の
  ページ割りから除外できる(cooViewer-oxr.32)。
- delegate で抑止した内部リンクをホスト UI から明示的にたどり、遷移履歴へ
  記録する `EPUBReaderView.follow(_:)` を追加した(cooViewer-oxr.32)。
- `EPUBReaderSettings` に行間倍率・横組み字間・段落間隔・
  著者フォント上書き・ルビ非表示を型付きで指定する `lineHeightScale` /
  `letterSpacingEm` /
  `paragraphSpacingEm` / `fontFamilyOverride` / `hidesRuby` を追加した。すべて
  ページ割りと census キーへ反映し、CJK 縦組みでは字間指定を適用しない
  (cooViewer-oxr.33)。
- 正規化 UTF-16 範囲と reader-view 座標の矩形を返す `EPUBTextSelection`、
  `currentSelection`、`clearSelection()`、`rects(forTextRange:inSpineIndex:)` と
  選択変更 delegate を追加した(cooViewer-oxr.34)。
- `EPUBContextMenuPolicy` と表示直前 delegate、`EPUBClickEvent.locationInView`、
  `EPUBReaderView.contentFrame` を追加した。`EPUBRGBAColor` による型付き背景色／
  文字色は従来の CSS 文字列より優先し、CSS 色の解析を
  rgb()/hsl()/名前付き色へ拡張した。従来の `suppressesContextMenu` も
  引き続き利用できる(cooViewer-oxr.35)。
- 宣言 PPD、`primary-writing-mode`、冒頭 XHTML/CSS の縦書き、RTL 言語の
  優先順で `.byDefault` を解決する `effectiveReadingDirection` と判定元を追加し、
  表示層の綴じ方向をこの実効値へ統一した(cooViewer-oxr.36)。
- 確定したページ変更の VoiceOver 通知、reader の accessibility label/value、
  コントラスト増加／色以外での区別への追従を追加した。Accessibility metadata
  では `<link rel="dcterms:conformsTo">` と `a11y:certifierCredential` も収集し、
  `EPUBAccessibility.certifierCredentials` として公開する(cooViewer-oxr.37)。
- EPUB の page-list を読む `printPageLabels` / `go(toPrintPage:)` /
  `currentPrintPage` と変更 delegate を追加した。本文の pagebreak marker を追跡し、
  `showsPrintPageInFurniture` で印刷ページ名をノンブルへ併記できる
  (cooViewer-oxr.38)。
- census と画面サムネイルの不可視 WebKit を、最後の計測／描画完了から
  20 秒後に自動解放し、次の要求で遅延再構築するようにした。進行中または
  FIFO 待機中の要求がある間は解放しない(cooViewer-oxr.68)。
- 著者スクリプトを許可した場合だけ、PAGE world の document-start script で
  WebRTC コンストラクタを復元不能な `undefined` にし、CSP だけでは
  遮断できない STUN / UDP 経路を閉じる防御を追加した(cooViewer-oxr.87)。

### 修正
- コンテキストメニューポリシーによるフィルタ後に項目が残らない場合や
  `.suppressed` の場合も表示直前 delegate を必ず 1 回呼び出し、delegate が返した
  非空メニューを表示できるよう修正した。delegate が `nil` または空メニューを
  返した場合は表示を抑止する(cooViewer-oxr.93)。
- `dc:title` / `dc:creator` / `dc:contributor` の `dir` と `xml:lang` を、
  metadata・package 要素からの継承込みで保持するよう修正し、
  `EPUBTextDirection` と既定値付きの追加フィールドを公開した(cooViewer-oxr.52)。
- ダークテーマで小さなインライン外字画像だけを判定して反転できる
  `invertsGlyphImagesInDark` を追加し、無指定 fill のインライン SVG と黒 stroke も
  `currentColor` で描画して、黒い字形が背景へ消える問題を修正した。あわせて
  snapshot テストの画素取得では `NSCalibratedRGBColorSpace` の未変換成分値を使い、
  sRGB への再変換による値の歪みを除いた(cooViewer-oxr.78)。
- 1.16.0 の公開 API 追加は、delegate の既定実装と初期化引数／設定の既定値に
  より既存利用側とのソース互換性を維持する(cooViewer-oxr.31、
  cooViewer-oxr.32、cooViewer-oxr.33、cooViewer-oxr.34、cooViewer-oxr.35、
  cooViewer-oxr.36、cooViewer-oxr.37、cooViewer-oxr.38、cooViewer-oxr.52、
  cooViewer-oxr.78)。

## [1.15.0] - 2026-09-06

> 1.16.0 と同じコミットで同時公開(1.15.0 単独のタグは発行していない)。

### 追加
- 全文検索へ追加 API `search(_:options:snippetRadius:)` と
  `EPUBSearchOptions` を導入し、既存 API を保ったまま大小文字・ダイアクリティカル
  マーク・全半角の区別を個別指定できるようにした。`EPUBSearchHit` には DOM の
  Range へ直接渡せる UTF-16 コード単位の `utf16Range` を追加した
  (cooViewer-oxr.11)。
- nav/NCX の見出しへ共通の可読テキスト規則を追加し、ルビ読み・非表示メタ文字列を
  除外しながら、画像だけの項目では alt/title を見出しに利用する
  (cooViewer-oxr.7)。
- itemref のプロパティを文書順・重複込みで保持する
  `SpineItemRef.propertyList` と、項目別の見開き指定を解決する
  `EPUBPackage.effectiveSpread(for:)` を追加した
  (cooViewer-oxr.14、cooViewer-oxr.51)。
- spine 宣言元を保ったまま描画可能な manifest fallback を公開する
  `ReadingOrderItem.resolvedItem` / `resolvedContainerPath` を追加した
  (cooViewer-oxr.16)。
- `FixedLayoutPageInfo.viewportIsDeviceSized` と、device viewport の描画先寸法を
  指定できる `EPUBPageRasterizer.renderPage(atSpineIndex:deviceViewportSize:maxPixelSize:)`
  を追加した(cooViewer-oxr.50)。
- ZIP 内のリソースが存在しても破損等で読めない場合を表す
  `EPUBError.containerReadFailed(path:reason:)` を追加。`EPUBError` を網羅的に
  `switch` している利用側は、この新しい case の追加が必要になる
  (cooViewer-oxr.17)。
- 実際の画像ページが常に単ページになる場合でも計画上の段組を切り替えられる
  `EPUBReaderView.toggleColumnMode()` と `plannedPagesPerScreen` の用途を明確化した
  (cooViewer-oxr.20)。
- 縦書き見開きに必要な WebKit の column-axis 対応状況を公開する
  `EPUBReaderView.columnAxisSupported` を追加した(cooViewer-oxr.48)。
- ページ割り方式の世代を表す `EPUBScreenMetrics.paginationVersion` を追加し、
  census のメトリクスキーへ組み込んだ(cooViewer-oxr.25、cooViewer-oxr.26)。
- `EPUBReaderSettings.defersTapsForDoubleClick` を追加。既定の `false` では
  primary click を即時通知し、`true` のときだけ単語選択のダブルクリックを
  ページ送りにしないためシステムのダブルクリック間隔まで通知を保留する
  (cooViewer-oxr.27)。

### 修正
- nav/NCX の全角空白を保持し、a と span が併存するときは a を優先するよう修正。
  同一 spine を指す複数見出しでは文書順先頭を章題とし、spine 解決を事前索引化した
  (cooViewer-oxr.7、cooViewer-oxr.8)。
- nav の目次が空の場合も NCX へフォールバックし、`spine@toc` のない EPUB 2 では
  manifest 内の NCX を検出するよう修正した(cooViewer-oxr.9)。
- WHATWG の HTML 名前付き実体を単一走査で数値参照へ変換し、非文書 spine の
  XML 解析を省略した(cooViewer-oxr.10、cooViewer-oxr.13)。
- 検索語の全角空白・NBSP を本文と同じ規則で正規化した(cooViewer-oxr.11)。
- XML 宣言と meta charset の検出を解析・表示で共有し、UTF-8 を優先しつつ
  Shift_JIS 系宣言を CP932、EUC-JP を日本語 EUC として復号するよう修正した
  (cooViewer-oxr.12、cooViewer-oxr.90)。
- SVG の title/desc と MathML annotation を本文・検索から除外し、表セルと
  caption の境界を本文抽出と DOM テキスト地図で一致させた
  (cooViewer-oxr.89、cooViewer-oxr.92)。
- spine ごとの抽出本文をロック保護された上限付きキャッシュで共有し、検索と
  概算ページ数の再解析を避けた(cooViewer-oxr.67、cooViewer-oxr.71)。
- 文書全体の rendition meta と itemref の layout 重複指定を文書順の先頭優先へ
  修正し、部分的な `display-seq` は title/creator/author の文書順を保つようにした
  (cooViewer-oxr.14、cooViewer-oxr.49)。
- itemref の `rendition:spread-*`（旧 `spread-*` を含む）を現在項目の表示と
  項目別 census に反映し、見開き対応幅でも `spread-none` を単ページ化した
  (cooViewer-oxr.51)。
- `device-width` / `device-height` viewport を欠落と区別し、ライブ表示は表示領域、
  ラスタライズは要求寸法の縦横比へ追従するよう修正した(cooViewer-oxr.50)。
- `EPUBLocator.progression` を初期化・代入・復号の全経路で 0...1 へ丸め、NaN を
  0 として扱うとともに、ページ番号変換直前にも防御して範囲外変換の SIGTRAP を
  防止した(cooViewer-oxr.73)。
- 単一画像を包む SVG spine と画像そのものの spine を WebKit なしで解決し、
  画像 spine はリフロー表示用 XHTML wrapper を介して既存の画像ページ配置へ
  接続した(cooViewer-oxr.91、cooViewer-oxr.15)。
- 非描画形式または欠落リソースの spine に manifest fallback chain を適用し、
  本文抽出・固定ページ情報・reader・census が解決後のリソースを使うようにした
  (cooViewer-oxr.16)。
- コンテナ URL の余剰な `..` をルートへ clamp し（フォルダ読取側の脱出拒否は維持）、
  percent-encode された `refines` 対象を復号して解決するようにした
  (cooViewer-oxr.18)。
- UTF-32 XML を libxml2 へ渡す前に拒否し、実体爆弾による DTD 検査の迂回を
  防止。未終端 DOCTYPE の走査を 64 KiB の単一前向き走査へ制限した
  (cooViewer-oxr.85、cooViewer-oxr.86)。
- ZIP リソースの破損・未対応圧縮・暗号化・切り詰め・サイズ超過を英語理由付きの
  `EPUBError.containerReadFailed` へ写し、公開エラー詳細と未知 DRM 名を英語へ
  統一した(cooViewer-oxr.17)。
- spine 読み込み中の位置指定を保留して最新要求をロード完了後に適用し、読み込み中の
  `currentLocator` も保留先から導出するよう修正。idref 付き locator は spineIndex
  より idref を優先して解決する(cooViewer-oxr.19、cooViewer-oxr.23、
  cooViewer-oxr.72)。
- census の失敗抑止中に旧メトリクスのページ数を残さず、欠落・破損した spine は
  1 ページとして部分的な計測を完走するよう修正。完了済み nil タスクへの合流後も
  最新要求を再計測する(cooViewer-oxr.21、cooViewer-oxr.22、cooViewer-oxr.55)。
- pagination CSS が EPUB 側の `min-*` / `max-*` 制約を確実に中和するよう修正。
  `paginationVersion` を 3 へ更新し、1.14.x の記録に加えて lifecycle batch の
  version 2 で測定した census レコードも再度無効化して再計測する
  (cooViewer-oxr.25、cooViewer-oxr.26、cooViewer-oxr.56、cooViewer-oxr.57、
  cooViewer-oxr.58、cooViewer-oxr.59、cooViewer-oxr.60、cooViewer-oxr.61、
  cooViewer-oxr.76、cooViewer-oxr.77)。
- `userCSS` を含む派生レイアウトキーで再ページ割り要否を判断し、読み込み後の
  キーボードナビゲーション設定も JavaScript へ即時反映する(cooViewer-oxr.24)。
- メディアオーバーレイの可視判定から不要な往復ページ通知を除外。合成クリックと
  テキスト選択の抑止は保ちつつ、primary click は既定で click count ごとに即時通知し、
  opt-in 時だけダブルクリックを保留・抑止するよう修正した。audio/video とフォーム
  部品・summary・label・編集可能領域の操作はページタップから除外した
  (cooViewer-oxr.23、cooViewer-oxr.27、cooViewer-oxr.82)。
- 偶数・奇数幅の見開きで `2 * pageW + gap` を viewport 幅へ厳密に一致させ、本文の
  末尾 fragment から実ページ数を数えるよう修正。奇数末尾には内部空列を加えて単独ページを
  本文とノンブルとも読書順の先頭スロットへ置き、横書き RTL は WebKit の負方向へ
  ページ送りする
  (cooViewer-oxr.56、cooViewer-oxr.57、cooViewer-oxr.58、cooViewer-oxr.61)。
- figure 全体の高さを制限せず、子画像・SVG・動画に figcaption 分の上限を設けて、
  caption が次カラムの本文へ重なる問題を修正した(cooViewer-oxr.59)。
- `fontScale` を書籍の計算済み root font-size に乗算し、rem ベースの設計を保持。
  `defaultFontFamily` は著者 stylesheet より前かつ低詳細度で適用し、書籍側の
  html-level font-family が常に優先されるよう修正した
  (cooViewer-oxr.60、cooViewer-oxr.76、cooViewer-oxr.77)。
- 固定レイアウト spine 項目でも矢印・Space・PageUp/Down・Home/End の組み込みキーを
  項目境界のページ送りへ接続した(cooViewer-oxr.81)。
- WebContent プロセス終了時の再読み込みを回数制限・バックオフし、不可視時は再表示まで
  延期するよう修正。不可視ビューのレイアウトと census も再表示まで保留する
  (cooViewer-oxr.47、cooViewer-oxr.54)。
- 縦書き見開きで column-axis が利用できない WebKit を検出し、安全な単ページ表示へ
  フォールバックするよう修正した(cooViewer-oxr.48)。
- census・サムネイル・ページラスタライザの無効化と呼び出し元キャンセルが進行中の
  ナビゲーション待機を即座に終了し、不可視 WebView の自動再生を禁止した
  (cooViewer-oxr.53、cooViewer-oxr.62、cooViewer-oxr.88)。
- `allowsScriptedContent` を census キーと不可視レンダラ構成へ反映し、ライブ表示と
  オフスクリーンページ割りの条件を一致させた(cooViewer-oxr.75)。
- reader view 自身が first responder の場合もキー入力を処理・委譲し、ドロップ通知は
  file URL だけに限定した(cooViewer-oxr.80、cooViewer-oxr.84)。
- `EPUBCensusRecord.releaseIdentifier` の説明を、更新日時がない本では主識別子へ
  フォールバックする実装に合わせて修正した(cooViewer-oxr.74)。

### テスト・ドキュメント
- 1.15.0 / 1.16.0 の公開 API に合わせて README を更新し、Washi / WashiCore の
  DocC カタログを追加した(Swift Package Index 用 `.spi.yml` は既存のまま
  維持。cooViewer-oxr.30)。
- `WASHI_CORPUS_DIR` で公開 EPUB コーパスを指定できる、WashiCore の
  オプトイン・スモークテストを追加。
- HTTP Range の不正な非数値終端を無効として扱う `parseRange` 修正と、
  境界条件の単体テストを追加。
- README の SMIL 再生 API・DPFJ 制作ガイド表記を更新し、既知の制限と
  開発時の検証手順を追記。
- 日本語 EPUB の合成フィクスチャを生成する、第三者依存のない
  `Scripts/make-jp-epub-fixtures.py` を追加。

## [1.14.1] - 2026-09-06

### 修正
- SVG 包み画像ページが白紙になる問題と、画像ページがウインドウのリサイズへ
  即座に追従しない問題を修正。報告者提案の viewport 単位と縦横比によるサイズ
  決定を採用し、Calibre/Kindle 表紙の引き伸ばしも防止
  ([ミラー issue #1](https://github.com/shunnag/Washi/issues/1)、cooViewer-oxr.3)。
- 画像ページ判定を可視テキストに基づく処理へ変更。style/script・非表示の代替文・
  SVG の title/desc を除外し、同一画像のパネル表示用複製を重複計上しない
  (cooViewer-oxr.6)。
- ダークテーマ／読みやすさ優先で本の白背景が残る問題を修正。body の背景を
  ダーク時に透明化し、読みやすさ優先ではライト／ダーク両方で画像以外の子孫背景も
  含めて透明化する。ライトで本の配色を尊重するときは本来の背景を保つ。a の子孫は
  リンク色を継承し、pre/code とその子孫は固有の文字色を保つ。コードの暗い背景は
  ダークの読みやすさ優先時だけ適用する(cooViewer-oxr.4)。
- 縦書き見開きで章全体や長い段落を指す showFragment が最終ページへ飛ぶ問題を
  修正。先頭断片へ着地するようにし、読み上げハイライトの可視判定も揃えた
  (cooViewer-oxr.5)。
- 固定レイアウトの複雑ページ(画像 1 枚に還元できないページ・画像が直接 spine
  にあるページ)をオフスクリーンでラスタライズする `EPUBPageRasterizer` が、
  一度も表示されないウインドウでは `requestAnimationFrame` が発火せず永久に
  待ち続けていた問題を修正(フォント/画像デコード待ち+タイムアウトに変更)。
  cooViewer ではこれらのページが真っ黒になっていた(cooViewer-oxr.2)。
- 縦書き見開きで章内のページ送り(`showPage`/`goForward`)が動かなくなっていた
  回帰を修正。1.14.0 の末尾単独ページ修正(cooViewer-97e)で導入したスクロール量
  クランプが、vertical-rl 見開きの負方向スクロール座標を 0 に丸めていた
  (cooViewer-oxr.1)。

## [1.14.0] - 2026-09-03

### 追加
- リフロー EPUB の `rendition:spread`(auto/none/landscape/both)を尊重する。
  著者が見開き/単ページを指定した本は、段組設定が auto のときその指定に従う
  (none=常に単ページ、both=常に見開き、landscape=横長ウインドウでのみ見開き)。
  段組を single/double に明示した場合はユーザー設定が優先。reader 表示・全文
  census・合本(コレクション)のページマップ/サムネイルすべてが本ごとの spread で
  整合する。`EPUBScreenMetrics.applyingRenditionSpread(_:)` と
  `EPUBScreenAtlas.screenPlan(metrics:)` を追加(旧 `screenCounts(metrics:)` は撤去)。

### 修正
- 外部 DTD 参照付き DOCTYPE(XHTML 1.1 等)の本文で、`extractText`/`search` が
  名前付き実体(`&nbsp;` `&hellip;` 等)を落として WebKit の DOM 本文と乖離して
  いた問題を修正(未定義実体を数値参照へ前処理して展開)。

## [1.13.0] - 2026-08-27

### 修正
- めくりカバーのライフサイクルを堅牢化: 所有権を意識した単一の回収経路
  (`foldTurnCover`)、孤立カバーの回収、遷移中にめくりが奪われないよう
  タイムアウトを適切にキャンセル(runSetup 完了スナップショットの await 前と
  効果開始時)、spine 項目のロード中は効果をスキップ。
- `EPUBScreenAtlas`: `invalidate()` 後は新規作業を拒否(isInvalidated ゲート)、
  measuring エントリをタスク同一性で自己退避、再要求された実行中キーが nil に
  飢えないよう `newestRequestedKey` を先に更新。
- census: 明示 `.userInitiated` 優先度、2-strike + TTL の失敗台帳(一時的な計測
  失敗を許容)、キャンセル以外の全終了で censusTask を対称的に自己退避。
- `NavigationWaiter`: キャンセル対応の `wait()`(キャンセル時の 15/30 秒停止を解消)、
  resolve 時のタイマー回収、install 競合ガード。
- 入力検証: 非有限/負の SMIL 時刻値を拒否、空/複数トークンの `media:active-class`
  を未設定扱い、既定フォント名から制御文字・行区切りを除去してから CSS エスケープ。

## [1.12.0] - 2026-08-26

### 変更
- ページめくり効果(curl/slide/fade)が本文ボックスだけでなく余白・ノンブルを
  含むページ全体をめくるようにした(実際の紙のように一枚全体が動く)。
  `snapshot()` の全ページ合成(背景+本文+ノンブル)を `composeFullPage` として
  切り出し、3経路(章内・FXL・リフロー章末)のめくりカバーと効果矩形で共有。
  バッキングスケールのビットマップへ直接合成してホストの cgImage 抽出で文字を
  鮮明に保つ。カバー表示中はライブのノンブルを隠す(焼き込み番号との二重表示と、
  新章ロード中の「1」のちらつきを解消)。非対称余白の合成テストを追加。

## [1.11.0] - 2026-08-25

### 追加
- `EPUBReaderSettings.forcesReadableColors`(既定 false)。true にすると、本が
  色を指定していても(class・要素セレクタ含む)テーマの文字色を `!important` で
  上書きし、テーマ背景に対して確実に読める色にする「読みやすさ優先」モード。
  false のままなら本の配色を尊重(従来どおり、ダークは継承用の明灰のみ)。
  `textColorCSS` 明示時は無視(ホストの明示色が最優先)。ダークモードで黒文字を
  ハードコードした本(電書協系・自動生成本など)の可読性を確保する。

## [1.10.0] - 2026-08-25

### 追加
- `EPUBReaderSettings.horizontalWheelTurnsPages`(既定 true)。false にすると
  水平トラックパッド/ホイールジェスチャでページをめくらない — ホストが自前の
  スワイプめくりを持つ場合に二重発火を避け、ホストの「スワイプでめくる」設定を
  尊重できる。縦方向のページ送り(縦積みのスクロール読み)は影響を受けない。
- `EPUBReaderSettings.reversesHorizontalWheelTurn`(既定 false)。水平ホイール
  めくりの読書方向を反転する。ホストのスワイプ方向設定や、合本(単巻と異なる
  読み順のコレクション)の綴じ方向にホイールめくりをそろえるために使う。
- どちらも表示条件(ページ割り・census メトリクス)には影響しない挙動のみの
  設定で、`cacheKey`/census には含めない。

## [1.9.0] - 2026-08-25

### 追加
- `EPUBReaderSettings.spreadInsets`(見開き専用の余白)。nil のとき見開きも
  `insets` を使う(従来互換)。設定すると単ページと見開きで別々の余白を
  適用できる(例: 大きなウインドウの見開きで外側を広めに)。見開き判定は
  基準 `insets` の内容幅で行うので切替閾値は揺れない。webView フレーム・
  ノンブル位置・census メトリクスすべてがモードに応じた余白で整合する

## [1.8.1] - 2026-08-25

### セキュリティ
- リーダーへの JS 呼び出しで、EPUB 由来の断片 id・`media:active-class` を
  文字列連結で埋め込んでいた箇所(メディアオーバーレイのハイライトと
  フラグメント移動)を、`callAsyncJavaScript` の引数渡しに変更。手動の
  `\`/`'` エスケープでは取りこぼす改行・行区切り(U+2028/U+2029)による
  細工 EPUB からの JS インジェクションを防ぐ

## [1.8.0] - 2026-08-25

### 追加
- **メディアオーバーレイ(SMIL)の音声同期再生**。`EPUBReaderView` に
  `playMediaOverlay()` / `pauseMediaOverlay()` / `stopMediaOverlay()` /
  `toggleMediaOverlayPlayback()` と `isPlayingMediaOverlay` /
  `hasMediaOverlayForCurrentItem` を追加。par 単位で音声(AVFoundation)を
  再生しながら、読み上げ中のテキストへ `media:active-class` を付与し、
  必要なページへ自動でめくる。項目末尾では次の音声付き項目へ連続再生
  (オーディオブック)。`EPUBReaderViewDelegate` に再生状態・終了の通知を追加
- `EPUBMetadata.mediaOverlayActiveClass`(`media:active-class` の読み出し)

## [1.7.0] - 2026-08-25

### 追加
- `EPUBPublication.spineIndex(forHref:)` — 目次や相互参照の href(フラグメント
  可)を収録項目の spine index へ解決(`spineIndex(forNavItem:)` の一般化)
- `EPUBPublication.hasMediaOverlays` — メディアオーバーレイ(SMIL)を持つ本かの
  判定。項目ごとの取得は既存の `mediaOverlay(forSpineIndex:)`(音声・テキストの
  対を返すのでホスト側で同期再生を組める)

## [1.6.0] - 2026-08-25

### 追加
- `EPUBPublication.coverImageData()` — 表紙をデコードせず生バイト+メディア
  タイプで取得(元ファイルの保存・配信用。`coverImage` と同じフォールバック連鎖)
- `EPUBNavigation.flattenedTOC` と `EPUBNavItem.flattened(startingAt:)` —
  目次ツリーを depth 付きの一列へ平坦化(フラットな目次 UI 向け)

### 修正
- 全文検索が半角濁点カナ(`ｶﾞ` 等)を全角(`ガ`)と一致させるように
  (NFKC 畳み込み。全角/半角形ブロックのみ対象で 1:1・高速、オフセットは
  元テキストに正確)。1.5.x までの既知の取りこぼしを解消

## [1.5.0] - 2026-08-25

### 追加
- `EPUBPublication.estimatedPageCount(charactersPerPage:)` /
  `estimatedPageCounts(charactersPerPage:)` — WebKit 不要で本文文字数から
  概算ページ数を即時に得る(オフスクリーン census 完了前の「約 N ページ」
  表示や、ヘッドレスでの規模把握に)。画像のみのページは 1 とみなす。
  実 census(総文字数÷実測ページ)から charactersPerPage を較正すると精度が上がる

## [1.4.0] - 2026-08-25

### 追加
- 全文ページ census の永続化 API。`EPUBReaderView.exportCensus()` /
  `importCensus(_:)` と `EPUBCensusRecord`(Codable)。実測済みのページ数を
  ホストが保存し、同一メトリクス・同一版で再オープンしたときに注入すると、
  オフスクリーンの再実測を省いて N/M ページ表示・ページバーが即座に出る
  (版識別子と spine 数で他版の値を安全に拒否)

## [1.3.0] - 2026-08-25

### 追加
- `EPUBReadStrategy`(`.mappedIfSafe` 既定 / `.alwaysCopy`)を
  `EPUBPublication.open`・`init(url:)`・`ZipArchive(url:)` に追加。
  `.alwaysCopy` は memory-map を使わず全読みするので、揮発・信頼できない
  ストレージ(ネットワークボリューム・未検証アップロード)の SIGBUS を避ける。
  ヘッドレス/サーバ利用向け

## [1.2.1] - 2026-08-25

### 追加
- Swift Package Index 設定(`.spi.yml`)。登録すれば WashiCore / Washi 両
  プロダクトの DocC ドキュメントがホストされる(公開 API doc は英語)

## [1.2.0] - 2026-08-25

### 追加
- **`WashiCore` プロダクト**(解析層の分離)。Foundation / Compression /
  CryptoKit / CoreGraphics / ImageIO のみに依存し、AppKit/WebKit を引かない。
  GUI セッションのないヘッドレス利用(CLI・索引・サーバ)で
  `import WashiCore` だけで解析・メタデータ・本文抽出/検索・表紙デコードが
  使える。`Washi`(表示層)は `WashiCore` を `@_exported` 再輸出するので、
  `import Washi` の利用者は従来どおり両層の API が見える(ソース互換)

## [1.1.0] - 2026-08-25

弱点探索(多エージェント敵対的監査)で見つかった実在の穴を修正した堅牢化リリース。

### 修正
- 非 UTF-8(Shift_JIS/EUC-JP/UTF-16)の XML に名前付き HTML 実体
  (`&nbsp;` `&copy;` 等)が含まれると救済に失敗していた問題。宣言の
  `encoding` を尊重して復号するようにし、Shift_JIS の OPF で本が開けない・
  Shift_JIS の本文で抽出/検索が黙って空になる・非 UTF-8 の nav/NCX で
  目次が落ちる、を解消(旧来の日本語 EPUB に多いパターン)
- 細工された zip64 EOCD ロケータの巨大 64bit オフセットで `Int(UInt64)` が
  トラップしプロセスが落ちる問題(42 バイトの EPUB でクラッシュ)を、
  `Int(exactly:)` + 範囲検査で throw に
- `EPUBPublication.search` に負の `snippetRadius` を渡すとスニペット範囲が
  反転してクラッシュする問題を、非負クランプで解消
- 固定レイアウトの巨大 viewport(悪意ある `width`/`height`)で
  オフスクリーンスナップショットが巨大確保されクラッシュする問題を、
  描画寸法のクランプ(最大 5000px・非有限/0/負値の除外)で解消

## [1.0.0] - 2026-08-25

初回の安定版。0.2.0〜0.5.0 で加えた外部利用向けの機能・堅牢化・安定化を
まとめ、公開 API を 1.0 として固定する。

### 変更
- 公開 API の doc コメントをすべて英語化(DocC 生成が英語で読める)

### この版までに揃った外部利用向けの主な API(0.2.0〜0.5.0 の総括)
- 解析: `EPUBPublication.open(url:)`(非同期)/ `resource(at:)` /
  `resourcePaths` / `extractText(forSpineIndex:)` / `search(_:)`
- メタデータ: `metadata`(dc:* 一式)/ `accessibility` / `authors` / `series` /
  `coverImage(maxPixelSize:)`
- 位置: `EPUBLocator`(idref 付き)/ `resolve(_:)`
- 表示: `EPUBReaderView`(縦組み・見開き・テーマ・FXL)、
  `forwardsKeyEventsNatively` / `suppressesContextMenu`、消費者が保持する
  オフスクリーン型(`EPUBScreenAtlas` / `EPUBPageRasterizer`)の `invalidate()`
- エラー: 全型 `LocalizedError` 準拠
- 堅牢化: XML 実体爆弾・ZIP 爆弾・パス/シンボリックリンク脱出・深い XML を
  入口で遮断

## [0.5.0] - 2026-08-25

### 追加
- `EPUBMetadata.accessibility` (`EPUBAccessibility`) — schema.org / EPUB
  Accessibility のメタデータ(accessMode・feature・hazard・summary・
  conformsTo・certifiedBy)を型付きで公開。EU アクセシビリティ法などで
  表示が求められる情報を一覧アプリがそのまま出せる
- `EPUBMetadata.authors`(role=aut を display-seq 順)と `EPUBMetadata.series`
  の便利アクセサ

### 修正
- 固定レイアウトの `page-spread-*` プロパティで、接頭辞なし(EPUB 3.0)と
  `rendition:` 付き(EPUB 3.1+)の両同義形を認識するように

### 既知の制限
- リフロー本の `rendition:spread="none"` は未反映(見開き判定は
  columnMode と画面幅で決まる)。固定レイアウトの見開き指定は反映される

## [0.4.0] - 2026-08-25

### 追加
- `EPUBPublication.open(url:)` — 解析を `.userInitiated` の detached タスクで
  行う非同期オープン。UI からはこちらを推奨(重い解析でメインを塞がない)
- `EPUBPublication.resourcePaths` — コンテナ内の全リソースパス列挙
  (索引・抽出・監査用)
- `EPUBReaderSettings.suppressesContextMenu` — 右クリックの WKWebView
  コンテキストメニューを抑制し、ホスト独自メニューを出せるようにする

### 変更
- `EPUBError` / `ZipError` / `EPUBPageRasterizer.RasterizeError` を
  `LocalizedError` 準拠にし、`errorDescription`(英語)を提供。外部利用者が
  エラーをそのまま UI へ表示できる

## [0.3.0] - 2026-08-25

### 追加
- `EPUBPublication.extractText(forSpineIndex:)` と `search(_:snippetRadius:)` —
  WebKit を介さない本文プレーンテキスト抽出と全文検索(ルビの読みを除去、
  大小・濁点・全半角を無視)。索引・検索・引用に使える。`EPUBSearchHit` は
  spine index・文字オフセット・スニペットを持ち、将来のハイライトの土台
- `EPUBReaderSettings.forwardsKeyEventsNatively` と
  `EPUBReaderViewDelegate.readerView(_:didReceiveNativeKey:)` —
  ネイティブ `NSEvent` のキーを WKWebView より先に横取り転送する経路。
  ホスト独自のキーバインド向けの推奨経路(JS 経路のキー取りこぼしを回避)

## [0.2.0] - 2026-08-25

### 追加
- `EPUBPublication.coverImage(maxPixelSize:)` / `resolvedCoverImagePath` —
  宣言のない実在本もフォールバック連鎖(cover-image → EPUB2 meta →
  landmarks cover → cover を含む名前の画像 → 先頭ページの単一画像)で
  表紙を解決し、ImageIO のみでデコード(ヘッドレス利用可)
- `EPUBLocator.idref` と `EPUBPublication.locator(forSpineIndex:)` /
  `resolve(_:)` — 保存した読書位置を配信本の改版(spine の並べ替え・増減)を
  跨いで正しい章へ追跡する。旧 JSON とデコード互換
- 消費者が保持するオフスクリーン型(`EPUBScreenAtlas` /
  `EPUBPageRasterizer`)に `invalidate()` — 不可視ウインドウと WebContent
  プロセスを明示的に畳む(`EPUBScreenAtlas` は内部の census・サムネイル
  レンダラも畳む。`EPUBReaderView` はウインドウ離脱時に自動)
- `ZipArchive` の `maxEntrySize`(既定 512MB)

### セキュリティ・堅牢化
- XML 実体爆弾(billion laughs)を入口で遮断。内部 DTD の実体宣言を検査し、
  処理命令バイパス・UTF-16 バイパス・文字参照密輸を防ぐ(実在の互換シムは許容)
- 異常に深い XML ネスト(> 512 段)を拒否し、再帰パーサの SIGSEGV を防止
- ZIP 爆弾の絶対サイズ上限、フォルダコンテナのシンボリックリンク脱出遮断

### 修正
- `EPUBReaderView` の高速な spine 移動で読書位置ジャンプ・位置復元が失われ、
  古いナビゲーションのイベントで章が飛ぶ競合(ナビゲーション世代トークン)
- ウインドウから外れた `EPUBReaderView` がオフスクリーン計測を止めず、
  ビュー・不可視ウインドウ・WebContent プロセスを生かし続けるリーク

## [0.1.0] - 2026-08-24

- 初回公開(cooViewer から切り出した EPUB 3 ツールキット)
