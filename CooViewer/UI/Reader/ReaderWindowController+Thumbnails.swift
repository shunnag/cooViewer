import AppKit

/// サムネイルオーバーレイとリーダーの配線(仕様書 §4.8)。
/// 表示・非表示の切替と、表示中のページ送りキーの転用を担う。
/// EN: Wires the in-window thumbnail overlay to the reader.
extension ReaderWindowController {
    /// サムネイルオーバーレイのトグル。本が無ければ何もしない
    func showThumbnail() {
        guard let book else { return }
        if isThumbnailOverlayVisible {
            hideThumbnailOverlay()
            return
        }
        presentThumbnailOverlay(for: book)
        thumbnailHostingView?.isHidden = false
    }

    /// オーバーレイの内容を book で組み直す(表示中の本の切替時にも使う)
    func presentThumbnailOverlay(for book: Book) {
        thumbnailOverlayModel.onJump = { [weak self, weak book] index in
            // 本の入替の最中(オーバーレイがまだ旧 Book の内容のうち)は
            // クリックを無視する。入替完了時に openBookFlow 側が新しい本で
            // 一覧を組み直すので、そこで正しいジャンプができるようになる
            // EN: Ignore clicks while the reader is switching books (the overlay
            // EN: still shows the old book); the open flow rebuilds it right after.
            guard let self, let book, book === self.book else { return }
            self.hideThumbnailOverlay()
            book.goTo(index: index)
            self.refreshAfterJump()
        }
        thumbnailOverlayModel.onClose = { [weak self] in
            self?.hideThumbnailOverlay()
        }
        thumbnailOverlayModel.present(book: book,
                                      displayedIndices: lastSpreadIndices)
    }

    func hideThumbnailOverlay() {
        thumbnailHostingView?.isHidden = true
        // 閉じた後のサムネイル先読みはページ表示と帯域を奪い合うだけなので止める
        // EN: Stop the overlay prefetch; it would only compete with page loads.
        thumbnailOverlayModel.pausePrefetch()
    }

    var isThumbnailOverlayVisible: Bool {
        thumbnailHostingView?.isHidden == false
    }

    /// オーバーレイ表示中のページ送りキーはサムネイル画面の送りに転用する
    /// (旧来のページ単位閲覧 §4.8)
    /// EN: While the overlay is visible, page-turn keys move thumbnail screens.
    func thumbnailOverlayTurnPage(forward: Bool) {
        thumbnailOverlayModel.moveScreen(by: forward ? 1 : -1)
    }

    @objc func showThumbnailsMenu(_ sender: Any?) {
        showThumbnail()
    }
}
