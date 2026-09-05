# Washi(和紙)

macOS ネイティブ技術だけで実装した EPUB 3 ツールキット。
日本語組版(縦組み・ルビ・縦中横・圏点・右綴じ)を第一級でサポートする。

**Washi** は macOS のシステムフレームワークだけで構成した、MIT ライセンスの
EPUB 3 ツールキット。第三者パッケージには依存しない。解析層は Foundation /
CoreFoundation / Compression / CryptoKit / CoreGraphics / ImageIO だけを使うため
ヘッドレスでも動作し、表示層は AppKit / WebKit を加える。縦組み(`vertical-rl`)・
ルビ・縦中横・圏点・右綴じを含む日本語組版を第一級の機能として扱う。

## 特徴

- **依存ゼロ**: ZIP 読み取り(zip64 対応・CRC 検証)から自前実装。
  解析層は Foundation の `XMLDocument`・CoreFoundation・Compression・CryptoKit・
  CoreGraphics・ImageIO のみ(ヘッドレス利用可)、表示層(`EPUBReaderView` 等)は
  AppKit・WebKit を使用
- **攻撃的 EPUB への耐性**: zip 爆弾(比率+絶対上限)、XML 実体爆弾
  (billion laughs。互換シムは許容)、異常な深さの XML、パス走査・
  シンボリックリンク脱出をすべて入口で遮断(テスト付き)
- **EPUB 3.3 の RS(閲覧システム)要件に準拠する設計**(EPUB 2.0.1 後方互換込み):
  - OCF コンテナ(`container.xml` 複数 rootfile / `mimetype` 検証 /
    `encryption.xml`)。`.epub` と展開済みフォルダの両方を開ける
  - パッケージ文書: DCMES + `refines`、`display-seq`、`belongs-to-collection`
    (シリーズ)、`prefix` 宣言の正規化、rendition プロパティ、
    `page-progression-direction`、manifest フォールバック連鎖(循環ガード付き)、
    EPUB 2 の `opf:*` 属性・`meta name="cover"`
  - ナビゲーション: EPUB 3 nav(toc / page-list / landmarks)+ NCX フォールバック
  - **本文抽出・全文検索**: WebKit を使わず、大小文字・ダイアクリティカルマーク・
    全半角の区別を `EPUBSearchOptions` で個別指定できる。
    `EPUBSearchHit.utf16Range` は DOM Range と同じ UTF-16 コード単位
  - XML 宣言と HTML の meta charset を解析・表示で共通判定し、Shift_JIS 系は
    NEC / IBM 拡張文字を含む CP932、EUC-JP は日本語 EUC として復号
  - **フォント難読化の透過解除**: IDPF(SHA-1/1040 バイト)と
    Adobe(UUID/1024 バイト)。DRM(ADEPT / LCP / FairPlay)は指紋検出して
    明示的に報告(復号はしない)
  - **メディアオーバーレイ(SMIL)の再生**: `playMediaOverlay()` /
    `pauseMediaOverlay()` / `stopMediaOverlay()` で制御し、読み上げ箇所へ
    `media:active-class` を付けてハイライトしながら必要なページへ自動追従
- **リフローレンダラー** `EPUBReaderView`(AppKit / WKWebView):
  - 標準 CSS multicol によるページ分割。縦組みは「縦積みカラム + 無アニメーション
    ジャンプ」方式(Bibi / Readium CSS と同じ、実運用で実証済みのモデル。
    行が途中で割れない)
  - **Apple Books 風の版面**: ウインドウ幅で単ページ⇔**見開き 2 ページ**を
    自動切替(`columnMode` で固定も可)。縦書きの見開きは
    `-webkit-column-axis: horizontal` の半幅ページボックス(WKWebView 専用・
    実測検証済み)で右綴じの正順(先のページが右)。中央にノド、
    **各ページの下部中央に素のノンブル**(`showsPageFurniture` で OFF 可)。
    表紙などの画像単独ページは見開き時も単独の中央フィット
  - **ライト/ダークテーマ**: 既定でシステム外観に追従(`EPUBReaderTheme` で
    固定も可)。ダークは Apple Books 系のほぼ黒 + 明灰文字で、
    `color-scheme` も注入する。`invertsGlyphImagesInDark` は小さなインライン
    外字画像をヒューリスティックに反転し、無指定 fill のインライン SVG と
    黒 stroke は `currentColor` で描画する
  - 電書連(DPFJ)EPUB 3 制作ガイド ver.1.1.4(2025-10、旧電書協 1.1.3 と
    CSS 互換)のテンプレートが使う抽象フォント名(`serif-ja` 等)を
    ヒラギノ明朝 ProN / ヒラギノ角ゴシックへ結び付ける `@font-face` ポリフィル
  - `WKURLSchemeHandler` によるコンテナ内配信(正しい MIME / CSP /
    Range 対応)。外部ネットワークはコンテンツルールで遮断、
    本の JavaScript は既定で無効。有効化した場合も PAGE world の
    document-start script で WebRTC コンストラクタを使用不能にし、
    CSP だけでは遮断できない STUN / UDP 経路を閉じる
  - `EPUBReaderSettings` でフォント倍率・行間・横組み字間・段落間隔・
    著者フォントの上書き・ルビの表示/非表示、型付き配色・余白・
    ユーザー CSS を指定。`EPUBLocator`(spine index + 進行率)で位置を保存/復元
  - 宣言された `page-progression-direction`、`primary-writing-mode`、冒頭の
    XHTML / CSS、RTL 言語の順で `effectiveReadingDirection` を決め、
    表示層もその実効値を使用
  - 内部リンク・目次・locator・UTF-16 範囲へのジャンプ元を最大 50 件保持する
    `canGoBack` / `goBack()` と、履歴の利用可否が変わったときの delegate 通知
  - `EPUBInternalLink` と `shouldFollowInternalLink` delegate で内部リンクを
    遷移前に判定。同一文書／別文書の脚注は `noteContent(for:)` で抽出でき、
    `hidesFootnoteAsides` で本文のページ割りから脚注 aside を除外できる。
    抑止後に `follow(_:)` を呼べば delegate を再度通さず、履歴を記録して遷移する
  - 正規化 UTF-16 範囲と reader-view 座標を結ぶ選択 API
    (`currentSelection` / `clearSelection()` /
    `rects(forTextRange:inSpineIndex:)`)と選択変更 delegate
  - EPUB page-list のラベル一覧・移動・現在位置
    (`printPageLabels` / `go(toPrintPage:)` / `currentPrintPage`)に対応し、
    本文の pagebreak marker とノンブル表示にも連動
  - VoiceOver への確定ページ通知と accessibility label/value、システムの
    コントラスト増加・色以外での区別へ追従
  - 全文ページ数の census は、欠落または決定的に読み込めない spine 項目を
    1 ページとして残りの計測を続け、部分的な結果も利用可能にする
  - **ピンチでフォント倍率**(0.5〜3.0 倍): ジェスチャ中は
    `WKWebView.magnification` で滑らかに視覚追従し、指を離すと倍率を確定して
    進行率を保ったまま再ページ割り(テキストは再流し込みでシャープなまま)。
    `adjustFontScale(by:)` で段階調整も可、変更は delegate へ通知
  - ホスト統合: キー/クリック/ファイルドロップの delegate 転送と、
    `EPUBContextMenuPolicy` / 表示直前 delegate によるコンテキストメニュー制御
    (アプリ独自のキーバインドやページ送りに接続できる。既定では
    左右端タップでページ送り)。キーは `forwardsKeyEventsNatively` で
    ネイティブ `NSEvent` を横取り転送でき、WKWebView にキーを食われる
    問題を避けられる(ホスト独自バインド向けの推奨経路)
- **固定レイアウト**: viewport 解析、`page-spread-left/right/center`、
  「画像 1 枚だけのページ」の検出(WebKit を介さず画像を直接取り出せる —
  日本の漫画 EPUB の大多数がこの形)、複雑ページの
  オフスクリーンラスタライズ(`EPUBPageRasterizer`)。`device-width` /
  `device-height` の viewport はライブ表示の領域へ追従し、ラスタライズ時は
  `deviceViewportSize` で描画先寸法を渡せる。
  `FixedLayoutPageInfo.viewportIsDeviceSized` で該当ページを判別できる
- 文書全体に加えて itemref ごとの `rendition:spread-*` も文書順に解決し、
  現在項目の表示と項目別 census の単ページ／見開き計画へ反映

## 導入

SwiftPM で依存に追加する:

```swift
// Package.swift
.package(url: "https://github.com/shunnag/Washi.git", from: "1.0.0")
```

通常利用するプロダクトは 2 つ:

- **`WashiCore`** — 解析層のみ(Foundation / CoreFoundation / Compression /
  CryptoKit / CoreGraphics / ImageIO)。AppKit/WebKit を引かないので、GUI セッションの
  ない**ヘッドレス利用**(CLI・索引・サーバ・変換ツール)で使える。
  OCF/OPF/nav 解析・メタデータ・本文抽出/検索・表紙デコードまで。
- **`Washi`** — 表示層込み(AppKit / WebKit を追加。リーダービュー・
  ページ census・サムネイル)。`WashiCore` を再輸出するので、
  **`import Washi` だけで両層の公開 API が見える**(従来どおり)。

```swift
import WashiCore          // ヘッドレス: 解析・メタデータ・検索のみ
let book = try EPUBPublication(url: url)
print(book.metadata.mainTitle ?? "", book.search("keyword").count)
```

このほか、`WashiDynamic` は動的ライブラリとして 1 本にまとめたいホスト
(フレームワーク同梱など)向けで、両ターゲットを含む。

## 使い方

```swift
import Foundation
import Washi

// 解析(UI からは非同期の open を推奨。重い解析をメインで走らせない)
let publication = try await EPUBPublication.open(url: epubURL)
print(publication.metadata.mainTitle ?? "")
print(publication.effectiveReadingDirection)       // 常に .ltr または .rtl
print(publication.effectiveReadingDirectionSource) // 判定に使った出典
for item in publication.navigation.toc { print(item.title) }

// 表示(AppKit)
let reader = EPUBReaderView()
reader.delegate = self
reader.load(publication: publication)      // at: EPUBLocator で位置復元
reader.goForward()                         // 読書順で次ページ
reader.turnPageLeft()                      // 物理方向(右綴じなら「進む」)

// 表紙(ライブラリ一覧用。宣言がない本もフォールバック連鎖で解決)
let cover = publication.coverImage(maxPixelSize: 480)   // CGImage?

// 本文抽出・全文検索(WebKit 不要。索引・検索・引用に)
let plain = try publication.extractText(forSpineIndex: 0)
for hit in publication.search("吾輩") {                 // 大小・全半角無視
    print(hit.spineIndex, hit.characterOffset, hit.snippet)
}

// 固定レイアウトの画像直取り
let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
if let path = info.simpleImagePath {
    let (data, _) = try publication.resource(at: path)   // PNG/JPEG そのもの
}
```

ジャンプ履歴の利用可否は delegate で UI へ同期できる。通常のページ送りは
この履歴に入らない。

```swift
func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {
    print("戻る操作:", view.canGoBack ? "有効" : "無効")
}

if reader.canGoBack {
    reader.goBack()
}
```

`noteref` は既定遷移を止め、ホストのポップオーバーへ表示できる。
`presentFootnote(_:anchor:)` はホスト側の表示処理とする。

```swift
func readerView(
    _ view: EPUBReaderView,
    shouldFollowInternalLink link: EPUBInternalLink
) -> Bool {
    guard link.isNoteReference else { return true }
    Task { @MainActor in
        if let note = await view.noteContent(for: link) {
            presentFootnote(note, anchor: link.anchorRect)
        }
    }
    return false
}

var footnoteSettings = reader.settings
footnoteSettings.hidesFootnoteAsides = true
reader.settings = footnoteSettings

// ポップオーバーの「本文で開く」操作などから呼ぶ
func openFootnoteInReader(_ link: EPUBInternalLink) {
    reader.follow(link)
}
```

文字組み設定はまとめて代入すると、1 回の再ページ割りで反映できる。
`letterSpacingEm` は CJK の縦組みには適用されない。

```swift
var typography = reader.settings
typography.lineHeightScale = 1.1
typography.letterSpacingEm = 0.03
typography.paragraphSpacingEm = 0.8
typography.fontFamilyOverride = "Hiragino Mincho ProN"
typography.hidesRuby = false
reader.settings = typography
```

選択範囲は正規化済み UTF-16 オフセットと reader-view 座標で通知される。

```swift
func readerView(
    _ view: EPUBReaderView,
    selectionDidChange selection: EPUBTextSelection?
) {
    guard let selection else { return }
    print(selection.spineIndex, selection.text,
          selection.utf16Range, selection.rects)
}
```

census は `load(publication:)` の後に復元する。`metricsKey` には
`EPUBScreenMetrics.paginationVersion` が含まれ、古いページ割り方式の記録は
`importCensus(_:)` が自動的に拒否する。現在と異なる表示メトリクスの記録は、
同じ本・同じ世代なら受け入れられ、メトリクスが一致した時点で使われる。

```swift
reader.load(publication: publication)
if let savedRecord = try? JSONDecoder().decode(
    EPUBCensusRecord.self, from: savedCensusData
) {
    let accepted = reader.importCensus(savedRecord)
    print("census 復元:", accepted)
}

if let currentRecord = reader.exportCensus() {
    let dataToPersist = try JSONEncoder().encode(currentRecord)
    // dataToPersist をホスト側で保存する
}
```

## 対応状況(EPUB 3.3 RS チェックリスト抜粋)

| 領域 | 状態 |
|---|---|
| OCF(ZIP / zip64 / mimetype / container.xml / encryption.xml) | ✅ |
| パッケージ文書(metadata refines / spine / rendition / fallback) | ✅ |
| ナビゲーション(nav の toc / landmarks、NCX フォールバック) | ✅ |
| EPUB page-list(一覧・移動・現在位置・本文 marker) | ✅ |
| パッケージ metadata の `dir` / `xml:lang` | ✅(package / metadata から title・creator・contributor へ継承) |
| 実効読書方向(`page-progression-direction` / `primary-writing-mode` / CSS / 言語) | ✅ |
| 内部リンクと `noteref`(遷移前 delegate・脚注抽出) | ✅ |
| フォント難読化(IDPF / Adobe) | ✅ |
| リフロー描画(縦組み・ルビ・縦中横・圏点・右綴じ) | ✅ |
| 固定レイアウト(viewport / spread 指定 / SVG ラッパー) | ✅ |
| 本文テキスト抽出・全文検索(ルビ除去・大小/全半角無視) | ✅(解析層のみ) |
| メタデータ(著者/シリーズ/アクセシビリティの型付きサーフェス) | ✅ |
| scripted コンテンツ | 任意(既定オフ。CSP / 外部通信ルール / WebRTC 無効化込みで有効化可) |
| メディアオーバーレイ(SMIL) | パース+項目取得(`mediaOverlay`)。1.8.0 から `playMediaOverlay()` / `pauseMediaOverlay()` / `stopMediaOverlay()` で再生し、active-class ハイライトと自動ページ追従に対応 |
| DRM(ADEPT / LCP / FairPlay) | 非対応(検出して報告) |
| リフロー見開き(横組み / 縦組み) | ✅ |
| FXL 見開き合成 | 未実装(ホスト側で合成可) |

## 既知の制限

- `text-spacing-trim` は WebKit に未実装のため、指定しても反映されない。
- `hanging-punctuation: force-end` は WebKit では効果がない。
- EPUB 3.4 で outdated とされた機能のうち、`rendition:spread` /
  `rendition:flow` / `rendition:orientation` は legacy hint として保持し、
  フォント難読化・NCX・OPF 2 の `meta` は互換性のため引き続き対応する。
  `collection` 要素には未対応。
- `rendition:flow` の scrolled モード(`scrolled-doc` / `scrolled-continuous`)は
  まだ実装していない。
- `defersTapsForDoubleClick = true` は、ダブルクリックによる単語選択より先に
  ページ送りが起きるのを防ぐ代わりに、primary click の通知をシステムの
  ダブルクリック間隔だけ遅らせる。既定の `false` はクリックを即時通知する。
- `invertsGlyphImagesInDark` の外字判定はクラス名と表示寸法に基づくため、
  小さな挿絵を外字と誤判定する場合がある。原色が必要な本では `false` にする。
- WebRTC コンストラクタの無効化は `allowsScriptedContent = true` で著者
  JavaScript を許可した EPUB コンテンツだけが対象で、ホストアプリや別の
  WebView に対する一般的な WebRTC 制御ではない。

## 開発

- 公開コーパスのヘッドレススモークテストは、`WASHI_CORPUS_DIR` に EPUB
  コーパスのディレクトリを指定して `swift test --filter CorpusSmokeTests` を
  実行する。未設定またはディレクトリが存在しない場合はスキップされる。
- 日本語 EPUB の合成フィクスチャは、第三者パッケージ不要の
  `python3 Scripts/make-jp-epub-fixtures.py <outdir> [--big]` で生成できる。

## 動作環境

macOS 14+ / Swift 6(strict concurrency)/ Apple Silicon・Intel 両対応の
ソースだが、cooViewer 同梱ビルドは arm64 のみ。

## 組み込みの注意(オフスクリーン WebKit)

- 消費者が保持するオフスクリーン型 `EPUBScreenAtlas`(census と
  サムネイルを内部に持つ)と `EPUBPageRasterizer` は、それぞれ不可視の
  NSWindow + WebContent プロセスを抱える。アトラス内部の census／サムネイルは
  完了後 20 秒のアイドルで WebKit を自動解放し、次回要求で再構築するが、
  **使い終えたオフスクリーン型には `invalidate()` を呼ぶ**(アトラスを
  キャッシュから追い出すときも)。`EPUBReaderView` は
  ウインドウから外れた時点で自分のオフスクリーン(内部の census・
  サムネイルレンダラ含む)を自動で畳むので、明示呼び出しは不要
- オフスクリーン系 API は **`.userInitiated` 以上の優先度で呼ぶ**こと。
  低 QoS(`.utility` 等)を継いだまま最初の JS 実行を発行すると、WebKit の
  応答が返らず永久待ちになる(実測)
- 表示・計測系(Rendering/)は全て `@MainActor`。GUI セッションのないデーモン
  からは解析層(`EPUBPublication` ほか)だけを使う
- 全文ページ数の実測(census)はオフスクリーン WebKit で数秒かかることが
  ある。`EPUBReaderView.exportCensus()` の結果を保存し、再オープン時に
  `importCensus(_:)` で注入すると再実測を省ける。同一版かつ現行の
  `paginationVersion` の記録だけを受け入れ、メトリクスも一致すれば
  ページ番号／バーへ即時反映する

## ドキュメント

英語の DocC カタログ記事を公開 API の doc コメントと合わせて生成できる。
Swift Package Index 用の設定(`.spi.yml`)では、Washi / WashiCore の両ターゲットを
ドキュメント生成対象に指定している。公開時の
[パッケージ登録](https://swiftpackageindex.com/add-a-package)もここから行える。

Washi パッケージのルートで、ローカルの DocC を次のコマンドでビルドできる。

```sh
xcodebuild docbuild -scheme Washi -destination 'platform=macOS'
```

## 開発体制

このリポジトリは [cooViewer](https://github.com/shunnag/cooViewer) モノレポ内の
`Washi/` ディレクトリから `git subtree split` で切り出した片方向ミラー。
開発はモノレポ側で行われ、リリースのたびにここへ反映される。
Issue / PR は歓迎するが、取り込みはモノレポ側で行った上でミラーに現れる。

## ライセンス

MIT License(LICENSE を参照)。依存パッケージはない。
設計にあたり Readium CSS・Bibi(いずれも実装は独立)の公開知見を参考にした。
