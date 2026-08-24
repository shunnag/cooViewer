# 変更履歴

すべての注目すべき変更をこのファイルに記録する。書式は
[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

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
- 各オフスクリーンエンジン(`EPUBPaginationCensus` /
  `EPUBScreenThumbnailRenderer` / `EPUBPageRasterizer` / `EPUBScreenAtlas`)に
  `invalidate()` — 不可視ウインドウと WebContent プロセスを明示的に畳む
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
