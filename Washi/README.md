# Washi(和紙)

macOS ネイティブ技術だけで実装した EPUB 3 ツールキット。
日本語組版(縦組み・ルビ・縦中横・圏点・右綴じ)を第一級でサポートする。

**Washi** is an EPUB 3 toolkit for macOS built exclusively on system frameworks
with **zero third-party dependencies**, MIT licensed. The parsing layer needs
only Foundation / Compression / CryptoKit / ImageIO (usable headless); the
rendering layer adds AppKit / WebKit. Japanese typography — vertical writing
(`vertical-rl`), ruby, tate-chu-yoko, kenten, right-to-left page progression —
is a first-class citizen. Public API doc comments are English; the README and
internal comments are Japanese.

## 特徴

- **依存ゼロ**: ZIP 読み取り(zip64 対応・CRC 検証)から自前実装。
  解析層は Foundation の `XMLDocument`・Compression・CryptoKit・ImageIO のみ
  (ヘッドレス利用可)、表示層(`EPUBReaderView` 等)は AppKit・WebKit を使用
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
  - **フォント難読化の透過解除**: IDPF(SHA-1/1040 バイト)と
    Adobe(UUID/1024 バイト)。DRM(ADEPT / LCP / FairPlay)は指紋検出して
    明示的に報告(復号はしない)
  - メディアオーバーレイ(SMIL)のパース(再生は将来拡張)
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
    `color-scheme` も注入する
  - 電書協(EBPAJ)テンプレートの抽象フォント名(`serif-ja` 等)を
    ヒラギノ明朝 ProN / ヒラギノ角ゴシックへ結び付ける `@font-face` ポリフィル
  - `WKURLSchemeHandler` によるコンテナ内配信(正しい MIME / CSP /
    Range 対応)。外部ネットワークはコンテンツルールで遮断、
    本の JavaScript は既定で無効
  - フォントサイズ・配色・余白・ユーザー CSS、位置の保存/復元
    (`EPUBLocator` = spine index + 進行率)
  - **ピンチでフォント倍率**(0.5〜3.0 倍): ジェスチャ中は
    `WKWebView.magnification` で滑らかに視覚追従し、指を離すと倍率を確定して
    進行率を保ったまま再ページ割り(テキストは再流し込みでシャープなまま)。
    `adjustFontScale(by:)` で段階調整も可、変更は delegate へ通知
  - ホスト統合: キー/クリック/ファイルドロップの delegate 転送
    (アプリ独自のキーバインドやページ送りに接続できる。既定では
    左右端タップでページ送り)。キーは `forwardsKeyEventsNatively` で
    ネイティブ `NSEvent` を横取り転送でき、WKWebView にキーを食われる
    問題を避けられる(ホスト独自バインド向けの推奨経路)
- **固定レイアウト**: viewport 解析、`page-spread-left/right/center`、
  「画像 1 枚だけのページ」の検出(WebKit を介さず画像を直接取り出せる —
  日本の漫画 EPUB の大多数がこの形)、複雑ページの
  オフスクリーンラスタライズ(`EPUBPageRasterizer`)

## 導入

SwiftPM で依存に追加する:

```swift
// Package.swift
.package(url: "https://github.com/shunnag/Washi.git", from: "0.1.0")
```

通常は `Washi` プロダクトを使う。`WashiDynamic` は動的ライブラリとして
組み立てたいホスト(フレームワーク同梱など)向けで、API は同一。

## 使い方

```swift
import Washi

// 解析(UI からは非同期の open を推奨。重い解析をメインで走らせない)
let publication = try await EPUBPublication.open(url: epubURL)
print(publication.metadata.mainTitle ?? "")
print(publication.readingDirection)        // .rtl = 右綴じ
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

## 対応状況(EPUB 3.3 RS チェックリスト抜粋)

| 領域 | 状態 |
|---|---|
| OCF(ZIP / zip64 / mimetype / container.xml / encryption.xml) | ✅ |
| パッケージ文書(metadata refines / spine / rendition / fallback) | ✅ |
| ナビゲーション(nav / NCX) | ✅ |
| フォント難読化(IDPF / Adobe) | ✅ |
| リフロー描画(縦組み・ルビ・縦中横・圏点・右綴じ) | ✅ |
| 固定レイアウト(viewport / spread 指定 / SVG ラッパー) | ✅ |
| 本文テキスト抽出・全文検索(ルビ除去・大小/全半角無視) | ✅(解析層のみ) |
| メタデータ(著者/シリーズ/アクセシビリティの型付きサーフェス) | ✅ |
| scripted コンテンツ | 任意(既定オフ。CSP 込みで有効化可) |
| メディアオーバーレイ | パースのみ(再生は未実装) |
| DRM(ADEPT / LCP / FairPlay) | 非対応(検出して報告) |
| 見開き合成(リフロー 2 段組 / FXL 見開き) | 未実装(ホスト側で合成可) |

## 動作環境

macOS 14+ / Swift 6(strict concurrency)/ Apple Silicon・Intel 両対応の
ソースだが、cooViewer 同梱ビルドは arm64 のみ。

## 組み込みの注意(オフスクリーン WebKit)

- `EPUBPaginationCensus`(全文ページ数の実測)・`EPUBScreenThumbnailRenderer`・
  `EPUBPageRasterizer`・`EPUBScreenAtlas` は、それぞれ不可視の
  NSWindow + WebContent プロセスを持つ。**使い終えたら `invalidate()` を呼ぶ**
  (アトラスをキャッシュから追い出すときも)。`EPUBReaderView` は
  ウインドウから外れた時点で自分のオフスクリーンを自動で畳む
- オフスクリーン系 API は **`.userInitiated` 以上の優先度で呼ぶ**こと。
  低 QoS(`.utility` 等)を継いだまま最初の JS 実行を発行すると、WebKit の
  応答が返らず永久待ちになる(実測)
- 表示・計測系(Rendering/)は全て `@MainActor`。GUI セッションのないデーモン
  からは解析層(`EPUBPublication` ほか)だけを使う

## 開発体制

このリポジトリは [cooViewer](https://github.com/shunnag/cooViewer) モノレポ内の
`Washi/` ディレクトリから `git subtree split` で切り出した片方向ミラー。
開発はモノレポ側で行われ、リリースのたびにここへ反映される。
Issue / PR は歓迎するが、取り込みはモノレポ側で行った上でミラーに現れる。

## ライセンス

MIT License(LICENSE を参照)。依存パッケージはない。
設計にあたり Readium CSS・Bibi(いずれも実装は独立)の公開知見を参考にした。
