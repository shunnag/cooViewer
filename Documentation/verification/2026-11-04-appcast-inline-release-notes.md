# Sparkle のリリースノートを feed 内の HTML に移行

## 症状と対象

更新ウインドウのリリースノート欄に次のエラーが表示される。

> The release notes is improperly signed and could not be validated.

影響を受けるインストール済みの版は **2.0b50〜2.0b54**。
2.0b50 から `CooViewer/Info.plist` の `SURequireSignedFeed=YES` が有効になっている。
appcast の全 item が、個別の EdDSA 署名を持たない GitHub のリリースページを
`sparkle:releaseNotesLink` に指定していた。

## 原因と Sparkle 2.10.1 の根拠

- [`SUHost.m` の `requiresSignedAppcast`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUHost.m#L209-L212)
  は `SURequireSignedFeed` の値を返す。
- [`SPUUIBasedUpdateDriver.m` のリリースノート検証](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUUIBasedUpdateDriver.m#L83-L100)
  は、この値が真ならダウンロードしたノートの生データを `SUSignatureVerifier` に渡す。
  feed の署名が正しくても、リンク先のノートの署名検証は別に必要になる。
- [`Autoupdate/SUSignatureVerifier.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Autoupdate/SUSignatureVerifier.m#L137-L147)
  は、アプリに EdDSA 公開鍵があり、ノートに署名が無い場合に拒否する。
  `fileKind` がノートの場合、理由には `no EdDSA signature in the release notes` が含まれる。
- [`SUAppcastItem.m` のノート URL 選択](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SUAppcastItem.m#L770-L821)
  と [ダウンロード開始条件](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUUIBasedUpdateDriver.m#L307-L322)
  により、`releaseNotesLink` とインラインの `<description>` が両方あればリンク先が優先される。
  本文を追加するだけでは直らない。

GitHub のリリースページは動的に生成される HTML であり、本文を編集しなくても GitHub 側の
変更や応答条件でバイト列が変わる。受信する全バイト列を固定して署名することができないため、
この URL に対して有効な EdDSA 署名を安定して付ける運用は成立しない。

## 修正

`Scripts/make-appcast.sh` は公開済みの GitHub リリース本文を取得し、
[GitHub Markdown API](https://docs.github.com/en/rest/markdown/markdown#render-a-markdown-document)
で GFM から HTML に変換して `<description><![CDATA[...]]></description>` に埋め込む。
インラインの本文は feed 全体の署名で保護される。リリースが未公開・本文が空なら処理を止める。
公開順序は **GitHub リリース公開 → make-appcast.sh** とする。

`releaseNotesLink` は全 item から取り除き、同じ URL の `fullReleaseNotesLink` に置き換える。
`<link>` も残す。`fullReleaseNotesLink` はブラウザで開くリンクであり、ノートとしての
ダウンロード・個別署名検証の対象にならない。本文の末尾にも「GitHub のリリースページ」を置く。
更新ウインドウが表示するのは選ばれた最新 item のノートだけなので、既存本文の補完は 2.0b54 に限る。

macOS 26 の Sparkle の Markdown 表示では GFM の表が欠落するため、既定の HTML 形式を使う。
GitHub 独自の `<markdown-accessiblity-table>` だけを取り除き、内側の `<table>` は保持する。
表の罫線・余白、コードの読みやすさ、ダークモード対応は小さなインラインの `<style>` にまとめる。
署名必須の feed では外部読み込みが遮断されるため、外部 CSS 等には依存しない。
本文は `<style>` から始め、URL と誤認される形にしない。CDATA 終端も安全に処理する。

`--notes-html <version> [notes.md]` は署名せずに HTML を標準出力へ出す。
任意の Markdown ファイルで本文取得を差し替えられる(通常実行では第 4 引数)。
ファイル指定時も HTML 変換には GitHub API 接続が必要。
長い本文と item は一時ファイル経由で受け渡す。
通常実行の順序は item 挿入 → XML 検査 → `sign_update appcast.xml` →
`sign_update --verify appcast.xml`。XML 検査は `xmllint --noout`、無ければ Python の XML パーサーを使う。
CI にも、`sparkle:edSignature` が無い `releaseNotesLink` を拒否する検査を加える。

## この作業環境の制約

サンドボックスからの `gh release view v2.0b54 -R shunnag/cooViewer --json body -q .body` は
`error connecting to api.github.com` で失敗した。公開本文を取得できなかったため、2.0b54 の
`<description>` は明示的な仮置き。所有者がネットワークへ接続できる環境で次を実行し、
仮置きを生成した HTML に差し替えてから feed を再署名する。

```sh
Scripts/make-appcast.sh --notes-html 2.0b54 > /tmp/cooviewer-2.0b54-notes.html
```

このデータ編集では **再署名していない**。先頭の署名警告コメントと末尾の既存署名コメントは
保持するが、内容を変更したため既存の feed 署名は無効。公開前に所有者のキーチェーンで再署名が必要。
実際の更新ウインドウの確認結果と署名検証結果は、下の表に所有者が記入する。

## ローカル検証

`zsh -n Scripts/make-appcast.sh`、`xmllint --noout appcast.xml`、`git diff --check` は成功。
全 53 item に `fullReleaseNotesLink` が 1 件ずつあり、`releaseNotesLink` は 0 件、
item 内の description は 2.0b54 の 1 件だけであることを確認した。
リンク要素の置換と description の追記以外は、署名コメントも含めて元データとバイト単位で一致する。

一時ディレクトリ内で GitHub API と署名ツールをモックに差し替え、HTML 出力の表・コード・
独自タグ除去・CDATA・明暗 CSS・リンクと、1 MB を超える本文の受け渡しを確認した。
未公開リリース・空本文・API 失敗を拒否し、不正な XML では feed の署名に進まない。
通常実行の署名・検証の順序と、xmllint 不在時の Python 検査への切り替えも成功。
CI の実際のステップを一時コピーに対して実行し、新 appcast の受理、未署名リンクの拒否、
署名属性のある複数行リンクの受理、従来の署名コメント欠落チェックの維持を確認した。
これらのモック検証は公開本文の取得や実際の署名検証・画面確認の代わりにはならない。

## 所有者による最終検証

| 項目 | 手順・期待結果 | 結果 | 実施日・環境 |
| --- | --- | --- | --- |
| feed 署名検証 | 本文差し替え後に `Frameworks/Sparkle-dist/bin/sign_update appcast.xml`、続いて同コマンドの `--verify appcast.xml` が成功 | 成功(feed length 49,982) | 2026-11-04 M4 Max |
| xmllint | 最終の `appcast.xml` に `xmllint --noout appcast.xml` が成功 | 成功。item 53 件、`releaseNotesLink` 0 件、`fullReleaseNotesLink` 53 件、item の `<description>` は 2.0b54 の 1 件 | 2026-11-04 M4 Max |
| 実更新ウインドウ | 2.0b50〜2.0b53 から 2.0b54 の更新を確認し、署名エラーが消えて表・コード・日英の本文が表示される。明暗両方と GitHub リンクのブラウザ起動も確認 | 公開中の 2.0b53 を `SUFeedURL`(user defaults)で署名済みの新 feed(localhost 配信)へ向けて起動。自動確認で「2.0b54 が入手できます」が開き、署名エラーは出ずに本文(冒頭・793 さんへ・同梱・1.x に戻す場合)を表示。ダークモードで可読。表の行とライトモード、リンクのブラウザ起動は未確認(スクロール操作が効かず) | 2026-11-04 Mac mini M4(macOS 27.2、ダーク) |
