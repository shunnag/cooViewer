import Foundation

/// メディアオーバーレイ(SMIL)再生の公開 API と、コントローラが使う内部フック。
/// 再生・一時停止・停止と、テキストのハイライト/ページ追従を仲介する
extension EPUBReaderView {
    /// media:active-class の既定(本が宣言していないとき)
    private static let defaultActiveClass = "-epub-media-overlay-active"

    /// 現在の spine 項目がメディアオーバーレイ(音声同期)を持つか
    public var hasMediaOverlayForCurrentItem: Bool {
        publication?.mediaOverlay(forSpineIndex: currentSpineIndex) != nil
    }

    /// この本のどこかにメディアオーバーレイがあるか
    public var hasMediaOverlays: Bool {
        publication?.hasMediaOverlays ?? false
    }

    /// メディアオーバーレイを再生中か
    public var isPlayingMediaOverlay: Bool {
        mediaOverlayController?.isPlaying ?? false
    }

    /// メディアオーバーレイの再生を開始/再開する。現在の項目が音声を持たない
    /// ときは何もしない。項目末尾では次の音声付き項目へ連続再生する
    public func playMediaOverlay() {
        guard let publication, hasMediaOverlayForCurrentItem else { return }
        if let controller = mediaOverlayController {
            if controller.isPlaying { return }
            // 一時停止後に別の章へ移動していたら、その章の先頭から始め直す
            // (古い章の音声を再開しない)
            if controller.spineIndex == currentSpineIndex {
                controller.resume()
            } else {
                controller.play(fromSpineIndex: currentSpineIndex)
            }
            return
        }
        let activeClass = publication.metadata.mediaOverlayActiveClass
            ?? Self.defaultActiveClass
        let controller = MediaOverlayController(
            reader: self, publication: publication, activeClass: activeClass)
        mediaOverlayController = controller
        controller.play(fromSpineIndex: currentSpineIndex)
    }

    /// 一時停止(ハイライトは残す)
    public func pauseMediaOverlay() {
        mediaOverlayController?.pause()
    }

    /// 停止してハイライトを消す
    public func stopMediaOverlay() {
        mediaOverlayController?.stop()
    }

    /// 再生⇔一時停止のトグル
    public func toggleMediaOverlayPlayback() {
        if isPlayingMediaOverlay { pauseMediaOverlay() } else { playMediaOverlay() }
    }

    // MARK: - コントローラ用の内部フック

    /// 指定断片へハイライトを移し、必要ならそのページへめくる(id=nil で解除)
    func mediaOverlayHighlight(fragmentID: String?, cssClass: String) {
        let cls = cssClass
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let idArg: String
        if let fragmentID {
            let escaped = fragmentID
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            idArg = "'\(escaped)'"
        } else {
            idArg = "null"
        }
        evaluateWashi("__washi.mediaOverlayHighlight(\(idArg), '\(cls)');")
    }

    /// 連続再生で次の項目へ移動する(先頭から表示)
    func navigateForMediaOverlay(toSpineIndex index: Int) {
        guard let publication,
              publication.readingOrder.indices.contains(index) else { return }
        goToContainerPath(publication.readingOrder[index].containerPath,
                          fragment: nil)
    }

    /// 再生状態の変化を delegate へ通知
    func mediaOverlayPlayingChanged(_ isPlaying: Bool) {
        delegate?.readerView(self, isPlayingMediaOverlayDidChange: isPlaying)
    }

    /// 本の末尾まで再生し終えた
    func mediaOverlayDidFinish() {
        delegate?.readerViewMediaOverlayDidFinish(self)
    }
}
