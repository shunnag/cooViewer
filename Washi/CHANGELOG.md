# 変更履歴

すべての注目すべき変更をこのファイルに記録する。書式は
[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

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
