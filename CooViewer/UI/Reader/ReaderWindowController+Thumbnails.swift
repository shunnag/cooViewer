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
            self?.hideThumbnailOverlay()
            book?.goTo(index: index)
            self?.refreshAfterJump()
        }
        thumbnailOverlayModel.onClose = { [weak self] in
            self?.hideThumbnailOverlay()
        }
        thumbnailOverlayModel.present(book: book,
                                      displayedIndices: lastSpreadIndices)
    }

    func hideThumbnailOverlay() {
        thumbnailHostingView?.isHidden = true
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
